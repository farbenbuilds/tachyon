const std = @import("std");
const zslay = @import("zslay");
const tachyon = @import("tachyon");

const support = @import("../support.zig");

const connection = tachyon.connection;
const Frame = tachyon.Frame;
const MaskingKey = tachyon.MaskingKey;
const WebSocketError = tachyon.WebSocketError;
const EncodedStream = support.EncodedStream;
const next_wire_frame = support.next_wire_frame;
const ConnectionRig = support.ConnectionRig;
const append_masked = support.append_masked;

test "WebSocket: auto_pong suppresses ping and sends an exact pong" {
    var stream: EncodedStream(32) = .{};
    var ping_payload = [_]u8{ 'h', 'i' };
    var text_payload = [_]u8{ 'o', 'k' };
    try append_masked(&stream, Frame.ping(&ping_payload), .{ 0x01, 0x02, 0x03, 0x04 });
    try append_masked(&stream, Frame.text(&text_payload), .{ 0x05, 0x06, 0x07, 0x08 });

    var reader = stream.reader();
    var server: ConnectionRig(32, 2, 64, 8, 0, 32) = .{};
    try server.init(&reader, .{ .role = .server });

    const received = try server.ws.read_frame();
    try std.testing.expectEqual(connection.OpCode.text, received.opcode);
    try std.testing.expectEqualStrings("ok", received.payload);

    var index: usize = 0;
    const pong = try next_wire_frame(server.bytes(), &index);
    try std.testing.expectEqual(connection.OpCode.pong, connection.OpCode.from_wire(pong.header.header.opcode).?);
    try std.testing.expect(!pong.header.header.mask);
    try std.testing.expectEqual(@as(?connection.MaskingKey, null), pong.header.masking_key);
    try std.testing.expectEqualStrings("hi", pong.payload);
    try std.testing.expectEqual(server.writer.written, index);
}

test "WebSocket: auto_pong off delivers the ping and sends nothing" {
    var stream: EncodedStream(16) = .{};
    var payload = [_]u8{ 'h', 'i' };
    try append_masked(&stream, Frame.ping(&payload), .{ 0x09, 0x0a, 0x0b, 0x0c });

    var reader = stream.reader();
    var server: ConnectionRig(16, 1, 64, 8, 0, 8) = .{};
    try server.init(&reader, .{ .role = .server, .options = .{ .auto_pong = false } });

    const received = try server.ws.read_frame();
    try std.testing.expectEqual(connection.OpCode.ping, received.opcode);
    try std.testing.expect(received.fin);
    try std.testing.expectEqual(@as(?connection.MaskingKey, null), received.masking_key);
    try std.testing.expectEqualStrings("hi", received.payload);
    try std.testing.expectEqual(@as(usize, 0), server.writer.written);
}

test "WebSocket: auto_apply_mask off delivers masked frames and skips control policy" {
    const key: MaskingKey = .{ 0x11, 0x22, 0x33, 0x44 };
    var stream: EncodedStream(64) = .{};
    var text_payload = [_]u8{ 'h', 'i' };
    var ping_payload = [_]u8{'p'};
    var close_storage: [8]u8 = undefined;
    try append_masked(&stream, Frame.text(&text_payload), key);
    try append_masked(&stream, Frame.ping(&ping_payload), key);
    try append_masked(&stream, try Frame.close(1000, "bye", &close_storage), key);

    var reader = stream.reader();
    var server: ConnectionRig(32, 2, 64, 8, 0, 8) = .{};
    try server.init(&reader, .{ .role = .server, .options = .{ .auto_apply_mask = false } });

    var plaintext: [8]u8 = undefined;

    const text = try server.ws.read_frame();
    try std.testing.expectEqual(connection.OpCode.text, text.opcode);
    try std.testing.expectEqual(@as(?connection.MaskingKey, key), text.masking_key);
    @memcpy(plaintext[0..text.payload.len], text.payload);
    zslay.mask(plaintext[0..text.payload.len], key, 0);
    try std.testing.expectEqualStrings("hi", plaintext[0..text.payload.len]);

    const ping = try server.ws.read_frame();
    try std.testing.expectEqual(connection.OpCode.ping, ping.opcode);
    try std.testing.expectEqual(@as(?connection.MaskingKey, key), ping.masking_key);
    @memcpy(plaintext[0..ping.payload.len], ping.payload);
    zslay.mask(plaintext[0..ping.payload.len], key, 0);
    try std.testing.expectEqualStrings("p", plaintext[0..ping.payload.len]);
    try std.testing.expectEqual(@as(usize, 0), server.writer.written);

    const close = try server.ws.read_frame();
    try std.testing.expectEqual(connection.OpCode.close, close.opcode);
    try std.testing.expectEqual(@as(?connection.MaskingKey, key), close.masking_key);
    @memcpy(plaintext[0..close.payload.len], close.payload);
    zslay.mask(plaintext[0..close.payload.len], key, 0);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xe8, 'b', 'y', 'e' }, plaintext[0..close.payload.len]);
    try std.testing.expectEqual(@as(usize, 0), server.writer.written);
    try std.testing.expect(!server.ws.is_closed());
}

test "WebSocket: client with auto_apply_mask off delivers control frames without replying" {
    const seed: [connection.mask_seed_len]u8 = @splat(0x3c);
    var stream: EncodedStream(32) = .{};
    var ping_payload = [_]u8{ 'h', 'i' };
    var close_storage: [8]u8 = undefined;
    var trailing_payload = [_]u8{'x'};
    try stream.append(Frame.ping(&ping_payload));
    try stream.append(try Frame.close(1000, "bye", &close_storage));
    try stream.append(Frame.text(&trailing_payload));

    var reader = stream.reader();
    var client: ConnectionRig(32, 2, 64, 8, 0, 32) = .{};
    try client.init(&reader, .{
        .role = .client,
        .options = .{ .auto_apply_mask = false },
        .mask_keys = connection.MaskKeySource.from_seed(seed),
    });

    const ping = try client.ws.read_frame();
    try std.testing.expectEqual(connection.OpCode.ping, ping.opcode);
    try std.testing.expectEqualStrings("hi", ping.payload);
    try std.testing.expectEqual(@as(usize, 0), client.writer.written);
    try std.testing.expect(!client.ws.is_closed());

    const close = try client.ws.read_frame();
    try std.testing.expectEqual(connection.OpCode.close, close.opcode);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xe8, 'b', 'y', 'e' }, close.payload);
    try std.testing.expectEqual(@as(usize, 0), client.writer.written);

    // Neither an automatic pong nor a close echo may latch this client's read,
    // but the validated close still makes the connection terminal.
    try std.testing.expectEqual(@as(?WebSocketError, null), client.ws.read_failure);
    try std.testing.expectEqual(@as(?WebSocketError, null), client.ws.write_failure);
    try std.testing.expect(client.ws.is_closed());

    try std.testing.expectError(error.ConnectionClosed, client.ws.read_frame());
    try std.testing.expectEqual(@as(usize, 0), client.writer.written);
}

test "WebSocket: suppressed invalid close reply is terminal" {
    const seed: [connection.mask_seed_len]u8 = @splat(0x3d);
    var stream: EncodedStream(32) = .{};
    var close_storage: [8]u8 = undefined;
    var trailing_payload = [_]u8{'x'};
    try stream.append(try Frame.close(999, "bad", &close_storage));
    try stream.append(Frame.text(&trailing_payload));

    var reader = stream.reader();
    var client: ConnectionRig(32, 2, 64, 8, 0, 32) = .{};
    try client.init(&reader, .{
        .role = .client,
        .options = .{ .auto_apply_mask = false },
        .mask_keys = connection.MaskKeySource.from_seed(seed),
    });

    try std.testing.expectError(error.InvalidCloseCode, client.ws.read_frame());
    try std.testing.expectEqual(@as(usize, 0), client.writer.written);
    try std.testing.expectEqual(@as(?WebSocketError, null), client.ws.write_failure);
    try std.testing.expect(client.ws.is_closed());

    // The invalid close was fully consumed, so the wire boundary is clean; the
    // reset clears only the latched read failure and keeps `closed`.
    client.ws.reset();

    try std.testing.expectError(error.ConnectionClosed, client.ws.read_frame());
    try std.testing.expectEqual(@as(usize, 0), client.writer.written);
}

test "WebSocket: auto_pong masks a client pong with a fresh key" {
    const seed: [connection.mask_seed_len]u8 = @splat(0x55);
    var stream: EncodedStream(32) = .{};
    var ping_payload = [_]u8{ 'h', 'i' };
    var text_payload = [_]u8{ 'o', 'k' };
    try stream.append(Frame.ping(&ping_payload));
    try stream.append(Frame.text(&text_payload));

    var reader = stream.reader();
    var client: ConnectionRig(32, 2, 64, 8, 0, 64) = .{};
    try client.init(&reader, .{
        .role = .client,
        .mask_keys = connection.MaskKeySource.from_seed(seed),
    });

    var outbound = [_]u8{'a'};
    try client.ws.write_frame(Frame.text(&outbound));

    const received = try client.ws.read_frame();
    try std.testing.expectEqual(connection.OpCode.text, received.opcode);
    try std.testing.expectEqualStrings("ok", received.payload);

    var expected_keys = connection.MaskKeySource.from_seed(seed);
    const text_key = expected_keys.next();
    const pong_key = expected_keys.next();

    var index: usize = 0;
    const text_frame = try next_wire_frame(client.bytes(), &index);
    try std.testing.expectEqual(connection.OpCode.text, connection.OpCode.from_wire(text_frame.header.header.opcode).?);
    try std.testing.expectEqualSlices(u8, &text_key, &text_frame.header.masking_key.?);

    const pong = try next_wire_frame(client.bytes(), &index);
    try std.testing.expectEqual(connection.OpCode.pong, connection.OpCode.from_wire(pong.header.header.opcode).?);
    try std.testing.expect(pong.header.header.mask);
    const key = pong.header.masking_key.?;
    try std.testing.expectEqualSlices(u8, &pong_key, &key);
    try std.testing.expectEqual(@as(usize, 2), pong.payload.len);
    try std.testing.expectEqual(@as(u8, 'h' ^ key[0]), pong.payload[0]);
    try std.testing.expectEqual(@as(u8, 'i' ^ key[1]), pong.payload[1]);
}

test "WebSocket: auto_pong preserves an in-progress fragmented message" {
    var stream: EncodedStream(64) = .{};
    var first = [_]u8{ 'h', 'e' };
    var ping_payload = [_]u8{'p'};
    var last = [_]u8{ 'l', 'l', 'o' };
    try append_masked(&stream, Frame.init(false, .text, null, &first), .{ 0x01, 0x02, 0x03, 0x04 });
    try append_masked(&stream, Frame.ping(&ping_payload), .{ 0x05, 0x06, 0x07, 0x08 });
    try append_masked(&stream, Frame.init(true, .continuation, null, &last), .{ 0x09, 0x0a, 0x0b, 0x0c });

    var reader = stream.reader();
    var server: ConnectionRig(32, 2, 64, 8, 0, 32) = .{};
    try server.init(&reader, .{ .role = .server });

    const start = try server.ws.read_frame();
    try std.testing.expectEqual(connection.OpCode.text, start.opcode);
    try std.testing.expect(!start.fin);
    try std.testing.expectEqualStrings("he", start.payload);
    try std.testing.expectEqual(connection.OpCode.text, server.ws.conn.rx_fragment.opcode.?);
    try std.testing.expectEqual(@as(u64, 2), server.ws.conn.rx_fragment.message_len);

    const tail = try server.ws.read_frame();
    try std.testing.expectEqual(connection.OpCode.continuation, tail.opcode);
    try std.testing.expect(tail.fin);
    try std.testing.expectEqualStrings("llo", tail.payload);
    try std.testing.expectEqual(@as(?connection.OpCode, null), server.ws.conn.rx_fragment.opcode);
    try std.testing.expectEqual(@as(u64, 0), server.ws.conn.rx_fragment.message_len);
    try std.testing.expect(server.ws.is_at_wire_boundary());

    var index: usize = 0;
    const pong = try next_wire_frame(server.bytes(), &index);
    try std.testing.expectEqual(connection.OpCode.pong, connection.OpCode.from_wire(pong.header.header.opcode).?);
    try std.testing.expectEqualStrings("p", pong.payload);
    try std.testing.expectEqual(server.writer.written, index);
}

test "WebSocket: ping-only after a close write returns ConnectionClosed without pong or extra read" {
    var stream: EncodedStream(32) = .{};
    var first_ping = [_]u8{'?'};
    var second_ping = [_]u8{'!'};
    try append_masked(&stream, Frame.ping(&first_ping), .{ 0x10, 0x20, 0x30, 0x40 });
    try append_masked(&stream, Frame.ping(&second_ping), .{ 0x50, 0x60, 0x70, 0x80 });

    var reader = stream.reader();
    var server: ConnectionRig(32, 2, 64, 8, 0, 32) = .{};
    try server.init(&reader, .{ .role = .server });

    var close_storage: [2]u8 = undefined;
    try server.ws.write_frame(try Frame.close(1000, "", &close_storage));
    const output_after_close = server.writer.written;

    try std.testing.expectError(error.ConnectionClosed, server.ws.read_frame());
    try std.testing.expectEqual(output_after_close, server.writer.written);
    try std.testing.expectEqual(@as(usize, 7), reader.seek);
    try std.testing.expectEqual(@as(usize, 7), reader.buffered().len);
    try std.testing.expect(server.ws.is_closed());
    try std.testing.expectEqual(@as(usize, 0), server.ws.tx_pending());

    var index: usize = 0;
    const close = try next_wire_frame(server.bytes(), &index);
    try std.testing.expectEqual(connection.OpCode.close, connection.OpCode.from_wire(close.header.header.opcode).?);
    try std.testing.expectEqual(server.writer.written, index);
}
