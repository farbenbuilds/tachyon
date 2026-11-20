const std = @import("std");
const zslay = @import("zslay");
const tachyon = @import("tachyon");

const support = @import("../support.zig");

const connection = tachyon.connection;
const fragment = tachyon.fragment;
const Frame = tachyon.Frame;
const EncodedStream = support.EncodedStream;
const RecordingVecWriter = support.RecordingVecWriter;
const next_wire_frame = support.next_wire_frame;
const ConnectionRig = support.ConnectionRig;

test "WebSocket: client masks outbound frames and server reads them back" {
    const seed: [connection.mask_seed_len]u8 = @splat(0x42);
    var empty = std.Io.Reader.fixed("");
    var client: ConnectionRig(64, 2, 64, 8, 0, 64) = .{};
    try client.init(&empty, .{
        .role = .client,
        .mask_keys = connection.MaskKeySource.from_seed(seed),
    });

    var payload = [_]u8{ 'h', 'i' };
    try client.ws.write_frame(Frame.text(&payload));

    var index: usize = 0;
    const first = try next_wire_frame(client.bytes(), &index);
    try std.testing.expect(first.header.header.mask);
    const key = first.header.masking_key.?;
    try std.testing.expectEqual(@as(usize, 2), first.payload.len);
    try std.testing.expectEqual(@as(u8, 'h' ^ key[0]), first.payload[0]);
    try std.testing.expectEqual(@as(u8, 'i' ^ key[1]), first.payload[1]);
    try std.testing.expectEqual(client.writer.written, index);

    var plaintext: [2]u8 = undefined;
    @memcpy(&plaintext, first.payload);
    zslay.mask(&plaintext, key, 0);
    try std.testing.expectEqualStrings("hi", &plaintext);
    try std.testing.expectEqualStrings("hi", &payload);

    var server_reader = std.Io.Reader.fixed(client.bytes());
    var server: ConnectionRig(64, 2, 64, 8, 0, 64) = .{};
    try server.init(&server_reader, .{ .role = .server });

    const received = try server.ws.read_frame();
    try std.testing.expectEqual(connection.OpCode.text, received.opcode);
    try std.testing.expectEqual(@as(?connection.MaskingKey, null), received.masking_key);
    try std.testing.expectEqualStrings("hi", received.payload);
    try std.testing.expectEqual(@as(usize, 0), server.writer.written);
}

test "WebSocket: server writes unmasked text and close frames" {
    var empty = std.Io.Reader.fixed("");
    var server: ConnectionRig(64, 2, 64, 125, 0, 128) = .{};
    try server.init(&empty, .{ .role = .server });

    var text = [_]u8{ 'o', 'k' };
    try server.ws.write_frame(Frame.text(&text));

    var close_storage: [8]u8 = undefined;
    const close = try Frame.close(1000, "bye", &close_storage);
    try server.ws.write_frame(close);

    var index: usize = 0;
    const text_frame = try next_wire_frame(server.bytes(), &index);
    try std.testing.expect(!text_frame.header.header.mask);
    try std.testing.expectEqual(@as(?connection.MaskingKey, null), text_frame.header.masking_key);
    try std.testing.expectEqualStrings("ok", text_frame.payload);

    const close_frame = try next_wire_frame(server.bytes(), &index);
    try std.testing.expect(!close_frame.header.header.mask);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xe8, 'b', 'y', 'e' }, close_frame.payload);
    try std.testing.expectEqual(server.writer.written, index);
    try std.testing.expect(server.ws.is_closed());
}

test "WebSocket: client rejects a masked inbound frame and latches" {
    const seed: [connection.mask_seed_len]u8 = @splat(0x24);
    var stream: EncodedStream(32) = .{};
    var payload = [_]u8{'x'};
    var masked = Frame.text(&payload);
    masked.mask(.{ 0x01, 0x02, 0x03, 0x04 });
    try stream.append(masked);

    var reader = stream.reader();
    var client: ConnectionRig(16, 1, 32, 8, 0, 8) = .{};
    try client.init(&reader, .{
        .role = .client,
        .mask_keys = connection.MaskKeySource.from_seed(seed),
    });

    try std.testing.expectError(error.PayloadMasked, client.ws.read_frame());
    const seek_after_failure = reader.seek;
    try std.testing.expectError(error.PayloadMasked, client.ws.read_frame());
    try std.testing.expectEqual(seek_after_failure, reader.seek);
    try std.testing.expect(!client.ws.is_at_wire_boundary());
}

test "WebSocket: server rejects an unmasked inbound frame and latches" {
    var stream: EncodedStream(16) = .{};
    var payload = [_]u8{'x'};
    try stream.append(Frame.text(&payload));

    var reader = stream.reader();
    var server: ConnectionRig(16, 1, 32, 8, 0, 8) = .{};
    try server.init(&reader, .{ .role = .server });

    try std.testing.expectError(error.PayloadNotMasked, server.ws.read_frame());
    const seek_after_failure = reader.seek;
    try std.testing.expectError(error.PayloadNotMasked, server.ws.read_frame());
    try std.testing.expectEqual(seek_after_failure, reader.seek);
}

test "WebSocket: write rejects a pre-masked payload" {
    const seed: [connection.mask_seed_len]u8 = @splat(0x33);
    var empty = std.Io.Reader.fixed("");
    var client: ConnectionRig(16, 2, 64, 8, 0, 32) = .{};
    try client.init(&empty, .{
        .role = .client,
        .mask_keys = connection.MaskKeySource.from_seed(seed),
    });

    var payload = [_]u8{'x'};
    var premasked = Frame.text(&payload);
    premasked.mask(.{ 0x11, 0x22, 0x33, 0x44 });

    try std.testing.expectError(error.PayloadMasked, client.ws.write_frame(premasked));
    try std.testing.expectEqual(@as(usize, 0), client.writer.written);
    try std.testing.expectEqual(@as(usize, 0), client.ws.tx_pending());
    try std.testing.expect(!client.ws.is_closed());
}

test "WebSocket: mask key source is deterministic per seed" {
    const seed: [connection.mask_seed_len]u8 = @splat(0x11);
    const other_seed: [connection.mask_seed_len]u8 = @splat(0x22);

    var same_a = connection.MaskKeySource.from_seed(seed);
    var same_b = connection.MaskKeySource.from_seed(seed);
    var different = connection.MaskKeySource.from_seed(other_seed);

    var saw_difference = false;
    for (0..4) |_| {
        const key_a = same_a.next();
        const key_b = same_b.next();
        const key_other = different.next();
        try std.testing.expectEqualSlices(u8, &key_a, &key_b);
        if (!std.mem.eql(u8, &key_a, &key_other)) saw_difference = true;
    }
    try std.testing.expect(saw_difference);
}

test "WebSocket: client init requires a mask source" {
    var empty = std.Io.Reader.fixed("");
    var out: [8]u8 = undefined;
    var writer = RecordingVecWriter.init(&out);
    var frame_buffer: [16]u8 = undefined;
    var tx_nodes: [1]zslay.FrameNode = undefined;
    var write_buffer: [16]u8 = undefined;
    var close_buffer: [2]u8 = undefined;

    try std.testing.expectError(error.MaskingKeyRequired, connection.WebSocket.init(
        &empty,
        &writer.writer,
        .{
            .frame_buffer = &frame_buffer,
            .tx_nodes = &tx_nodes,
            .write_buffer = &write_buffer,
            .close_buffer = &close_buffer,
        },
        .{ .role = .client },
    ));

    try std.testing.expectError(error.MaskingKeyRequired, connection.WebSocket.init(
        &empty,
        &writer.writer,
        .{
            .frame_buffer = &frame_buffer,
            .tx_nodes = &tx_nodes,
            .write_buffer = &write_buffer,
            .close_buffer = &close_buffer,
        },
        .{ .role = .client, .options = .{ .auto_apply_mask = false } },
    ));
}

test "WebSocket: client with auto_apply_mask off cannot write" {
    const seed: [connection.mask_seed_len]u8 = @splat(0x6e);
    var empty = std.Io.Reader.fixed("");
    var client: ConnectionRig(16, 2, 64, 8, 0, 32) = .{};
    try client.init(&empty, .{
        .role = .client,
        .mask_keys = connection.MaskKeySource.from_seed(seed),
    });
    client.ws.set_auto_apply_mask(false);

    var payload = [_]u8{'x'};
    try std.testing.expectError(error.PayloadNotMasked, client.ws.write_frame(Frame.text(&payload)));
    try std.testing.expectEqual(@as(usize, 0), client.writer.written);
    try std.testing.expectEqual(@as(usize, 0), client.ws.tx_pending());
    try std.testing.expect(!client.ws.is_closed());

    client.ws.set_auto_apply_mask(true);
    try client.ws.write_frame(Frame.text(&payload));
    try std.testing.expect(client.writer.written > 0);
}

test "WebSocket: public module re-exports the connection layer" {
    const root = @import("tachyon");

    try std.testing.expect(root.WebSocket == connection.WebSocket);
    try std.testing.expect(root.ConnectionOptions == connection.Options);
    try std.testing.expect(root.ConnectionConfig == connection.Config);
    try std.testing.expect(root.ConnectionStorage == connection.Storage);
    try std.testing.expect(root.MaskKeySource == connection.MaskKeySource);
    try std.testing.expectEqual(connection.default_max_message_size, root.default_max_message_size);
    try std.testing.expectEqual(connection.default_writev_threshold, root.default_writev_threshold);
}

test "WebSocket: options default to fastwebsockets values" {
    const options: connection.Options = .{};

    try std.testing.expect(options.auto_apply_mask);
    try std.testing.expect(options.auto_close);
    try std.testing.expect(options.auto_pong);
    try std.testing.expect(options.writev);
    try std.testing.expectEqual(@as(usize, 1024), options.writev_threshold);
    try std.testing.expectEqual(@as(usize, 64 << 20), options.max_message_size);
    try std.testing.expectEqual(@as(usize, 64 << 20), connection.default_max_message_size);
    try std.testing.expectEqual(@as(usize, 1024), connection.default_writev_threshold);
}

test "WebSocket: connection and fragment defaults agree" {
    try std.testing.expectEqual(fragment.default_max_message_size, connection.default_max_message_size);
}

test "WebSocket: role, pending, and limit accessors track state" {
    var empty = std.Io.Reader.fixed("");
    var server: ConnectionRig(16, 1, 64, 8, 0, 16) = .{};
    try server.init(&empty, .{ .role = .server });

    try std.testing.expectEqual(connection.Role.server, server.ws.role());
    try std.testing.expectEqual(@as(usize, 0), server.ws.tx_pending());
    try std.testing.expectEqual(connection.default_max_message_size, server.ws.max_message_size());
    try std.testing.expect(server.ws.is_at_wire_boundary());
    try std.testing.expect(!server.ws.is_closed());

    var payload = [_]u8{'x'};
    try server.ws.write_frame(Frame.text(&payload));

    try std.testing.expectEqual(connection.Role.server, server.ws.role());
    try std.testing.expectEqual(@as(usize, 0), server.ws.tx_pending());
    try std.testing.expect(server.ws.is_at_wire_boundary());
}

test "WebSocket: rejects storage aliasing the reader or writer buffer" {
    var shared: [64]u8 = undefined;
    var reader = std.Io.Reader.fixed(&shared);
    var out: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out);
    var tx_nodes: [1]zslay.FrameNode = undefined;
    var write_buffer: [64]u8 = undefined;
    var close_buffer: [8]u8 = undefined;

    try std.testing.expectError(error.InvalidLength, connection.WebSocket.init(&reader, &writer, .{
        .frame_buffer = &shared,
        .tx_nodes = &tx_nodes,
        .write_buffer = &write_buffer,
        .close_buffer = &close_buffer,
    }, .{ .role = .server }));

    try std.testing.expectError(error.InvalidLength, connection.WebSocket.init(&reader, &writer, .{
        .frame_buffer = &write_buffer,
        .tx_nodes = &tx_nodes,
        .write_buffer = out[0..32],
        .close_buffer = &close_buffer,
    }, .{ .role = .server }));
}
