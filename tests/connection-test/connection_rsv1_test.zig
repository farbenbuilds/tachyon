const std = @import("std");
const tachyon = @import("tachyon");

const support = @import("../support.zig");

const connection = tachyon.connection;
const Frame = tachyon.Frame;
const EncodedStream = support.EncodedStream;
const ConnectionRig = support.ConnectionRig;
const append_masked = support.append_masked;

test "Connection: default allow_rsv1 is false and RSV1 is rejected" {
    var stream: EncodedStream(16) = .{};
    var payload = [_]u8{0xff};
    try append_masked(&stream, Frame.init_rsv1(true, .text, true, null, &payload), .{ 1, 2, 3, 4 });

    var reader = stream.reader();
    var server: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
    try server.init(&reader, .{ .role = .server });

    try std.testing.expectError(error.ProtocolError, server.ws.read_frame());
    try std.testing.expectEqual(@as(usize, 0), server.writer.written);
    try std.testing.expectEqual(@as(usize, 0), server.ws.tx_pending());
}

test "Connection: negotiated RSV1 emits and queues first data frames" {
    var stream: EncodedStream(16) = .{};
    var payload = [_]u8{0xff};
    try append_masked(&stream, Frame.init_rsv1(true, .text, true, null, &payload), .{ 5, 6, 7, 8 });

    var reader = stream.reader();
    var server: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
    try server.init(&reader, .{
        .role = .server,
        .options = .{ .allow_rsv1 = true },
    });

    const incoming = try server.ws.read_frame();
    try std.testing.expect(incoming.rsv1);
    try std.testing.expectEqualSlices(u8, &.{0xff}, incoming.payload);

    var empty = [_]u8{};
    try server.ws.write_frame(Frame.init_rsv1(true, .text, true, null, &empty));
    try std.testing.expectEqualSlices(u8, &.{ 0xc1, 0x00 }, server.bytes());
    try std.testing.expectEqual(@as(usize, 0), server.ws.tx_pending());
}

test "Connection: compressed FIN text skips UTF8 until inflate" {
    var stream: EncodedStream(16) = .{};
    var invalid_text = [_]u8{0xff};
    try append_masked(&stream, Frame.init_rsv1(true, .text, true, null, &invalid_text), .{ 9, 10, 11, 12 });

    var reader = stream.reader();
    var server: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
    try server.init(&reader, .{
        .role = .server,
        .options = .{ .allow_rsv1 = true },
    });

    const incoming = try server.ws.read_frame();
    try std.testing.expect(incoming.rsv1);
    try std.testing.expectEqualSlices(u8, &.{0xff}, incoming.payload);
}

test "Connection: RSV1 on continuation, control, and second data frame is rejected" {
    {
        var stream: EncodedStream(16) = .{};
        var payload = [_]u8{};
        try append_masked(&stream, Frame.init_rsv1(false, .text, false, null, &payload), .{ 1, 2, 3, 4 });
        try append_masked(&stream, Frame.init_rsv1(true, .continuation, true, null, &payload), .{ 5, 6, 7, 8 });

        var reader = stream.reader();
        var server: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
        try server.init(&reader, .{ .role = .server, .options = .{ .allow_rsv1 = true } });
        try std.testing.expectEqual(connection.OpCode.text, (try server.ws.read_frame()).opcode);
        try std.testing.expectError(error.ProtocolError, server.ws.read_frame());
    }

    {
        var stream: EncodedStream(16) = .{};
        var payload = [_]u8{};
        try append_masked(&stream, Frame.init_rsv1(true, .ping, true, null, &payload), .{ 9, 10, 11, 12 });

        var reader = stream.reader();
        var server: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
        try server.init(&reader, .{ .role = .server, .options = .{ .allow_rsv1 = true } });
        try std.testing.expectError(error.ProtocolError, server.ws.read_frame());
    }

    {
        var stream: EncodedStream(16) = .{};
        var payload = [_]u8{};
        try append_masked(&stream, Frame.init_rsv1(true, .close, true, null, &payload), .{ 13, 14, 15, 16 });

        var reader = stream.reader();
        var server: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
        try server.init(&reader, .{ .role = .server, .options = .{ .allow_rsv1 = true } });
        try std.testing.expectError(error.ProtocolError, server.ws.read_frame());
    }

    {
        var stream: EncodedStream(16) = .{};
        var payload = [_]u8{};
        try append_masked(&stream, Frame.init_rsv1(false, .text, false, null, &payload), .{ 17, 18, 19, 20 });
        try append_masked(&stream, Frame.init_rsv1(true, .binary, true, null, &payload), .{ 21, 22, 23, 24 });

        var reader = stream.reader();
        var server: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
        try server.init(&reader, .{ .role = .server, .options = .{ .allow_rsv1 = true } });
        try std.testing.expectEqual(connection.OpCode.text, (try server.ws.read_frame()).opcode);
        try std.testing.expectError(error.ProtocolError, server.ws.read_frame());
    }
}
