//! Pure frame facade over zslay.
//!
//! `Frame` mirrors the fastwebsockets 0.10.0 surface while delegating every wire
//! operation to zslay: header coding, length markers, control-frame checks,
//! masking, and close policy. Payload memory stays caller-owned; nothing here
//! allocates, performs I/O, or reads ambient state.

const std = @import("std");
const zslay = @import("zslay");
const errors = @import("error.zig");
const utf8 = @import("utf8.zig");

/// Caller-owned mutable payload bytes, so masking can happen in place.
pub const Payload = []u8;

/// RFC 6455 opcode; the wire enum stays in zslay.
pub const OpCode = zslay.Opcode;

/// RFC 6455 close status; conversions delegate to zslay.
pub const CloseCode = zslay.StatusCode;

/// Four-byte RFC 6455 masking key, re-exported from zslay.
pub const MaskingKey = zslay.MaskingKey;

/// Largest serialized header: base, 64-bit length, and masking key.
pub const MaxHeadSize = zslay.MaxFrameHeaderLen;

pub const Frame = struct {
    fin: bool,
    opcode: OpCode,
    /// Present exactly when the payload bytes are masked on the wire.
    masking_key: ?MaskingKey,
    payload: Payload,
    /// Negotiated RSV1 bit. False for every frame unless an extension is active.
    rsv1: bool = false,

    /// Builds a frame from its parts with RSV1 clear.
    ///
    /// When `masking_key` is non-null, `payload` must already be masked with
    /// that key. Prefer `mask` when starting from plaintext payload bytes.
    pub fn init(fin: bool, opcode: OpCode, masking_key: ?MaskingKey, payload: Payload) Frame {
        return .{
            .fin = fin,
            .opcode = opcode,
            .masking_key = masking_key,
            .payload = payload,
        };
    }

    /// Builds a frame with an explicit negotiated RSV1 bit.
    ///
    /// zslay enforces the RFC 7692 position rules when the frame is queued.
    pub fn init_rsv1(
        fin: bool,
        opcode: OpCode,
        rsv1: bool,
        masking_key: ?MaskingKey,
        payload: Payload,
    ) Frame {
        return .{
            .fin = fin,
            .opcode = opcode,
            .masking_key = masking_key,
            .payload = payload,
            .rsv1 = rsv1,
        };
    }

    pub fn text(payload: Payload) Frame {
        return init(true, .text, null, payload);
    }

    pub fn binary(payload: Payload) Frame {
        return init(true, .binary, null, payload);
    }

    pub fn ping(payload: Payload) Frame {
        return init(true, .ping, null, payload);
    }

    pub fn pong(payload: Payload) Frame {
        return init(true, .pong, null, payload);
    }

    /// Builds a close frame over an already encoded payload; validation belongs
    /// to `close` callers that own policy, and to zslay at send time.
    pub fn close_raw(payload: Payload) Frame {
        return init(true, .close, null, payload);
    }

    /// Encodes `code` and `reason` into caller storage and returns a FIN close
    /// frame over it.
    ///
    /// The code and reason are not validated here: zslay's `prepare_frame`,
    /// `queue_frame`, and `validate_close_payload` stay authoritative at send
    /// time. `reason` must not alias any part of `storage`, because the bytes
    /// are copied with `@memcpy`.
    pub fn close(code: u16, reason: []const u8, storage: []u8) error{BufferTooShort}!Frame {
        if (storage.len < 2) return error.BufferTooShort;
        if (reason.len > storage.len - 2) return error.BufferTooShort;

        std.mem.writeInt(u16, storage[0..2], code, .big);
        @memcpy(storage[2..][0..reason.len], reason);

        return init(true, .close, null, storage[0 .. 2 + reason.len]);
    }

    /// Validates the payload bytes; the caller decides whether the opcode makes
    /// UTF-8 meaningful, matching the raw-frame contract.
    ///
    /// Returns false for a masked frame: a caller must unmask first, because
    /// masked bytes are ciphertext and are not a meaningful UTF-8 stream. Never
    /// validate a non-FIN fragment in isolation, because a code point may span
    /// fragments; use the incremental validator for a message assembled across
    /// frames. Do not use this on an RSV1 payload: compressed bytes are not
    /// text and must be inflated and validated by the extension layer.
    pub fn is_utf8(self: *const Frame) bool {
        if (self.masking_key != null) return false;
        return utf8.is_valid(self.payload);
    }

    /// Stores `key` and masks the payload in place at byte offset zero.
    ///
    /// The frame must be unmasked; masking an already masked payload would XOR
    /// the previous key into the bytes while the header advertises only `key`.
    pub fn mask(self: *Frame, key: MaskingKey) void {
        std.debug.assert(self.masking_key == null);

        self.masking_key = key;
        zslay.mask(self.payload, key, 0);
    }

    /// Applies the stored key and clears `masking_key`.
    ///
    /// fastwebsockets leaves the key set after unmasking, so a second call would
    /// mask the payload again. Clearing it keeps the record consistent with the
    /// unmasked bytes.
    pub fn unmask(self: *Frame) void {
        const key = self.masking_key orelse return;

        unmask_at(self.payload, key, 0);
        self.masking_key = null;
    }

    /// Serializes the header into `head` and returns its byte length.
    pub fn fmt_head(self: *const Frame, head: []u8) zslay.Error!usize {
        return zslay.encode_header_with_options(
            head,
            self.header(),
            self.payload.len,
            self.masking_key,
            .{ .allow_rsv1 = self.rsv1 },
        );
    }

    /// Wire header size for this payload and masking state.
    pub fn header_len(self: *const Frame) zslay.Error!usize {
        return zslay.get_serialized_size(self.payload.len, self.masking_key != null);
    }

    /// Writes the header and payload through `writer`.
    ///
    /// For a masked frame, call `mask` before this method; zslay validates the
    /// masking-key consistency in the header but never XORs payload bytes.
    /// One vectored drain where the writer supports it; `writeVecAll` retries
    /// partial writes, so neither header nor payload bytes are dropped.
    pub fn writev(
        self: *const Frame,
        writer: *std.Io.Writer,
    ) (zslay.Error || std.Io.Writer.Error)!void {
        var head: zslay.FrameHeaderBuffer = undefined;
        const head_len = try self.fmt_head(&head);

        var iovecs = [_][]const u8{ head[0..head_len], self.payload };
        try writer.writeVecAll(&iovecs);
    }

    /// Encodes the frame into `buf` and returns the written slice.
    ///
    /// For a masked frame, call `mask` before this method. `buf` must not alias
    /// `payload`, because the payload is copied with `@memcpy`.
    pub fn write(self: *const Frame, buf: []u8) zslay.Error![]const u8 {
        const head_len = try self.fmt_head(buf);

        // `fmt_head` proved `head_len <= buf.len`, so the subtraction cannot
        // underflow and the remainder bounds the payload copy.
        if (self.payload.len > buf.len - head_len) return error.BufferTooShort;

        @memcpy(buf[head_len..][0..self.payload.len], self.payload);

        return buf[0 .. head_len + self.payload.len];
    }

    /// zslay header view of this record. RSV1 follows the negotiated frame bit;
    /// RSV2 and RSV3 remain clear. The length marker is derived by zslay.
    fn header(self: *const Frame) zslay.FrameHeader {
        return .{
            .opcode = @backingInt(self.opcode),
            .rsv3 = false,
            .rsv2 = false,
            .rsv1 = self.rsv1,
            .fin = self.fin,
            .payload_len = zslay.frame.length_marker(self.payload.len),
            .mask = self.masking_key != null,
        };
    }
};

/// Unmasks a whole payload at offset zero through zslay's XOR routine.
pub fn unmask(payload: []u8, key: MaskingKey) void {
    zslay.mask(payload, key, 0);
}

/// Unmasks a chunk whose first byte sits at `pos` in the full payload.
pub fn unmask_at(payload: []u8, key: MaskingKey, pos: u64) void {
    zslay.mask(payload, key, pos);
}

/// Wire header size for an arbitrary payload length and masking state.
pub fn header_len(payload_len: usize, masked: bool) zslay.Error!usize {
    return zslay.get_serialized_size(payload_len, masked);
}

/// Parses a wire opcode value; unknown values are rejected like
/// fastwebsockets `TryFrom<u8>`.
pub fn opcode_from_u8(raw: u8) errors.WebSocketError!OpCode {
    return OpCode.from_wire(raw) orelse error.InvalidValue;
}

/// Returns the wire opcode value.
pub fn opcode_to_u8(op: OpCode) u8 {
    return @intCast(@backingInt(op));
}

/// Round-trips any 16-bit value through the non-exhaustive zslay status enum.
pub fn close_code_from_u16(code: u16) CloseCode {
    return @fromBackingInt(code);
}

/// Returns the wire close status value.
pub fn close_code_to_u16(code: CloseCode) u16 {
    return @backingInt(code);
}

/// RFC 6455 and IANA close-code predicate owned by zslay.
pub fn is_valid_close_code(code: u16) bool {
    return zslay.is_valid_close_code(code);
}

/// Allowed close code for a parsed status.
///
/// 1014 is accepted here per the IANA registry, unlike fastwebsockets, where
/// `CloseCode::from(1014)` produces `Bad(1014)`.
pub fn is_allowed(code: CloseCode) bool {
    return zslay.is_valid_close_code(@backingInt(code));
}

/// True for close, ping, and pong frames.
pub fn is_control(op: OpCode) bool {
    return op.is_control();
}

/// Authoritative close payload validation, re-exported from zslay.
pub const validate_close_payload = zslay.validate_close_payload;
