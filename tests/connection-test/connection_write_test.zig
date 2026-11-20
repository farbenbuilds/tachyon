const std = @import("std");
const zslay = @import("zslay");
const tachyon = @import("tachyon");

const support = @import("../support.zig");

const connection = tachyon.connection;
const Frame = tachyon.Frame;
const WebSocketError = tachyon.WebSocketError;
const EncodedStream = support.EncodedStream;
const FlushFailWriter = support.FlushFailWriter;
const next_wire_frame = support.next_wire_frame;
const ConnectionRig = support.ConnectionRig;
const append_masked = support.append_masked;

test "WebSocket: vectored writes above the threshold use two iovecs" {
    var empty = std.Io.Reader.fixed("");
    var server: ConnectionRig(16, 2, 64, 8, 0, 1100) = .{};
    try server.init(&empty, .{ .role = .server, .options = .{ .writev_threshold = 1024 } });

    var payload: [1025]u8 = @splat(0x5a);
    try server.ws.write_frame(Frame.binary(&payload));

    try std.testing.expectEqual(@as(usize, 1), server.writer.drain_calls);
    try std.testing.expectEqual(@as(usize, 2), server.writer.max_iovecs);

    var index: usize = 0;
    const wire_frame = try next_wire_frame(server.bytes(), &index);
    try std.testing.expectEqual(@as(usize, 1025), wire_frame.payload.len);
    try std.testing.expectEqualSlices(u8, &payload, wire_frame.payload);
    try std.testing.expectEqual(server.writer.written, index);
}

test "WebSocket: payload equal to the threshold uses the copied path" {
    var empty = std.Io.Reader.fixed("");
    var server: ConnectionRig(16, 2, 1100, 8, 0, 1100) = .{};
    try server.init(&empty, .{ .role = .server, .options = .{ .writev_threshold = 1024 } });

    var payload: [1024]u8 = @splat(0x6b);
    try server.ws.write_frame(Frame.binary(&payload));

    try std.testing.expectEqual(@as(usize, 1), server.writer.drain_calls);
    try std.testing.expectEqual(@as(usize, 1), server.writer.max_iovecs);

    var index: usize = 0;
    const wire_frame = try next_wire_frame(server.bytes(), &index);
    try std.testing.expectEqual(@as(usize, 1024), wire_frame.payload.len);
    try std.testing.expectEqualSlices(u8, &payload, wire_frame.payload);
    try std.testing.expectEqual(server.writer.written, index);
}

test "WebSocket: set_writev false composes header and payload through the write buffer" {
    var empty = std.Io.Reader.fixed("");
    var server: ConnectionRig(16, 2, 64, 8, 0, 2010) = .{};
    try server.init(&empty, .{ .role = .server });
    server.ws.set_writev(false);

    var payload: [2000]u8 = @splat(0x7c);
    var expected: [2010]u8 = undefined;
    const expected_bytes = try Frame.binary(&payload).write(&expected);

    try server.ws.write_frame(Frame.binary(&payload));

    try std.testing.expect(server.writer.drain_calls > 1);
    try std.testing.expectEqual(@as(usize, 1), server.writer.max_iovecs);
    try std.testing.expectEqualSlices(u8, expected_bytes, server.bytes());
    try std.testing.expectEqual(@as(usize, 0), server.ws.tx_pending());
}

test "WebSocket: masked vectored writes chunk through scratch and preserve offsets" {
    const seed: [connection.mask_seed_len]u8 = @splat(0x19);
    var empty = std.Io.Reader.fixed("");
    var client: ConnectionRig(16, 2, 64, 8, 4, 64) = .{};
    try client.init(&empty, .{
        .role = .client,
        .mask_keys = connection.MaskKeySource.from_seed(seed),
    });
    client.ws.set_writev_threshold(0);

    var payload = [_]u8{ 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j' };
    try client.ws.write_frame(Frame.text(&payload));

    try std.testing.expectEqual(@as(usize, 3), client.writer.drain_calls);
    try std.testing.expectEqual(@as(usize, 2), client.writer.max_iovecs);
    try std.testing.expectEqual(@as(usize, 16), client.writer.written);

    var index: usize = 0;
    const wire_frame = try next_wire_frame(client.bytes(), &index);
    try std.testing.expect(wire_frame.header.header.mask);
    const key = wire_frame.header.masking_key.?;
    try std.testing.expectEqual(@as(usize, 10), wire_frame.payload.len);

    var plaintext: [10]u8 = undefined;
    @memcpy(&plaintext, wire_frame.payload);
    zslay.mask(&plaintext, key, 0);
    try std.testing.expectEqualStrings("abcdefghij", &plaintext);
}

test "WebSocket: empty mask scratch falls back to the copied path" {
    const seed: [connection.mask_seed_len]u8 = @splat(0x2b);
    var empty = std.Io.Reader.fixed("");
    var client: ConnectionRig(16, 2, 64, 8, 0, 64) = .{};
    try client.init(&empty, .{
        .role = .client,
        .mask_keys = connection.MaskKeySource.from_seed(seed),
    });
    client.ws.set_writev_threshold(0);

    var payload = [_]u8{ 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j' };
    try client.ws.write_frame(Frame.text(&payload));

    try std.testing.expectEqual(@as(usize, 1), client.writer.drain_calls);
    try std.testing.expectEqual(@as(usize, 1), client.writer.max_iovecs);

    var index: usize = 0;
    const wire_frame = try next_wire_frame(client.bytes(), &index);
    const key = wire_frame.header.masking_key.?;
    var plaintext: [10]u8 = undefined;
    @memcpy(&plaintext, wire_frame.payload);
    zslay.mask(&plaintext, key, 0);
    try std.testing.expectEqualStrings("abcdefghij", &plaintext);
}

test "WebSocket: empty payload writes a header-only frame" {
    var empty = std.Io.Reader.fixed("");
    var server: ConnectionRig(16, 1, 64, 8, 0, 16) = .{};
    try server.init(&empty, .{ .role = .server });

    var payload: [0]u8 = .{};
    try server.ws.write_frame(Frame.text(&payload));

    try std.testing.expectEqual(@as(usize, 2), server.writer.written);
    try std.testing.expectEqual(@as(usize, 1), server.writer.drain_calls);
    try std.testing.expectEqual(@as(usize, 1), server.writer.max_iovecs);
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 0x00 }, server.bytes());
    try std.testing.expectEqual(@as(usize, 0), server.ws.tx_pending());
}

test "WebSocket: a latched write failure blocks reads" {
    const seed: [connection.mask_seed_len]u8 = @splat(0x5d);
    var stream: EncodedStream(16) = .{};
    var input = [_]u8{ 'o', 'k' };
    try stream.append(Frame.text(&input));

    var reader = stream.reader();
    var client: ConnectionRig(16, 2, 64, 2, 0, 16) = .{};
    try client.init(&reader, .{
        .role = .client,
        .mask_keys = connection.MaskKeySource.from_seed(seed),
    });
    client.writer.fail_after = 0;

    var payload = [_]u8{ 'h', 'i' };
    try std.testing.expectError(error.IoError, client.ws.write_frame(Frame.text(&payload)));
    try std.testing.expectEqual(@as(usize, 0), client.writer.written);
    try std.testing.expectEqual(@as(usize, 1), client.ws.tx_pending());

    const drain_calls_after_failure = client.writer.drain_calls;
    try std.testing.expectError(error.IoError, client.ws.write_frame(Frame.text(&payload)));
    try std.testing.expectEqual(drain_calls_after_failure, client.writer.drain_calls);

    try std.testing.expectError(error.IoError, client.ws.read_frame());
    try std.testing.expectEqual(@as(usize, 0), reader.seek);
}

test "WebSocket: flush reports a buffered writer failure and latches" {
    var empty = std.Io.Reader.fixed("");
    var frame_buffer: [16]u8 = undefined;
    var tx_nodes: [1]zslay.FrameNode = undefined;
    var write_buffer: [64]u8 = undefined;
    var close_buffer: [8]u8 = undefined;
    var out: [64]u8 = undefined;
    var flush_buffer: [64]u8 = undefined;
    var writer = FlushFailWriter.init(&out, &flush_buffer);

    var ws = try connection.WebSocket.init(&empty, &writer.writer, .{
        .frame_buffer = &frame_buffer,
        .tx_nodes = &tx_nodes,
        .write_buffer = &write_buffer,
        .close_buffer = &close_buffer,
    }, .{ .role = .server });

    var payload = [_]u8{ 'h', 'i' };
    try ws.write_frame(Frame.text(&payload));
    try std.testing.expectEqual(@as(usize, 0), writer.written);
    try std.testing.expectEqual(@as(usize, 4), writer.writer.end);

    try std.testing.expectError(error.IoError, ws.flush());
    try std.testing.expectEqual(@as(usize, 1), writer.flush_calls);

    try std.testing.expectError(error.IoError, ws.flush());
    try std.testing.expectEqual(@as(usize, 1), writer.flush_calls);

    var next_payload = [_]u8{'x'};
    try std.testing.expectError(error.IoError, ws.write_frame(Frame.text(&next_payload)));
}

test "WebSocket: automatic pong is flushed before read_frame returns" {
    var stream: EncodedStream(32) = .{};
    var ping_payload = [_]u8{'p'};
    var text_payload = [_]u8{ 'o', 'k' };
    try append_masked(&stream, Frame.ping(&ping_payload), .{ 0x01, 0x23, 0x45, 0x67 });
    try append_masked(&stream, Frame.text(&text_payload), .{ 0x89, 0xab, 0xcd, 0xef });

    var reader = stream.reader();
    var frame_buffer: [16]u8 = undefined;
    var tx_nodes: [1]zslay.FrameNode = undefined;
    var write_buffer: [64]u8 = undefined;
    var close_buffer: [8]u8 = undefined;
    var out: [16]u8 = undefined;
    var flush_buffer: [16]u8 = undefined;
    var writer = FlushFailWriter.init(&out, &flush_buffer);
    writer.fail_flush = false;

    var ws = try connection.WebSocket.init(&reader, &writer.writer, .{
        .frame_buffer = &frame_buffer,
        .tx_nodes = &tx_nodes,
        .write_buffer = &write_buffer,
        .close_buffer = &close_buffer,
    }, .{ .role = .server });

    const received = try ws.read_frame();
    try std.testing.expectEqual(connection.OpCode.text, received.opcode);
    try std.testing.expectEqualStrings("ok", received.payload);

    // The obligation flush moved the buffered pong to the recording sink
    // before read_frame returned.
    try std.testing.expectEqual(@as(usize, 1), writer.flush_calls);
    try std.testing.expectEqual(@as(usize, 0), writer.writer.end);
    try std.testing.expectEqual(@as(usize, 3), writer.written);

    var index: usize = 0;
    const pong = try next_wire_frame(out[0..writer.written], &index);
    try std.testing.expectEqual(connection.OpCode.pong, connection.OpCode.from_wire(pong.header.header.opcode).?);
    try std.testing.expectEqualStrings("p", pong.payload);
    try std.testing.expectEqual(writer.written, index);
}

test "WebSocket: failed automatic reply flush latches write failure" {
    var stream: EncodedStream(16) = .{};
    var ping_payload = [_]u8{'p'};
    var text_payload = [_]u8{ 'o', 'k' };
    try append_masked(&stream, Frame.ping(&ping_payload), .{ 0x01, 0x23, 0x45, 0x67 });
    try append_masked(&stream, Frame.text(&text_payload), .{ 0x89, 0xab, 0xcd, 0xef });

    var reader = stream.reader();
    var frame_buffer: [16]u8 = undefined;
    var tx_nodes: [1]zslay.FrameNode = undefined;
    var write_buffer: [64]u8 = undefined;
    var close_buffer: [8]u8 = undefined;
    var out: [16]u8 = undefined;
    var flush_buffer: [16]u8 = undefined;
    var writer = FlushFailWriter.init(&out, &flush_buffer);

    var ws = try connection.WebSocket.init(&reader, &writer.writer, .{
        .frame_buffer = &frame_buffer,
        .tx_nodes = &tx_nodes,
        .write_buffer = &write_buffer,
        .close_buffer = &close_buffer,
    }, .{ .role = .server });

    try std.testing.expectError(error.IoError, ws.read_frame());
    // The automatic pong reached the buffered writer, so the flush failure is
    // a transmit failure rather than a read failure.
    try std.testing.expectEqual(@as(?WebSocketError, error.IoError), ws.write_failure);
    try std.testing.expectEqual(@as(?WebSocketError, null), ws.read_failure);
    try std.testing.expectEqual(@as(usize, 1), writer.flush_calls);
    try std.testing.expectEqual(@as(usize, 0), writer.written);

    const seek_after_failure = reader.seek;
    try std.testing.expectError(error.IoError, ws.read_frame());
    try std.testing.expectEqual(seek_after_failure, reader.seek);
    try std.testing.expectEqual(@as(usize, 1), writer.flush_calls);

    ws.reset_tx();
    try std.testing.expectEqual(@as(?WebSocketError, null), ws.write_failure);
    try std.testing.expectEqual(@as(?WebSocketError, null), ws.read_failure);

    const received = try ws.read_frame();
    try std.testing.expectEqual(connection.OpCode.text, received.opcode);
    try std.testing.expectEqualStrings("ok", received.payload);
}

test "WebSocket: a successful buffered flush releases queued bytes" {
    var empty = std.Io.Reader.fixed("");
    var frame_buffer: [16]u8 = undefined;
    var tx_nodes: [1]zslay.FrameNode = undefined;
    var write_buffer: [64]u8 = undefined;
    var close_buffer: [8]u8 = undefined;
    var out: [16]u8 = undefined;
    var flush_buffer: [16]u8 = undefined;
    var writer = FlushFailWriter.init(&out, &flush_buffer);
    writer.fail_flush = false;

    var ws = try connection.WebSocket.init(&empty, &writer.writer, .{
        .frame_buffer = &frame_buffer,
        .tx_nodes = &tx_nodes,
        .write_buffer = &write_buffer,
        .close_buffer = &close_buffer,
    }, .{ .role = .server });

    var payload = [_]u8{ 'h', 'i' };
    try ws.write_frame(Frame.text(&payload));
    try std.testing.expectEqual(@as(usize, 0), writer.written);
    try std.testing.expectEqual(@as(usize, 4), writer.writer.end);

    try ws.flush();

    try std.testing.expectEqual(@as(usize, 4), writer.written);
    try std.testing.expectEqual(@as(usize, 0), writer.writer.end);
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 0x02, 'h', 'i' }, out[0..writer.written]);
}

test "WebSocket: reset_tx clears a terminal write failure and closed" {
    var empty = std.Io.Reader.fixed("");
    var server: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
    try server.init(&empty, .{ .role = .server });
    server.writer.fail_after = 0;

    var close_storage: [2]u8 = undefined;
    try std.testing.expectError(
        error.IoError,
        server.ws.write_frame(try Frame.close(1000, "", &close_storage)),
    );
    try std.testing.expect(server.ws.is_closed());
    try std.testing.expectEqual(@as(usize, 1), server.ws.tx_pending());
    try std.testing.expectEqual(@as(usize, 0), server.writer.written);

    server.writer.fail_after = null;
    server.ws.reset_tx();

    try std.testing.expect(!server.ws.is_closed());
    try std.testing.expectEqual(@as(usize, 0), server.ws.tx_pending());

    var next_close_storage: [2]u8 = undefined;
    try server.ws.write_frame(try Frame.close(1000, "", &next_close_storage));
    try std.testing.expect(server.ws.is_closed());
    try std.testing.expectEqual(@as(usize, 0), server.ws.tx_pending());

    var index: usize = 0;
    const close = try next_wire_frame(server.bytes(), &index);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xe8 }, close.payload);
    try std.testing.expectEqual(server.writer.written, index);
}

test "WebSocket: a mid-frame writer failure is not retried" {
    var empty = std.Io.Reader.fixed("");
    var server: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
    try server.init(&empty, .{ .role = .server });
    server.writer.fail_after = 2;

    var payload = [_]u8{ 'h', 'e', 'l', 'l', 'o' };
    try std.testing.expectError(error.IoError, server.ws.write_frame(Frame.text(&payload)));
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 0x05 }, server.bytes());
    try std.testing.expectEqual(@as(usize, 1), server.writer.drain_calls);
    try std.testing.expectEqual(@as(usize, 1), server.ws.tx_pending());

    var retry = [_]u8{'x'};
    try std.testing.expectError(error.IoError, server.ws.write_frame(Frame.text(&retry)));
    try std.testing.expectEqual(@as(usize, 1), server.writer.drain_calls);
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 0x05 }, server.bytes());
}
