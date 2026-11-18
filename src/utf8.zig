//! Incremental UTF-8 validation for text-message payloads.
//!
//! zslay owns close-reason UTF-8 validation and the WebSocket error taxonomy;
//! text-message validation is a tachyon responsibility. Complete ranges are
//! validated by `std.unicode`, while a small caller-carried `State` remembers
//! only the final bytes of a code point that spans a chunk boundary.
//!
//! `std.Io` readers return arbitrary chunk sizes, so validation must pause
//! inside a code point instead of treating each read as a complete message.
//! Nothing here allocates or parses wire frames. `validate_reader` is an
//! optional edge adapter over a caller-buffered `std.Io.Reader`; it validates
//! payload bytes, not framing bytes.

const std = @import("std");
const zslay = @import("zslay");

/// zslay's `InvalidUtf8` is the single wire error for text validation; the
/// connection boundary maps it to `WebSocketError.InvalidUTF8` once.
pub const Error = zslay.Error;

/// A UTF-8 sequence is at most four bytes, so at most three bytes can remain.
const max_carry_len = 3;

/// Incremental UTF-8 validator state.
///
/// `feed` is a pure transition: it returns a new state and leaves the input
/// state untouched on failure. Call `finish` at the end of a text message to
/// reject a truncated final code point.
pub const State = struct {
    carry: [max_carry_len]u8 = @splat(0),
    /// `u2` makes the 0-3 byte invariant structural.
    carry_len: u2 = 0,

    /// Feeds one payload chunk and returns the next state.
    pub fn feed(self: State, chunk: []const u8) Error!State {
        var next = self;
        var input = chunk;

        if (next.carry_len != 0) {
            const expected: usize = std.unicode.utf8ByteSequenceLength(next.carry[0]) catch return error.InvalidUtf8;
            const carried: usize = next.carry_len;
            if (carried >= expected) return error.InvalidUtf8;

            const need = expected - carried;
            const take = @min(need, input.len);

            // Reject a malformed continuation as soon as it arrives. The
            // special lead-byte ranges (overlong, surrogate, above U+10FFFF)
            // stay with `std.unicode.utf8ValidateSlice` once the sequence is
            // complete.
            for (input[0..take]) |byte| {
                if (byte & 0xc0 != 0x80) return error.InvalidUtf8;
            }

            if (take < need) {
                @memcpy(next.carry[carried..][0..take], input[0..take]);
                next.carry_len = @intCast(carried + take);
                return next;
            }

            var window: [4]u8 = undefined;
            @memcpy(window[0..carried], next.carry[0..carried]);
            @memcpy(window[carried..][0..take], input[0..take]);
            if (!std.unicode.utf8ValidateSlice(window[0..expected])) return error.InvalidUtf8;

            next.carry_len = 0;
            input = input[take..];
        }

        if (input.len == 0) return next;

        const split = try incomplete_tail_start(input);
        if (!std.unicode.utf8ValidateSlice(input[0..split])) return error.InvalidUtf8;

        const tail = input[split..];
        @memcpy(next.carry[0..tail.len], tail);
        next.carry_len = @intCast(tail.len);
        return next;
    }

    /// Rejects a state that ends inside a code point.
    pub fn finish(self: State) Error!void {
        if (self.carry_len != 0) return error.InvalidUtf8;
    }

    /// Reports whether the state ends on a code-point boundary.
    pub fn is_complete(self: State) bool {
        return self.carry_len == 0;
    }
};

comptime {
    std.debug.assert(@sizeOf(State) <= 8);
}

/// Returns the start of a trailing incomplete code point, or `input.len` when
/// the whole slice ends on a boundary.
///
/// Only the last four bytes are inspected. A longer run of continuation bytes
/// is invalid, so it is left for `std.unicode.utf8ValidateSlice` to reject.
fn incomplete_tail_start(input: []const u8) Error!usize {
    var start = input.len;
    var inspected: usize = 0;

    while (start > 0 and inspected < 4) : (inspected += 1) {
        const last = input[start - 1];
        if (last & 0xc0 != 0x80) {
            const begin = start - 1;
            const len = std.unicode.utf8ByteSequenceLength(last) catch return error.InvalidUtf8;
            return if (begin + len > input.len) begin else input.len;
        }
        start -= 1;
    }

    return input.len;
}

/// Validates a complete contiguous slice.
pub fn validate(input: []const u8) Error!void {
    if (!is_valid(input)) return error.InvalidUtf8;
}

/// Reports whether a complete contiguous slice is valid UTF-8.
pub fn is_valid(input: []const u8) bool {
    return std.unicode.utf8ValidateSlice(input);
}

/// Validates a `std.Io.Reader` payload stream in caller-owned chunks.
///
/// The reader may return any chunk size; state is carried across reads. The
/// reader is consumed to end-of-stream, and `buffer` must be non-empty. This
/// function does not know frame boundaries: wrap a bounded payload in
/// `std.Io.Reader.limited` when the message length is known.
pub fn validate_reader(reader: *std.Io.Reader, buffer: []u8) (Error || std.Io.Reader.ShortError)!void {
    if (buffer.len == 0) return error.BufferTooShort;

    var state: State = .{};
    while (true) {
        const n = try reader.readSliceShort(buffer);
        if (n != 0) state = try state.feed(buffer[0..n]);
        if (n < buffer.len) break;
    }
    try state.finish();
}
