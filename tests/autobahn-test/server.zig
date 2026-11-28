//! Repository-only Autobahn echo fixture.
//!
//! This executable is the integration harness for the Autobahn workflow; it is
//! not imported by `tests/main.zig` and is not part of the aggregate test step.
//! The allocator is edge-only and backs the process-lifetime socket buffers.
//! Framing, masking, UTF-8 validation, close policy, and queue admission are
//! delegated to tachyon and zslay; the fixture only copies assembled message
//! bytes and drives the public upgrade, native transport, and stream APIs. A
//! green `.github/workflows/autobahn.yml` run on the configured case set is
//! evidence only for that case set, not a full Autobahn or compression
//! compliance claim.
//!
//! After a failure close, the fixture half-closes the send direction and drains
//! kernel receive bytes with a 64 MiB bound and a single absolute two-second
//! deadline before dropping the stream. A 16 MiB + 1 message fits the one-byte
//! frame-buffer headroom above the 16 MiB message buffer, so the whole message
//! is consumed before the fixture sends 1009. Larger frames are rejected at the
//! header; the bounded drain keeps their failure close observable up to the
//! budget and deadline, while larger inputs or peers that never close may still
//! end in a transport reset.

const std = @import("std");
const tachyon = @import("tachyon");

const bind_host = "127.0.0.1";
const bind_port: u16 = 9001;

// Exclusive fastwebsockets-style limit. 16 MiB + 2 accepts exactly 16 MiB + 1,
// one byte above the message buffer, so the fixture can consume the whole
// oversized frame before sending 1009. Larger inputs are rejected from the
// frame header and handled by the bounded failure drain below.
const max_message_size: usize = 16 * 1024 * 1024 + 2;

const frame_buffer_len: usize = 16 * 1024 * 1024 + 1;
const message_buffer_len: usize = 16 * 1024 * 1024;
const transport_read_len: usize = 64 * 1024;
const transport_write_len: usize = 64 * 1024;
const connection_write_len: usize = 64 * 1024;
const head_buffer_len: usize = 16 * 1024;
// `connection_close_buffer` is the connection's automatic 1002 storage. The
// fixture answers application-level 1002/1007/1009 failures through the
// separate `failure_close_buffer`, because `write_frame` rejects payloads that
// overlap any connection storage region.
const connection_close_len: usize = 125;
const failure_close_len: usize = 125;
const tx_node_count: usize = 4;

// Bound the post-failure drain so a peer that keeps sending cannot pin the
// sequential accept loop. Rejected payloads up to this budget are discarded.
const failure_drain_budget_len: usize = 64 * 1024 * 1024;
const failure_drain_chunk_len: usize = 16 * 1024;

comptime {
    std.debug.assert(frame_buffer_len == message_buffer_len + 1);
    std.debug.assert(max_message_size == frame_buffer_len + 1);
}

/// Process-lifetime storage owned by the fixture.
const Buffers = struct {
    frame_buffer: []u8,
    message_buffer: []u8,
    transport_read: []u8,
    transport_write: []u8,
    connection_write: []u8,
    head: []u8,
    connection_close_buffer: []u8,
    failure_close_buffer: []u8,
    tx_nodes: [tx_node_count]tachyon.zslay.FrameNode = undefined,

    fn init(allocator: std.mem.Allocator, buffers: *Buffers) !void {
        const frame_buffer = try allocator.alloc(u8, frame_buffer_len);
        errdefer allocator.free(frame_buffer);
        const message_buffer = try allocator.alloc(u8, message_buffer_len);
        errdefer allocator.free(message_buffer);
        const transport_read = try allocator.alloc(u8, transport_read_len);
        errdefer allocator.free(transport_read);
        const transport_write = try allocator.alloc(u8, transport_write_len);
        errdefer allocator.free(transport_write);
        const connection_write = try allocator.alloc(u8, connection_write_len);
        errdefer allocator.free(connection_write);
        const head = try allocator.alloc(u8, head_buffer_len);
        errdefer allocator.free(head);
        const connection_close_buffer = try allocator.alloc(u8, connection_close_len);
        errdefer allocator.free(connection_close_buffer);
        const failure_close_buffer = try allocator.alloc(u8, failure_close_len);
        errdefer allocator.free(failure_close_buffer);

        buffers.* = .{
            .frame_buffer = frame_buffer,
            .message_buffer = message_buffer,
            .transport_read = transport_read,
            .transport_write = transport_write,
            .connection_write = connection_write,
            .head = head,
            .connection_close_buffer = connection_close_buffer,
            .failure_close_buffer = failure_close_buffer,
        };
    }

    fn deinit(self: *Buffers, allocator: std.mem.Allocator) void {
        allocator.free(self.frame_buffer);
        allocator.free(self.message_buffer);
        allocator.free(self.transport_read);
        allocator.free(self.transport_write);
        allocator.free(self.connection_write);
        allocator.free(self.head);
        allocator.free(self.connection_close_buffer);
        allocator.free(self.failure_close_buffer);
    }

    fn connection_storage(self: *Buffers) tachyon.ConnectionStorage {
        return .{
            .frame_buffer = self.frame_buffer,
            .tx_nodes = &self.tx_nodes,
            .write_buffer = self.connection_write,
            .close_buffer = self.connection_close_buffer,
            .mask_scratch = &.{},
        };
    }

    /// Rejects aliasing regions before any socket is bound.
    ///
    /// `NativeTransport.init` and `NativeWebSocket.init` keep their own overlap
    /// checks; this pass covers the fixture-owned regions that those layers
    /// cannot see together.
    fn validate_disjoint(self: *Buffers) error{InvalidLength}!void {
        const storage = self.connection_storage();
        if (storage.overlaps(self.message_buffer)) return error.InvalidLength;
        if (storage.overlaps(self.failure_close_buffer)) return error.InvalidLength;
        if (storage.overlaps(self.head)) return error.InvalidLength;

        if (regions_overlap(self.message_buffer, self.frame_buffer)) return error.InvalidLength;
        if (regions_overlap(self.message_buffer, self.transport_read)) return error.InvalidLength;
        if (regions_overlap(self.message_buffer, self.transport_write)) return error.InvalidLength;
        if (regions_overlap(self.message_buffer, self.head)) return error.InvalidLength;
        if (regions_overlap(self.message_buffer, self.failure_close_buffer)) return error.InvalidLength;

        if (regions_overlap(self.failure_close_buffer, self.transport_read)) return error.InvalidLength;
        if (regions_overlap(self.failure_close_buffer, self.transport_write)) return error.InvalidLength;
        if (regions_overlap(self.failure_close_buffer, self.frame_buffer)) return error.InvalidLength;
        if (regions_overlap(self.failure_close_buffer, self.head)) return error.InvalidLength;

        if (regions_overlap(self.head, self.transport_read)) return error.InvalidLength;
        if (regions_overlap(self.head, self.transport_write)) return error.InvalidLength;
    }
};

/// Reports whether two caller-owned regions overlap.
///
/// This is a local buffer-lifetime check, not protocol logic.
fn regions_overlap(left: []const u8, right: []const u8) bool {
    return tachyon.zslay.event.ranges_overlap(
        @intFromPtr(left.ptr),
        left.len,
        @intFromPtr(right.ptr),
        right.len,
    );
}

/// Best-effort application close after a wire failure.
///
/// The connection already echoed a valid close or answered an invalid close
/// code, so `is_closed` suppresses duplicates. Returns true when a close was
/// flushed and the caller should drain the rejected inbound bytes.
fn send_failure_close(
    ws: *tachyon.WebSocket,
    failure_close_buffer: []u8,
    err: tachyon.WebSocketError,
) bool {
    if (ws.is_closed()) return false;
    const status = tachyon.errors.to_close_code(err) orelse return false;
    const frame = tachyon.Frame.close(tachyon.close_code_to_u16(status), &.{}, failure_close_buffer) catch return false;
    ws.write_frame(frame) catch return false;
    ws.flush() catch return false;
    return true;
}

/// Discards kernel receive bytes after a failure close so the close is not lost
/// to a TCP reset.
///
/// The connection rejects a frame before consuming the offending payload.
/// Half-closing the send direction lets the peer observe the close and finish;
/// the direct socket read loop then discards the unread payload without
/// spinning. The whole drain has a single absolute two-second deadline, so a
/// half-open or trickling peer cannot pin the sequential accept loop, plus a
/// 64 MiB byte budget. A 16 MiB + 1 message is consumed through the frame-buffer
/// headroom, so its 1009 close is not raced by unread payload; the drain still
/// consumes the peer's close response. Larger rejected frames fit the budget so
/// their close remains deliverable. Inputs above the budget may still reset the
/// transport.
fn drain_after_failure(io: std.Io, stream: std.Io.net.Stream) void {
    stream.shutdown(io, .send) catch {};

    const deadline = std.Io.Clock.Timestamp.fromNow(io, .{
        .raw = std.Io.Duration.fromMilliseconds(2000),
        .clock = .awake,
    });
    const timeout: std.Io.Timeout = .{ .deadline = deadline };

    var scratch: [failure_drain_chunk_len]u8 = undefined;
    var remaining = failure_drain_budget_len;
    while (remaining != 0) {
        var data: [1][]u8 = .{scratch[0..@min(scratch.len, remaining)]};
        const operation = std.Io.operateTimeout(io, .{ .net_read = .{
            .socket_handle = stream.socket.handle,
            .data = &data,
        } }, timeout) catch return;
        const read = operation.net_read catch return;
        if (read.data_len == 0) return;
        remaining -= read.data_len;
    }
}

/// Writes one assembled message as a single FIN frame.
///
/// A `WouldBlock` or `QueueFull` leaves the writer state unchanged, so the same
/// payload is retried once after `flush`.
fn write_message(writer: *tachyon.MessageWriter, payload: []u8) tachyon.WebSocketError!void {
    writer.write(payload, true) catch |err| switch (err) {
        error.WouldBlock, error.QueueFull => {
            try writer.flush();
            try writer.write(payload, true);
        },
        else => return err,
    };
    try writer.flush();
}

/// Assembles one message, then echoes it as one FIN frame with its kind.
///
/// Returns true when a failure close was flushed and the caller must drain the
/// rejected inbound bytes before closing the stream.
fn echo(ws: *tachyon.WebSocket, buffers: *Buffers) bool {
    var reader = tachyon.MessageReader.init(ws);
    var message_len: usize = 0;

    // Each iteration consumes one frame; a delivered close or a read error is
    // terminal, so the loop is bounded by the peer.
    while (true) {
        const event = reader.next() catch |err| {
            return send_failure_close(ws, buffers.failure_close_buffer, err);
        };
        switch (event) {
            // Pings are auto-ponged by the connection; unsolicited pongs are
            // not echoed.
            .control => {},
            // A validated close is already echoed and flushed by the connection.
            .close => return false,
            .chunk => |chunk| {
                std.debug.assert(message_len <= buffers.message_buffer.len);
                if (chunk.payload.len > buffers.message_buffer.len - message_len) {
                    return send_failure_close(ws, buffers.failure_close_buffer, error.FrameTooLarge);
                }
                @memcpy(buffers.message_buffer[message_len..][0..chunk.payload.len], chunk.payload);
                message_len += chunk.payload.len;
                if (!chunk.fin) continue;

                var writer = tachyon.MessageWriter.init(ws, chunk.kind);
                write_message(&writer, buffers.message_buffer[0..message_len]) catch |err| {
                    return send_failure_close(ws, buffers.failure_close_buffer, err);
                };
                message_len = 0;
            },
        }
    }
    unreachable;
}

fn handle(io: std.Io, stream: std.Io.net.Stream, buffers: *Buffers) tachyon.WebSocketError!void {
    var transport = try tachyon.NativeTransport.init(io, stream, .{
        .read_buffer = buffers.transport_read,
        .write_buffer = buffers.transport_write,
    });

    const incoming = try tachyon.upgrade.incoming(transport.reader(), buffers.head);

    // Construct the connection before the 101 so storage and alias validation
    // still happen before any response byte, mirroring the split upgrade order.
    var ws = try tachyon.NativeWebSocket.init(&transport, buffers.connection_storage(), .{
        .role = .server,
        .options = .{
            .auto_apply_mask = true,
            .auto_close = true,
            .auto_pong = true,
            .writev = true,
            .writev_threshold = 1024,
            .max_message_size = max_message_size,
            .backpressure = null,
        },
    });

    try tachyon.handshake.write_response(transport.writer(), incoming.request.key);
    transport.writer().flush() catch |err| return tachyon.from_writer(err);

    const failure_close_sent = echo(&ws.inner, buffers);
    if (failure_close_sent) drain_after_failure(io, stream);
}

/// True for readiness probes and peers that disconnect before a frame.
fn is_normal_disconnect(err: tachyon.WebSocketError) bool {
    return switch (err) {
        error.UnexpectedEOF, error.UnexpectedEof, error.ConnectionClosed => true,
        else => false,
    };
}

pub fn main() !void {
    var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var buffers: Buffers = undefined;
    try Buffers.init(std.heap.smp_allocator, &buffers);
    defer buffers.deinit(std.heap.smp_allocator);

    try buffers.validate_disjoint();

    const address = try std.Io.net.IpAddress.parse(bind_host, bind_port);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    std.log.scoped(.autobahn).info("listening on {s}:{d}", .{ bind_host, bind_port });

    // The accept loop is the process lifetime; the workflow kills the server
    // after the suite, and each connection is handled sequentially on the
    // calling thread.
    while (true) {
        const stream = server.accept(io) catch |err| switch (err) {
            error.ConnectionAborted => continue,
            else => return err,
        };
        handle(io, stream, &buffers) catch |err| {
            if (!is_normal_disconnect(err)) {
                std.log.scoped(.autobahn).err("connection failed: {s}", .{tachyon.description(err)});
            }
        };
        stream.close(io);
    }
}
