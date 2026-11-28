const std = @import("std");
const tachyon = @import("tachyon");

const support = @import("../support.zig");

const stream = tachyon.stream;
const Frame = tachyon.Frame;
const EncodedStream = support.EncodedStream;
const ConnectionRig = support.ConnectionRig;
const append_masked = support.append_masked;

test "Stream: compressed message flag skips UTF8 on continuations" {
    var wire: EncodedStream(32) = .{};
    var first = [_]u8{0xff};
    var second = [_]u8{0xfe};
    try append_masked(&wire, Frame.init_rsv1(false, .text, true, null, &first), .{ 1, 2, 3, 4 });
    try append_masked(&wire, Frame.init_rsv1(true, .continuation, false, null, &second), .{ 5, 6, 7, 8 });

    var reader = wire.reader();
    var rig: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
    try rig.init(&reader, .{
        .role = .server,
        .options = .{ .allow_rsv1 = true },
    });
    var chunks = stream.MessageReader.init(&rig.ws);

    const one = switch (try chunks.next()) {
        .chunk => |chunk| chunk,
        else => return error.UnexpectedEvent,
    };
    try std.testing.expect(one.rsv1);
    try std.testing.expect(!one.fin);
    try std.testing.expect(chunks.is_compressed());
    try std.testing.expectEqualSlices(u8, &.{0xff}, one.payload);

    const two = switch (try chunks.next()) {
        .chunk => |chunk| chunk,
        else => return error.UnexpectedEvent,
    };
    try std.testing.expect(!two.rsv1);
    try std.testing.expect(two.fin);
    try std.testing.expectEqualSlices(u8, &.{0xfe}, two.payload);
}

test "Stream: writer emits RSV1 only on the first frame" {
    var empty = std.Io.Reader.fixed("");
    var rig: ConnectionRig(16, 4, 64, 8, 0, 32) = .{};
    try rig.init(&empty, .{
        .role = .server,
        .options = .{ .allow_rsv1 = true },
    });

    var payload = [_]u8{'x'};
    var writer = stream.MessageWriter.init(&rig.ws, .text);
    try writer.write_with_options(&payload, false, .{ .rsv1 = true });
    try writer.write_with_options(&payload, true, .{});
    try writer.flush();

    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x41, 0x01, 'x', 0x80, 0x01, 'x' },
        rig.bytes(),
    );
}

test "Stream: compressed empty message writes RSV1 FIN" {
    var empty = std.Io.Reader.fixed("");
    var rig: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
    try rig.init(&empty, .{
        .role = .server,
        .options = .{ .allow_rsv1 = true },
    });

    var zero = [_]u8{};
    var writer = stream.MessageWriter.init(&rig.ws, .binary);
    try writer.write_with_options(&zero, true, .{ .rsv1 = true });
    try writer.flush();
    try std.testing.expectEqualSlices(u8, &.{ 0xc2, 0x00 }, rig.bytes());
}
