//! Split WebSocket halves over `src/connection.zig`.
//!
//! `zslay.Conn` couples receive and transmit state, so a split pair owns one
//! `connection.WebSocket` per half. The read half is driven only through
//! `read_event`; the write half only through `write_frame` and `flush`. Both
//! halves may borrow the same external reader and writer because each uses one
//! direction. Nothing here allocates, opens a socket, or spawns a task.
//!
//! All storage is caller-owned and must outlive the split pair. Returned
//! payloads borrow the read half's `frame_buffer`, its `close_buffer`, or the
//! collector's `message_buffer` until the next read. Automatic pong and close
//! replies are handed to the write half through `send_obligation`, which writes
//! and flushes before the read call returns, matching the unsplit connection.
//! The write half may carry the optional watermark policy; reads are paced by
//! the caller, so outbound pressure never blocks a peer close from arriving.
//! A validated (clear) close under `auto_close` is terminal: the read half and
//! any shared split pair gate later non-close reads and writes. With
//! `auto_close` off, or for a masked close delivered unvalidated when
//! `auto_apply_mask` is off, the close is returned without setting `closed`,
//! matching unsplit parity.

const std = @import("std");
const zslay = @import("zslay");
const connection = @import("connection.zig");
const fragment = @import("fragment.zig");

/// Local endpoint role, re-exported from the connection layer.
pub const Role = connection.Role;

/// RFC 6455 opcode alias from the connection layer.
pub const OpCode = connection.OpCode;

/// Close status alias from the connection layer.
pub const CloseCode = connection.CloseCode;

/// Four-byte masking key alias from the connection layer.
pub const MaskingKey = connection.MaskingKey;

/// Frame record with caller-owned payload bytes.
pub const Frame = connection.Frame;

/// Split-half error set, shared with the unsplit connection.
pub const Error = connection.Error;

/// fastwebsockets-compatible policy options.
pub const Options = connection.Options;

/// Construction-time role, options, and client mask source.
pub const Config = connection.Config;

/// Read-half caller storage. The slices must outlive the read half and must not
/// overlap one another.
pub const ReadStorage = struct {
    /// Bounds one inbound frame payload. A payload that fits the configured
    /// limit but not this buffer fails closed with `error.BufferTooShort` after
    /// its header is consumed.
    frame_buffer: []u8,
    /// Holds a synthesized 1002 close payload. At least two bytes are required;
    /// 125 bytes preserve any valid close reason.
    close_buffer: []u8,
    /// Required by the connection constructor but never written by the read
    /// path. It must be longer than `zslay.MaxFrameHeaderLen`.
    compose_buffer: []u8,
};

/// Write-half caller storage, matching `connection.Storage` without the inbound
/// `frame_buffer`. The slices must outlive the write half and must not overlap
/// one another.
pub const WriteStorage = struct {
    /// Bounded zslay transmit queue. Automatic pong and close replies need at
    /// least one node; an empty slice is allowed only when both are disabled.
    tx_nodes: []zslay.FrameNode,
    /// Composes copied writes. It must be longer than
    /// `zslay.MaxFrameHeaderLen`.
    write_buffer: []u8,
    /// Dedicated close payload storage required by the connection constructor.
    /// At least two bytes are required.
    close_buffer: []u8,
    /// Optional masking scratch for vectored masked writes. An empty slice
    /// falls back to the copied path.
    mask_scratch: []u8 = &.{},
};

/// Combined caller-owned storage for both halves.
///
/// Regions owned by different halves must not overlap: a read reply borrows
/// read storage while the write half queues and drains it, and the write half
/// rejects outbound payloads that alias its own storage. `after_handshake_split`
/// rejects cross-half aliasing with `InvalidLength`.
pub const Storage = struct {
    read: ReadStorage,
    write: WriteStorage,

    /// True when `bytes` overlaps any read or write region in this storage.
    ///
    /// Native adapters use this to keep caller-provided `std.Io` buffers
    /// disjoint from every region without duplicating the storage layout.
    pub fn overlaps(self: Storage, bytes: []const u8) bool {
        const tx_bytes: []const u8 = std.mem.sliceAsBytes(self.write.tx_nodes);
        const regions = [_][]const u8{
            self.read.frame_buffer,
            self.read.close_buffer,
            self.read.compose_buffer,
            tx_bytes,
            self.write.write_buffer,
            self.write.close_buffer,
            self.write.mask_scratch,
        };

        for (regions) |region| {
            if (zslay.event.ranges_overlap(
                @intFromPtr(bytes.ptr),
                bytes.len,
                @intFromPtr(region.ptr),
                region.len,
            )) return true;
        }
        return false;
    }
};

/// Raw read half over its own receive connection.
///
/// The half never writes and never advances its client mask source. A client
/// still supplies `config.mask_keys` because `connection.WebSocket.init`
/// enforces that rule; the source is only consumed by the write half.
pub const WebSocketRead = struct {
    /// Connection policy state with the requested automatic reply flags.
    inner: connection.WebSocket,

    /// Builds a read half over caller-owned reader, writer, and storage.
    ///
    /// The temporary connection is initialized with automatic close and pong
    /// replies disabled so an empty transmit queue is accepted. Both flags are
    /// restored from `config.options` after init; replies then travel through
    /// the write half supplied to `read_frame`.
    pub fn init(
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
        storage: ReadStorage,
        config: Config,
    ) Error!WebSocketRead {
        var options = config.options;
        options.auto_close = false;
        options.auto_pong = false;
        // The read half has no transmit ring. Backpressure belongs to the
        // write half and never gates this read path.
        options.backpressure = null;

        var inner = try connection.WebSocket.init(reader, writer, .{
            .frame_buffer = storage.frame_buffer,
            .tx_nodes = &.{},
            .write_buffer = storage.compose_buffer,
            .close_buffer = storage.close_buffer,
            .mask_scratch = &.{},
        }, .{
            .role = config.role,
            .options = options,
            .mask_keys = config.mask_keys,
        });

        inner.options.auto_close = config.options.auto_close;
        inner.options.auto_pong = config.options.auto_pong;
        return .{ .inner = inner };
    }

    /// Reads one raw frame, forwarding automatic replies to `sink`.
    ///
    /// `sink` must expose `send_obligation(Frame) Error!void`, `is_closed() bool`,
    /// and `failure() ?Error`. A sink obligation must complete or return a
    /// terminal error; a `WouldBlock` result after the frame was consumed is
    /// converted to `SendError` and latched because the reply cannot be
    /// recovered by retrying. The read half's latch is checked first, then the
    /// sink's write failure latch. A reply is sent even when `read_event`
    /// reports a close or protocol error, so a 1002 reply is not lost; a send
    /// failure wins over the original read error. A send failure that emits no
    /// bytes and leaves the sink's latch unset becomes a read failure, while a
    /// transport failure keeps the sink's write latch authoritative. A
    /// validated (clear) close returned under `auto_close` marks the read half
    /// closed even with an external sink, so later split calls gate. Non-close
    /// frames are refused once either half is closed, including a close whose
    /// reply was suppressed on a client that cannot mask.
    pub fn read_frame(self: *WebSocketRead, sink: anytype) Error!Frame {
        if (self.inner.read_failure) |failure| return failure;
        if (sink.failure()) |failure| return failure;

        // Each iteration consumes one wire frame or returns; a peer that only
        // sends pings keeps the loop alive, so the transport owns termination.
        while (true) {
            var reply: ?Frame = null;
            const event = self.inner.read_event(self.read_closed(sink), &reply);

            // Send before propagating the read error: an invalid close still
            // needs its 1002 reply, and a send failure is the terminal error.
            // A prepare or queue failure emits nothing and becomes a read
            // failure; a transport failure is owned by the sink's write latch.
            if (reply) |outgoing| {
                sink.send_obligation(outgoing) catch |raw_err| {
                    // The frame has already been consumed, so a retryable sink
                    // result cannot recover the pong or close reply. Treat it
                    // as a terminal send failure instead of silently dropping
                    // the obligation.
                    const err = if (raw_err == error.WouldBlock) error.SendError else raw_err;
                    if (err != error.ConnectionClosed and sink.failure() == null) {
                        self.inner.read_failure = err;
                    }
                    return err;
                };
                // A close reply, including a 1002, is terminal even when the
                // sink is external and owns the write side.
                if (outgoing.opcode == .close) self.inner.closed = true;
            }

            const incoming = event catch |err| {
                // read_event defers the latch while a reply is pending; the
                // reply is on the wire now, so latch the originating error.
                // A failed send returned above and leaves the read latch alone.
                if (reply != null and err != error.ConnectionClosed and sink.failure() == null) {
                    self.inner.read_failure = err;
                }
                return err;
            };
            if (incoming) |outgoing| {
                if (self.read_closed(sink) and outgoing.opcode != .close) return error.ConnectionClosed;
                // Record a validated clear close even when the echo went to an
                // external sink, so later split reads and writes gate. A masked
                // close under `auto_apply_mask` off is delivered unvalidated and
                // must not set `closed`.
                if (outgoing.opcode == .close and self.inner.options.auto_close and outgoing.masking_key == null) {
                    self.inner.closed = true;
                }
                return outgoing;
            }
        }
    }

    /// Reads one raw frame using `write` as the reply sink.
    pub fn read_frame_with(self: *WebSocketRead, write: *WebSocketWrite) Error!Frame {
        return self.read_frame(write);
    }

    /// Retained for fastwebsockets read-half parity; it does not affect this
    /// read-only path.
    pub fn set_writev_threshold(self: *WebSocketRead, threshold: usize) void {
        self.inner.set_writev_threshold(threshold);
    }

    /// Enables or disables automatic inbound close validation and echo.
    pub fn set_auto_close(self: *WebSocketRead, enabled: bool) void {
        self.inner.set_auto_close(enabled);
    }

    /// Enables or disables automatic pong replies.
    pub fn set_auto_pong(self: *WebSocketRead, enabled: bool) void {
        self.inner.set_auto_pong(enabled);
    }

    /// Sets the exclusive inbound message limit, clamped by the connection.
    pub fn set_max_message_size(self: *WebSocketRead, max_size: usize) void {
        self.inner.set_max_message_size(max_size);
    }

    /// Controls inbound unmasking. A client with this off cannot produce a
    /// conforming reply, so control frames are delivered instead.
    pub fn set_auto_apply_mask(self: *WebSocketRead, enabled: bool) void {
        self.inner.set_auto_apply_mask(enabled);
    }

    /// Exclusive inbound message limit.
    pub fn max_message_size(self: *const WebSocketRead) usize {
        return self.inner.max_message_size();
    }

    /// True when the next wire byte starts a frame. This is the reset-safety
    /// predicate after a read error.
    pub fn is_at_wire_boundary(self: *const WebSocketRead) bool {
        return self.inner.is_at_wire_boundary();
    }

    /// True when the raw read path is at a frame boundary.
    ///
    /// The raw path does not accumulate fragments, so this equals
    /// `is_at_wire_boundary`; `FragmentCollectorRead` adds the accumulator
    /// check.
    pub fn is_at_frame_boundary(self: *const WebSocketRead) bool {
        return self.inner.is_at_wire_boundary();
    }

    /// Clears the read latch and zslay receive state without clearing a close.
    ///
    /// Safe only when `is_at_wire_boundary()` is true, or when the transport is
    /// discarded; a failed mid-frame read leaves the reader advanced.
    pub fn reset(self: *WebSocketRead) void {
        self.inner.reset();
    }

    /// Local endpoint role.
    pub fn role(self: *const WebSocketRead) Role {
        return self.inner.role();
    }

    /// Caller-owned buffer that bounds one inbound payload.
    pub fn frame_buffer(self: *const WebSocketRead) []u8 {
        return self.inner.frame_buffer;
    }

    /// True when the write sink or this half's suppressed-close state is
    /// terminal.
    fn read_closed(self: *const WebSocketRead, sink: anytype) bool {
        return self.inner.is_closed() or sink.is_closed();
    }
};

/// Raw write half over its own transmit connection.
///
/// The half never reads. `reader` is unused but keeps construction symmetric
/// with the read half and lets both halves share one transport pair.
pub const WebSocketWrite = struct {
    /// Connection policy state used for frame preparation and draining.
    inner: connection.WebSocket,

    /// Builds a write half over caller-owned reader, writer, and storage.
    ///
    /// `config.options.auto_close` and `auto_pong` are accepted for symmetry;
    /// automatic replies only run when `send_obligation` is called by a read
    /// half.
    pub fn init(
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
        storage: WriteStorage,
        config: Config,
    ) Error!WebSocketWrite {
        const inner = try connection.WebSocket.init(reader, writer, .{
            .frame_buffer = &.{},
            .tx_nodes = storage.tx_nodes,
            .write_buffer = storage.write_buffer,
            .close_buffer = storage.close_buffer,
            .mask_scratch = storage.mask_scratch,
        }, config);

        return .{ .inner = inner };
    }

    /// Queues and drains one outbound frame without flushing.
    ///
    /// The payload must be clear and caller-owned. On success it must stay
    /// valid until the call returns; after a partial drain failure the queued
    /// node keeps borrowing it until `reset_tx` or transport discard. The zslay
    /// queue is fully drained into the writer. A close sets the terminal closed
    /// flag, and later non-close writes return `error.ConnectionClosed`.
    /// `error.WouldBlock` reports either the paused phase or a non-empty queue
    /// that cannot fit the frame without crossing a high mark.
    pub fn write_frame(self: *WebSocketWrite, outgoing: Frame) Error!void {
        return self.inner.write_frame(outgoing);
    }

    /// Validates and queues one outbound frame without draining it.
    ///
    /// The payload stays borrowed until `flush`, or until `reset_tx` if the
    /// transport is discarded after a failure. It must not alias the read
    /// `frame_buffer`, reader buffer, or writer buffer, because a later read or
    /// drain can overwrite those regions. A configured watermark policy returns
    /// `error.WouldBlock` for a data frame while backpressured or when the
    /// non-empty queue cannot fit it; application controls other than close stop
    /// at the data capacity so one node stays free for automatic replies.
    pub fn enqueue_frame(self: *WebSocketWrite, outgoing: Frame) Error!void {
        return self.inner.enqueue_frame(outgoing);
    }

    /// Drains queued nodes and flushes the caller's writer.
    pub fn flush(self: *WebSocketWrite) Error!void {
        return self.inner.flush();
    }

    /// Enables or disables vectored writes.
    pub fn set_writev(self: *WebSocketWrite, enabled: bool) void {
        self.inner.set_writev(enabled);
    }

    /// Sets the payload size above which vectored writes are preferred.
    pub fn set_writev_threshold(self: *WebSocketWrite, threshold: usize) void {
        self.inner.set_writev_threshold(threshold);
    }

    /// Controls client outbound masking.
    pub fn set_auto_apply_mask(self: *WebSocketWrite, enabled: bool) void {
        self.inner.set_auto_apply_mask(enabled);
    }

    /// Sets the exclusive outbound message limit, clamped by the connection.
    pub fn set_max_message_size(self: *WebSocketWrite, max_size: usize) void {
        self.inner.set_max_message_size(max_size);
    }

    /// Replaces the client mask-key source. Infallible; the source is copied.
    pub fn set_mask_keys(self: *WebSocketWrite, mask_keys: connection.MaskKeySource) void {
        self.inner.set_mask_keys(mask_keys);
    }

    /// True after a close frame was queued, including a read-half echo.
    pub fn is_closed(self: *const WebSocketWrite) bool {
        return self.inner.is_closed();
    }

    /// Number of queued outbound frames not yet drained.
    pub fn tx_pending(self: *const WebSocketWrite) usize {
        return self.inner.tx_pending();
    }

    /// True while the configured watermark policy is backpressured.
    ///
    /// This is the latched phase only; a write can also return `WouldBlock`
    /// for a non-empty queue that cannot fit the next frame.
    pub fn is_backpressured(self: *const WebSocketWrite) bool {
        return self.inner.is_backpressured();
    }

    /// Payload bytes currently charged to the watermark policy. Zero without a
    /// policy.
    pub fn queued_bytes(self: *const WebSocketWrite) usize {
        return self.inner.queued_bytes();
    }

    /// Frames currently charged to the watermark policy, or zslay `tx_pending`
    /// without a policy.
    pub fn queued_frames(self: *const WebSocketWrite) usize {
        return self.inner.queued_frames();
    }

    /// Local endpoint role.
    pub fn role(self: *const WebSocketWrite) Role {
        return self.inner.role();
    }

    /// Exclusive outbound message limit.
    pub fn max_message_size(self: *const WebSocketWrite) usize {
        return self.inner.max_message_size();
    }

    /// Clears the transmit queue, the write latch, and the closed flag.
    ///
    /// Safe only when the transport is discarded or in a test that never
    /// shipped the partial bytes.
    pub fn reset_tx(self: *WebSocketWrite) void {
        self.inner.reset_tx();
    }

    /// True when the next wire byte starts a frame. The write half never reads,
    /// so this remains true unless the connection was reused for reads.
    pub fn is_at_wire_boundary(self: *const WebSocketWrite) bool {
        return self.inner.is_at_wire_boundary();
    }

    /// Sends an automatic reply and flushes it before returning.
    ///
    /// The reply borrows read-half storage and must stay valid for the call.
    /// This matches the unsplit connection, which never leaves an obligation in
    /// a buffered writer. `send_control` may use the node reserved for automatic
    /// replies; application control frames cannot consume it.
    pub fn send_obligation(self: *WebSocketWrite, outgoing: Frame) Error!void {
        return self.inner.send_control(outgoing);
    }

    /// Latched transmit failure, cleared only by `reset_tx`.
    pub fn failure(self: *const WebSocketWrite) ?Error {
        return self.inner.write_failure;
    }
};

/// Split read and write halves over one transport pair.
///
/// Both halves own independent `zslay.Conn` values, so RX and TX state never
/// interleave. The pair is zero-allocation and borrows caller-owned storage.
pub const Split = struct {
    read: WebSocketRead,
    write: WebSocketWrite,

    /// Reads one raw frame, routing automatic replies through the write half.
    pub fn read_frame(self: *Split) Error!Frame {
        return self.read.read_frame(&self.write);
    }

    /// Reads one raw frame, routing replies through a caller-supplied sink.
    pub fn read_frame_with(self: *Split, sink: anytype) Error!Frame {
        return self.read.read_frame(sink);
    }

    /// Queues and drains one outbound frame without flushing.
    ///
    /// Non-close frames are refused once either half observed a close; a
    /// repeated close frame is still allowed. Payload lifetime and
    /// `error.WouldBlock` follow `WebSocketWrite.write_frame`.
    pub fn write_frame(self: *Split, outgoing: Frame) Error!void {
        if (outgoing.opcode != .close and self.is_closed()) return error.ConnectionClosed;
        return self.write.write_frame(outgoing);
    }

    /// Validates and queues one outbound frame without draining it.
    ///
    /// Non-close frames are refused once either half observed a close. The
    /// payload stays borrowed until `flush`, or until `reset_tx` after a
    /// transport failure, and must not alias read-lifetime buffers.
    pub fn enqueue_frame(self: *Split, outgoing: Frame) Error!void {
        if (outgoing.opcode != .close and self.is_closed()) return error.ConnectionClosed;
        return self.write.enqueue_frame(outgoing);
    }

    /// Drains queued nodes and flushes the caller's writer.
    pub fn flush(self: *Split) Error!void {
        return self.write.flush();
    }

    /// Clears the read latch and zslay receive state. Keeps the closed flag.
    pub fn reset(self: *Split) void {
        self.read.reset();
    }

    /// Clears the transmit queue, the write latch, and the closed flag.
    pub fn reset_tx(self: *Split) void {
        self.write.reset_tx();
    }

    /// True after either half observed a terminal close.
    pub fn is_closed(self: *const Split) bool {
        return self.read.inner.is_closed() or self.write.is_closed();
    }

    /// True while the write half's watermark policy is backpressured.
    ///
    /// This is the latched phase only; a write can also return `WouldBlock`
    /// for a non-empty queue that cannot fit the next frame.
    pub fn is_backpressured(self: *const Split) bool {
        return self.write.is_backpressured();
    }

    /// Payload bytes currently charged to the write half's policy. Zero without
    /// a policy.
    pub fn queued_bytes(self: *const Split) usize {
        return self.write.queued_bytes();
    }

    /// Frames currently charged to the write half's policy, or zslay
    /// `tx_pending` without a policy.
    pub fn queued_frames(self: *const Split) usize {
        return self.write.queued_frames();
    }

    /// Enables or disables vectored writes.
    pub fn set_writev(self: *Split, enabled: bool) void {
        self.write.set_writev(enabled);
    }

    /// Sets the vectored-write payload threshold on both halves.
    pub fn set_writev_threshold(self: *Split, threshold: usize) void {
        self.read.set_writev_threshold(threshold);
        self.write.set_writev_threshold(threshold);
    }

    /// Enables or disables automatic inbound close validation and echo.
    pub fn set_auto_close(self: *Split, enabled: bool) void {
        self.read.set_auto_close(enabled);
    }

    /// Enables or disables automatic pong replies.
    pub fn set_auto_pong(self: *Split, enabled: bool) void {
        self.read.set_auto_pong(enabled);
    }

    /// Controls inbound unmasking and client outbound masking on both halves.
    pub fn set_auto_apply_mask(self: *Split, enabled: bool) void {
        self.read.set_auto_apply_mask(enabled);
        self.write.set_auto_apply_mask(enabled);
    }

    /// Sets the exclusive message limit on both halves.
    pub fn set_max_message_size(self: *Split, max_size: usize) void {
        self.read.set_max_message_size(max_size);
        self.write.set_max_message_size(max_size);
    }

    /// True when the read half is at a frame boundary.
    pub fn is_at_wire_boundary(self: *const Split) bool {
        return self.read.is_at_wire_boundary();
    }
};

/// Builds both halves after a successful handshake.
///
/// Read and write storage are checked for cross-half overlap before either half
/// is constructed. The write half is then built first so a missing transmit
/// queue fails before the read half is constructed. Both halves borrow the same
/// reader and writer pointers and independent copies of `config`, including any
/// client mask source.
pub fn after_handshake_split(
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    storage: Storage,
    config: Config,
) Error!Split {
    try validate_halves(storage);

    const write = try WebSocketWrite.init(reader, writer, storage.write, config);
    const read = try WebSocketRead.init(reader, writer, storage.read, config);
    return .{ .read = read, .write = write };
}

/// Rejects read storage that aliases write storage.
///
/// `connection.validate_storage` checks each half's regions independently; the
/// split pair also needs the cross product because a read reply can borrow read
/// storage while the write half queues or composes from its own storage.
fn validate_halves(storage: Storage) Error!void {
    const read_regions = [_][]const u8{
        storage.read.frame_buffer,
        storage.read.close_buffer,
        storage.read.compose_buffer,
    };
    const write_regions = [_][]const u8{
        std.mem.sliceAsBytes(storage.write.tx_nodes),
        storage.write.write_buffer,
        storage.write.close_buffer,
        storage.write.mask_scratch,
    };

    for (read_regions) |read_region| {
        for (write_regions) |write_region| {
            if (zslay.event.ranges_overlap(
                @intFromPtr(read_region.ptr),
                read_region.len,
                @intFromPtr(write_region.ptr),
                write_region.len,
            )) return error.InvalidLength;
        }
    }
}

/// Alias for `after_handshake_split`.
pub fn init(
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    storage: Storage,
    config: Config,
) Error!Split {
    return after_handshake_split(reader, writer, storage, config);
}

/// Read-side fragment collector over a `WebSocketRead`.
///
/// The collector consumes the read half by value, owns a `Fragments`
/// accumulator over caller-owned `message_buffer`, and routes every automatic
/// reply through the sink supplied to `read_frame`. Completed messages borrow
/// `message_buffer`; control frames and unfragmented messages borrow the read
/// half's `frame_buffer`. Read and accumulation failures latch until `reset`,
/// except `ConnectionClosed`, which is returned without latching so a later
/// peer close stays deliverable, and the zero-maximum configuration rejection,
/// matching the unsplit collector. Nothing here allocates or validates close
/// policy, which stays in the read half.
pub const FragmentCollectorRead = struct {
    read: WebSocketRead,
    fragments: fragment.Fragments,
    /// Latched read or accumulation failure, cleared only by `reset`.
    failure: ?Error = null,

    /// Binds the collector to a read half and caller-owned message storage.
    ///
    /// `message_buffer` bounds one assembled message and must not overlap
    /// `read.frame_buffer`, the read half's `std.Io.Reader` buffer, or its
    /// `std.Io.Writer` buffer, because accumulation copies with `@memcpy` and
    /// reader fills can move bytes between those regions. A zero-length buffer
    /// is allowed and rejects every non-empty message with
    /// `error.BufferTooShort`.
    pub fn init(read: WebSocketRead, message_buffer: []u8) Error!FragmentCollectorRead {
        const frame_buffer = read.frame_buffer();
        const reader_buffer = read.inner.reader.buffer;
        const writer_buffer = read.inner.writer.buffer;
        const byte_regions = [_][]const u8{ frame_buffer, reader_buffer, writer_buffer };

        for (byte_regions) |region| {
            if (zslay.event.ranges_overlap(
                @intFromPtr(message_buffer.ptr),
                message_buffer.len,
                @intFromPtr(region.ptr),
                region.len,
            )) return error.InvalidLength;
        }

        return .{
            .read = read,
            .fragments = fragment.Fragments.init(message_buffer),
        };
    }

    /// Reads raw frames until a complete message or control frame is ready.
    ///
    /// Pings are consumed only when an automatic pong is actually due: it needs
    /// `auto_pong` enabled and a role that can produce a conforming mask, so a
    /// client with `auto_apply_mask` off receives them instead. A close is
    /// returned after its automatic echo is sent when one is due; a suppressed
    /// or disabled echo returns the close directly. A validated (clear) close
    /// under `auto_close` is terminal. Read and accumulation failures latch and
    /// are returned by later calls until `reset`; `ConnectionClosed` is returned
    /// but not latched so a later peer close stays deliverable. A zero maximum
    /// is a configuration rejection that is not latched. A sink-owned transport
    /// failure stays in the sink's write latch and is not duplicated here, so
    /// `reset_tx` recovers it.
    pub fn read_frame(self: *FragmentCollectorRead, sink: anytype) Error!Frame {
        if (self.failure) |failure| return failure;

        // A completed message or a control frame ends the loop; every other
        // fragment has been consumed and the read half fetches the next one.
        while (true) {
            const incoming = self.read.read_frame(sink) catch |err| {
                // `ConnectionClosed` is not latched so a later peer close stays
                // deliverable. A zero maximum is a configuration rejection,
                // matching the unsplit collector, not a latched failure. A
                // sink-owned transport failure stays in the write latch, so
                // `reset_tx` recovers it and the next read can continue.
                // A consumed obligation that the sink cannot send is terminal
                // and already converted to `SendError` by the read half.
                if (err == error.FrameTooLarge and self.read.max_message_size() == 0) return err;
                if (err != error.ConnectionClosed and sink.failure() == null) {
                    self.failure = err;
                }
                return err;
            };

            const completed = self.fragments.accumulate(incoming) catch |err| {
                self.failure = err;
                return err;
            };

            if (completed) |frame| return frame;
        }
    }

    /// Clears the collector latch, the read latch, zslay receive state, and any
    /// in-progress message.
    ///
    /// Safe only when `is_at_wire_boundary()` is true, or when the transport is
    /// discarded; reset deliberately discards an in-progress message, and a
    /// failed mid-frame read leaves the reader advanced.
    pub fn reset(self: *FragmentCollectorRead) void {
        self.failure = null;
        self.read.reset();
        self.fragments.reset();
    }

    /// True when the read half is between frames and no message is in progress.
    pub fn is_at_frame_boundary(self: *const FragmentCollectorRead) bool {
        return self.read.is_at_wire_boundary() and self.fragments.is_idle();
    }

    /// Bytes collected so far for the in-progress message.
    pub fn message_len(self: *const FragmentCollectorRead) usize {
        return self.fragments.message_len();
    }
};
