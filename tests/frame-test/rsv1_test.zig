const std = @import("std");
const zslay = @import("zslay");
const tachyon = @import("tachyon");

const Frame = tachyon.Frame;

test "Frame: default rejects rsv1 and explicit constructor preserves it" {
    var payload = [_]u8{'x'};
    const strict = Frame.text(&payload);
    try std.testing.expect(!strict.rsv1);

    var head: zslay.FrameHeaderBuffer = undefined;
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 0x01 }, head[0..try strict.fmt_head(&head)]);

    const compressed = Frame.init_rsv1(true, .text, true, null, &payload);
    try std.testing.expect(compressed.rsv1);
    const head_len = try compressed.fmt_head(&head);
    try std.testing.expectEqualSlices(u8, &.{ 0xc1, 0x01 }, head[0..head_len]);
}

test "Frame: RSV1 write path uses zslay negotiated option" {
    var payload = [_]u8{ 'h', 'i' };
    const compressed = Frame.init_rsv1(true, .binary, true, null, &payload);

    var out: [16]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out);
    try compressed.writev(&writer);
    try std.testing.expectEqual(@as(usize, 4), writer.end);
    try std.testing.expectEqualSlices(u8, &.{ 0xc2, 0x02, 'h', 'i' }, out[0..writer.end]);

    var copied: [16]u8 = undefined;
    const encoded = try compressed.write(&copied);
    try std.testing.expectEqualSlices(u8, &.{ 0xc2, 0x02, 'h', 'i' }, encoded);
}
