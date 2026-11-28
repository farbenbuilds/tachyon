const std = @import("std");
const zslay = @import("zslay");
const tachyon = @import("tachyon");

const support = @import("../support.zig");

const connection = tachyon.connection;
const Frame = tachyon.Frame;
const EncodedStream = support.EncodedStream;
const RecordingVecWriter = support.RecordingVecWriter;
const next_wire_frame = support.next_wire_frame;
const ConnectionRig = support.ConnectionRig;
const append_masked = support.append_masked;

test "WebSocket: max_message_size is exclusive across short and extended lengths" {
    const seed: [connection.mask_seed_len]u8 = @splat(0x77);
    var payload: [65536]u8 = @splat(0x41);

    {
        var stream: EncodedStream(512) = .{};
        for ([_]usize{ 0, 1, 125, 126, 127 }) |len| {
            try stream.append(Frame.binary(payload[0..len]));
        }

        var reader = stream.reader();
        var client: ConnectionRig(127, 1, 64, 2, 0, 8) = .{};
        try client.init(&reader, .{
            .role = .client,
            .options = .{ .max_message_size = 128 },
            .mask_keys = connection.MaskKeySource.from_seed(seed),
        });

        for ([_]usize{ 0, 1, 125, 126, 127 }) |len| {
            const received = try client.ws.read_frame();
            try std.testing.expectEqual(len, received.payload.len);
            try std.testing.expectEqualSlices(u8, payload[0..len], received.payload);
        }
        try std.testing.expect(client.ws.is_at_wire_boundary());
    }

    {
        var stream: EncodedStream(256) = .{};
        try stream.append(Frame.binary(payload[0..128]));

        var reader = stream.reader();
        var client: ConnectionRig(128, 1, 64, 2, 0, 8) = .{};
        try client.init(&reader, .{
            .role = .client,
            .options = .{ .max_message_size = 128 },
            .mask_keys = connection.MaskKeySource.from_seed(seed),
        });

        try std.testing.expectError(error.FrameTooLarge, client.ws.read_frame());
    }

    {
        var stream: EncodedStream(65545) = .{};
        try stream.append(Frame.binary(payload[0..65535]));

        var reader = stream.reader();
        var client: ConnectionRig(65535, 1, 64, 2, 0, 8) = .{};
        try client.init(&reader, .{
            .role = .client,
            .options = .{ .max_message_size = 65536 },
            .mask_keys = connection.MaskKeySource.from_seed(seed),
        });

        const received = try client.ws.read_frame();
        try std.testing.expectEqual(@as(usize, 65535), received.payload.len);
        try std.testing.expectEqual(@as(u8, 0x41), received.payload[0]);
        try std.testing.expectEqual(@as(u8, 0x41), received.payload[65534]);
    }

    {
        var stream: EncodedStream(65546) = .{};
        try stream.append(Frame.binary(&payload));

        var reader = stream.reader();
        var client: ConnectionRig(16, 1, 64, 2, 0, 8) = .{};
        try client.init(&reader, .{
            .role = .client,
            .options = .{ .max_message_size = 65536 },
            .mask_keys = connection.MaskKeySource.from_seed(seed),
        });

        try std.testing.expectError(error.FrameTooLarge, client.ws.read_frame());
    }
}

test "WebSocket: zero max_message_size rejects before reading and does not latch" {
    var stream: EncodedStream(16) = .{};
    var payload = [_]u8{ 'o', 'k' };
    try stream.append(Frame.text(&payload));

    var reader = stream.reader();
    var client: ConnectionRig(16, 1, 64, 2, 0, 8) = .{};
    try client.init(&reader, .{
        .role = .client,
        .options = .{ .max_message_size = 0 },
        .mask_keys = connection.MaskKeySource.from_seed(@splat(0x31)),
    });

    try std.testing.expectError(error.FrameTooLarge, client.ws.read_frame());
    try std.testing.expectEqual(@as(usize, 0), reader.seek);
    try std.testing.expectEqual(@as(usize, 0), client.ws.max_message_size());

    try std.testing.expectError(error.FrameTooLarge, client.ws.read_frame());
    try std.testing.expectEqual(@as(usize, 0), reader.seek);

    client.ws.set_max_message_size(8);
    try std.testing.expectEqual(@as(usize, 8), client.ws.max_message_size());

    const received = try client.ws.read_frame();
    try std.testing.expectEqualStrings("ok", received.payload);
}

test "WebSocket: one-byte limit accepts an empty frame and rejects one byte" {
    {
        var stream: EncodedStream(16) = .{};
        var empty: [0]u8 = .{};
        try stream.append(Frame.text(&empty));

        var reader = stream.reader();
        var client: ConnectionRig(16, 1, 64, 2, 0, 8) = .{};
        try client.init(&reader, .{
            .role = .client,
            .options = .{ .max_message_size = 1 },
            .mask_keys = connection.MaskKeySource.from_seed(@splat(0x71)),
        });

        const received = try client.ws.read_frame();
        try std.testing.expectEqual(connection.OpCode.text, received.opcode);
        try std.testing.expectEqual(@as(usize, 0), received.payload.len);
    }

    {
        var stream: EncodedStream(16) = .{};
        var payload = [_]u8{'x'};
        try stream.append(Frame.text(&payload));

        var reader = stream.reader();
        var client: ConnectionRig(16, 1, 64, 2, 0, 8) = .{};
        try client.init(&reader, .{
            .role = .client,
            .options = .{ .max_message_size = 1 },
            .mask_keys = connection.MaskKeySource.from_seed(@splat(0x72)),
        });

        try std.testing.expectError(error.FrameTooLarge, client.ws.read_frame());
    }
}

test "WebSocket: frame larger than frame_buffer returns BufferTooShort and latches" {
    var stream: EncodedStream(32) = .{};
    var payload = [_]u8{ 'a', 'b', 'c', 'd', 'e' };
    try append_masked(&stream, Frame.binary(&payload), .{ 0x0f, 0x1e, 0x2d, 0x3c });

    var reader = stream.reader();
    var server: ConnectionRig(4, 1, 64, 8, 0, 8) = .{};
    try server.init(&reader, .{ .role = .server });

    try std.testing.expectError(error.BufferTooShort, server.ws.read_frame());
    try std.testing.expectEqual(@as(usize, 6), reader.seek);
    try std.testing.expect(!server.ws.is_at_wire_boundary());

    try std.testing.expectError(error.BufferTooShort, server.ws.read_frame());
    try std.testing.expectEqual(@as(usize, 6), reader.seek);
}

test "WebSocket: cumulative fragmented message over max_message_len returns FrameTooLarge" {
    var stream: EncodedStream(32) = .{};
    var first_payload = [_]u8{ 'a', 'b', 'c', 'd', 'e' };
    var second_payload = [_]u8{ 'f', 'g', 'h', 'i', 'j' };
    try append_masked(&stream, Frame.init(false, .binary, null, &first_payload), .{ 0x11, 0x32, 0x53, 0x74 });
    try append_masked(&stream, Frame.init(true, .continuation, null, &second_payload), .{ 0x85, 0xa6, 0xc7, 0xe8 });

    var reader = stream.reader();
    var server: ConnectionRig(16, 1, 64, 8, 0, 8) = .{};
    try server.init(&reader, .{ .role = .server, .options = .{ .max_message_size = 9 } });

    const first = try server.ws.read_frame();
    try std.testing.expectEqual(connection.OpCode.binary, first.opcode);
    try std.testing.expect(!first.fin);
    try std.testing.expectEqualStrings("abcde", first.payload);

    try std.testing.expectError(error.FrameTooLarge, server.ws.read_frame());
}

test "WebSocket: set_max_message_size updates the read gate and zslay limits" {
    var stream: EncodedStream(32) = .{};
    var first_payload = [_]u8{ 'a', 'b', 'c' };
    var second_payload = [_]u8{ 'd', 'e', 'f', 'g' };
    try stream.append(Frame.text(&first_payload));
    try stream.append(Frame.text(&second_payload));

    var reader = stream.reader();
    var client: ConnectionRig(16, 1, 64, 2, 0, 8) = .{};
    try client.init(&reader, .{
        .role = .client,
        .options = .{ .max_message_size = 4 },
        .mask_keys = connection.MaskKeySource.from_seed(@splat(0x44)),
    });

    const first = try client.ws.read_frame();
    try std.testing.expectEqualStrings("abc", first.payload);

    client.ws.set_max_message_size(0);
    try std.testing.expectEqual(@as(usize, 0), client.ws.max_message_size());
    const seek_before_zero = reader.seek;
    try std.testing.expectError(error.FrameTooLarge, client.ws.read_frame());
    try std.testing.expectEqual(seek_before_zero, reader.seek);

    client.ws.set_max_message_size(8);
    try std.testing.expectEqual(@as(usize, 8), client.ws.max_message_size());
    const second = try client.ws.read_frame();
    try std.testing.expectEqualStrings("defg", second.payload);

    {
        var boundary_stream: EncodedStream(16) = .{};
        var boundary_payload = [_]u8{ 'd', 'e', 'f', 'g' };
        try boundary_stream.append(Frame.text(&boundary_payload));

        var boundary_reader = boundary_stream.reader();
        var boundary: ConnectionRig(16, 1, 64, 2, 0, 8) = .{};
        try boundary.init(&boundary_reader, .{
            .role = .client,
            .options = .{ .max_message_size = 4 },
            .mask_keys = connection.MaskKeySource.from_seed(@splat(0x45)),
        });

        try std.testing.expectError(error.FrameTooLarge, boundary.ws.read_frame());
    }
}

test "WebSocket: lowering max_message_size mid-fragment clamps the cumulative limit" {
    {
        var stream: EncodedStream(32) = .{};
        var first_payload = [_]u8{ 'a', 'b', 'c', 'd', 'e' };
        var second_payload = [_]u8{'f'};
        try append_masked(&stream, Frame.init(false, .text, null, &first_payload), .{ 0x11, 0x22, 0x33, 0x44 });
        try append_masked(
            &stream,
            Frame.init(true, .continuation, null, &second_payload),
            .{ 0x55, 0x66, 0x77, 0x88 },
        );

        var reader = stream.reader();
        var server: ConnectionRig(16, 1, 64, 8, 0, 8) = .{};
        try server.init(&reader, .{ .role = .server, .options = .{ .max_message_size = 64 } });

        const first = try server.ws.read_frame();
        try std.testing.expect(!first.fin);
        try std.testing.expectEqualStrings("abcde", first.payload);

        server.ws.set_max_message_size(4);
        // The exclusive 4-byte limit derives an inclusive 3, but the accepted
        // five-byte fragment must stay valid until its message completes.
        try std.testing.expectEqual(@as(u64, 5), server.ws.conn.max_message_len);
        try std.testing.expectError(error.FrameTooLarge, server.ws.read_frame());
    }

    {
        var empty = std.Io.Reader.fixed("");
        var server: ConnectionRig(16, 1, 64, 8, 0, 16) = .{};
        try server.init(&empty, .{ .role = .server, .options = .{ .max_message_size = 64 } });

        var first_payload = [_]u8{ 'a', 'b', 'c', 'd', 'e' };
        var second_payload = [_]u8{'f'};
        try server.ws.write_frame(Frame.init(false, .text, null, &first_payload));
        try std.testing.expectEqual(connection.OpCode.text, server.ws.conn.tx_fragment.opcode.?);
        try std.testing.expectEqual(@as(u64, 5), server.ws.conn.tx_fragment.message_len);

        server.ws.set_max_message_size(4);
        try std.testing.expectEqual(@as(u64, 5), server.ws.conn.max_message_len);
        try std.testing.expectError(
            error.FrameTooLarge,
            server.ws.write_frame(Frame.init(true, .continuation, null, &second_payload)),
        );
        try std.testing.expectEqual(@as(usize, 0), server.ws.tx_pending());
        try std.testing.expect(!server.ws.is_closed());
    }
}

test "WebSocket: init requires a write buffer longer than the maximum header" {
    var empty = std.Io.Reader.fixed("");
    var out: [8]u8 = undefined;
    var writer = RecordingVecWriter.init(&out);
    var frame_buffer: [8]u8 = undefined;
    var tx_nodes: [1]zslay.FrameNode = undefined;
    var close_buffer: [2]u8 = undefined;

    var too_small: [zslay.MaxFrameHeaderLen]u8 = undefined;
    try std.testing.expectError(error.InvalidLength, connection.WebSocket.init(
        &empty,
        &writer.writer,
        .{
            .frame_buffer = &frame_buffer,
            .tx_nodes = &tx_nodes,
            .write_buffer = &too_small,
            .close_buffer = &close_buffer,
        },
        .{ .role = .server },
    ));

    var minimum: [zslay.MaxFrameHeaderLen + 1]u8 = undefined;
    const ws = try connection.WebSocket.init(
        &empty,
        &writer.writer,
        .{
            .frame_buffer = &frame_buffer,
            .tx_nodes = &tx_nodes,
            .write_buffer = &minimum,
            .close_buffer = &close_buffer,
        },
        .{ .role = .server },
    );
    try std.testing.expectEqual(connection.Role.server, ws.role());
}

test "WebSocket: init rejects a close buffer smaller than two bytes" {
    var empty = std.Io.Reader.fixed("");
    var out: [8]u8 = undefined;
    var writer = RecordingVecWriter.init(&out);
    var frame_buffer: [8]u8 = undefined;
    var tx_nodes: [1]zslay.FrameNode = undefined;
    var write_buffer: [zslay.MaxFrameHeaderLen + 1]u8 = undefined;

    var too_small: [1]u8 = undefined;
    try std.testing.expectError(error.InvalidLength, connection.WebSocket.init(
        &empty,
        &writer.writer,
        .{
            .frame_buffer = &frame_buffer,
            .tx_nodes = &tx_nodes,
            .write_buffer = &write_buffer,
            .close_buffer = &too_small,
        },
        .{ .role = .server },
    ));

    var minimum: [2]u8 = undefined;
    const ws = try connection.WebSocket.init(
        &empty,
        &writer.writer,
        .{
            .frame_buffer = &frame_buffer,
            .tx_nodes = &tx_nodes,
            .write_buffer = &write_buffer,
            .close_buffer = &minimum,
        },
        .{ .role = .server },
    );
    try std.testing.expectEqual(connection.Role.server, ws.role());
}

test "WebSocket: init rejects overlapping caller buffers" {
    var empty = std.Io.Reader.fixed("");
    var out: [8]u8 = undefined;
    var writer = RecordingVecWriter.init(&out);
    var frame_buffer: [8]u8 = undefined;
    var tx_nodes: [2]zslay.FrameNode = undefined;
    var write_buffer: [zslay.MaxFrameHeaderLen + 1]u8 = undefined;
    var close_buffer: [2]u8 = undefined;

    // The frame buffer aliases the transmit-node storage.
    try std.testing.expectError(error.InvalidLength, connection.WebSocket.init(
        &empty,
        &writer.writer,
        .{
            .frame_buffer = std.mem.sliceAsBytes(&tx_nodes),
            .tx_nodes = &tx_nodes,
            .write_buffer = &write_buffer,
            .close_buffer = &close_buffer,
        },
        .{ .role = .server },
    ));

    // Mask scratch aliases the copied-write composition buffer.
    try std.testing.expectError(error.InvalidLength, connection.WebSocket.init(
        &empty,
        &writer.writer,
        .{
            .frame_buffer = &frame_buffer,
            .tx_nodes = &tx_nodes,
            .write_buffer = &write_buffer,
            .close_buffer = &close_buffer,
            .mask_scratch = write_buffer[0..4],
        },
        .{ .role = .server },
    ));
}

test "WebSocket: tx nodes are required for automatic replies" {
    var empty = std.Io.Reader.fixed("");
    var out: [16]u8 = undefined;
    var writer = RecordingVecWriter.init(&out);
    var frame_buffer: [8]u8 = undefined;
    var no_nodes: [0]zslay.FrameNode = .{};
    var write_buffer: [zslay.MaxFrameHeaderLen + 1]u8 = undefined;
    var close_buffer: [2]u8 = undefined;
    const storage: connection.Storage = .{
        .frame_buffer = &frame_buffer,
        .tx_nodes = &no_nodes,
        .write_buffer = &write_buffer,
        .close_buffer = &close_buffer,
    };

    try std.testing.expectError(error.InvalidLength, connection.WebSocket.init(
        &empty,
        &writer.writer,
        storage,
        .{ .role = .server },
    ));

    var ws = try connection.WebSocket.init(
        &empty,
        &writer.writer,
        storage,
        .{ .role = .server, .options = .{ .auto_pong = false, .auto_close = false } },
    );

    var payload = [_]u8{'x'};
    try std.testing.expectError(error.QueueFull, ws.write_frame(Frame.text(&payload)));
    try std.testing.expectEqual(@as(usize, 0), writer.written);
    try std.testing.expect(!ws.is_closed());
    try std.testing.expectEqual(@as(usize, 0), ws.tx_pending());
}

test "WebSocket: zero max_message_size also bounds outbound control payloads" {
    var empty = std.Io.Reader.fixed("");
    var server: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
    try server.init(&empty, .{ .role = .server, .options = .{ .max_message_size = 0 } });

    var close_storage: [2]u8 = undefined;
    try std.testing.expectError(
        error.FrameTooLarge,
        server.ws.write_frame(try Frame.close(1000, "", &close_storage)),
    );
    try std.testing.expectEqual(@as(usize, 0), server.writer.written);
    try std.testing.expect(!server.ws.is_closed());

    var empty_payload: [0]u8 = .{};
    try server.ws.write_frame(Frame.close_raw(&empty_payload));
    try std.testing.expect(server.ws.is_closed());

    var index: usize = 0;
    const close = try next_wire_frame(server.bytes(), &index);
    try std.testing.expectEqual(@as(usize, 0), close.payload.len);
    try std.testing.expectEqual(server.writer.written, index);
}

test "WebSocket: write rejects storage overlaps but allows frame_buffer payloads" {
    var empty = std.Io.Reader.fixed("");
    var server: ConnectionRig(16, 2, 64, 8, 8, 32) = .{};
    try server.init(&empty, .{ .role = .server });

    try std.testing.expectError(error.InvalidLength, server.ws.write_frame(Frame.binary(server.write_buffer[0..4])));
    try std.testing.expectError(error.InvalidLength, server.ws.write_frame(Frame.binary(server.close_buffer[0..2])));
    try std.testing.expectError(error.InvalidLength, server.ws.write_frame(Frame.binary(server.mask_scratch[0..4])));

    const tx_bytes = std.mem.sliceAsBytes(&server.tx_nodes);
    try std.testing.expectError(error.InvalidLength, server.ws.write_frame(Frame.binary(tx_bytes[0..4])));

    try std.testing.expectEqual(@as(usize, 0), server.writer.written);
    try std.testing.expect(!server.ws.is_closed());
    try std.testing.expectEqual(@as(usize, 0), server.ws.tx_pending());

    // A delivered frame may be echoed from frame_buffer; that region is not
    // connection-owned scratch. Deferred enqueue still rejects it because the
    // payload outlives the read.
    @memcpy(server.frame_buffer[0..2], "hi");
    try std.testing.expectError(error.InvalidLength, server.ws.enqueue_frame(Frame.text(server.frame_buffer[0..2])));
    try std.testing.expectEqual(@as(usize, 0), server.ws.tx_pending());
    try server.ws.write_frame(Frame.text(server.frame_buffer[0..2]));
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 0x02, 'h', 'i' }, server.bytes());
    try std.testing.expectEqual(@as(usize, 0), server.ws.tx_pending());
}

test "WebSocket: write rejects payloads aliasing reader or writer buffers" {
    var input: [8]u8 = @splat(0x41);
    var output: [64]u8 = undefined;
    var reader = std.Io.Reader.fixed(&input);
    var writer = std.Io.Writer.fixed(&output);
    var frame_buffer: [16]u8 = undefined;
    var tx_nodes: [2]zslay.FrameNode = undefined;
    var write_buffer: [16]u8 = undefined;
    var close_buffer: [8]u8 = undefined;
    var ws = try connection.WebSocket.init(&reader, &writer, .{
        .frame_buffer = &frame_buffer,
        .tx_nodes = &tx_nodes,
        .write_buffer = &write_buffer,
        .close_buffer = &close_buffer,
    }, .{ .role = .server });

    try std.testing.expectError(error.InvalidLength, ws.write_frame(Frame.binary(ws.reader.buffer[0..4])));
    try std.testing.expectError(error.InvalidLength, ws.write_frame(Frame.binary(ws.writer.buffer[0..4])));
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
    try std.testing.expectEqual(@as(usize, 0), ws.tx_pending());

    try std.testing.expectError(error.InvalidLength, ws.enqueue_frame(Frame.binary(ws.reader.buffer[0..4])));
    try std.testing.expectError(error.InvalidLength, ws.enqueue_frame(Frame.binary(ws.writer.buffer[0..4])));
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
    try std.testing.expectEqual(@as(usize, 0), ws.tx_pending());
}

test "WebSocket: max_message_size above zslay MaxPayloadLen is clamped" {
    var empty = std.Io.Reader.fixed("");
    var server: ConnectionRig(16, 1, 64, 8, 0, 8) = .{};
    try server.init(&empty, .{
        .role = .server,
        .options = .{ .max_message_size = std.math.maxInt(usize) },
    });

    const clamped_payload_len = std.math.cast(usize, zslay.MaxPayloadLen) orelse std.math.maxInt(usize);
    const expected = @min(std.math.maxInt(usize), clamped_payload_len);
    try std.testing.expectEqual(expected, server.ws.max_message_size());
}

test "WebSocket: set_max_message_size clamps above zslay MaxPayloadLen" {
    const seed: [connection.mask_seed_len]u8 = @splat(0x46);
    var stream: EncodedStream(16) = .{};
    var payload = [_]u8{ 'o', 'k' };
    try stream.append(Frame.text(&payload));

    var reader = stream.reader();
    var client: ConnectionRig(16, 1, 64, 2, 0, 8) = .{};
    try client.init(&reader, .{
        .role = .client,
        .options = .{ .max_message_size = 8 },
        .mask_keys = connection.MaskKeySource.from_seed(seed),
    });

    client.ws.set_max_message_size(std.math.maxInt(usize));

    const clamped_payload_len = std.math.cast(usize, zslay.MaxPayloadLen) orelse std.math.maxInt(usize);
    const clamped = @min(std.math.maxInt(usize), clamped_payload_len);
    try std.testing.expectEqual(clamped, client.ws.max_message_size());

    const received = try client.ws.read_frame();
    try std.testing.expectEqual(connection.OpCode.text, received.opcode);
    try std.testing.expectEqualStrings("ok", received.payload);
}
