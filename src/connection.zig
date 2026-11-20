//! Role-aware WebSocket connection policy over zslay.Conn.
//!
//! The connection consumes a caller-provided `std.Io.Reader` and
//! `std.Io.Writer` plus caller-owned frame, transmit-node, mask, write
//! composition, and close-reply storage. It owns automatic pong and close
//! replies, mask application, the closed flag, the exclusive maximum message
//! size, and the read and write failure latches.
//!
//! Automatic pong and close replies are drained and flushed before
//! `read_frame` returns; `write_frame` stays buffered until `flush`. A client
//! that disables `auto_apply_mask` cannot produce a conforming masked frame,
//! so it delivers inbound control frames instead of attempting a reply.
//!
//! zslay owns the header codec, masking direction, fragment ordering, frame and
//! message limits, close payload validation, and the bounded transmit queue.
//! The optional `Options.backpressure` policy adds byte/frame watermarks above
//! that queue; `enqueue_frame` batches, `write_frame` drains, and `flush` is the
//! `std.Io` wait point. Nothing here allocates, opens a socket, or spawns a task.

const std = @import("std");
const zslay = @import("zslay");
const errors = @import("error.zig");
const frame = @import("frame.zig");
const utf8 = @import("utf8.zig");
const backpressure = @import("backpressure.zig");

/// Local endpoint role, re-exported from zslay.
///
/// This is the same type as `fragment.Role`; the alias is repeated here so the
/// connection layer does not depend on the read-side collector module. It is
/// not a second enum.
pub const Role = zslay.EndpointRole;

/// RFC 6455 opcode alias from the frame facade.
pub const OpCode = frame.OpCode;

/// Close status alias from the frame facade.
pub const CloseCode = frame.CloseCode;

/// Four-byte masking key alias from the frame facade.
pub const MaskingKey = frame.MaskingKey;

/// Frame record with caller-owned payload bytes.
pub const Frame = frame.Frame;

/// Connection error set.
pub const Error = errors.WebSocketError;

/// fastwebsockets default: 64 MiB, exclusive.
pub const default_max_message_size: usize = 64 << 20;

/// fastwebsockets default.
pub const default_writev_threshold: usize = 1024;

/// Seed length for the client mask-key generator.
pub const mask_seed_len: usize = std.Random.DefaultCsprng.secret_seed_length;

/// fastwebsockets-compatible policy options.
pub const Options = struct {
    auto_apply_mask: bool = true,
    auto_close: bool = true,
    auto_pong: bool = true,
    writev: bool = true,
    writev_threshold: usize = default_writev_threshold,
    /// Exclusive bound, clamped to `zslay.MaxPayloadLen` by init and the
    /// setter.
    max_message_size: usize = default_max_message_size,
    /// Optional byte and frame watermarks. Null keeps the fastwebsockets
    /// synchronous write behavior and never gates admission on a high-water
    /// mark. The high frame mark must leave headroom for automatic controls.
    backpressure: ?backpressure.Limits = null,
};

/// Seeded ChaCha8 source for client-to-server mask keys.
///
/// The seed must be uniform and secret in production; a fixed seed is the
/// deterministic test seam. The connection never reads ambient randomness, so
/// the handshake or transport boundary supplies the seed. This type uses
/// static dispatch only: no function pointers, no vtable, no allocator.
pub const MaskKeySource = struct {
    prng: std.Random.DefaultCsprng,

    pub fn from_seed(seed: [mask_seed_len]u8) MaskKeySource {
        return .{ .prng = std.Random.DefaultCsprng.init(seed) };
    }

    /// Returns the next four-byte key. Deterministic for a fixed seed.
    pub fn next(self: *MaskKeySource) MaskingKey {
        var key: MaskingKey = undefined;
        self.prng.fill(&key);
        return key;
    }
};

/// Construction-time configuration.
pub const Config = struct {
    role: Role,
    options: Options = .{},
    /// Required for client role; null is allowed for server role.
    mask_keys: ?MaskKeySource = null,
};

/// Caller-owned storage. Every slice outlives the WebSocket.
///
/// `frame_buffer` must hold the largest accepted inbound payload, including a
/// 125-byte control payload; a shorter buffer latches `BufferTooShort` on the
/// read that needs it. `tx_nodes` is the bounded zslay transmit queue.
/// `write_buffer` composes copied writes and must be longer than
/// `zslay.MaxFrameHeaderLen` (15 bytes is the minimum). `close_buffer` is
/// a dedicated reply buffer for a synthesized 1002 close payload and must be
/// at least 2 bytes; 125 bytes preserves any valid close reason. It must be
/// separate from `write_buffer` and `mask_scratch` because the queued 1002
/// payload must stay stable while the pump composes the header and masks
/// chunks. `mask_scratch` is optional and only accelerates vectored masked
/// writes; an empty slice falls back to the copied path.
pub const Storage = struct {
    frame_buffer: []u8,
    tx_nodes: []zslay.FrameNode,
    write_buffer: []u8,
    close_buffer: []u8,
    mask_scratch: []u8 = &.{},

    /// True when `bytes` overlaps any caller-owned region in this storage.
    ///
    /// Native adapters and connection construction use this to keep
    /// caller-provided `std.Io` buffers disjoint from protocol storage.
    /// Empty regions never overlap.
    pub fn overlaps(self: Storage, bytes: []const u8) bool {
        const tx_bytes: []const u8 = std.mem.sliceAsBytes(self.tx_nodes);
        const regions = [_][]const u8{
            self.frame_buffer,
            tx_bytes,
            self.write_buffer,
            self.close_buffer,
            self.mask_scratch,
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

/// Role-aware WebSocket policy over one `zslay.Conn`.
pub const WebSocket = struct {
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,

    /// Combined zslay receive and transmit state.
    ///
    /// Treat this as read-only when `flow` is configured: external queue or
    /// drain mutations bypass the watermark accounting.
    conn: zslay.Conn,

    frame_buffer: []u8,
    write_buffer: []u8,
    close_buffer: []u8,
    mask_scratch: []u8,
    /// Caller transmit-ring capacity, captured for the control reserve.
    tx_capacity: usize,

    /// Null only for a server, which never masks outbound frames.
    mask_keys: ?MaskKeySource,

    options: Options,

    /// Optional watermarks over zslay's bounded transmit queue.
    ///
    /// The connection owns every policy transition when this is non-null;
    /// callers must not reset or enqueue through this value directly.
    flow: ?backpressure.Flow = null,

    /// Set after a close frame is successfully queued, or by a validated peer
    /// close whose reply was suppressed by configuration. Terminal for
    /// non-close writes and for non-close reads.
    closed: bool = false,

    /// Latched read failure. Cleared only by `reset`.
    read_failure: ?Error = null,

    /// Latched transmit failure, including a failed flush of an automatic
    /// pong or close reply. Cleared only by `reset_tx`; a partial write cannot
    /// be resumed safely on the same transport.
    write_failure: ?Error = null,

    /// Builds a connection over caller-owned reader, writer, and storage.
    ///
    /// `max_message_size` is clamped silently to `zslay.MaxPayloadLen`, unlike
    /// `FragmentCollector.init`, and the derived zslay limits carry the
    /// exclusive fastwebsockets bound. A client must supply a mask source even
    /// when `auto_apply_mask` is false, so `set_auto_apply_mask(true)` stays
    /// infallible. Empty `tx_nodes` is rejected only when an automatic reply
    /// is enabled. The reader and writer buffers must not overlap each other or
    /// any storage region.
    pub fn init(
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
        storage: Storage,
        config: Config,
    ) Error!WebSocket {
        const max_size = clamp_max_message_size(config.options.max_message_size);
        try validate_storage(storage);
        try validate_io_buffers(reader, writer, storage);

        if (config.role == .client and config.mask_keys == null) return error.MaskingKeyRequired;
        if (storage.tx_nodes.len == 0 and (config.options.auto_pong or config.options.auto_close)) {
            return error.InvalidLength;
        }

        var options = config.options;
        options.max_message_size = max_size;

        var flow: ?backpressure.Flow = null;
        if (options.backpressure) |limits| {
            // A policy without a ring has nothing to observe. One node is
            // always reserved for automatic control replies, independent of
            // the current auto flags, so a later setter cannot invalidate the
            // reserve.
            if (storage.tx_nodes.len < 2) return error.InvalidLength;
            const data_capacity = storage.tx_nodes.len - 1;
            const configured = backpressure.Flow.init(limits) catch return error.InvalidLength;
            if (configured.state.limits.high_water_frames > data_capacity) {
                return error.InvalidLength;
            }
            options.backpressure = configured.state.limits;
            flow = configured;
        }

        const limit = derived_limit(max_size);
        const conn = zslay.Conn.init(storage.tx_nodes, .{
            .role = config.role,
            .max_frame_len = limit,
            .max_message_len = limit,
        }) catch |err| return errors.from_zslay(err);

        return .{
            .reader = reader,
            .writer = writer,
            .conn = conn,
            .frame_buffer = storage.frame_buffer,
            .write_buffer = storage.write_buffer,
            .close_buffer = storage.close_buffer,
            .mask_scratch = storage.mask_scratch,
            .tx_capacity = storage.tx_nodes.len,
            .mask_keys = config.mask_keys,
            .options = options,
            .flow = flow,
        };
    }

    /// Reads one raw wire frame, applying control policy.
    ///
    /// Returned payloads borrow `frame_buffer` until the next `read_frame`.
    /// Clear FIN text frames are validated; non-FIN fragments and continuations
    /// are delivered raw. Automatic pong and close replies are flushed before
    /// the call returns. A client with `auto_apply_mask` off has no reply path,
    /// so inbound pings are delivered and closes are validated and returned
    /// without an echo or 1002 attempt. This is the fastwebsockets raw path,
    /// not the assembled-message path: `FragmentCollector` remains a separate
    /// API. `read_event` defers the read latch for an error that also fills a
    /// reply obligation; this call sends the reply first and latches the error
    /// only after a successful send. A transport write or flush failure while
    /// sending the reply latches `write_failure` instead, so the originating
    /// read error is not latched and `reset_tx` alone recovers it. A prepare or
    /// queue failure before any reply bytes are emitted latches as a read
    /// failure. Every other read failure except `ConnectionClosed` and the
    /// zero-max configuration rejection latches until `reset`.
    pub fn read_frame(self: *WebSocket) Error!Frame {
        // Captured before any obligation write: a valid close echo sets
        // `closed`, but the frame itself must still be delivered.
        const was_closed = self.closed;
        const reply_capable = self.can_reply();

        while (true) {
            var reply: ?Frame = null;
            const event = self.read_event(was_closed, &reply);
            if (reply) |outgoing| {
                self.send_obligation(reply_capable, was_closed, outgoing) catch |err| {
                    // A prepare or queue failure emits nothing and is a read
                    // failure, matching a failure inside the old read loop.
                    if (err != error.ConnectionClosed and self.write_failure == null) {
                        self.read_failure = err;
                    }
                    return err;
                };
            }

            const incoming = event catch |err| {
                // read_event defers the read latch while a reply is pending;
                // the reply is on the wire now, so latch the originating error.
                // A failed send returned above and leaves the read latch alone.
                if (reply != null and err != error.ConnectionClosed and self.write_failure == null) {
                    self.read_failure = err;
                }
                return err;
            };
            if (incoming) |outgoing| return outgoing;
        }
    }

    /// Reads one frame or reports an automatic reply obligation without writing.
    ///
    /// `reply_out` is cleared first. When set, the reply borrows `frame_buffer`
    /// or `close_buffer` until the next read. A split caller passes the write
    /// half's closed state as `was_closed` and forwards the reply to the write
    /// half. An invalid close code sets the 1002 reply before returning
    /// `InvalidCloseCode`. This function never writes or flushes. A read error
    /// that also fills `reply_out` is not latched here: the caller that sends
    /// the reply owns the read-latch decision, and `read_frame` latches after a
    /// successful send. Only an error without a reply latches inside this call;
    /// `ConnectionClosed` never latches.
    pub fn read_event(self: *WebSocket, was_closed: bool, reply_out: *?Frame) Error!?Frame {
        reply_out.* = null;

        if (self.read_failure) |failure| return failure;
        if (self.write_failure) |failure| return failure;
        if (self.options.max_message_size == 0) return error.FrameTooLarge;

        self.apply_message_limit();

        return self.read_event_inner(reply_out, was_closed, self.can_reply()) catch |err| {
            // An error that also filled a reply defers its read latch to the
            // caller that sends the reply, so a failed send leaves only the
            // write latch. A no-reply error stays a read failure here.
            if (reply_out.* == null and err != error.ConnectionClosed and self.write_failure == null) {
                self.read_failure = err;
            }
            return err;
        };
    }

    /// Queues and drains one outbound frame.
    ///
    /// The payload must be clear (`masking_key == null`); the connection owns
    /// mask application and masks chunks at write time so close validation
    /// sees clear bytes. On success the payload must remain valid until the
    /// call returns; if the drain fails after a node is queued, the node keeps
    /// borrowing it until `reset_tx` or transport discard. The call drains the
    /// zslay queue into the `std.Io.Writer` but does not call `writer.flush()`;
    /// call `flush()` for buffered transports. Outbound text is not UTF-8
    /// validated, matching fastwebsockets and zslay.
    ///
    /// When watermarks are configured, a data frame is refused with
    /// `error.WouldBlock` while the policy is backpressured or when a non-empty
    /// queue cannot fit the frame without crossing a high mark. Application
    /// controls other than close stop at the data capacity; a close may use the
    /// reserved node because it suppresses later automatic replies. Automatic
    /// pong and close replies use the reserved node.
    pub fn write_frame(self: *WebSocket, outgoing: Frame) Error!void {
        try self.enqueue_frame(outgoing);

        self.pump_tx() catch |err| {
            self.write_failure = err;
            return err;
        };
    }

    /// Validates and queues one outbound frame without draining it.
    ///
    /// This is the batching path for the watermark policy. A caller can enqueue
    /// frames until `error.WouldBlock`, then call `flush()` to drain zslay's
    /// ring and the caller's writer. The payload remains borrowed until a
    /// later flush advances it, or until `reset_tx` if the transport is
    /// discarded after a failure. Data frames are admitted while the policy is
    /// writable; application controls may use the data capacity, and automatic
    /// replies use the reserved node.
    pub fn enqueue_frame(self: *WebSocket, outgoing: Frame) Error!void {
        if (self.write_failure) |failure| return failure;
        if (outgoing.masking_key != null) return error.PayloadMasked;
        if (outgoing.opcode != .close and self.closed) return error.ConnectionClosed;
        if (self.payload_overlaps_storage(outgoing.payload)) return error.InvalidLength;

        return self.queue_frame(outgoing, false);
    }

    /// Sends one automatic control obligation through the reserved ring slot.
    ///
    /// This is the sink path used by split reads. It bypasses the application
    /// control cap so a pong or close reply can use the node that
    /// `Options.backpressure` reserves. It still respects zslay's hard ring
    /// capacity and close payload validation.
    pub fn send_control(self: *WebSocket, outgoing: Frame) Error!void {
        if (self.write_failure) |failure| return failure;
        if (!frame.is_control(outgoing.opcode)) return error.InvalidOpcode;
        if (outgoing.masking_key != null) return error.PayloadMasked;

        try self.queue_frame(outgoing, true);

        self.pump_tx() catch |err| {
            self.write_failure = err;
            return err;
        };

        self.writer.flush() catch |err| {
            const mapped = errors.from_writer(err);
            self.write_failure = mapped;
            return mapped;
        };
    }

    /// Drains any queued zslay nodes and flushes the caller's writer.
    pub fn flush(self: *WebSocket) Error!void {
        if (self.write_failure) |failure| return failure;

        self.apply_message_limit();

        self.pump_tx() catch |err| {
            self.write_failure = err;
            return err;
        };

        self.writer.flush() catch |err| {
            const mapped = errors.from_writer(err);
            self.write_failure = mapped;
            return mapped;
        };
    }

    pub fn is_closed(self: *const WebSocket) bool {
        return self.closed;
    }

    pub fn role(self: *const WebSocket) Role {
        return self.conn.role;
    }

    pub fn max_message_size(self: *const WebSocket) usize {
        return self.options.max_message_size;
    }

    pub fn tx_pending(self: *const WebSocket) usize {
        return self.conn.tx_pending();
    }

    /// True while the configured watermark policy is backpressured.
    ///
    /// This reports only the latched phase. A data write can also return
    /// `error.WouldBlock` when a non-empty queue cannot fit the frame without
    /// crossing a high mark; use that error, not this accessor, as the
    /// admission result, and `flush` before retrying.
    pub fn is_backpressured(self: *const WebSocket) bool {
        if (self.flow) |flow| return flow.is_backpressured();
        return false;
    }

    /// Payload bytes currently charged to the watermark policy.
    pub fn queued_bytes(self: *const WebSocket) usize {
        if (self.flow) |flow| return flow.state.queued_bytes;
        return 0;
    }

    /// Frames currently charged to the watermark policy.
    pub fn queued_frames(self: *const WebSocket) usize {
        if (self.flow) |flow| return flow.state.queued_frames;
        return self.conn.tx_pending();
    }

    /// True when the next wire byte starts a frame. This is the reset-safety
    /// predicate after a read error.
    pub fn is_at_wire_boundary(self: *const WebSocket) bool {
        return self.conn.is_at_frame_boundary();
    }

    pub fn set_writev(self: *WebSocket, enabled: bool) void {
        self.options.writev = enabled;
    }

    pub fn set_writev_threshold(self: *WebSocket, threshold: usize) void {
        self.options.writev_threshold = threshold;
    }

    /// Enables or disables automatic close validation and echo.
    ///
    /// The setter does not create transmit-queue capacity; automatic replies
    /// need at least one `tx_nodes` entry.
    pub fn set_auto_close(self: *WebSocket, enabled: bool) void {
        self.options.auto_close = enabled;
    }

    /// Enables or disables automatic pong replies.
    ///
    /// The setter does not create transmit-queue capacity; automatic replies
    /// need at least one `tx_nodes` entry.
    pub fn set_auto_pong(self: *WebSocket, enabled: bool) void {
        self.options.auto_pong = enabled;
    }

    /// Controls server inbound unmasking and client outbound masking.
    ///
    /// A client with auto-mask off cannot write, because zslay requires
    /// client-to-server frames to be masked and returns `PayloadNotMasked`.
    /// Automatic replies are suppressed for such a client: inbound pings are
    /// delivered and inbound closes are validated and returned without an echo
    /// or 1002 attempt.
    pub fn set_auto_apply_mask(self: *WebSocket, enabled: bool) void {
        self.options.auto_apply_mask = enabled;
    }

    /// Sets the exclusive inbound limit, clamped to `zslay.MaxPayloadLen`.
    ///
    /// The derived per-frame limit applies to the next header immediately. The
    /// cumulative limit applies at the next frame boundary; while a fragmented
    /// message is in flight it is clamped to the accumulated lengths so zslay's
    /// fragment invariant holds, and a payload already in flight keeps the
    /// previous cumulative limit until it completes.
    pub fn set_max_message_size(self: *WebSocket, max_size: usize) void {
        const clamped = clamp_max_message_size(max_size);

        self.options.max_message_size = clamped;
        self.conn.max_frame_len = derived_limit(clamped);
        self.apply_message_limit();
    }

    /// Applies the configured cumulative limit at the next frame boundary.
    ///
    /// zslay asserts that an in-flight fragmented message never exceeds its
    /// current cumulative limit, so a lowered limit is clamped to the
    /// accumulated fragment lengths until the message ends.
    fn apply_message_limit(self: *WebSocket) void {
        // A frame payload already accepted cannot change limits safely; the
        // next call after it completes applies the stored option.
        if (self.conn.decoded_header != null) return;

        const limit = derived_limit(self.options.max_message_size);
        if (self.limits_idle()) {
            self.conn.max_message_len = limit;
            return;
        }

        const rx_len = self.conn.rx_fragment.message_len;
        const tx_len = self.conn.tx_fragment.message_len;
        self.conn.max_message_len = @max(limit, @max(rx_len, tx_len));
    }

    /// True when no frame and no fragmented message is in flight in either
    /// direction.
    fn limits_idle(self: *const WebSocket) bool {
        if (!self.conn.is_at_frame_boundary()) return false;
        if (self.conn.rx_fragment.opcode != null) return false;
        if (self.conn.tx_fragment.opcode != null) return false;
        return true;
    }

    /// Replaces the client mask-key source. Infallible; the source is copied.
    pub fn set_mask_keys(self: *WebSocket, mask_keys: MaskKeySource) void {
        self.mask_keys = mask_keys;
    }

    /// Clears the read latch and zslay RX partial state.
    ///
    /// Does not clear `closed`, the TX queue, or the write latch. Safe only
    /// when `is_at_wire_boundary()` is true or the transport is discarded; a
    /// failed mid-frame read leaves the reader advanced, and resetting protocol
    /// state does not rewind it.
    pub fn reset(self: *WebSocket) void {
        self.conn.reset_rx();
        self.read_failure = null;
    }

    /// Clears the TX queue, the write latch, and `closed`.
    ///
    /// Safe only when the transport is discarded or in a test that never
    /// shipped the partial bytes.
    pub fn reset_tx(self: *WebSocket) void {
        self.conn.reset_tx();
        self.write_failure = null;
        self.closed = false;
        if (self.flow) |*flow| flow.reset();
    }

    /// Applies automatic pong, close, and text policy for one wire frame.
    ///
    /// `was_closed` is captured before any obligation write so a valid inbound
    /// close is still delivered after its echo sets `closed`, matching
    /// fastwebsockets. `reply_capable` gates both obligations: a client that
    /// cannot mask delivers clear ping and close frames instead of sending a
    /// frame zslay would reject. A suppressed ping returns `null` so the caller
    /// sends the pong and continues to the next frame.
    fn read_event_inner(
        self: *WebSocket,
        reply_out: *?Frame,
        was_closed: bool,
        reply_capable: bool,
    ) Error!?Frame {
        const incoming = try self.read_wire_frame();

        switch (incoming.opcode) {
            .close => {
                if (self.options.auto_close and incoming.masking_key == null) {
                    try self.validate_inbound_close(incoming.payload, was_closed, reply_capable, reply_out);
                }
                return try self.gate_closed(incoming, was_closed);
            },
            .ping => {
                if (self.options.auto_pong and reply_capable and incoming.masking_key == null) {
                    if (!was_closed) {
                        reply_out.* = Frame.init(true, .pong, null, incoming.payload);
                    }
                    return null;
                }
                return try self.gate_closed(incoming, was_closed);
            },
            .text => {
                if (incoming.fin and incoming.masking_key == null and !utf8.is_valid(incoming.payload)) {
                    return error.InvalidUTF8;
                }
                return try self.gate_closed(incoming, was_closed);
            },
            else => return try self.gate_closed(incoming, was_closed),
        }
    }

    /// True when automatic replies can be sent on the wire.
    ///
    /// A client that disables `auto_apply_mask` cannot produce a conforming
    /// masked frame: zslay rejects it with `PayloadNotMasked`, which would
    /// latch the read. Such a client delivers inbound control frames instead.
    fn can_reply(self: *const WebSocket) bool {
        return self.conn.role != .client or self.options.auto_apply_mask;
    }

    /// Drives zslay's receive state machine until one frame is emitted.
    fn read_wire_frame(self: *WebSocket) Error!Frame {
        while (true) {
            const action = self.conn.advance_rx() catch |err| return errors.from_zslay(err);
            switch (action) {
                .need_header => try self.fill_header(),
                .need_payload => try self.fill_payload(),
                .emit_frame => return self.emit_rx_frame(),
                // zslay returns only the three documented receive actions.
                else => unreachable,
            }
        }
    }

    /// Fills the header bytes zslay currently asks for.
    fn fill_header(self: *WebSocket) Error!void {
        const target = self.conn.get_header_buffer();
        const read_len = self.reader.readSliceShort(target) catch |err| return errors.from_reader(err);

        if (read_len < target.len) {
            // Bytes consumed by a short read must reach zslay so the wire
            // boundary predicate does not report a clean frame start while the
            // reader sits mid-header. zslay rejects a zero-byte advance, and
            // no bytes were consumed then.
            if (read_len != 0) {
                self.conn.advance_header_read(read_len) catch |err| return errors.from_zslay(err);
            }
            return error.UnexpectedEOF;
        }

        self.conn.advance_header_read(read_len) catch |err| return errors.from_zslay(err);
    }

    /// Reads the remaining bytes of the current frame payload in one bounded
    /// read.
    fn fill_payload(self: *WebSocket) Error!void {
        const decoded = self.conn.current_frame() catch |err| return errors.from_zslay(err);
        if (decoded.payload_len > @as(u64, @intCast(self.frame_buffer.len))) return error.BufferTooShort;

        const remaining = self.conn.rx_remaining() catch |err| return errors.from_zslay(err);
        const count: usize = @intCast(remaining);

        const read_len = self.reader.readSliceShort(self.frame_buffer[0..count]) catch |err|
            return errors.from_reader(err);
        if (read_len < count) return error.UnexpectedEOF;

        self.conn.advance_payload_read(remaining) catch |err| return errors.from_zslay(err);
    }

    /// Completes a decoded frame, applies the inbound mask policy, and builds
    /// the frame record.
    fn emit_rx_frame(self: *WebSocket) Error!Frame {
        const decoded = self.conn.current_frame() catch |err| return errors.from_zslay(err);
        self.conn.complete_frame() catch |err| return errors.from_zslay(err);

        const payload_len: usize = @intCast(decoded.payload_len);
        const payload = self.frame_buffer[0..payload_len];

        var key = decoded.masking_key;
        if (key) |masking_key| {
            if (self.options.auto_apply_mask) {
                zslay.mask(payload, masking_key, 0);
                key = null;
            }
        }

        const opcode = OpCode.from_wire(decoded.header.opcode) orelse return error.InvalidOpcode;
        return Frame.init(decoded.header.fin, opcode, key, payload);
    }

    /// Validates an inbound close frame and fills the reply obligation.
    ///
    /// The reason is checked as UTF-8 first, matching fastwebsockets, and then
    /// zslay's payload validator stays authoritative. An invalid code fills a
    /// 1002 close carrying the validated reason when it fits the close buffer,
    /// or an empty reason otherwise; a valid close fills an echo with the exact
    /// inbound payload. zslay's decoder rejects a one-byte close with
    /// `ProtocolError` before this policy runs. When `reply_capable` is false
    /// the frame is still validated, but no echo or 1002 is filled because a
    /// client without auto-mask cannot send a conforming frame; a validated
    /// close, or an invalid code that would normally receive a 1002, still sets
    /// `closed` so the suppressed reply is terminal. An invalid UTF-8 reason
    /// leaves `closed` untouched.
    fn validate_inbound_close(
        self: *WebSocket,
        payload: []u8,
        was_closed: bool,
        reply_capable: bool,
        reply_out: *?Frame,
    ) Error!void {
        const reason: []const u8 = if (payload.len >= 2) payload[2..] else &.{};

        // fastwebsockets checks the reason before code allowance; zslay's
        // validator checks the code first, so this pre-check fixes the order.
        if (!utf8.is_valid(reason)) return error.InvalidUTF8;

        zslay.validate_close_payload(payload) catch |err| {
            const mapped = errors.from_zslay_close(err);
            if (mapped == error.InvalidCloseCode) {
                if (!reply_capable) {
                    // The suppressed 1002 reply is still terminal.
                    self.closed = true;
                    return mapped;
                }
                if (!was_closed) reply_out.* = try self.make_1002_close(reason);
            }
            return mapped;
        };

        if (!reply_capable) self.closed = true;
        if (reply_capable and !was_closed) {
            reply_out.* = Frame.init(true, .close, null, payload);
        }
    }

    /// Encodes a 1002 reply payload into `close_buffer`.
    ///
    /// The reason is reused only after the UTF-8 pre-check and only when it
    /// fits; otherwise the reason is dropped rather than truncated mid-code
    /// point.
    fn make_1002_close(self: *WebSocket, reason: []const u8) Error!Frame {
        const close_capacity = self.close_buffer.len;
        const reason_fits = close_capacity >= 2 and reason.len <= close_capacity - 2;
        const stored_reason: []const u8 = if (reason_fits) reason else &.{};

        return Frame.close(frame.close_code_to_u16(.protocol_error), stored_reason, self.close_buffer);
    }

    /// Sends a queued automatic reply unless a close was already observed or
    /// the role cannot produce a conforming frame.
    ///
    /// The reply is flushed before returning, because one left in a buffered
    /// writer delays the close handshake or hides a pong. A transport write or
    /// flush failure latches `write_failure`, matching `flush`; a prepare or
    /// queue failure emits nothing and is latched by `read_frame` as a read
    /// failure.
    fn send_obligation(self: *WebSocket, reply_capable: bool, was_closed: bool, outgoing: Frame) Error!void {
        if (!reply_capable or was_closed) return;
        return self.send_control(outgoing);
    }

    /// Reports a non-close frame read after a close as `ConnectionClosed`.
    fn gate_closed(self: *WebSocket, outgoing: Frame, was_closed: bool) Error!Frame {
        _ = self;
        if (was_closed and outgoing.opcode != .close) return error.ConnectionClosed;
        return outgoing;
    }

    /// True when the outbound payload overlaps connection-owned scratch or the
    /// transmit nodes. The inbound `frame_buffer` may be reused for an echo.
    fn payload_overlaps_storage(self: *const WebSocket, payload: []const u8) bool {
        const start = @intFromPtr(payload.ptr);
        if (self.conn.tx_storage_overlaps(start, payload.len)) return true;
        if (zslay.event.ranges_overlap(
            start,
            payload.len,
            @intFromPtr(self.mask_scratch.ptr),
            self.mask_scratch.len,
        )) return true;
        if (zslay.event.ranges_overlap(
            start,
            payload.len,
            @intFromPtr(self.write_buffer.ptr),
            self.write_buffer.len,
        )) return true;
        if (zslay.event.ranges_overlap(
            start,
            payload.len,
            @intFromPtr(self.close_buffer.ptr),
            self.close_buffer.len,
        )) return true;
        return false;
    }

    /// Prepares and queues a frame without the public payload checks.
    ///
    /// Obligations borrow known-disjoint internal storage, so only the public
    /// entry points need the overlap and pre-mask checks. Admission happens
    /// before mask-key consumption and header preparation so a rejected frame
    /// has no side effects. The flow counters are restored if preparation or
    /// zslay's queue mutation fails, keeping the policy and ring in lockstep.
    /// `allow_control_reserve` is true only for automatic pong and close
    /// replies; application control frames stay at or below the data capacity.
    fn queue_frame(self: *WebSocket, outgoing: Frame, allow_control_reserve: bool) Error!void {
        self.apply_message_limit();

        if (self.flow != null and frame.is_control(outgoing.opcode) and
            outgoing.opcode != .close and !allow_control_reserve)
        {
            const data_capacity = self.tx_capacity - 1;
            if (self.conn.tx_pending() >= data_capacity) return error.WouldBlock;
        }

        const saved_flow: ?backpressure.Flow = if (self.flow) |flow| flow else null;
        if (self.flow) |*flow| {
            const charge = backpressure.Charge.frame(outgoing.payload.len);
            if (frame.is_control(outgoing.opcode)) {
                _ = flow.enqueue_control(charge) catch |err| return flow_error(err);
            } else {
                _ = flow.enqueue_data(charge) catch |err| return flow_error(err);
            }
        }

        const masked = self.conn.role == .client and self.options.auto_apply_mask;
        const key: ?MaskingKey = if (masked) self.next_mask_key() catch |err| {
            self.restore_flow(saved_flow);
            return err;
        } else null;

        const node = self.conn.prepare_frame(
            outgoing.fin,
            outgoing.opcode,
            outgoing.payload,
            masked,
            key,
        ) catch |err| {
            self.restore_flow(saved_flow);
            return errors.from_zslay(err);
        };

        self.conn.queue_frame(node) catch |err| {
            self.restore_flow(saved_flow);
            return errors.from_zslay_queue(err);
        };

        if (outgoing.opcode == .close) {
            self.closed = true;
            if (self.flow) |*flow| _ = flow.close() catch |err| return flow_error(err);
        }
    }

    fn restore_flow(self: *WebSocket, saved: ?backpressure.Flow) void {
        if (self.flow) |*flow| {
            if (saved) |value| flow.* = value;
        }
    }

    /// Returns the next client mask key.
    fn next_mask_key(self: *WebSocket) Error!MaskingKey {
        const source = if (self.mask_keys) |*mask_keys| mask_keys else return error.MaskingKeyRequired;
        return source.next();
    }

    /// Drains the zslay transmit queue until it is empty.
    ///
    /// Frame completion is observed through `tx_pending` because zslay discards
    /// fully sent nodes inside `advance_tx`. Payload bytes are accounted at the
    /// point each chunk advances, so a partial transport write leaves both the
    /// queue and the policy counters intact.
    fn pump_tx(self: *WebSocket) Error!void {
        while (true) {
            const before = self.conn.tx_pending();
            const action = self.conn.advance_tx() orelse {
                try self.flow_flushed(.{ .frames = before });
                if (self.flow) |flow| std.debug.assert(flow.state.is_idle());
                return;
            };
            const after = self.conn.tx_pending();
            try self.flow_flushed(.{ .frames = before - after });

            switch (action) {
                .write_header => try self.emit_header_step(),
                .write_payload => try self.emit_payload_step(),
                // zslay returns only the two documented transmit actions.
                else => unreachable,
            }
        }
    }

    fn flow_flushed(self: *WebSocket, charge: backpressure.Charge) Error!void {
        if (charge.bytes == 0 and charge.frames == 0) return;
        if (self.flow) |*flow| {
            _ = flow.flushed(charge) catch return error.SendError;
        }
    }

    fn advance_payload(self: *WebSocket, count: usize) Error!void {
        if (count == 0) return;
        self.conn.advance_tx_payload(count) catch |err| return errors.from_zslay(err);
        try self.flow_flushed(.{ .bytes = count });
    }

    fn flow_error(err: backpressure.TransitionError) Error {
        return switch (err) {
            error.WouldBlock => error.WouldBlock,
            error.StreamClosed => error.ConnectionClosed,
            // Local policy bookkeeping failures are not peer protocol errors.
            error.ByteCountOverflow, error.FlushExceedsQueue => error.SendError,
        };
    }

    /// Emits the remaining header, plus one masked or unmasked payload chunk
    /// when the vectored path applies.
    fn emit_header_step(self: *WebSocket) Error!void {
        const header = self.conn.get_tx_header_buffer();
        const payload = self.conn.get_tx_payload() catch |err| return errors.from_zslay(err);
        const offset = self.conn.get_tx_payload_offset() catch |err| return errors.from_zslay(err);
        const key = self.conn.get_tx_masking_key() catch |err| return errors.from_zslay(err);

        const use_vectored = self.options.writev and payload.len > self.options.writev_threshold;

        if (use_vectored) {
            var chunk = payload;
            if (key) |masking_key| {
                if (self.mask_scratch.len == 0) {
                    try self.emit_header_copied(header, payload, offset, masking_key);
                    return;
                }

                const chunk_len = @min(payload.len, self.mask_scratch.len);
                @memcpy(self.mask_scratch[0..chunk_len], payload[0..chunk_len]);
                zslay.mask(self.mask_scratch[0..chunk_len], masking_key, @intCast(offset));
                chunk = self.mask_scratch[0..chunk_len];
            }

            var iovecs = [_][]const u8{ header, chunk };
            self.writer.writeVecAll(&iovecs) catch |err| return errors.from_writer(err);

            self.conn.advance_tx_header(header.len) catch |err| return errors.from_zslay(err);
            try self.advance_payload(chunk.len);
            return;
        }

        try self.emit_header_copied(header, payload, offset, key);
    }

    /// Composes the remaining header and one payload chunk in `write_buffer`,
    /// masking the payload region when a key is present.
    fn emit_header_copied(
        self: *WebSocket,
        header: []const u8,
        payload: []const u8,
        offset: usize,
        key: ?MaskingKey,
    ) Error!void {
        const capacity = self.write_buffer.len - header.len;
        const chunk_len = @min(payload.len, capacity);

        @memcpy(self.write_buffer[0..header.len], header);
        if (chunk_len != 0) {
            @memcpy(self.write_buffer[header.len..][0..chunk_len], payload[0..chunk_len]);
            if (key) |masking_key| {
                zslay.mask(self.write_buffer[header.len..][0..chunk_len], masking_key, @intCast(offset));
            }
        }

        self.writer.writeAll(self.write_buffer[0 .. header.len + chunk_len]) catch |err|
            return errors.from_writer(err);

        self.conn.advance_tx_header(header.len) catch |err| return errors.from_zslay(err);
        try self.advance_payload(chunk_len);
    }

    /// Emits one remaining payload chunk, masking through scratch or the write
    /// buffer when the frame is masked.
    fn emit_payload_step(self: *WebSocket) Error!void {
        const payload = self.conn.get_tx_payload() catch |err| return errors.from_zslay(err);
        const offset = self.conn.get_tx_payload_offset() catch |err| return errors.from_zslay(err);
        const key = self.conn.get_tx_masking_key() catch |err| return errors.from_zslay(err);

        // An unmasked large payload goes straight to the writer.
        if (key == null and self.options.writev and payload.len > self.options.writev_threshold) {
            self.writer.writeAll(payload) catch |err| return errors.from_writer(err);
            try self.advance_payload(payload.len);
            return;
        }

        if (key) |masking_key| {
            // A masked large payload can stream through scratch.
            if (self.options.writev and self.mask_scratch.len != 0 and payload.len > self.options.writev_threshold) {
                const chunk_len = @min(payload.len, self.mask_scratch.len);
                @memcpy(self.mask_scratch[0..chunk_len], payload[0..chunk_len]);
                zslay.mask(self.mask_scratch[0..chunk_len], masking_key, @intCast(offset));
                self.writer.writeAll(self.mask_scratch[0..chunk_len]) catch |err| return errors.from_writer(err);
                try self.advance_payload(chunk_len);
                return;
            }

            // Otherwise mask a chunk in the composition buffer.
            const chunk_len = @min(payload.len, self.write_buffer.len);
            @memcpy(self.write_buffer[0..chunk_len], payload[0..chunk_len]);
            zslay.mask(self.write_buffer[0..chunk_len], masking_key, @intCast(offset));
            self.writer.writeAll(self.write_buffer[0..chunk_len]) catch |err| return errors.from_writer(err);
            try self.advance_payload(chunk_len);
            return;
        }

        // Unmasked copied chunk.
        const chunk_len = @min(payload.len, self.write_buffer.len);
        @memcpy(self.write_buffer[0..chunk_len], payload[0..chunk_len]);
        self.writer.writeAll(self.write_buffer[0..chunk_len]) catch |err| return errors.from_writer(err);
        try self.advance_payload(chunk_len);
    }
};

/// Clamps the exclusive maximum to the RFC 6455 wire-format bound.
///
/// The u128 comparison keeps the clamp correct on 32-bit targets, where `usize`
/// is narrower than `zslay.MaxPayloadLen`.
fn clamp_max_message_size(max_message_size: usize) usize {
    const clamped = @min(@as(u128, max_message_size), @as(u128, zslay.MaxPayloadLen));
    return std.math.cast(usize, clamped) orelse std.math.maxInt(usize);
}

/// Converts the exclusive maximum to zslay's inclusive frame and message limit.
fn derived_limit(max_message_size: usize) u64 {
    if (max_message_size == 0) return 0;
    return @intCast(max_message_size - 1);
}

/// Validates the caller-owned storage layout.
///
/// Empty optional regions are ignored. The pairwise check is a local
/// buffer-lifetime invariant, not protocol logic; zslay's transmit overlap
/// helpers remain the outbound payload check.
fn validate_storage(storage: Storage) Error!void {
    if (storage.write_buffer.len <= zslay.MaxFrameHeaderLen) return error.InvalidLength;
    if (storage.close_buffer.len < 2) return error.InvalidLength;

    const tx_bytes: []const u8 = std.mem.sliceAsBytes(storage.tx_nodes);
    const regions = [_][]const u8{
        storage.frame_buffer,
        tx_bytes,
        storage.write_buffer,
        storage.close_buffer,
        storage.mask_scratch,
    };

    for (regions, 0..) |region, index| {
        for (regions[index + 1 ..]) |other| {
            if (zslay.event.ranges_overlap(
                @intFromPtr(region.ptr),
                region.len,
                @intFromPtr(other.ptr),
                other.len,
            )) return error.InvalidLength;
        }
    }
}

/// Rejects caller `std.Io` buffers that alias each other or protocol storage.
///
/// `Reader.readSliceShort` can copy from its internal buffer into a payload
/// target, and the socket reader/writer add their buffers as vectored slices.
/// Sharing either direction with payload, queue, or composition storage would
/// let protocol I/O overwrite live bytes.
fn validate_io_buffers(reader: *const std.Io.Reader, writer: *const std.Io.Writer, storage: Storage) Error!void {
    if (zslay.event.ranges_overlap(
        @intFromPtr(reader.buffer.ptr),
        reader.buffer.len,
        @intFromPtr(writer.buffer.ptr),
        writer.buffer.len,
    )) return error.InvalidLength;
    if (storage.overlaps(reader.buffer)) return error.InvalidLength;
    if (storage.overlaps(writer.buffer)) return error.InvalidLength;
}
