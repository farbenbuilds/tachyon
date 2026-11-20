const std = @import("std");
const zslay = @import("zslay");
const tachyon = @import("tachyon");

const support = @import("../support.zig");

const Frame = tachyon.Frame;
const connection = tachyon.connection;
const EncodedStream = support.EncodedStream;
const ConnectionRig = support.ConnectionRig;
const FlushFailWriter = support.FlushFailWriter;
const append_masked = support.append_masked;
const next_wire_frame = support.next_wire_frame;

test "Connection: watermark batching pauses data admission until flush drains" {
    var peer = EncodedStream(64){};
    var peer_payload = [_]u8{ 'p', 'e', 'e', 'r' };
    try append_masked(&peer, Frame.text(&peer_payload), .{ 1, 2, 3, 4 });
    var reader = peer.reader();

    var server: ConnectionRig(16, 4, 64, 8, 0, 64) = .{};
    try server.init(&reader, .{
        .role = .server,
        .options = .{
            .backpressure = .{
                .high_water_bytes = 8,
                .low_water_bytes = 2,
                .high_water_frames = 2,
                .low_water_frames = 1,
            },
        },
    });

    var first = [_]u8{ 'a', 'a', 'a' };
    var second = [_]u8{ 'b', 'b', 'b' };
    var third = [_]u8{ 'c', 'c', 'c' };

    try server.ws.enqueue_frame(Frame.text(&first));
    try std.testing.expectEqual(@as(usize, 0), server.writer.written);
    try std.testing.expectEqual(@as(usize, 1), server.ws.queued_frames());
    try std.testing.expect(!server.ws.is_backpressured());

    try server.ws.enqueue_frame(Frame.text(&second));
    try std.testing.expectEqual(@as(usize, 2), server.ws.queued_frames());
    try std.testing.expectEqual(@as(usize, 6), server.ws.queued_bytes());
    try std.testing.expect(server.ws.is_backpressured());
    try std.testing.expectEqual(@as(usize, 0), server.writer.written);

    try std.testing.expectError(error.WouldBlock, server.ws.enqueue_frame(Frame.text(&third)));
    try std.testing.expectError(error.WouldBlock, server.ws.write_frame(Frame.text(&third)));
    try std.testing.expectEqual(@as(usize, 2), server.ws.queued_frames());

    // Outbound pressure never blocks a peer read or the close handshake.
    const incoming = try server.ws.read_frame();
    try std.testing.expectEqualSlices(u8, "peer", incoming.payload);
    try std.testing.expect(server.ws.read_failure == null);

    try server.ws.flush();
    try std.testing.expectEqual(@as(usize, 0), server.ws.queued_frames());
    try std.testing.expectEqual(@as(usize, 0), server.ws.queued_bytes());
    try std.testing.expect(!server.ws.is_backpressured());

    var index: usize = 0;
    const wire_first = try next_wire_frame(server.bytes(), &index);
    try std.testing.expectEqualSlices(u8, &first, wire_first.payload);
    const wire_second = try next_wire_frame(server.bytes(), &index);
    try std.testing.expectEqualSlices(u8, &second, wire_second.payload);
}

test "Connection: control frames bypass the paused producer and close drains" {
    var empty = std.Io.Reader.fixed("");
    var server: ConnectionRig(16, 5, 64, 8, 0, 64) = .{};
    try server.init(&empty, .{
        .role = .server,
        .options = .{
            .backpressure = .{
                .high_water_bytes = 4,
                .high_water_frames = 2,
                .low_water_frames = 1,
            },
        },
    });

    var first = [_]u8{ 'a', 'a' };
    var second = [_]u8{ 'b', 'b' };
    var ping = [_]u8{'p'};
    var close_storage: [2]u8 = undefined;

    try server.ws.enqueue_frame(Frame.text(&first));
    try server.ws.enqueue_frame(Frame.text(&second));
    try std.testing.expect(server.ws.is_backpressured());

    try server.ws.enqueue_frame(Frame.ping(&ping));
    try std.testing.expectEqual(@as(usize, 3), server.ws.queued_frames());

    try server.ws.enqueue_frame(try Frame.close(1000, "", &close_storage));
    try std.testing.expect(server.ws.is_closed());
    try std.testing.expectEqual(@as(usize, 4), server.ws.queued_frames());

    try std.testing.expectError(error.ConnectionClosed, server.ws.enqueue_frame(Frame.text(&first)));
    try std.testing.expectEqual(@as(usize, 0), server.writer.written);

    try server.ws.flush();
    try std.testing.expectEqual(@as(usize, 0), server.ws.queued_frames());
    try std.testing.expect(!server.ws.is_backpressured());

    var index: usize = 0;
    _ = try next_wire_frame(server.bytes(), &index);
    _ = try next_wire_frame(server.bytes(), &index);
    _ = try next_wire_frame(server.bytes(), &index);
    _ = try next_wire_frame(server.bytes(), &index);
    try std.testing.expectEqual(server.writer.written, index);
}

test "Connection: watermark configuration must fit the transmit ring" {
    var empty = std.Io.Reader.fixed("");
    var unsuitable: ConnectionRig(16, 2, 64, 8, 0, 64) = .{};

    try std.testing.expectError(error.InvalidLength, unsuitable.init(&empty, .{
        .role = .server,
        .options = .{
            .backpressure = .{
                .high_water_bytes = 8,
                .high_water_frames = 3,
            },
        },
    }));

    // The reserve is unconditional, so disabling auto replies at init does not
    // let a two-node ring pause at two data frames.
    try std.testing.expectError(error.InvalidLength, unsuitable.init(&empty, .{
        .role = .server,
        .options = .{
            .auto_pong = false,
            .auto_close = false,
            .backpressure = .{
                .high_water_bytes = 8,
                .high_water_frames = 2,
            },
        },
    }));

    try std.testing.expectError(error.InvalidLength, unsuitable.init(&empty, .{
        .role = .server,
        .options = .{
            .backpressure = .{
                .high_water_bytes = 0,
                .high_water_frames = 1,
            },
        },
    }));
}

test "Connection: application controls stop at the data capacity" {
    var peer = EncodedStream(64){};
    var ping_payload = [_]u8{'p'};
    var text_payload = [_]u8{ 'n', 'e', 'x', 't' };
    try append_masked(&peer, Frame.ping(&ping_payload), .{ 1, 2, 3, 4 });
    try append_masked(&peer, Frame.text(&text_payload), .{ 5, 6, 7, 8 });
    var reader = peer.reader();

    var server: ConnectionRig(16, 2, 64, 8, 0, 64) = .{};
    try server.init(&reader, .{
        .role = .server,
        .options = .{
            .backpressure = .{
                .high_water_bytes = 8,
                .high_water_frames = 1,
            },
        },
    });

    var app_ping = [_]u8{'a'};
    var app_pong = [_]u8{'b'};
    try server.ws.enqueue_frame(Frame.ping(&app_ping));
    try std.testing.expectError(error.WouldBlock, server.ws.enqueue_frame(Frame.pong(&app_pong)));
    try std.testing.expectEqual(@as(usize, 1), server.ws.queued_frames());

    // The data capacity is full, but the automatic pong still uses the
    // reserved node and the following text frame is delivered.
    const incoming = try server.ws.read_frame();
    try std.testing.expectEqualSlices(u8, "next", incoming.payload);
    try std.testing.expectEqual(@as(usize, 0), server.ws.queued_frames());
    try std.testing.expectEqual(@as(usize, 0), server.ws.tx_pending());
}

test "Connection: enabling auto replies after init keeps the reserve" {
    var peer = EncodedStream(64){};
    var ping_payload = [_]u8{'p'};
    var text_payload = [_]u8{ 'n', 'e', 'x', 't' };
    try append_masked(&peer, Frame.ping(&ping_payload), .{ 1, 2, 3, 4 });
    try append_masked(&peer, Frame.text(&text_payload), .{ 5, 6, 7, 8 });
    var reader = peer.reader();

    var server: ConnectionRig(16, 2, 64, 8, 0, 64) = .{};
    try server.init(&reader, .{
        .role = .server,
        .options = .{
            .auto_pong = false,
            .auto_close = false,
            .backpressure = .{
                .high_water_bytes = 8,
                .high_water_frames = 1,
            },
        },
    });
    server.ws.set_auto_pong(true);

    var data = [_]u8{'d'};
    try server.ws.enqueue_frame(Frame.text(&data));
    try std.testing.expect(server.ws.is_backpressured());

    const incoming = try server.ws.read_frame();
    try std.testing.expectEqualSlices(u8, "next", incoming.payload);
    try std.testing.expectEqual(@as(usize, 0), server.ws.tx_pending());
}

test "Connection: a peer close is delivered while the producer is paused" {
    var peer = EncodedStream(64){};
    var close_payload: [2]u8 = undefined;
    try append_masked(&peer, try Frame.close(1000, "", &close_payload), .{ 1, 2, 3, 4 });
    var reader = peer.reader();

    var server: ConnectionRig(16, 3, 64, 8, 0, 64) = .{};
    try server.init(&reader, .{
        .role = .server,
        .options = .{
            .backpressure = .{
                .high_water_bytes = 8,
                .high_water_frames = 1,
            },
        },
    });

    var data = [_]u8{'d'};
    try server.ws.enqueue_frame(Frame.text(&data));
    try std.testing.expect(server.ws.is_backpressured());

    const incoming = try server.ws.read_frame();
    try std.testing.expectEqual(tachyon.OpCode.close, incoming.opcode);
    try std.testing.expect(server.ws.is_closed());
    try std.testing.expectEqual(@as(usize, 0), server.ws.tx_pending());
}

test "Connection: application close may use the reserved node at data capacity" {
    var empty = std.Io.Reader.fixed("");
    var server: ConnectionRig(16, 3, 64, 8, 0, 64) = .{};
    try server.init(&empty, .{
        .role = .server,
        .options = .{
            .backpressure = .{
                .high_water_bytes = 8,
                .high_water_frames = 2,
            },
        },
    });

    var first = [_]u8{'a'};
    var second = [_]u8{'b'};
    var close_storage: [2]u8 = undefined;

    try server.ws.enqueue_frame(Frame.text(&first));
    try server.ws.enqueue_frame(Frame.text(&second));
    try std.testing.expectEqual(@as(usize, 2), server.ws.tx_pending());
    try std.testing.expect(server.ws.is_backpressured());

    try server.ws.enqueue_frame(try Frame.close(1000, "", &close_storage));
    try std.testing.expect(server.ws.is_closed());
    try std.testing.expectEqual(@as(usize, 3), server.ws.tx_pending());

    try server.ws.flush();
    try std.testing.expectEqual(@as(usize, 0), server.ws.tx_pending());
}

test "Connection: watermark counters exclude caller writer-buffered bytes" {
    var out: [64]u8 = undefined;
    var sink_buffer: [8]u8 = undefined;
    var sink = FlushFailWriter.init(&out, &sink_buffer);
    sink.fail_flush = false;

    var reader = std.Io.Reader.fixed("");
    var frame_buffer: [16]u8 = undefined;
    var tx_nodes: [2]zslay.FrameNode = undefined;
    var write_buffer: [32]u8 = undefined;
    var close_buffer: [8]u8 = undefined;

    var ws = try connection.WebSocket.init(&reader, &sink.writer, .{
        .frame_buffer = &frame_buffer,
        .tx_nodes = &tx_nodes,
        .write_buffer = &write_buffer,
        .close_buffer = &close_buffer,
    }, .{
        .role = .server,
        .options = .{
            .backpressure = .{
                .high_water_bytes = 4,
                .high_water_frames = 1,
            },
        },
    });

    var payload = [_]u8{ 'a', 'b' };
    try ws.write_frame(Frame.text(&payload));

    // The frame reached the caller's writer buffer, so the zslay watermark is
    // empty even though `flush` still has bytes to send.
    try std.testing.expectEqual(@as(usize, 0), ws.queued_bytes());
    try std.testing.expectEqual(@as(usize, 0), ws.queued_frames());
    try std.testing.expect(sink.writer.buffered().len != 0);

    try ws.flush();
    try std.testing.expectEqual(@as(usize, 0), sink.writer.buffered().len);
    try std.testing.expectEqual(@as(usize, 4), sink.written);
}

test "Connection: a partial write keeps the watermark charge until reset_tx" {
    var empty = std.Io.Reader.fixed("");
    var server: ConnectionRig(16, 3, 64, 8, 0, 64) = .{};
    try server.init(&empty, .{
        .role = .server,
        .options = .{
            .backpressure = .{
                .high_water_bytes = 8,
                .high_water_frames = 1,
            },
        },
    });
    server.writer.fail_after = 2;

    var payload = [_]u8{ 'h', 'e', 'l', 'l', 'o' };
    try std.testing.expectError(error.IoError, server.ws.write_frame(Frame.text(&payload)));
    try std.testing.expectEqual(@as(usize, 1), server.ws.queued_frames());
    try std.testing.expectEqual(@as(usize, 5), server.ws.queued_bytes());

    server.ws.reset_tx();
    try std.testing.expectEqual(@as(usize, 0), server.ws.queued_frames());
    try std.testing.expectEqual(@as(usize, 0), server.ws.queued_bytes());
    try std.testing.expect(!server.ws.is_backpressured());
}

test "Connection: reset_tx clears the watermark phase with the ring" {
    var empty = std.Io.Reader.fixed("");
    var server: ConnectionRig(16, 3, 64, 8, 0, 64) = .{};
    try server.init(&empty, .{
        .role = .server,
        .options = .{
            .backpressure = .{
                .high_water_bytes = 4,
                .high_water_frames = 2,
            },
        },
    });

    var first = [_]u8{ 'a', 'a' };
    var second = [_]u8{ 'b', 'b' };
    try server.ws.enqueue_frame(Frame.text(&first));
    try server.ws.enqueue_frame(Frame.text(&second));
    try std.testing.expect(server.ws.is_backpressured());

    server.ws.reset_tx();

    try std.testing.expect(!server.ws.is_backpressured());
    try std.testing.expectEqual(@as(usize, 0), server.ws.queued_frames());
    try std.testing.expectEqual(@as(usize, 0), server.ws.queued_bytes());
    try std.testing.expectEqual(@as(usize, 0), server.ws.tx_pending());
}
