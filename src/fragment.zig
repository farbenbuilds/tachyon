//! Fragment collection and read-side message assembly.
//!
//! `FragmentCollector` drives `zslay.Conn` over a caller-provided
//! `std.Io.Reader` and buffers text and binary continuations until `fin`.
//! zslay owns continuation ordering, control-frame validation, masking
//! direction, and cumulative frame/message limits; this module owns only the
//! collected bytes, incremental text validation, and completed-message
//! delivery. Nothing here allocates or opens a stream.
//!
//! The collector is deliberately read-only. Control frames are delivered to the
//! caller, which must answer pings and closes; automatic replies belong to
//! `src/connection.zig`. `FragmentCollectorRead` is not a separate type because
//! this collector already takes only a read side; `src/split.zig` layers the
//! write half on top of it.
//!
//! Returned payloads borrow `frame_buffer` (control frames and unfragmented
//! messages) or `message_buffer` (completed fragmented messages). They stay
//! valid until the next `read_frame` call.
//!
//! Close frames are returned after zslay's header-level length checks only. The
//! caller or the connection layer must call `zslay.validate_close_payload`
//! before acting on the close code or reason, or echoing the close. This
//! collector does not validate close codes or UTF-8 reasons.

const std = @import("std");
const zslay = @import("zslay");
const errors = @import("error.zig");
const frame = @import("frame.zig");
const utf8 = @import("utf8.zig");

/// Local endpoint role, re-exported from zslay.
pub const Role = zslay.EndpointRole;

/// RFC 6455 opcode, re-exported from the frame facade.
pub const OpCode = frame.OpCode;

/// Frame record with caller-owned payload bytes.
pub const Frame = frame.Frame;

/// tachyon error set for the fragment layer.
pub const Error = errors.WebSocketError;

/// fastwebsockets default: 64 MiB, exclusive.
pub const default_max_message_size: usize = 64 << 20;

/// Fragment accumulator over caller-owned storage.
///
/// `accumulate` is a pure transition over the supplied frame: every check and
/// every UTF-8 step runs before any copy or state commit, so a rejected frame
/// leaves the previous message intact. A text code point may span fragments;
/// the pending bytes live in `utf8_state` and the collected bytes stay
/// contiguous in `buffer`. U+FFFD is never substituted.
///
/// The accumulator has no built-in message-size cap: `FragmentCollector` gets
/// its cap from zslay's `max_message_len`, while direct users must bound input
/// themselves. Incoming payload bytes must not alias `buffer`, because
/// accumulation copies with `@memcpy`.
pub const Fragments = struct {
    buffer: []u8,
    opcode: ?OpCode = null,
    len: usize = 0,
    utf8_state: utf8.State = .{},

    /// Binds the accumulator to caller-owned message storage.
    ///
    /// `buffer` bounds one complete message, not one frame. Its contents are
    /// borrowed by completed frames until the next `accumulate` or `reset`.
    pub fn init(buffer: []u8) Fragments {
        return .{ .buffer = buffer };
    }

    /// Discards the in-progress message without touching `buffer` bytes.
    pub fn reset(self: *Fragments) void {
        self.opcode = null;
        self.len = 0;
        self.utf8_state = .{};
    }

    /// True when no fragmented message is being collected.
    pub fn is_idle(self: *const Fragments) bool {
        return self.opcode == null;
    }

    /// Bytes collected so far for the in-progress message.
    pub fn message_len(self: *const Fragments) usize {
        return self.len;
    }

    /// Opcode of the in-progress message, or null when idle.
    pub fn message_opcode(self: *const Fragments) ?OpCode {
        return self.opcode;
    }

    /// Returns null when another fragment is required, the completed frame
    /// otherwise. Control frames are returned immediately.
    ///
    /// Text validation is incremental: a non-FIN text fragment is accepted with
    /// a trailing partial code point, and the FIN continuation rejects a
    /// message that ends inside one. Invalid UTF-8 returns
    /// `error.InvalidUTF8`; a message exceeding `buffer` returns
    /// `error.BufferTooShort`, matching the collector's fail-closed contract.
    /// Payload bytes must already be unmasked, as the collector delivers them;
    /// masked frames return `error.PayloadMasked` instead of validating
    /// ciphertext as UTF-8.
    pub fn accumulate(self: *Fragments, incoming: Frame) Error!?Frame {
        if (incoming.masking_key != null) return error.PayloadMasked;

        return switch (incoming.opcode) {
            .text, .binary => self.start_message(incoming),
            .continuation => self.continue_message(incoming),
            else => incoming,
        };
    }

    /// Starts a data message, returning it directly when it is already complete.
    fn start_message(self: *Fragments, incoming: Frame) Error!?Frame {
        if (self.opcode != null) return error.InvalidFragment;

        if (incoming.fin) {
            if (incoming.opcode == .text) {
                utf8.validate(incoming.payload) catch |err| return errors.from_zslay(err);
            }
            return incoming;
        }

        if (incoming.payload.len > self.buffer.len) return error.BufferTooShort;

        // A pure transition: `self.utf8_state` is untouched on failure.
        var next_state = self.utf8_state;
        if (incoming.opcode == .text) {
            next_state = self.utf8_state.feed(incoming.payload) catch |err| return errors.from_zslay(err);
        }

        @memcpy(self.buffer[0..incoming.payload.len], incoming.payload);
        self.opcode = incoming.opcode;
        self.len = incoming.payload.len;
        self.utf8_state = next_state;
        return null;
    }

    /// Appends a continuation and returns the assembled message on `fin`.
    fn continue_message(self: *Fragments, incoming: Frame) Error!?Frame {
        const opcode = self.opcode orelse return error.InvalidContinuationFrame;

        const new_len = std.math.add(usize, self.len, incoming.payload.len) catch return error.FrameTooLarge;
        if (new_len > self.buffer.len) return error.BufferTooShort;

        // Validate the appended bytes before copying or committing length.
        var next_state = self.utf8_state;
        if (opcode == .text) {
            next_state = self.utf8_state.feed(incoming.payload) catch |err| return errors.from_zslay(err);
            if (incoming.fin) {
                next_state.finish() catch |err| return errors.from_zslay(err);
            }
        }

        @memcpy(self.buffer[self.len..new_len], incoming.payload);

        if (!incoming.fin) {
            self.len = new_len;
            self.utf8_state = next_state;
            return null;
        }

        const completed = Frame.init(true, opcode, null, self.buffer[0..new_len]);
        self.reset();
        return completed;
    }
};

/// Read-side frame collector that assembles fragmented messages.
///
/// The caller owns and sizes both buffers and they must not overlap.
/// `frame_buffer` must hold the largest frame payload the configured limit can
/// accept; a frame payload that fits zslay's limit but not `frame_buffer` fails
/// closed with `error.BufferTooShort` after the header is consumed.
/// `message_buffer` bounds one collected message. Size it to at least
/// `max_message_size - 1` bytes for full limit parity, because zslay rejects a
/// frame or cumulative message that reaches the exclusive fastwebsockets bound.
/// A message that exceeds `message_buffer` fails closed with
/// `error.BufferTooShort`.
///
/// `max_message_size` is exclusive: zero rejects every frame before any byte is
/// consumed, matching fastwebsockets. `init` rejects values above
/// `zslay.MaxPayloadLen` with `error.InvalidLength`.
pub const FragmentCollector = struct {
    reader: *std.Io.Reader,
    conn: zslay.Conn,
    frame_buffer: []u8,
    fragments: Fragments,
    max_message_size: usize,
    failure: ?Error = null,

    /// Builds a collector over caller-owned reader and buffers.
    ///
    /// `reader` is borrowed and must outlive the collector. The transmit path is
    /// never used, so `zslay.Conn` is initialized with an empty node slice.
    /// `message_buffer` must not overlap `frame_buffer`, because accumulation
    /// copies with `@memcpy`.
    pub fn init(
        reader: *std.Io.Reader,
        frame_buffer: []u8,
        message_buffer: []u8,
        role: Role,
        max_message_size: usize,
    ) Error!FragmentCollector {
        if (@as(u64, @intCast(max_message_size)) > zslay.MaxPayloadLen) return error.InvalidLength;
        if (zslay.event.ranges_overlap(
            @intFromPtr(frame_buffer.ptr),
            frame_buffer.len,
            @intFromPtr(message_buffer.ptr),
            message_buffer.len,
        )) return error.InvalidLength;

        // fastwebsockets rejects `payload_len >= max_message_size`, so zslay's
        // inclusive limit carries the exclusive bound minus one.
        const limit: u64 = if (max_message_size == 0) 0 else @intCast(max_message_size - 1);

        const conn = zslay.Conn.init(&.{}, .{
            .role = role,
            .max_frame_len = limit,
            .max_message_len = limit,
        }) catch |err| return errors.from_zslay(err);

        return .{
            .reader = reader,
            .conn = conn,
            .frame_buffer = frame_buffer,
            .fragments = Fragments.init(message_buffer),
            .max_message_size = max_message_size,
        };
    }

    /// Reads wire frames until a complete message or a control frame is ready.
    ///
    /// A partial header or payload is `error.UnexpectedEOF`; a reader failure is
    /// `error.IoError`. Text invalid UTF-8 is `error.InvalidUTF8`. Control
    /// frames are returned as soon as they are read and never disturb the
    /// in-progress message.
    ///
    /// Every protocol, frame, and I/O failure is latched and returned by later
    /// calls until `reset`; a zero `max_message_size` is a configuration
    /// rejection outside the latch. This keeps zslay's fragment accounting from
    /// drifting away from the accumulator when a decoded frame is rejected.
    pub fn read_frame(self: *FragmentCollector) Error!Frame {
        if (self.failure) |failure| return failure;
        if (self.max_message_size == 0) return error.FrameTooLarge;

        return self.read_frame_inner() catch |err| {
            self.failure = err;
            return err;
        };
    }

    /// Discards partial wire state, the failure latch, and any in-progress
    /// message.
    ///
    /// Safe only when `is_at_wire_boundary()` is true, or when the transport is
    /// being discarded. A header or payload read that failed mid-frame leaves
    /// the reader advanced; resetting the protocol state does not rewind it.
    pub fn reset(self: *FragmentCollector) void {
        self.conn.reset_rx();
        self.fragments.reset();
        self.failure = null;
    }

    /// True when zslay is exactly between frames and no message is in progress.
    ///
    /// This is stronger than `is_at_wire_boundary` because it also requires the
    /// accumulator to be idle. It is not the reset-safety predicate: `reset`
    /// only needs the reader aligned to a frame, even mid-message.
    pub fn is_at_frame_boundary(self: *const FragmentCollector) bool {
        return self.conn.is_at_frame_boundary() and self.fragments.is_idle();
    }

    /// True when the next wire byte starts a frame.
    ///
    /// This is the reset-safety predicate after an error, because the reader
    /// must be aligned to a frame. The accumulator may still hold an
    /// in-progress message.
    pub fn is_at_wire_boundary(self: *const FragmentCollector) bool {
        return self.conn.is_at_frame_boundary();
    }

    /// Reads frames until a message or control frame is ready.
    ///
    /// Each iteration consumes header or payload bytes and advances zslay's
    /// state, or delivers a frame; EOF and read failures terminate the loop.
    fn read_frame_inner(self: *FragmentCollector) Error!Frame {
        while (true) {
            const action = self.conn.advance_rx() catch |err| return errors.from_zslay(err);
            switch (action) {
                .need_header => try self.fill_header(),
                .need_payload => try self.fill_payload(),
                .emit_frame => {
                    if (try self.deliver_frame()) |completed| return completed;
                },
                // zslay returns only the three documented receive actions.
                else => unreachable,
            }
        }
    }

    /// Fills the header bytes zslay currently asks for.
    fn fill_header(self: *FragmentCollector) Error!void {
        const target = self.conn.get_header_buffer();
        const read_len = self.reader.readSliceShort(target) catch |err| return errors.from_reader(err);

        if (read_len < target.len) {
            // Bytes consumed by a short read must reach zslay so the wire
            // boundary predicate does not report a clean frame start while the
            // reader sits mid-header. This mirrors the connection read path.
            if (read_len != 0) {
                self.conn.advance_header_read(read_len) catch |err| return errors.from_zslay(err);
            }
            return error.UnexpectedEOF;
        }

        self.conn.advance_header_read(read_len) catch |err| return errors.from_zslay(err);
    }

    /// Reads the remaining bytes of the current frame payload in one bounded read.
    fn fill_payload(self: *FragmentCollector) Error!void {
        const decoded = self.conn.current_frame() catch |err| return errors.from_zslay(err);
        if (decoded.payload_len > @as(u64, @intCast(self.frame_buffer.len))) return error.BufferTooShort;

        const remaining = self.conn.rx_remaining() catch |err| return errors.from_zslay(err);
        const count: usize = @intCast(remaining);

        // The frame payload is read in a single all-or-nothing call; a short read is EOF.
        const read_len = self.reader.readSliceShort(self.frame_buffer[0..count]) catch |err|
            return errors.from_reader(err);
        if (read_len < count) return error.UnexpectedEOF;

        self.conn.advance_payload_read(remaining) catch |err| return errors.from_zslay(err);
    }

    /// Completes a decoded frame, unmasks it, and feeds the accumulator.
    fn deliver_frame(self: *FragmentCollector) Error!?Frame {
        const decoded = self.conn.current_frame() catch |err| return errors.from_zslay(err);
        self.conn.complete_frame() catch |err| return errors.from_zslay(err);

        const payload_len: usize = @intCast(decoded.payload_len);
        const payload = self.frame_buffer[0..payload_len];

        if (decoded.masking_key) |key| zslay.mask(payload, key, 0);

        const opcode = OpCode.from_wire(decoded.header.opcode) orelse return error.InvalidOpcode;
        return self.fragments.accumulate(Frame.init(decoded.header.fin, opcode, null, payload));
    }
};
