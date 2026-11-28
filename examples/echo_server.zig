//! Minimal concurrent WebSocket echo server.
//!
//! The accept loop is sequential and dispatches into a bounded `std.Io` task
//! group. At the group limit, work can run inline instead of on a separate
//! task. Framing, masking, automatic pong and close replies, and message limits
//! stay in tachyon and zslay; this file only performs the HTTP upgrade and
//! echoes data frames.
//!
//! Run with:
//!   zig build examples
//!   ./zig-out/bin/tachyon-echo-server
//!
//! Then connect a client to ws://127.0.0.1:8080/ (set PORT to change it).

const std = @import("std");
const tachyon = @import("tachyon");

const bind_host = "127.0.0.1";
const default_port: u16 = 8080;
const max_message_size: usize = 64 * 1024;
const transport_buffer_len: usize = 16 * 1024;
const connection_write_len: usize = 16 * 1024;
const head_len: usize = 16 * 1024;
const tx_node_count: usize = 8;
const async_limit: usize = 512;
const task_stack_len: usize = 512 * 1024;

/// Caller-owned buffers for one connection.
const Buffers = struct {
    frame_buffer: [max_message_size]u8 = undefined,
    transport_read: [transport_buffer_len]u8 = undefined,
    transport_write: [transport_buffer_len]u8 = undefined,
    connection_write: [connection_write_len]u8 = undefined,
    close_buffer: [125]u8 = undefined,
    head: [head_len]u8 = undefined,
    tx_nodes: [tx_node_count]tachyon.zslay.FrameNode = undefined,
};

/// Connection storage assembled from the caller-owned buffers.
fn connectionStorage(buffers: *Buffers) tachyon.ConnectionStorage {
    return .{
        .frame_buffer = &buffers.frame_buffer,
        .tx_nodes = &buffers.tx_nodes,
        .write_buffer = &buffers.connection_write,
        .close_buffer = &buffers.close_buffer,
        .mask_scratch = &.{},
    };
}

/// Runs one upgraded connection and echoes text, binary, and continuation
/// frames. A validated close is already echoed by the connection layer.
fn handle(io: std.Io, stream: std.Io.net.Stream, buffers: *Buffers) tachyon.WebSocketError!void {
    var transport = try tachyon.NativeTransport.init(io, stream, .{
        .read_buffer = &buffers.transport_read,
        .write_buffer = &buffers.transport_write,
    });

    const incoming = try tachyon.upgrade.incoming(transport.reader(), &buffers.head);

    // Validate and construct the connection before committing the 101 response.
    var ws = try tachyon.NativeWebSocket.init(&transport, connectionStorage(buffers), .{
        .role = .server,
        .options = .{ .max_message_size = max_message_size },
    });

    try tachyon.handshake.write_response(transport.writer(), incoming.request.key);
    transport.writer().flush() catch |err| return tachyon.from_writer(err);

    while (true) {
        const frame = ws.read_frame() catch |err| {
            if (err == error.ConnectionClosed or tachyon.is_eof_error(err)) return;
            return err;
        };

        switch (frame.opcode) {
            // The connection already validates and echoes a peer close before
            // returning the frame.
            .close => return,
            // Echoing each data frame preserves fragmentation as received.
            .text, .binary, .continuation => {
                try ws.write_frame(frame);
                try ws.flush();
            },
            else => {},
        }
    }
}

/// Disables Nagle's algorithm on POSIX sockets so request/response latency is
/// not dominated by delayed ACKs during benchmarks.
fn setNoDelay(stream: std.Io.net.Stream) void {
    if (comptime @import("builtin").os.tag == .windows) return;
    std.posix.setsockopt(
        stream.socket.handle,
        std.posix.IPPROTO.TCP,
        std.posix.TCP.NODELAY,
        &std.mem.toBytes(@as(c_int, 1)),
    ) catch {};
}

/// Owns the per-connection allocation and closes the socket after `handle`.
fn serveConnection(io: std.Io, gpa: std.mem.Allocator, stream: std.Io.net.Stream) void {
    defer stream.close(io);
    setNoDelay(stream);

    const buffers = gpa.create(Buffers) catch return;
    defer gpa.destroy(buffers);

    handle(io, stream, buffers) catch |err| {
        if (err != error.ConnectionClosed and !tachyon.is_eof_error(err) and err != error.IoError) {
            std.log.debug("connection ended: {s}", .{tachyon.description(err)});
        }
    };
}

pub fn main(init: std.process.Init) !void {
    var threaded: std.Io.Threaded = .init(init.gpa, .{
        .async_limit = .limited(async_limit),
        .stack_size = task_stack_len,
    });
    defer threaded.deinit();
    const io = threaded.io();

    const port = if (init.environ_map.get("PORT")) |raw|
        try std.fmt.parseInt(u16, raw, 10)
    else
        default_port;
    const address = try std.Io.net.IpAddress.parse(bind_host, port);
    var listener = try address.listen(io, .{
        .kernel_backlog = 1024,
        .reuse_address = true,
    });
    defer listener.deinit(io);

    var group: std.Io.Group = .init;
    defer group.cancel(io);

    std.debug.print("echo server listening on ws://{s}:{d}/\n", .{ bind_host, port });

    while (true) {
        const stream = listener.accept(io) catch |err| switch (err) {
            error.ConnectionAborted => continue,
            else => return err,
        };
        group.async(io, serveConnection, .{ io, init.gpa, stream });
    }
}
