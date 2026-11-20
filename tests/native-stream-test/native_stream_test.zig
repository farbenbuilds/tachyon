const std = @import("std");
const zslay = @import("zslay");
const tachyon = @import("tachyon");

const native_stream = tachyon.native_stream;
const support = @import("../support.zig");

const Pair = struct {
    listener: std.Io.net.Server,
    client: std.Io.net.Stream,
    server: std.Io.net.Stream,

    fn close(self: *Pair, io: std.Io) void {
        self.client.close(io);
        self.server.close(io);
        self.listener.deinit(io);
    }
};

/// Opens a loopback TCP pair through the caller's `std.Io`.
///
/// The listening socket and both accepted streams are real
/// `std.Io.net.Stream` values, so the tests exercise the same native reader and
/// writer paths used in production. The backlog makes connect complete before
/// accept runs, so no test thread or task is needed.
fn openPair(io: std.Io) !Pair {
    const bind_address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try bind_address.listen(io, .{});
    errdefer listener.deinit(io);

    const connect_address = try std.Io.net.IpAddress.parse("127.0.0.1", listener.socket.address.getPort());
    const client = try connect_address.connect(io, .{ .mode = .stream });
    errdefer client.close(io);

    const server = try listener.accept(io);
    errdefer server.close(io);

    return .{ .listener = listener, .client = client, .server = server };
}

test "Native stream: rejects empty and overlapping transport buffers" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var pair = try openPair(io);
    defer pair.close(io);

    var storage: [32]u8 = undefined;

    try std.testing.expectError(error.InvalidLength, native_stream.Transport.init(io, pair.client, .{
        .read_buffer = &.{},
        .write_buffer = storage[16..32],
    }));
    try std.testing.expectError(error.InvalidLength, native_stream.Transport.init(io, pair.client, .{
        .read_buffer = storage[0..20],
        .write_buffer = storage[10..30],
    }));

    var transport = try native_stream.Transport.init(io, pair.client, .{
        .read_buffer = storage[0..16],
        .write_buffer = storage[16..32],
    });
    try std.testing.expectEqual(@as(usize, 16), transport.reader().buffer.len);
    try std.testing.expectEqual(@as(usize, 16), transport.writer().buffer.len);
    try std.testing.expect(!transport.is_bound());
    try std.testing.expect(transport.stream_read_error() == null);
    try std.testing.expect(transport.stream_write_error() == null);
}

test "Native stream: client and server exchange text frames over loopback" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var pair = try openPair(io);
    defer pair.close(io);

    var client_read_buffer: [64]u8 = undefined;
    var client_write_buffer: [64]u8 = undefined;
    var client_transport = try native_stream.Transport.init(io, pair.client, .{
        .read_buffer = &client_read_buffer,
        .write_buffer = &client_write_buffer,
    });

    var server_read_buffer: [64]u8 = undefined;
    var server_write_buffer: [64]u8 = undefined;
    var server_transport = try native_stream.Transport.init(io, pair.server, .{
        .read_buffer = &server_read_buffer,
        .write_buffer = &server_write_buffer,
    });

    var client_frame_buffer: [64]u8 = undefined;
    var client_write_storage: [64]u8 = undefined;
    var client_close_storage: [16]u8 = undefined;
    var client_nodes: [2]zslay.FrameNode = undefined;
    var client = try native_stream.WebSocket.init(&client_transport, .{
        .frame_buffer = &client_frame_buffer,
        .tx_nodes = &client_nodes,
        .write_buffer = &client_write_storage,
        .close_buffer = &client_close_storage,
    }, .{
        .role = .client,
        .mask_keys = tachyon.MaskKeySource.from_seed(@splat(0x2a)),
    });
    try std.testing.expect(client_transport.is_bound());
    try std.testing.expectError(error.InvalidLength, native_stream.WebSocket.init(&client_transport, .{
        .frame_buffer = &client_frame_buffer,
        .tx_nodes = &client_nodes,
        .write_buffer = &client_write_storage,
        .close_buffer = &client_close_storage,
    }, .{
        .role = .client,
        .mask_keys = tachyon.MaskKeySource.from_seed(@splat(0x2a)),
    }));

    var server_frame_buffer: [64]u8 = undefined;
    var server_write_storage: [64]u8 = undefined;
    var server_close_storage: [16]u8 = undefined;
    var server_nodes: [2]zslay.FrameNode = undefined;
    var server = try native_stream.WebSocket.init(&server_transport, .{
        .frame_buffer = &server_frame_buffer,
        .tx_nodes = &server_nodes,
        .write_buffer = &server_write_storage,
        .close_buffer = &server_close_storage,
    }, .{ .role = .server });

    var hello = [_]u8{ 'h', 'e', 'l', 'l', 'o' };
    try client.write_frame(tachyon.Frame.text(&hello));
    try client.flush();
    try std.testing.expectEqual(@as(usize, 0), client.tx_pending());

    const request = try server.read_frame();
    try std.testing.expectEqual(tachyon.OpCode.text, request.opcode);
    try std.testing.expect(request.fin);
    try std.testing.expectEqual(@as(?tachyon.MaskingKey, null), request.masking_key);
    try std.testing.expectEqualStrings("hello", request.payload);

    var world = [_]u8{ 'w', 'o', 'r', 'l', 'd' };
    try server.write_frame(tachyon.Frame.text(&world));
    try server.flush();

    const response = try client.read_frame();
    try std.testing.expectEqual(tachyon.OpCode.text, response.opcode);
    try std.testing.expectEqual(@as(?tachyon.MaskingKey, null), response.masking_key);
    try std.testing.expectEqualStrings("world", response.payload);

    try std.testing.expect(!client.is_closed());
    try std.testing.expect(!server.is_closed());
    try std.testing.expect(client_transport.stream_read_error() == null);
    try std.testing.expect(server_transport.stream_read_error() == null);
}

test "Native stream: split half answers a ping and exchanges text" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var pair = try openPair(io);
    defer pair.close(io);

    var client_read_buffer: [64]u8 = undefined;
    var client_write_buffer: [64]u8 = undefined;
    var client_transport = try native_stream.Transport.init(io, pair.client, .{
        .read_buffer = &client_read_buffer,
        .write_buffer = &client_write_buffer,
    });

    var server_read_buffer: [64]u8 = undefined;
    var server_write_buffer: [64]u8 = undefined;
    var server_transport = try native_stream.Transport.init(io, pair.server, .{
        .read_buffer = &server_read_buffer,
        .write_buffer = &server_write_buffer,
    });

    var client_frame_buffer: [64]u8 = undefined;
    var client_write_storage: [64]u8 = undefined;
    var client_close_storage: [16]u8 = undefined;
    var client_nodes: [2]zslay.FrameNode = undefined;
    var client = try native_stream.WebSocket.init(&client_transport, .{
        .frame_buffer = &client_frame_buffer,
        .tx_nodes = &client_nodes,
        .write_buffer = &client_write_storage,
        .close_buffer = &client_close_storage,
    }, .{
        .role = .client,
        .mask_keys = tachyon.MaskKeySource.from_seed(@splat(0x4c)),
    });

    var split_read_frame_buffer: [64]u8 = undefined;
    var split_read_close_buffer: [16]u8 = undefined;
    var split_compose_buffer: [64]u8 = undefined;
    var split_write_storage: [64]u8 = undefined;
    var split_write_close_buffer: [16]u8 = undefined;
    var split_nodes: [2]zslay.FrameNode = undefined;
    var server = try native_stream.Split.init(&server_transport, .{
        .read = .{
            .frame_buffer = &split_read_frame_buffer,
            .close_buffer = &split_read_close_buffer,
            .compose_buffer = &split_compose_buffer,
        },
        .write = .{
            .tx_nodes = &split_nodes,
            .write_buffer = &split_write_storage,
            .close_buffer = &split_write_close_buffer,
        },
    }, .{ .role = .server });
    try std.testing.expect(server_transport.is_bound());

    var other_frame_buffer: [16]u8 = undefined;
    var other_write_buffer: [32]u8 = undefined;
    var other_close_buffer: [8]u8 = undefined;
    try std.testing.expectError(error.InvalidLength, native_stream.WebSocket.init(&server_transport, .{
        .frame_buffer = &other_frame_buffer,
        .tx_nodes = &split_nodes,
        .write_buffer = &other_write_buffer,
        .close_buffer = &other_close_buffer,
    }, .{ .role = .server }));

    var ping_payload = [_]u8{ 'p', 'i', 'n', 'g' };
    try client.write_frame(tachyon.Frame.ping(&ping_payload));
    var text_payload = [_]u8{ 'h', 'i' };
    try client.write_frame(tachyon.Frame.text(&text_payload));
    try client.flush();

    const incoming = try server.read_frame();
    try std.testing.expectEqual(tachyon.OpCode.text, incoming.opcode);
    try std.testing.expectEqualStrings("hi", incoming.payload);
    try std.testing.expectEqual(@as(usize, 0), server.inner.write.tx_pending());

    const pong = try client.read_frame();
    try std.testing.expectEqual(tachyon.OpCode.pong, pong.opcode);
    try std.testing.expectEqualStrings("ping", pong.payload);

    var reply = [_]u8{ 'o', 'k' };
    try server.write_frame(tachyon.Frame.text(&reply));
    try server.flush();

    const reply_frame = try client.read_frame();
    try std.testing.expectEqual(tachyon.OpCode.text, reply_frame.opcode);
    try std.testing.expectEqualStrings("ok", reply_frame.payload);
}

test "Native stream: handshake then bind preserves coalesced frame bytes" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var pair = try openPair(io);
    defer pair.close(io);

    var client_write_buffer: [256]u8 = undefined;
    var client_writer = pair.client.writer(io, &client_write_buffer);
    try client_writer.interface.writeAll(support.handshake_valid_request);

    var payload = [_]u8{ 'h', 'i' };
    var frame = tachyon.Frame.text(&payload);
    frame.mask(.{ 0x01, 0x02, 0x03, 0x04 });
    try frame.writev(&client_writer.interface);
    try client_writer.interface.flush();

    var server_read_buffer: [128]u8 = undefined;
    var server_write_buffer: [128]u8 = undefined;
    var server_transport = try native_stream.Transport.init(io, pair.server, .{
        .read_buffer = &server_read_buffer,
        .write_buffer = &server_write_buffer,
    });

    var head_storage: [1024]u8 = undefined;
    const request = try tachyon.handshake.read_request(server_transport.reader(), &head_storage);
    try tachyon.handshake.write_response(server_transport.writer(), request.key);
    try server_transport.writer().flush();

    var frame_buffer: [64]u8 = undefined;
    var write_storage: [64]u8 = undefined;
    var close_storage: [16]u8 = undefined;
    var nodes: [2]zslay.FrameNode = undefined;
    var server = try native_stream.WebSocket.init(&server_transport, .{
        .frame_buffer = &frame_buffer,
        .tx_nodes = &nodes,
        .write_buffer = &write_storage,
        .close_buffer = &close_storage,
    }, .{ .role = .server });

    const received = try server.read_frame();
    try std.testing.expectEqual(tachyon.OpCode.text, received.opcode);
    try std.testing.expectEqual(@as(?tachyon.MaskingKey, null), received.masking_key);
    try std.testing.expectEqualStrings("hi", received.payload);
}

test "Native stream: rejects connection and split storage aliasing the transport" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var pair = try openPair(io);
    defer pair.close(io);

    var read_buffer: [64]u8 = undefined;
    var write_buffer: [64]u8 = undefined;
    var transport = try native_stream.Transport.init(io, pair.client, .{
        .read_buffer = &read_buffer,
        .write_buffer = &write_buffer,
    });

    var frame_buffer: [64]u8 = undefined;
    var node_storage: [64]u8 = undefined;
    var read_close_storage: [16]u8 = undefined;
    var write_close_storage: [16]u8 = undefined;
    var nodes: [2]zslay.FrameNode = undefined;
    const split_storage: tachyon.SplitStorage = .{
        .read = .{
            .frame_buffer = &frame_buffer,
            .close_buffer = &read_close_storage,
            .compose_buffer = &node_storage,
        },
        .write = .{
            .tx_nodes = &nodes,
            .write_buffer = &write_buffer,
            .close_buffer = &write_close_storage,
        },
    };

    try std.testing.expectError(error.InvalidLength, native_stream.WebSocket.init(&transport, .{
        .frame_buffer = &read_buffer,
        .tx_nodes = &nodes,
        .write_buffer = &node_storage,
        .close_buffer = &read_close_storage,
    }, .{
        .role = .client,
        .mask_keys = tachyon.MaskKeySource.from_seed(@splat(0x11)),
    }));
    try std.testing.expect(!transport.is_bound());

    try std.testing.expectError(error.InvalidLength, native_stream.Split.init(&transport, split_storage, .{
        .role = .client,
        .mask_keys = tachyon.MaskKeySource.from_seed(@splat(0x11)),
    }));
    try std.testing.expect(!transport.is_bound());
}

test "Native stream: WebSocket delegates watermark batching and flush" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var pair = try openPair(io);
    defer pair.close(io);

    var read_buffer: [64]u8 = undefined;
    var write_buffer: [64]u8 = undefined;
    var transport = try native_stream.Transport.init(io, pair.client, .{
        .read_buffer = &read_buffer,
        .write_buffer = &write_buffer,
    });

    var frame_buffer: [64]u8 = undefined;
    var write_storage: [64]u8 = undefined;
    var close_storage: [16]u8 = undefined;
    var nodes: [2]zslay.FrameNode = undefined;

    var ws = try native_stream.WebSocket.init(&transport, .{
        .frame_buffer = &frame_buffer,
        .tx_nodes = &nodes,
        .write_buffer = &write_storage,
        .close_buffer = &close_storage,
    }, .{
        .role = .client,
        .mask_keys = tachyon.MaskKeySource.from_seed(@splat(0x5a)),
        .options = .{
            .backpressure = .{
                .high_water_bytes = 8,
                .high_water_frames = 1,
            },
        },
    });

    var first = [_]u8{'a'};
    var second = [_]u8{'b'};
    try ws.enqueue_frame(tachyon.Frame.text(&first));
    try std.testing.expect(ws.is_backpressured());
    try std.testing.expectEqual(@as(usize, 1), ws.queued_frames());
    try std.testing.expectEqual(@as(usize, 1), ws.queued_bytes());
    try std.testing.expectError(error.WouldBlock, ws.enqueue_frame(tachyon.Frame.text(&second)));

    try ws.flush();
    try std.testing.expect(!ws.is_backpressured());
    try std.testing.expectEqual(@as(usize, 0), ws.queued_frames());
    try std.testing.expectEqual(@as(usize, 0), ws.queued_bytes());
}
