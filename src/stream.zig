//! Chunked message reader and writer over `connection.WebSocket`.
//!
//! `MessageReader` yields one borrowed payload chunk per data frame and marks
//! the message boundary with `Chunk.fin`. Control frames may interleave: pings
//! and pongs arrive as `Event.control` when the connection delivers them, while
//! automatic pong and close replies stay in the connection. A close aborts the
//! in-progress message and is terminal at this layer even when `auto_close` is
//! off, because a message stream cannot continue past a close.
//!
//! `MessageWriter` queues one frame per chunk through
//! `connection.WebSocket.enqueue_frame`, so each chunk observes the watermark
//! policy; `flush` is the only drain point. Writer state advances only after a
//! queue succeeds, so a `WouldBlock` or `QueueFull` chunk can be retried after
//! `flush`. There is no stream-level abort: abandoning a partial message
//! requires `reset_tx` and discarding the transport.
//!
//! Text is validated incrementally across frames and chunks; binary bypasses
//! UTF-8. A first text or binary frame with RSV1 marks the whole message
//! compressed, so UTF-8 validation is deferred for every continuation until the
//! extension layer inflates and validates it. `Chunk.rsv1` identifies the frame
//! that carried the bit, and `MessageWriter.write_with_options` sets it only on
//! a first frame. Nothing here allocates, copies a whole message, or opens I/O.
//! `ReaderState` and `WriterState` are pure and can drive split halves later.
//! The data-ordering rules mirror `Fragments.accumulate`; if the two diverge,
//! extract a shared pure state in a follow-up rather than editing
//! `src/fragment.zig` here.
//! Compression itself belongs at the edge: the stream exposes RSV1 and the
//! compressed-message state, while the caller composes `deflate.zig`.

const std = @import("std");
const errors = @import("error.zig");
const frame = @import("frame.zig");
const utf8 = @import("utf8.zig");
const connection = @import("connection.zig");

/// RFC 6455 opcode alias from the frame facade.
pub const OpCode = frame.OpCode;

/// Frame record with caller-owned payload bytes.
pub const Frame = frame.Frame;

/// Connection error set; the stream layer adds no new error names.
pub const Error = connection.Error;

/// Text or binary message kind.
pub const MessageKind = enum { text, binary };

/// One borrowed payload chunk from a data frame.
pub const Chunk = struct {
    /// Text or binary message kind; continuation frames report the message kind.
    kind: MessageKind,
    /// True exactly when this chunk ends the message.
    fin: bool,
    /// True only when this frame carried RSV1; continuation chunks report false.
    rsv1: bool,
    /// Borrowed from `connection.WebSocket.frame_buffer`; valid until the next
    /// `MessageReader.next` call. Never written by this module.
    payload: []const u8,
};

/// One read event.
pub const Event = union(enum) {
    chunk: Chunk,
    /// Ping or pong delivered by the connection (for example when `auto_pong`
    /// is off or a client cannot produce a conforming reply). Message state is
    /// unchanged. The payload borrows `frame_buffer` until the next `next`; a
    /// control payload may still be masked when `auto_apply_mask` is off.
    control: Frame,
    /// Peer close, already validated and echoed by the connection when policy
    /// allows. Aborts the in-progress message and makes the reader terminal.
    /// The payload borrows `frame_buffer` until the next `next`.
    close: Frame,
};

/// Pure per-message read state. Drives no I/O and can be reused by split.
pub const ReaderState = struct {
    kind: ?MessageKind = null,
    compressed: bool = false,
    utf8_state: utf8.State = .{},

    pub fn init() ReaderState {
        return .{};
    }

    pub fn reset(self: *ReaderState) void {
        self.* = .{};
    }

    pub fn is_idle(self: *const ReaderState) bool {
        return self.kind == null;
    }

    pub fn message_kind(self: *const ReaderState) ?MessageKind {
        return self.kind;
    }

    pub fn is_compressed(self: *const ReaderState) bool {
        return self.compressed;
    }

    /// Consumes one data frame (`text`, `binary`, or `continuation`).
    ///
    /// Control frames are the wrapper's responsibility. The transition commits
    /// only after every check succeeds, so a rejected frame leaves the previous
    /// message state untouched. RSV1 on the first text or binary frame marks
    /// the whole message compressed, so UTF-8 validation is deferred until
    /// after inflate for every chunk, including continuations without RSV1.
    pub fn accept(self: *ReaderState, incoming: Frame) Error!Chunk {
        if (incoming.masking_key != null) return error.PayloadMasked;
        if (incoming.opcode == .continuation and incoming.rsv1) return error.ProtocolError;

        const kind: MessageKind = switch (incoming.opcode) {
            .text, .binary => started: {
                if (self.kind != null) return error.InvalidFragment;
                break :started if (incoming.opcode == .text) .text else .binary;
            },
            .continuation => self.kind orelse return error.InvalidContinuationFrame,
            else => return error.InvalidFragment,
        };
        const compressed = switch (incoming.opcode) {
            .text, .binary => incoming.rsv1,
            else => self.compressed,
        };

        const next_utf8 = try self.validate(kind, incoming.payload, incoming.fin, compressed);
        if (incoming.fin) {
            self.reset();
        } else {
            self.kind = kind;
            self.compressed = compressed;
            self.utf8_state = next_utf8;
        }
        return .{
            .kind = kind,
            .fin = incoming.fin,
            .rsv1 = incoming.rsv1,
            .payload = incoming.payload,
        };
    }

    fn validate(
        self: *const ReaderState,
        kind: MessageKind,
        payload: []const u8,
        fin: bool,
        compressed: bool,
    ) Error!utf8.State {
        if (kind == .binary or compressed) return self.utf8_state;

        const next = utf8.State.feed(self.utf8_state, payload) catch |err| return errors.from_zslay(err);
        if (fin) next.finish() catch |err| return errors.from_zslay(err);
        return next;
    }
};

/// Chunked reader over one connection.
pub const MessageReader = struct {
    ws: *connection.WebSocket,
    state: ReaderState = .{},
    failure: ?Error = null,
    closed: bool = false,

    pub fn init(ws: *connection.WebSocket) MessageReader {
        return .{ .ws = ws };
    }

    /// Returns one chunk, control frame, or close.
    ///
    /// Errors are returned and latched until `reset`, except `ConnectionClosed`
    /// and the zero-maximum configuration rejection. The in-progress message is
    /// aborted on every error and on a close.
    pub fn next(self: *MessageReader) Error!Event {
        if (self.failure) |failure| return failure;
        if (self.closed) return error.ConnectionClosed;

        const incoming = self.ws.read_frame() catch |err| {
            self.state.reset();
            if (latch_read_error(err, self.ws)) {
                if (self.ws.is_closed()) self.closed = true;
                self.failure = err;
            }
            return err;
        };

        switch (incoming.opcode) {
            .close => {
                self.state.reset();
                self.closed = true;
                if (incoming.masking_key != null) {
                    self.failure = error.PayloadMasked;
                    return error.PayloadMasked;
                }
                return .{ .close = incoming };
            },
            .ping, .pong => return .{ .control = incoming },
            .text, .binary, .continuation => {
                const chunk = self.state.accept(incoming) catch |err| {
                    self.state.reset();
                    self.failure = err;
                    return err;
                };
                return .{ .chunk = chunk };
            },
            else => {
                self.state.reset();
                self.failure = error.InvalidOpcode;
                return error.InvalidOpcode;
            },
        }
    }

    pub fn is_idle(self: *const MessageReader) bool {
        return self.state.is_idle();
    }

    pub fn message_kind(self: *const MessageReader) ?MessageKind {
        return self.state.message_kind();
    }

    /// True while the in-progress message was started with RSV1.
    ///
    /// A completed single-frame message resets the state before returning, so
    /// adapters should also inspect `Chunk.rsv1` on the delivered chunk.
    pub fn is_compressed(self: *const MessageReader) bool {
        return self.state.is_compressed();
    }

    /// True after a delivered close, a rejected close frame, or an error that
    /// also closed the connection. A latched failure that leaves the connection
    /// open is terminal even when this is false.
    pub fn is_closed(self: *const MessageReader) bool {
        return self.closed;
    }

    /// Clears the stream latch, the message state, and `ws.reset()`.
    ///
    /// A terminal close is deliberately not cleared. Safe only at a wire
    /// boundary or when the transport is discarded.
    pub fn reset(self: *MessageReader) void {
        self.failure = null;
        self.state.reset();
        self.ws.reset();
    }
};

/// Pure frame-shape decision for the next writer chunk.
pub const FrameSpec = struct {
    opcode: OpCode,
    fin: bool,
};

/// Per-chunk writer options for negotiated frame extensions.
pub const WriteOptions = struct {
    /// Set only on the first frame of a compressed message.
    rsv1: bool = false,
};

/// Pure per-message write state. Can be driven by split later.
pub const WriterState = struct {
    kind: MessageKind,
    started: bool = false,
    finished: bool = false,

    pub fn init(kind: MessageKind) WriterState {
        return .{ .kind = kind };
    }

    pub fn is_started(self: *const WriterState) bool {
        return self.started;
    }

    pub fn is_finished(self: *const WriterState) bool {
        return self.finished;
    }

    pub fn message_kind(self: *const WriterState) MessageKind {
        return self.kind;
    }

    /// Returns the next frame shape without mutating.
    ///
    /// Returns `error.InvalidFragment` after a FIN frame was queued; a caller
    /// needs a new writer for the next message.
    pub fn spec(self: *const WriterState, fin: bool) Error!FrameSpec {
        if (self.finished) return error.InvalidFragment;
        return .{ .opcode = self.next_opcode(), .fin = fin };
    }

    /// Commits a frame only after it was successfully queued.
    pub fn note_queued(self: *WriterState, queued: FrameSpec) void {
        std.debug.assert(!self.finished);
        std.debug.assert(queued.opcode == self.next_opcode());

        self.started = true;
        if (queued.fin) self.finished = true;
    }

    /// Returns to a fresh, unstarted message with the same kind.
    ///
    /// This does not touch zslay's transmit state, so it must not be used to
    /// abandon a partial message that was already committed.
    pub fn reset(self: *WriterState) void {
        self.started = false;
        self.finished = false;
    }

    fn next_opcode(self: *const WriterState) OpCode {
        if (self.started) return .continuation;
        return switch (self.kind) {
            .text => .text,
            .binary => .binary,
        };
    }
};

/// Chunked writer over one connection.
///
/// A finished message needs a new `MessageWriter`; there is no writer reset.
pub const MessageWriter = struct {
    ws: *connection.WebSocket,
    state: WriterState,
    empty: [0]u8 = .{},

    pub fn init(ws: *connection.WebSocket, kind: MessageKind) MessageWriter {
        return .{ .ws = ws, .state = WriterState.init(kind) };
    }

    /// Queues one chunk without draining.
    ///
    /// `payload` must be mutable, caller-owned, unmodified until `flush`, and
    /// disjoint from connection read and write storage. On any error the writer
    /// state is unchanged; a `WouldBlock` or `QueueFull` chunk may be retried
    /// after `flush`. Outbound text is not UTF-8 validated, matching
    /// `connection.write_frame` and zslay. This strict wrapper never sets RSV1.
    pub fn write(self: *MessageWriter, payload: []u8, fin: bool) Error!void {
        return self.write_with_options(payload, fin, .{});
    }

    /// Queues one chunk with explicit negotiated frame options.
    ///
    /// `options.rsv1` is valid only on the first frame; zslay rejects it on a
    /// continuation. The writer state advances only after a successful queue.
    pub fn write_with_options(
        self: *MessageWriter,
        payload: []u8,
        fin: bool,
        options: WriteOptions,
    ) Error!void {
        const next = try self.state.spec(fin);
        try self.ws.enqueue_frame(Frame.init_rsv1(
            next.fin,
            next.opcode,
            options.rsv1,
            null,
            payload,
        ));
        self.state.note_queued(next);
    }

    /// Queues an empty FIN continuation, or an empty FIN first frame when no
    /// chunk was written. The strict convenience path never sets RSV1; use
    /// `write_with_options` for a compressed empty message.
    pub fn finish(self: *MessageWriter) Error!void {
        try self.write(self.empty[0..], true);
    }

    /// Drains queued frames and flushes the caller's `std.Io.Writer`.
    pub fn flush(self: *MessageWriter) Error!void {
        return self.ws.flush();
    }

    pub fn is_started(self: *const MessageWriter) bool {
        return self.state.is_started();
    }

    pub fn is_finished(self: *const MessageWriter) bool {
        return self.state.is_finished();
    }
};

/// Zero-max is a configuration rejection, not a latched wire failure.
fn latch_read_error(err: Error, ws: *const connection.WebSocket) bool {
    if (err == error.ConnectionClosed) return false;
    if (err == error.FrameTooLarge and ws.max_message_size() == 0) return false;
    return true;
}
