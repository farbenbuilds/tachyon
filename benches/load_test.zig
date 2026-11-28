//! WebSocket load generator for the echo servers.
//!
//! Usage:
//!   tachyon-load-test <host> <port> <connections> <duration_seconds> <payload_bytes>
//!
//! Each worker opens one connection, completes the tachyon client handshake,
//! then sends and receives one binary message at a time. Per-second totals are
//! printed as `Msg/sec <n>`; the final line reports the average and errors.
//! Buffers are caller-owned and allocated per worker. Mask keys use a
//! deterministic seed so runs are reproducible.

const std = @import("std");
const tachyon = @import("tachyon");

const max_payload_len: usize = 1024 * 1024;
const transport_buffer_len: usize = 4096;
const connection_write_len: usize = 4096;
const head_len: usize = 8192;
const tx_node_count: usize = 4;
const min_frame_buffer_len: usize = 256;
const task_stack_len: usize = 256 * 1024;

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

const Worker = struct {
    id: usize,
    address: std.Io.net.IpAddress,
    host_header: []const u8,
    payload: []u8,
    stop: *std.atomic.Value(bool),
    messages: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    errors: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    transport_read: []u8,
    transport_write: []u8,
    frame_buffer: []u8,
    connection_write: []u8,
    head: []u8,
    close_buffer: [125]u8 = undefined,
    tx_nodes: [tx_node_count]tachyon.zslay.FrameNode = undefined,
    mask_seed: [tachyon.connection.mask_seed_len]u8 = undefined,

    fn init(
        gpa: std.mem.Allocator,
        id: usize,
        address: std.Io.net.IpAddress,
        host_header: []const u8,
        payload: []u8,
        stop: *std.atomic.Value(bool),
    ) !Worker {
        const transport_read = try gpa.alloc(u8, transport_buffer_len);
        errdefer gpa.free(transport_read);

        const transport_write = try gpa.alloc(u8, transport_buffer_len);
        errdefer gpa.free(transport_write);

        const frame_buffer = try gpa.alloc(u8, @max(payload.len + 1, min_frame_buffer_len));
        errdefer gpa.free(frame_buffer);

        const connection_write = try gpa.alloc(u8, connection_write_len);
        errdefer gpa.free(connection_write);

        const head = try gpa.alloc(u8, head_len);
        errdefer gpa.free(head);

        var worker: Worker = .{
            .id = id,
            .address = address,
            .host_header = host_header,
            .payload = payload,
            .stop = stop,
            .transport_read = transport_read,
            .transport_write = transport_write,
            .frame_buffer = frame_buffer,
            .connection_write = connection_write,
            .head = head,
        };
        @memset(&worker.mask_seed, @truncate(id +% 1));
        return worker;
    }

    fn deinit(self: *Worker, gpa: std.mem.Allocator) void {
        gpa.free(self.transport_read);
        gpa.free(self.transport_write);
        gpa.free(self.frame_buffer);
        gpa.free(self.connection_write);
        gpa.free(self.head);
    }

    fn connectionStorage(self: *Worker) tachyon.ConnectionStorage {
        return .{
            .frame_buffer = self.frame_buffer,
            .tx_nodes = &self.tx_nodes,
            .write_buffer = self.connection_write,
            .close_buffer = &self.close_buffer,
            .mask_scratch = &.{},
        };
    }

    fn run(worker: *Worker, io: std.Io) void {
        worker.runInner(io) catch |err| {
            _ = worker.errors.fetchAdd(1, .monotonic);
            if (err != error.ConnectionClosed and !tachyon.is_eof_error(err) and err != error.IoError) {
                std.log.debug("worker {d} ended: {s}", .{ worker.id, @errorName(err) });
            }
        };
    }

    fn runInner(worker: *Worker, io: std.Io) !void {
        var stream = try worker.address.connect(io, .{ .mode = .stream });
        defer stream.close(io);
        setNoDelay(stream);

        var transport = try tachyon.NativeTransport.init(io, stream, .{
            .read_buffer = worker.transport_read,
            .write_buffer = worker.transport_write,
        });

        var status: u16 = 0;
        _ = try tachyon.handshake.client(
            io,
            transport.reader(),
            transport.writer(),
            .{ .host = worker.host_header },
            worker.head,
            &status,
        );

        var ws = try tachyon.NativeWebSocket.init(&transport, worker.connectionStorage(), .{
            .role = .client,
            .options = .{ .max_message_size = @max(worker.payload.len + 1, min_frame_buffer_len) },
            .mask_keys = tachyon.MaskKeySource.from_seed(worker.mask_seed),
        });

        while (!worker.stop.load(.acquire)) {
            try ws.write_frame(tachyon.Frame.binary(worker.payload));
            try ws.flush();

            const frame = try ws.read_frame();
            switch (frame.opcode) {
                .text, .binary => _ = worker.messages.fetchAdd(1, .monotonic),
                .close => return,
                else => {},
            }
        }

        var close_buffer: [125]u8 = undefined;
        const close = tachyon.Frame.close(1000, "", &close_buffer) catch return;
        ws.write_frame(close) catch {};
        ws.flush() catch {};
    }
};

fn usage() error{InvalidArguments} {
    std.debug.print(
        "usage: tachyon-load-test <host> <port> <connections> <duration_seconds> <payload_bytes>\n",
        .{},
    );
    return error.InvalidArguments;
}

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();

    _ = args.next();
    const host = args.next() orelse return usage();
    const port_text = args.next() orelse return usage();
    const connections_text = args.next() orelse return usage();
    const duration_text = args.next() orelse return usage();
    const payload_text = args.next() orelse return usage();
    if (args.next() != null) return usage();

    const port = std.fmt.parseInt(u16, port_text, 10) catch return usage();
    const connections = std.fmt.parseInt(usize, connections_text, 10) catch return usage();
    const duration = std.fmt.parseInt(u64, duration_text, 10) catch return usage();
    const payload_len = std.fmt.parseInt(usize, payload_text, 10) catch return usage();

    if (connections == 0 or connections > 10_000) return usage();
    if (duration == 0 or duration > 3600) return usage();
    if (payload_len == 0 or payload_len > max_payload_len) return usage();

    const address = try std.Io.net.IpAddress.parse(host, port);
    const host_header = try std.fmt.allocPrint(init.gpa, "{s}:{d}", .{ host, port });
    defer init.gpa.free(host_header);

    const payload = try init.gpa.alloc(u8, payload_len);
    defer init.gpa.free(payload);
    @memset(payload, 'x');

    const workers = try init.gpa.alloc(Worker, connections);
    var initialized: usize = 0;
    defer {
        for (workers[0..initialized]) |*worker| worker.deinit(init.gpa);
        init.gpa.free(workers);
    }

    var stop = std.atomic.Value(bool).init(false);
    while (initialized < workers.len) : (initialized += 1) {
        workers[initialized] = try Worker.init(
            init.gpa,
            initialized,
            address,
            host_header,
            payload,
            &stop,
        );
    }

    var threaded: std.Io.Threaded = .init(init.gpa, .{
        .async_limit = .limited(@min(connections + 8, 10_000)),
        .stack_size = task_stack_len,
    });
    defer threaded.deinit();
    const io = threaded.io();

    const start = std.Io.Clock.Timestamp.now(io, .awake);
    var group: std.Io.Group = .init;
    for (workers) |*worker| group.async(io, Worker.run, .{ worker, io });

    var previous: u64 = 0;
    var elapsed: u64 = 0;
    while (elapsed < duration) : (elapsed += 1) {
        io.sleep(std.Io.Duration.fromSeconds(1), .awake) catch break;

        var total: u64 = 0;
        for (workers) |*worker| total += worker.messages.load(.monotonic);
        const delta = total - previous;
        previous = total;
        std.debug.print("Msg/sec {d}\n", .{delta});
    }

    stop.store(true, .release);
    // Give cooperative workers a short chance to finish, then cancel any
    // worker still blocked on a stalled handshake or read. `Group.cancel`
    // guarantees every task has run, including its deferred stream close.
    const grace: std.Io.Timeout = .{
        .duration = .{
            .raw = std.Io.Duration.fromMilliseconds(250),
            .clock = .awake,
        },
    };
    grace.sleep(io) catch {};
    group.cancel(io);

    const end = std.Io.Clock.Timestamp.now(io, .awake);
    const elapsed_ns = start.durationTo(end).raw.toNanoseconds();
    const denominator: u64 = if (elapsed_ns <= 0) 1 else @intCast(elapsed_ns);

    var total: u64 = 0;
    var errors: u64 = 0;
    for (workers) |*worker| {
        total += worker.messages.load(.monotonic);
        errors += worker.errors.load(.monotonic);
    }
    const rate_f = @as(f64, @floatFromInt(total)) /
        (@as(f64, @floatFromInt(denominator)) / 1_000_000_000.0);
    const rate: u64 = @intFromFloat(rate_f);
    std.debug.print("Final Msg/sec {d} (total {d}, errors {d})\n", .{ rate, total, errors });
}
