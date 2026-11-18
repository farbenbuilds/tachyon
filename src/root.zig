//! tachyon public module.
//!
//! Re-exports the pinned zslay codec, the frame facade, and the WebSocket
//! error model.

pub const zslay = @import("zslay");

pub const frame = @import("frame.zig");
pub const Frame = frame.Frame;
pub const Payload = frame.Payload;
pub const OpCode = frame.OpCode;
pub const CloseCode = frame.CloseCode;
pub const MaskingKey = frame.MaskingKey;
pub const MaxHeadSize = frame.MaxHeadSize;
pub const unmask = frame.unmask;
pub const unmask_at = frame.unmask_at;
pub const header_len = frame.header_len;
pub const opcode_from_u8 = frame.opcode_from_u8;
pub const opcode_to_u8 = frame.opcode_to_u8;
pub const close_code_from_u16 = frame.close_code_from_u16;
pub const close_code_to_u16 = frame.close_code_to_u16;
pub const is_valid_close_code = frame.is_valid_close_code;
pub const is_allowed = frame.is_allowed;
pub const is_control = frame.is_control;
pub const validate_close_payload = frame.validate_close_payload;

pub const errors = @import("error.zig");
pub const WebSocketError = errors.WebSocketError;
pub const ZslayQueueError = errors.ZslayQueueError;
pub const from_zslay = errors.from_zslay;
pub const from_zslay_close = errors.from_zslay_close;
pub const from_zslay_queue = errors.from_zslay_queue;
pub const invalid_status_code = errors.invalid_status_code;
pub const from_reader = errors.from_reader;
pub const from_writer = errors.from_writer;
pub const from_stream = errors.from_stream;
pub const to_zslay = errors.to_zslay;
pub const description = errors.description;
pub const to_string = errors.to_string;
pub const to_close_code = errors.to_close_code;
pub const is_protocol_error = errors.is_protocol_error;
pub const is_fatal = errors.is_fatal;
pub const is_utf8_error = errors.is_utf8_error;
pub const is_eof_error = errors.is_eof_error;

test {
    _ = @import("test.zig");
}

test "Dependency: zslay encodes an unmasked text frame header" {
    const std = @import("std");

    var header_buffer: zslay.FrameHeaderBuffer = undefined;
    const header: zslay.FrameHeader = .{
        .opcode = @backingInt(zslay.Opcode.text),
        .rsv3 = false,
        .rsv2 = false,
        .rsv1 = false,
        .fin = true,
        .payload_len = 5,
        .mask = false,
    };

    const encoded_len = try zslay.encode_header(&header_buffer, header, 5, null);

    try std.testing.expectEqual(@as(usize, 2), encoded_len);
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 0x05 }, header_buffer[0..encoded_len]);
}

test "Frame: public module re-exports the facade" {
    const std = @import("std");

    var payload = [_]u8{ 'o', 'k' };
    const f = Frame.text(&payload);

    try std.testing.expectEqual(OpCode.text, f.opcode);
    try std.testing.expectEqual(@as(usize, 2), try header_len(payload.len, false));
    try std.testing.expectEqual(CloseCode.normal_closure, close_code_from_u16(1000));
    try std.testing.expect(is_control(.ping));
    try std.testing.expect(f.is_utf8());
}
