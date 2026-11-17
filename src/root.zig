//! tachyon public module.
//!
//! Protocol modules land in later changes. This bootstrap exposes the pinned
//! zslay codec that the frame layer will wrap.

pub const zslay = @import("zslay");

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

    const header_len = try zslay.encode_header(&header_buffer, header, 5, null);

    try std.testing.expectEqual(@as(usize, 2), header_len);
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 0x05 }, header_buffer[0..header_len]);
}
