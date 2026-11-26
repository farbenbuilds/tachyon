const std = @import("std");
const tachyon = @import("tachyon");

const support = @import("../support.zig");

const message = tachyon.stream;
const Frame = tachyon.Frame;
const EncodedStream = support.EncodedStream;
const ConnectionRig = support.ConnectionRig;
const append_masked = support.append_masked;

fn expect_borrowed(payload: []const u8, buffer: []const u8) !void {
    const start = @intFromPtr(payload.ptr);
    const buffer_start = @intFromPtr(buffer.ptr);

    try std.testing.expect(start >= buffer_start);
    try std.testing.expect(start + payload.len <= buffer_start + buffer.len);
}

test "Stream: unfragmented text yields one borrowed chunk with fin" {
    var stream: EncodedStream(32) = .{};
    var payload = [_]u8{ 'h', 'i' };
    try append_masked(&stream, Frame.text(&payload), .{ 0x01, 0x02, 0x03, 0x04 });

    var reader = stream.reader();
    var rig: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
    try rig.init(&reader, .{ .role = .server });
    var chunks = message.MessageReader.init(&rig.ws);

    const event = try chunks.next();
    const chunk = switch (event) {
        .chunk => |value| value,
        else => return error.UnexpectedEvent,
    };

    try std.testing.expectEqual(message.MessageKind.text, chunk.kind);
    try std.testing.expect(chunk.fin);
    try std.testing.expectEqualStrings("hi", chunk.payload);
    try expect_borrowed(chunk.payload, &rig.frame_buffer);
    try std.testing.expect(chunks.is_idle());
}

test "Stream: fragmented text yields chunks in frame order" {
    var stream: EncodedStream(64) = .{};
    var first = [_]u8{ 'a', 'b' };
    var second = [_]u8{ 'c', 'd' };
    var third = [_]u8{ 'e', 'f' };
    try append_masked(&stream, Frame.init(false, .text, null, &first), .{ 0x01, 0x02, 0x03, 0x04 });
    try append_masked(&stream, Frame.init(false, .continuation, null, &second), .{ 0x05, 0x06, 0x07, 0x08 });
    try append_masked(&stream, Frame.init(true, .continuation, null, &third), .{ 0x09, 0x0a, 0x0b, 0x0c });

    var reader = stream.reader();
    var rig: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
    try rig.init(&reader, .{ .role = .server });
    var chunks = message.MessageReader.init(&rig.ws);

    const one = switch (try chunks.next()) {
        .chunk => |value| value,
        else => return error.UnexpectedEvent,
    };
    try std.testing.expectEqualStrings("ab", one.payload);
    try std.testing.expect(!one.fin);

    const two = switch (try chunks.next()) {
        .chunk => |value| value,
        else => return error.UnexpectedEvent,
    };
    try std.testing.expectEqualStrings("cd", two.payload);
    try std.testing.expect(!two.fin);

    const three = switch (try chunks.next()) {
        .chunk => |value| value,
        else => return error.UnexpectedEvent,
    };
    try std.testing.expectEqualStrings("ef", three.payload);
    try std.testing.expect(three.fin);
    try std.testing.expectEqual(message.MessageKind.text, three.kind);
    try std.testing.expect(chunks.is_idle());
}

test "Stream: code point split across chunks validates incrementally" {
    var stream: EncodedStream(64) = .{};
    var first = [_]u8{ 'A', 0xc2 };
    var second = [_]u8{ 0xa2, 0xe2 };
    var third = [_]u8{ 0x82, 0xac };
    try append_masked(&stream, Frame.init(false, .text, null, &first), .{ 0x01, 0x02, 0x03, 0x04 });
    try append_masked(&stream, Frame.init(false, .continuation, null, &second), .{ 0x05, 0x06, 0x07, 0x08 });
    try append_masked(&stream, Frame.init(true, .continuation, null, &third), .{ 0x09, 0x0a, 0x0b, 0x0c });

    var reader = stream.reader();
    var rig: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
    try rig.init(&reader, .{ .role = .server });
    var chunks = message.MessageReader.init(&rig.ws);

    var joined: [6]u8 = undefined;
    var joined_len: usize = 0;
    var fin = false;
    while (!fin) {
        const chunk = switch (try chunks.next()) {
            .chunk => |value| value,
            else => return error.UnexpectedEvent,
        };
        @memcpy(joined[joined_len..][0..chunk.payload.len], chunk.payload);
        joined_len += chunk.payload.len;
        fin = chunk.fin;
    }

    try std.testing.expectEqualSlices(u8, "A\xc2\xa2\xe2\x82\xac", joined[0..joined_len]);
    try std.testing.expectEqual(@as(usize, 6), joined_len);
}

test "Stream: binary bypasses UTF-8 validation" {
    const expected_first = [_]u8{ 0xff, 0xfe };
    const expected_second = [_]u8{0x80};
    var stream: EncodedStream(32) = .{};
    var first = expected_first;
    var second = expected_second;
    try append_masked(&stream, Frame.init(false, .binary, null, &first), .{ 0x01, 0x02, 0x03, 0x04 });
    try append_masked(&stream, Frame.init(true, .continuation, null, &second), .{ 0x05, 0x06, 0x07, 0x08 });

    var reader = stream.reader();
    var rig: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
    try rig.init(&reader, .{ .role = .server });
    var chunks = message.MessageReader.init(&rig.ws);

    const one = switch (try chunks.next()) {
        .chunk => |value| value,
        else => return error.UnexpectedEvent,
    };
    try std.testing.expectEqual(message.MessageKind.binary, one.kind);
    try std.testing.expectEqualSlices(u8, &expected_first, one.payload);

    const two = switch (try chunks.next()) {
        .chunk => |value| value,
        else => return error.UnexpectedEvent,
    };
    try std.testing.expectEqualSlices(u8, &expected_second, two.payload);
    try std.testing.expect(two.fin);
}

test "Stream: zero-length frames preserve boundaries" {
    var stream: EncodedStream(32) = .{};
    var empty = [_]u8{};
    var payload = [_]u8{'a'};
    try append_masked(&stream, Frame.init(false, .text, null, &empty), .{ 0x01, 0x02, 0x03, 0x04 });
    try append_masked(&stream, Frame.init(true, .continuation, null, &payload), .{ 0x05, 0x06, 0x07, 0x08 });

    var reader = stream.reader();
    var rig: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
    try rig.init(&reader, .{ .role = .server });
    var chunks = message.MessageReader.init(&rig.ws);

    const one = switch (try chunks.next()) {
        .chunk => |value| value,
        else => return error.UnexpectedEvent,
    };
    const two = switch (try chunks.next()) {
        .chunk => |value| value,
        else => return error.UnexpectedEvent,
    };

    try std.testing.expectEqual(@as(usize, 0), one.payload.len);
    try std.testing.expect(!one.fin);
    try std.testing.expectEqualStrings("a", two.payload);
    try std.testing.expect(two.fin);
}

test "Stream: empty FIN text message is valid" {
    var stream: EncodedStream(16) = .{};
    var empty = [_]u8{};
    try append_masked(&stream, Frame.init(true, .text, null, &empty), .{ 0x01, 0x02, 0x03, 0x04 });

    var reader = stream.reader();
    var rig: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
    try rig.init(&reader, .{ .role = .server });
    var chunks = message.MessageReader.init(&rig.ws);

    const chunk = switch (try chunks.next()) {
        .chunk => |value| value,
        else => return error.UnexpectedEvent,
    };

    try std.testing.expectEqual(@as(usize, 0), chunk.payload.len);
    try std.testing.expect(chunk.fin);
    try std.testing.expect(chunks.is_idle());
}

test "Stream: empty FIN continuation completes a message" {
    var stream: EncodedStream(32) = .{};
    var payload = [_]u8{'a'};
    var empty = [_]u8{};
    try append_masked(&stream, Frame.init(false, .text, null, &payload), .{ 0x01, 0x02, 0x03, 0x04 });
    try append_masked(&stream, Frame.init(true, .continuation, null, &empty), .{ 0x05, 0x06, 0x07, 0x08 });

    var reader = stream.reader();
    var rig: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
    try rig.init(&reader, .{ .role = .server });
    var chunks = message.MessageReader.init(&rig.ws);

    _ = switch (try chunks.next()) {
        .chunk => |value| value,
        else => return error.UnexpectedEvent,
    };
    const last = switch (try chunks.next()) {
        .chunk => |value| value,
        else => return error.UnexpectedEvent,
    };

    try std.testing.expectEqual(@as(usize, 0), last.payload.len);
    try std.testing.expect(last.fin);
    try std.testing.expect(chunks.is_idle());
}

test "Stream: length boundaries yield exact borrowed chunks" {
    const lengths = [_]usize{ 0, 1, 125, 126, 127, 65535, 65536 };
    const key: tachyon.MaskingKey = .{ 0x01, 0x02, 0x03, 0x04 };

    var data: [65536]u8 = undefined;
    for (&data, 0..) |*byte, index| byte.* = @intCast(index & 0xff);
    var scratch: [65536]u8 = undefined;

    var stream: EncodedStream(132000) = .{};
    for (lengths) |length| {
        @memcpy(scratch[0..length], data[0..length]);
        try append_masked(&stream, Frame.binary(scratch[0..length]), key);
    }

    var reader = stream.reader();
    var rig: ConnectionRig(65536, 2, 64, 8, 0, 16) = .{};
    try rig.init(&reader, .{
        .role = .server,
        .options = .{ .max_message_size = 65537 },
    });
    var chunks = message.MessageReader.init(&rig.ws);

    for (lengths) |length| {
        const chunk = switch (try chunks.next()) {
            .chunk => |value| value,
            else => return error.UnexpectedEvent,
        };

        try std.testing.expectEqual(length, chunk.payload.len);
        try std.testing.expect(chunk.fin);
        try std.testing.expectEqualSlices(u8, data[0..length], chunk.payload);
        try expect_borrowed(chunk.payload, &rig.frame_buffer);
    }
}

test "Stream: a chunk aliases the connection frame buffer" {
    var stream: EncodedStream(16) = .{};
    var payload = [_]u8{ 'a', 'b', 'c' };
    try append_masked(&stream, Frame.text(&payload), .{ 0x01, 0x02, 0x03, 0x04 });

    var reader = stream.reader();
    var rig: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
    try rig.init(&reader, .{ .role = .server });
    var chunks = message.MessageReader.init(&rig.ws);

    const chunk = switch (try chunks.next()) {
        .chunk => |value| value,
        else => return error.UnexpectedEvent,
    };

    try std.testing.expectEqual(@intFromPtr(&rig.frame_buffer[0]), @intFromPtr(chunk.payload.ptr));

    rig.frame_buffer[0] = 'z';
    try std.testing.expectEqual(@as(u8, 'z'), chunk.payload[0]);
}

test "Stream: chunks are invalidated by the next read" {
    var stream: EncodedStream(32) = .{};
    var first = [_]u8{ 'a', 'b', 'c' };
    var second = [_]u8{ 'd', 'e' };
    try append_masked(&stream, Frame.text(&first), .{ 0x01, 0x02, 0x03, 0x04 });
    try append_masked(&stream, Frame.text(&second), .{ 0x05, 0x06, 0x07, 0x08 });

    var reader = stream.reader();
    var rig: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
    try rig.init(&reader, .{ .role = .server });
    var chunks = message.MessageReader.init(&rig.ws);

    const one = switch (try chunks.next()) {
        .chunk => |value| value,
        else => return error.UnexpectedEvent,
    };
    try std.testing.expectEqualStrings("abc", one.payload);

    const two = switch (try chunks.next()) {
        .chunk => |value| value,
        else => return error.UnexpectedEvent,
    };
    try std.testing.expectEqual(@intFromPtr(&rig.frame_buffer[0]), @intFromPtr(two.payload.ptr));
    try std.testing.expectEqualStrings("de", two.payload);
}
