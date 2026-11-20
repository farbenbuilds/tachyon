const std = @import("std");
const tachyon = @import("tachyon");

const support = @import("../support.zig");

const connection = tachyon.connection;
const Frame = tachyon.Frame;
const EncodedStream = support.EncodedStream;
const ConnectionRig = support.ConnectionRig;
const append_masked = support.append_masked;
const read_failed_stream = support.read_failed_stream;

test "WebSocket: non-FIN text fragments are delivered raw across a split code point" {
    var stream: EncodedStream(64) = .{};
    var first = [_]u8{ 0x41, 0xc2 };
    var second = [_]u8{0xa2};
    var third = [_]u8{0xff};
    var fourth = [_]u8{0xff};
    try append_masked(&stream, Frame.init(false, .text, null, &first), .{ 0x01, 0x11, 0x21, 0x31 });
    try append_masked(&stream, Frame.init(true, .continuation, null, &second), .{ 0x02, 0x12, 0x22, 0x32 });
    try append_masked(&stream, Frame.init(false, .text, null, &third), .{ 0x03, 0x13, 0x23, 0x33 });
    try append_masked(&stream, Frame.init(true, .continuation, null, &fourth), .{ 0x04, 0x14, 0x24, 0x34 });

    var reader = stream.reader();
    var server: ConnectionRig(16, 1, 64, 8, 0, 8) = .{};
    try server.init(&reader, .{ .role = .server });

    const start = try server.ws.read_frame();
    try std.testing.expectEqual(connection.OpCode.text, start.opcode);
    try std.testing.expect(!start.fin);
    try std.testing.expectEqualSlices(u8, &.{ 0x41, 0xc2 }, start.payload);

    const split_tail = try server.ws.read_frame();
    try std.testing.expectEqual(connection.OpCode.continuation, split_tail.opcode);
    try std.testing.expect(split_tail.fin);
    try std.testing.expectEqualSlices(u8, &.{0xa2}, split_tail.payload);

    const invalid_start = try server.ws.read_frame();
    try std.testing.expectEqual(connection.OpCode.text, invalid_start.opcode);
    try std.testing.expect(!invalid_start.fin);
    try std.testing.expectEqualSlices(u8, &.{0xff}, invalid_start.payload);

    const invalid_tail = try server.ws.read_frame();
    try std.testing.expectEqual(connection.OpCode.continuation, invalid_tail.opcode);
    try std.testing.expect(invalid_tail.fin);
    try std.testing.expectEqualSlices(u8, &.{0xff}, invalid_tail.payload);

    try std.testing.expectEqual(@as(usize, 0), server.writer.written);
    try std.testing.expect(server.ws.is_at_wire_boundary());
}

test "WebSocket: invalid FIN text latches InvalidUTF8 until reset at a frame boundary" {
    var stream: EncodedStream(32) = .{};
    var invalid = [_]u8{0xff};
    var valid = [_]u8{ 'o', 'k' };
    try append_masked(&stream, Frame.text(&invalid), .{ 0x05, 0x15, 0x25, 0x35 });
    try append_masked(&stream, Frame.text(&valid), .{ 0x06, 0x16, 0x26, 0x36 });

    var reader = stream.reader();
    var server: ConnectionRig(16, 1, 64, 8, 0, 8) = .{};
    try server.init(&reader, .{ .role = .server });

    try std.testing.expectError(error.InvalidUTF8, server.ws.read_frame());
    try std.testing.expect(server.ws.is_at_wire_boundary());
    const seek_after_failure = reader.seek;

    try std.testing.expectError(error.InvalidUTF8, server.ws.read_frame());
    try std.testing.expectEqual(seek_after_failure, reader.seek);

    server.ws.reset();
    const received = try server.ws.read_frame();
    try std.testing.expectEqualStrings("ok", received.payload);
    try std.testing.expect(server.ws.is_at_wire_boundary());
}

test "WebSocket: truncated header returns UnexpectedEOF and latches" {
    var wire = [_]u8{0x81};
    var reader = std.Io.Reader.fixed(&wire);
    var server: ConnectionRig(16, 1, 64, 8, 0, 8) = .{};
    try server.init(&reader, .{ .role = .server });

    try std.testing.expectError(error.UnexpectedEOF, server.ws.read_frame());
    try std.testing.expectEqual(@as(usize, 1), reader.seek);

    try std.testing.expectError(error.UnexpectedEOF, server.ws.read_frame());
    try std.testing.expectEqual(@as(usize, 1), reader.seek);
}

test "WebSocket: a partial header is not a wire boundary" {
    {
        var wire = [_]u8{0x81};
        var reader = std.Io.Reader.fixed(&wire);
        var server: ConnectionRig(16, 1, 64, 8, 0, 8) = .{};
        try server.init(&reader, .{ .role = .server });

        try std.testing.expectError(error.UnexpectedEOF, server.ws.read_frame());
        try std.testing.expectEqual(@as(usize, 1), reader.seek);
        try std.testing.expect(!server.ws.is_at_wire_boundary());

        try std.testing.expectError(error.UnexpectedEOF, server.ws.read_frame());
        try std.testing.expectEqual(@as(usize, 1), reader.seek);
        try std.testing.expect(!server.ws.is_at_wire_boundary());
    }

    {
        var reader = std.Io.Reader.fixed("");
        var server: ConnectionRig(16, 1, 64, 8, 0, 8) = .{};
        try server.init(&reader, .{ .role = .server });

        try std.testing.expectError(error.UnexpectedEOF, server.ws.read_frame());
        try std.testing.expectEqual(@as(usize, 0), reader.seek);
        try std.testing.expect(server.ws.is_at_wire_boundary());

        try std.testing.expectError(error.UnexpectedEOF, server.ws.read_frame());
        try std.testing.expectEqual(@as(usize, 0), reader.seek);
        try std.testing.expect(server.ws.is_at_wire_boundary());
    }
}

test "WebSocket: truncated payload returns UnexpectedEOF and latches" {
    var wire = [_]u8{ 0x81, 0x05, 'a', 'b', 'c' };
    var reader = std.Io.Reader.fixed(&wire);
    var client: ConnectionRig(16, 1, 64, 2, 0, 8) = .{};
    try client.init(&reader, .{
        .role = .client,
        .mask_keys = connection.MaskKeySource.from_seed(@splat(0x66)),
    });

    try std.testing.expectError(error.UnexpectedEOF, client.ws.read_frame());
    try std.testing.expectEqual(@as(usize, 5), reader.seek);
    try std.testing.expect(!client.ws.is_at_wire_boundary());

    try std.testing.expectError(error.UnexpectedEOF, client.ws.read_frame());
    try std.testing.expectEqual(@as(usize, 5), reader.seek);
    try std.testing.expect(!client.ws.is_at_wire_boundary());
}

test "WebSocket: a failed reader returns IoError and latches" {
    var reader = std.Io.Reader{
        .vtable = &.{ .stream = read_failed_stream },
        .buffer = &.{},
        .seek = 0,
        .end = 0,
    };
    var server: ConnectionRig(16, 1, 64, 8, 0, 8) = .{};
    try server.init(&reader, .{ .role = .server });

    try std.testing.expectError(error.IoError, server.ws.read_frame());
    try std.testing.expectError(error.IoError, server.ws.read_frame());

    server.ws.reset();
    try std.testing.expectError(error.IoError, server.ws.read_frame());
}
