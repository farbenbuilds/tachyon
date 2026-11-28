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

test "WebSocket: valid close is returned and echoed with the exact payload" {
    var stream: EncodedStream(32) = .{};
    var close_storage: [8]u8 = undefined;
    try append_masked(&stream, try Frame.close(1000, "bye", &close_storage), .{ 0xa1, 0xb2, 0xc3, 0xd4 });

    var reader = stream.reader();
    var server: ConnectionRig(32, 2, 64, 8, 0, 32) = .{};
    try server.init(&reader, .{ .role = .server });

    const received = try server.ws.read_frame();
    try std.testing.expectEqual(connection.OpCode.close, received.opcode);
    try std.testing.expectEqual(@as(?connection.MaskingKey, null), received.masking_key);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xe8, 'b', 'y', 'e' }, received.payload);
    try std.testing.expect(server.ws.is_closed());

    var index: usize = 0;
    const echo = try next_wire_frame(server.bytes(), &index);
    try std.testing.expectEqual(connection.OpCode.close, connection.OpCode.from_wire(echo.header.header.opcode).?);
    try std.testing.expect(!echo.header.header.mask);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xe8, 'b', 'y', 'e' }, echo.payload);
    try std.testing.expectEqual(server.writer.written, index);
}

test "WebSocket: ping-only after a close echo returns ConnectionClosed without pong or extra read" {
    var stream: EncodedStream(64) = .{};
    var close_storage: [8]u8 = undefined;
    var first_ping = [_]u8{'?'};
    var second_ping = [_]u8{'!'};
    try append_masked(&stream, try Frame.close(1000, "", &close_storage), .{ 0xa1, 0xb2, 0xc3, 0xd4 });
    try append_masked(&stream, Frame.ping(&first_ping), .{ 0x11, 0x22, 0x33, 0x44 });
    try append_masked(&stream, Frame.ping(&second_ping), .{ 0x55, 0x66, 0x77, 0x88 });

    var reader = stream.reader();
    var server: ConnectionRig(32, 2, 64, 8, 0, 32) = .{};
    try server.init(&reader, .{ .role = .server });

    const received = try server.ws.read_frame();
    try std.testing.expectEqual(connection.OpCode.close, received.opcode);
    try std.testing.expect(server.ws.is_closed());
    const output_after_echo = server.writer.written;
    const seek_after_echo = reader.seek;

    try std.testing.expectError(error.ConnectionClosed, server.ws.read_frame());
    try std.testing.expectEqual(output_after_echo, server.writer.written);
    try std.testing.expectEqual(seek_after_echo + 7, reader.seek);
    try std.testing.expectEqual(@as(usize, 7), reader.buffered().len);
    try std.testing.expectEqual(@as(usize, 0), server.ws.tx_pending());

    var index: usize = 0;
    const echo = try next_wire_frame(server.bytes(), &index);
    try std.testing.expectEqual(connection.OpCode.close, connection.OpCode.from_wire(echo.header.header.opcode).?);
    try std.testing.expectEqual(server.writer.written, index);
}

test "WebSocket: client echoes a valid close with a masked exact payload" {
    const seed: [connection.mask_seed_len]u8 = @splat(0x47);
    var stream: EncodedStream(32) = .{};
    var close_storage: [8]u8 = undefined;
    try stream.append(try Frame.close(1000, "bye", &close_storage));

    var reader = stream.reader();
    var client: ConnectionRig(32, 2, 64, 8, 0, 32) = .{};
    try client.init(&reader, .{
        .role = .client,
        .mask_keys = connection.MaskKeySource.from_seed(seed),
    });

    const received = try client.ws.read_frame();
    try std.testing.expectEqual(connection.OpCode.close, received.opcode);
    try std.testing.expectEqual(@as(?connection.MaskingKey, null), received.masking_key);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xe8, 'b', 'y', 'e' }, received.payload);
    try std.testing.expect(client.ws.is_closed());

    var index: usize = 0;
    const echo = try next_wire_frame(client.bytes(), &index);
    try std.testing.expect(echo.header.header.mask);
    const key = echo.header.masking_key.?;
    try std.testing.expectEqual(@as(usize, 5), echo.payload.len);

    var plaintext: [5]u8 = undefined;
    @memcpy(&plaintext, echo.payload);
    zslay.mask(&plaintext, key, 0);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xe8, 'b', 'y', 'e' }, &plaintext);
    try std.testing.expectEqual(client.writer.written, index);
}

test "WebSocket: client sends a masked 1002 for an invalid close code" {
    const seed: [connection.mask_seed_len]u8 = @splat(0x48);
    var stream: EncodedStream(32) = .{};
    var payload = [_]u8{ 0x03, 0xe7, 'b', 'a', 'd' };
    try stream.append(Frame.close_raw(&payload));

    var reader = stream.reader();
    var client: ConnectionRig(32, 2, 64, 8, 0, 32) = .{};
    try client.init(&reader, .{
        .role = .client,
        .mask_keys = connection.MaskKeySource.from_seed(seed),
    });

    try std.testing.expectError(error.InvalidCloseCode, client.ws.read_frame());
    try std.testing.expect(client.ws.is_closed());

    var index: usize = 0;
    const reply = try next_wire_frame(client.bytes(), &index);
    try std.testing.expect(reply.header.header.mask);
    const key = reply.header.masking_key.?;
    try std.testing.expectEqual(@as(usize, 5), reply.payload.len);

    var plaintext: [5]u8 = undefined;
    @memcpy(&plaintext, reply.payload);
    zslay.mask(&plaintext, key, 0);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xea, 'b', 'a', 'd' }, &plaintext);
    try std.testing.expectEqual(client.writer.written, index);
}

test "WebSocket: invalid close plus failed 1002 send leaves the read latch clear" {
    const seed: [connection.mask_seed_len]u8 = @splat(0x46);
    var stream: EncodedStream(32) = .{};
    var close_payload = [_]u8{ 0x03, 0xe7, 'b', 'a', 'd' };
    var text_payload = [_]u8{ 'o', 'k' };
    try stream.append(Frame.close_raw(&close_payload));
    try stream.append(Frame.text(&text_payload));

    var reader = stream.reader();
    var client: ConnectionRig(16, 2, 32, 8, 0, 16) = .{};
    try client.init(&reader, .{
        .role = .client,
        .mask_keys = connection.MaskKeySource.from_seed(seed),
    });
    client.writer.fail_after = 0;

    try std.testing.expectError(error.IoError, client.ws.read_frame());
    try std.testing.expectEqual(@as(?WebSocketError, null), client.ws.read_failure);
    try std.testing.expectEqual(@as(?WebSocketError, error.IoError), client.ws.write_failure);
    try std.testing.expectEqual(@as(usize, 0), client.writer.written);

    client.ws.reset_tx();
    try std.testing.expectEqual(@as(?WebSocketError, null), client.ws.write_failure);

    const received = try client.ws.read_frame();
    try std.testing.expectEqual(connection.OpCode.text, received.opcode);
    try std.testing.expectEqualStrings("ok", received.payload);
}

test "WebSocket: successful 1002 latches InvalidCloseCode" {
    const seed: [connection.mask_seed_len]u8 = @splat(0x45);
    var stream: EncodedStream(16) = .{};
    var payload = [_]u8{ 0x03, 0xe7, 'b', 'a', 'd' };
    try stream.append(Frame.close_raw(&payload));

    var reader = stream.reader();
    var client: ConnectionRig(16, 2, 32, 8, 0, 32) = .{};
    try client.init(&reader, .{
        .role = .client,
        .mask_keys = connection.MaskKeySource.from_seed(seed),
    });

    try std.testing.expectError(error.InvalidCloseCode, client.ws.read_frame());
    try std.testing.expectEqual(@as(?WebSocketError, error.InvalidCloseCode), client.ws.read_failure);
    try std.testing.expectEqual(@as(?WebSocketError, null), client.ws.write_failure);
    const seek_after_first = reader.seek;

    try std.testing.expectError(error.InvalidCloseCode, client.ws.read_frame());
    try std.testing.expectEqual(seek_after_first, reader.seek);
}

test "WebSocket: close code 1014 is accepted and echoed" {
    var stream: EncodedStream(32) = .{};
    var close_storage: [8]u8 = undefined;
    try append_masked(&stream, try Frame.close(1014, "gone", &close_storage), .{ 0x5a, 0x6b, 0x7c, 0x8d });

    var reader = stream.reader();
    var server: ConnectionRig(32, 2, 64, 8, 0, 32) = .{};
    try server.init(&reader, .{ .role = .server });

    const received = try server.ws.read_frame();
    try std.testing.expectEqual(connection.OpCode.close, received.opcode);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xf6, 'g', 'o', 'n', 'e' }, received.payload);
    try std.testing.expect(server.ws.is_closed());

    var index: usize = 0;
    const echo = try next_wire_frame(server.bytes(), &index);
    try std.testing.expectEqual(connection.OpCode.close, connection.OpCode.from_wire(echo.header.header.opcode).?);
    try std.testing.expect(!echo.header.header.mask);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xf6, 'g', 'o', 'n', 'e' }, echo.payload);
    try std.testing.expectEqual(server.writer.written, index);
}

test "WebSocket: empty close payload is echoed empty" {
    var stream: EncodedStream(16) = .{};
    var empty: [0]u8 = .{};
    try append_masked(&stream, Frame.close_raw(&empty), .{ 0x0a, 0x0b, 0x0c, 0x0d });

    var reader = stream.reader();
    var server: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
    try server.init(&reader, .{ .role = .server });

    const received = try server.ws.read_frame();
    try std.testing.expectEqual(connection.OpCode.close, received.opcode);
    try std.testing.expectEqual(@as(usize, 0), received.payload.len);
    try std.testing.expect(server.ws.is_closed());

    var index: usize = 0;
    const echo = try next_wire_frame(server.bytes(), &index);
    try std.testing.expectEqual(@as(usize, 0), echo.payload.len);
    try std.testing.expectEqual(server.writer.written, index);
}

test "WebSocket: invalid UTF-8 close reason returns InvalidUTF8 with no reply" {
    var stream: EncodedStream(16) = .{};
    var payload = [_]u8{ 0x03, 0xe8, 0xff };
    try append_masked(&stream, Frame.close_raw(&payload), .{ 0x1a, 0x2b, 0x3c, 0x4d });

    var reader = stream.reader();
    var server: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
    try server.init(&reader, .{ .role = .server });

    try std.testing.expectError(error.InvalidUTF8, server.ws.read_frame());
    try std.testing.expectEqual(@as(usize, 0), server.writer.written);
    try std.testing.expect(!server.ws.is_closed());
    try std.testing.expect(server.ws.is_at_wire_boundary());
    const seek_after_failure = reader.seek;

    try std.testing.expectError(error.InvalidUTF8, server.ws.read_frame());
    try std.testing.expectEqual(seek_after_failure, reader.seek);
}

test "WebSocket: invalid close code with valid reason sends 1002 with the reason" {
    var stream: EncodedStream(16) = .{};
    var payload = [_]u8{ 0x03, 0xe7, 'b', 'a', 'd' };
    try append_masked(&stream, Frame.close_raw(&payload), .{ 0xaa, 0xbb, 0xcc, 0xdd });

    var reader = stream.reader();
    var server: ConnectionRig(16, 2, 64, 8, 0, 32) = .{};
    try server.init(&reader, .{ .role = .server });

    try std.testing.expectError(error.InvalidCloseCode, server.ws.read_frame());
    try std.testing.expect(server.ws.is_closed());

    var index: usize = 0;
    const reply = try next_wire_frame(server.bytes(), &index);
    try std.testing.expectEqual(connection.OpCode.close, connection.OpCode.from_wire(reply.header.header.opcode).?);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xea, 'b', 'a', 'd' }, reply.payload);
    try std.testing.expectEqual(server.writer.written, index);
}

test "WebSocket: invalid close code and invalid UTF-8 reason returns InvalidUTF8" {
    var stream: EncodedStream(16) = .{};
    var payload = [_]u8{ 0x03, 0xe7, 0xff };
    try append_masked(&stream, Frame.close_raw(&payload), .{ 0x12, 0x34, 0x56, 0x78 });

    var reader = stream.reader();
    var server: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
    try server.init(&reader, .{ .role = .server });

    try std.testing.expectError(error.InvalidUTF8, server.ws.read_frame());
    try std.testing.expectEqual(@as(usize, 0), server.writer.written);
    try std.testing.expect(!server.ws.is_closed());
}

test "WebSocket: invalid close code with empty reason sends an exact 1002 payload" {
    var stream: EncodedStream(16) = .{};
    var payload = [_]u8{ 0x03, 0xee };
    try append_masked(&stream, Frame.close_raw(&payload), .{ 0x21, 0x43, 0x65, 0x87 });

    var reader = stream.reader();
    var server: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
    try server.init(&reader, .{ .role = .server });

    try std.testing.expectError(error.InvalidCloseCode, server.ws.read_frame());
    try std.testing.expect(server.ws.is_closed());

    var index: usize = 0;
    const reply = try next_wire_frame(server.bytes(), &index);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xea }, reply.payload);
    try std.testing.expectEqual(server.writer.written, index);
}

test "WebSocket: close buffer too small drops the 1002 reason" {
    var stream: EncodedStream(16) = .{};
    var payload = [_]u8{ 0x03, 0xe7, 'b', 'a', 'd' };
    try append_masked(&stream, Frame.close_raw(&payload), .{ 0x98, 0x76, 0x54, 0x32 });

    var reader = stream.reader();
    var server: ConnectionRig(16, 2, 64, 2, 0, 16) = .{};
    try server.init(&reader, .{ .role = .server });

    try std.testing.expectError(error.InvalidCloseCode, server.ws.read_frame());
    try std.testing.expect(server.ws.is_closed());

    var index: usize = 0;
    const reply = try next_wire_frame(server.bytes(), &index);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xea }, reply.payload);
    try std.testing.expectEqual(server.writer.written, index);
}

test "WebSocket: auto_close off delivers close bytes without validation or echo" {
    var stream: EncodedStream(16) = .{};
    var payload = [_]u8{ 0x03, 0xe7, 0xff };
    try append_masked(&stream, Frame.close_raw(&payload), .{ 0xef, 0xcd, 0xab, 0x89 });

    var reader = stream.reader();
    var server: ConnectionRig(16, 1, 64, 8, 0, 8) = .{};
    try server.init(&reader, .{ .role = .server, .options = .{ .auto_close = false } });

    const received = try server.ws.read_frame();
    try std.testing.expectEqual(connection.OpCode.close, received.opcode);
    try std.testing.expectEqual(@as(?connection.MaskingKey, null), received.masking_key);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xe7, 0xff }, received.payload);
    try std.testing.expectEqual(@as(usize, 0), server.writer.written);
    try std.testing.expect(!server.ws.is_closed());
}

test "WebSocket: one-byte close is rejected as ProtocolError before policy" {
    for ([_]bool{ true, false }) |auto_close| {
        var stream: EncodedStream(16) = .{};
        var payload = [_]u8{0x00};
        try append_masked(&stream, Frame.close_raw(&payload), .{ 0xde, 0xad, 0xbe, 0xef });

        var reader = stream.reader();
        var server: ConnectionRig(16, 1, 64, 8, 0, 8) = .{};
        try server.init(&reader, .{ .role = .server, .options = .{ .auto_close = auto_close } });

        try std.testing.expectError(error.ProtocolError, server.ws.read_frame());
        try std.testing.expectEqual(@as(usize, 0), server.writer.written);
        try std.testing.expect(!server.ws.is_closed());
    }
}

test "WebSocket: invalid outbound close payload is rejected by zslay" {
    var empty = std.Io.Reader.fixed("");
    var server: ConnectionRig(16, 2, 64, 8, 0, 32) = .{};
    try server.init(&empty, .{ .role = .server });

    var one_byte = [_]u8{0x03};
    try std.testing.expectError(error.ProtocolError, server.ws.write_frame(Frame.close_raw(&one_byte)));
    try std.testing.expectEqual(@as(usize, 0), server.writer.written);
    try std.testing.expect(!server.ws.is_closed());
    try std.testing.expectEqual(@as(usize, 0), server.ws.tx_pending());

    var bad_code = [_]u8{ 0x03, 0xe7 };
    try std.testing.expectError(error.ProtocolError, server.ws.write_frame(Frame.close_raw(&bad_code)));
    try std.testing.expectEqual(@as(usize, 0), server.writer.written);
    try std.testing.expect(!server.ws.is_closed());

    var close_storage: [2]u8 = undefined;
    try server.ws.write_frame(try Frame.close(1000, "", &close_storage));
    try std.testing.expect(server.ws.is_closed());
    try std.testing.expectEqual(@as(usize, 0), server.ws.tx_pending());
}

test "WebSocket: outbound close is terminal for data writes but repeated closes serialize" {
    var empty = std.Io.Reader.fixed("");
    var server: ConnectionRig(16, 2, 64, 8, 0, 64) = .{};
    try server.init(&empty, .{ .role = .server });

    var first_close_storage: [8]u8 = undefined;
    try server.ws.write_frame(try Frame.close(1000, "a", &first_close_storage));
    const after_first_close = server.writer.written;

    var text = [_]u8{'x'};
    try std.testing.expectError(error.ConnectionClosed, server.ws.write_frame(Frame.text(&text)));
    try std.testing.expectEqual(after_first_close, server.writer.written);
    try std.testing.expect(server.ws.is_closed());

    var second_close_storage: [8]u8 = undefined;
    try server.ws.write_frame(try Frame.close(1000, "b", &second_close_storage));
    try std.testing.expect(server.ws.is_closed());
    try std.testing.expectEqual(@as(usize, 0), server.ws.tx_pending());

    var index: usize = 0;
    const first = try next_wire_frame(server.bytes(), &index);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xe8, 'a' }, first.payload);
    const second = try next_wire_frame(server.bytes(), &index);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xe8, 'b' }, second.payload);
    try std.testing.expectEqual(server.writer.written, index);
}

test "WebSocket: non-close reads after a close write gate until a peer close" {
    var stream: EncodedStream(32) = .{};
    var text_payload = [_]u8{'x'};
    var close_storage: [8]u8 = undefined;
    try append_masked(&stream, Frame.text(&text_payload), .{ 0x01, 0x23, 0x45, 0x67 });
    try append_masked(&stream, try Frame.close(1000, "bye", &close_storage), .{ 0x89, 0xab, 0xcd, 0xef });

    var reader = stream.reader();
    var server: ConnectionRig(32, 2, 64, 8, 0, 32) = .{};
    try server.init(&reader, .{ .role = .server });

    var local_close_storage: [2]u8 = undefined;
    try server.ws.write_frame(try Frame.close(1000, "", &local_close_storage));
    const output_after_local_close = server.writer.written;

    try std.testing.expectError(error.ConnectionClosed, server.ws.read_frame());
    try std.testing.expectEqual(output_after_local_close, server.writer.written);

    const peer_close = try server.ws.read_frame();
    try std.testing.expectEqual(connection.OpCode.close, peer_close.opcode);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xe8, 'b', 'y', 'e' }, peer_close.payload);
    try std.testing.expectEqual(output_after_local_close, server.writer.written);
    try std.testing.expect(server.ws.is_closed());
}

test "WebSocket: invalid close after a close write returns InvalidCloseCode without a reply" {
    var stream: EncodedStream(16) = .{};
    var payload = [_]u8{ 0x03, 0xe7, 'b', 'a', 'd' };
    try append_masked(&stream, Frame.close_raw(&payload), .{ 0x02, 0x46, 0x8a, 0xce });

    var reader = stream.reader();
    var server: ConnectionRig(16, 2, 64, 8, 0, 32) = .{};
    try server.init(&reader, .{ .role = .server });

    var local_close_storage: [2]u8 = undefined;
    try server.ws.write_frame(try Frame.close(1000, "", &local_close_storage));
    const output_after_local_close = server.writer.written;

    try std.testing.expectError(error.InvalidCloseCode, server.ws.read_frame());
    try std.testing.expectEqual(output_after_local_close, server.writer.written);
    try std.testing.expect(server.ws.is_closed());
}

test "WebSocket: reset does not clear the closed flag" {
    var stream: EncodedStream(32) = .{};
    var close_storage: [2]u8 = undefined;
    var text_payload = [_]u8{'x'};
    try append_masked(&stream, try Frame.close(1000, "", &close_storage), .{ 0x13, 0x57, 0x9b, 0xdf });
    try append_masked(&stream, Frame.text(&text_payload), .{ 0x24, 0x68, 0xac, 0xe0 });

    var reader = stream.reader();
    var server: ConnectionRig(32, 2, 64, 8, 0, 32) = .{};
    try server.init(&reader, .{ .role = .server });

    _ = try server.ws.read_frame();
    try std.testing.expect(server.ws.is_closed());
    const output_after_close = server.writer.written;

    server.ws.reset();

    try std.testing.expect(server.ws.is_closed());
    try std.testing.expectError(error.ConnectionClosed, server.ws.read_frame());
    try std.testing.expectEqual(output_after_close, server.writer.written);
}
