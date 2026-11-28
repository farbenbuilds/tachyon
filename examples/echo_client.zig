//! Minimal WebSocket client for the echo server examples.
//!
//! Run the server first, then:
//!   zig build examples
//!   ./zig-out/bin/tachyon-echo-client
//!
//! The client connects to ws://127.0.0.1:8080/, sends one text frame, reads the
//! echoed frame, checks the bytes, and closes the connection.

const std = @import("std");
const tachyon = @import("tachyon");

const bind_host = "127.0.0.1";
const bind_port: u16 = 8080;
const max_message_size: usize = 64 * 1024;
const transport_buffer_len: usize = 16 * 1024;
const connection_write_len: usize = 16 * 1024;
const head_len: usize = 16 * 1024;
const tx_node_count: usize = 8;

const Buffers = struct {
    frame_buffer: [max_message_size]u8 = undefined,
    transport_read: [transport_buffer_len]u8 = undefined,
    transport_write: [transport_buffer_len]u8 = undefined,
    connection_write: [connection_write_len]u8 = undefined,
    close_buffer: [125]u8 = undefined,
    mask_scratch: [1024]u8 = undefined,
    head: [head_len]u8 = undefined,
    tx_nodes: [tx_node_count]tachyon.zslay.FrameNode = undefined,
};

fn connectionStorage(buffers: *Buffers) tachyon.ConnectionStorage {
    return .{
        .frame_buffer = &buffers.frame_buffer,
        .tx_nodes = &buffers.tx_nodes,
        .write_buffer = &buffers.connection_write,
        .close_buffer = &buffers.close_buffer,
        .mask_scratch = &buffers.mask_scratch,
    };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var payload: [18]u8 = undefined;
    @memcpy(&payload, "hello from tachyon");

    var buffers: Buffers = undefined;
    var seed: [tachyon.connection.mask_seed_len]u8 = undefined;
    try std.Io.randomSecure(io, &seed);

    const address = try std.Io.net.IpAddress.parse(bind_host, bind_port);
    var stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var transport = try tachyon.NativeTransport.init(io, stream, .{
        .read_buffer = &buffers.transport_read,
        .write_buffer = &buffers.transport_write,
    });

    var status: u16 = 0;
    _ = try tachyon.handshake.client(
        io,
        transport.reader(),
        transport.writer(),
        .{ .host = "127.0.0.1:8080" },
        &buffers.head,
        &status,
    );

    var ws = try tachyon.NativeWebSocket.init(&transport, connectionStorage(&buffers), .{
        .role = .client,
        .options = .{ .max_message_size = max_message_size },
        .mask_keys = tachyon.MaskKeySource.from_seed(seed),
    });

    try ws.write_frame(tachyon.Frame.text(&payload));
    try ws.flush();

    while (true) {
        const reply = try ws.read_frame();
        switch (reply.opcode) {
            .close => return error.ConnectionClosed,
            .text => {
                if (!std.mem.eql(u8, reply.payload, &payload)) return error.EchoMismatch;
                std.debug.print("echo received: {d} bytes\n", .{reply.payload.len});
                break;
            },
            else => {},
        }
    }

    var close_buffer: [125]u8 = undefined;
    const close = try tachyon.Frame.close(1000, "done", &close_buffer);
    try ws.write_frame(close);
    try ws.flush();
}
