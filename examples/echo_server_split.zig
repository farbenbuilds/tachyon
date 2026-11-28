//! Split WebSocket echo server.
//!
//! This mirrors the split example shape: the upgrade returns a read half and a
//! write half over one `std.Io.net.Stream`. Automatic pong and close replies
//! are routed through the write half by the split read path.
//!
//! Run with:
//!   zig build examples
//!   ./zig-out/bin/tachyon-echo-server-split
//!
//! Then connect a client to ws://127.0.0.1:8080/.

const std = @import("std");
const tachyon = @import("tachyon");

const bind_host = "127.0.0.1";
const bind_port: u16 = 8080;
const max_message_size: usize = 64 * 1024;
const transport_buffer_len: usize = 16 * 1024;
const compose_buffer_len: usize = 16 * 1024;
const write_buffer_len: usize = 16 * 1024;
const head_len: usize = 16 * 1024;
const tx_node_count: usize = 8;
const async_limit: usize = 512;
const task_stack_len: usize = 512 * 1024;

/// Caller-owned storage for one split connection.
const Buffers = struct {
    read_frame_buffer: [max_message_size]u8 = undefined,
    read_close_buffer: [125]u8 = undefined,
    read_compose_buffer: [compose_buffer_len]u8 = undefined,
    tx_nodes: [tx_node_count]tachyon.zslay.FrameNode = undefined,
    write_buffer: [write_buffer_len]u8 = undefined,
    write_close_buffer: [125]u8 = undefined,
    head: [head_len]u8 = undefined,
    transport_read: [transport_buffer_len]u8 = undefined,
    transport_write: [transport_buffer_len]u8 = undefined,
};

fn splitStorage(buffers: *Buffers) tachyon.SplitStorage {
    return .{
        .read = .{
            .frame_buffer = &buffers.read_frame_buffer,
            .close_buffer = &buffers.read_close_buffer,
            .compose_buffer = &buffers.read_compose_buffer,
        },
        .write = .{
            .tx_nodes = &buffers.tx_nodes,
            .write_buffer = &buffers.write_buffer,
            .close_buffer = &buffers.write_close_buffer,
            .mask_scratch = &.{},
        },
    };
}

/// Upgrades one connection, then echoes data frames through the split halves.
fn handle(io: std.Io, stream: std.Io.net.Stream, buffers: *Buffers) tachyon.WebSocketError!void {
    var transport = try tachyon.NativeTransport.init(io, stream, .{
        .read_buffer = &buffers.transport_read,
        .write_buffer = &buffers.transport_write,
    });

    var upgraded = try tachyon.upgrade.upgrade(
        transport.reader(),
        transport.writer(),
        &buffers.head,
        splitStorage(buffers),
        .{
            .role = .server,
            .options = .{ .max_message_size = max_message_size },
        },
    );

    var ws = &upgraded.websocket;
    while (true) {
        const frame = ws.read_frame() catch |err| {
            if (err == error.ConnectionClosed or tachyon.is_eof_error(err)) return;
            return err;
        };

        switch (frame.opcode) {
            .close => return,
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

    const address = try std.Io.net.IpAddress.parse(bind_host, bind_port);
    var listener = try address.listen(io, .{
        .kernel_backlog = 1024,
        .reuse_address = true,
    });
    defer listener.deinit(io);

    var group: std.Io.Group = .init;
    defer group.cancel(io);

    std.debug.print("split echo server listening on ws://{s}:{d}/\n", .{ bind_host, bind_port });

    while (true) {
        const stream = listener.accept(io) catch |err| switch (err) {
            error.ConnectionAborted => continue,
            else => return err,
        };
        group.async(io, serveConnection, .{ io, init.gpa, stream });
    }
}
