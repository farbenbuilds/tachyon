const std = @import("std");
const zslay = @import("zslay");
const tachyon = @import("tachyon");

const frame = tachyon.frame;
const connection = tachyon.connection;
const split = tachyon.split;

pub const Frame = frame.Frame;
pub const MaskingKey = frame.MaskingKey;

/// Fills `bytes` with a deterministic pseudo-random sequence from `seed`.
pub fn fill_deterministic(bytes: []u8, seed: u64) void {
    var state = seed;
    for (bytes) |*byte| {
        state = state *% 6364136223846793005 +% 1442695040888963407;
        byte.* = @truncate(state >> 33);
    }
}

/// Test-only stream that always fails a read.
pub fn read_failed_stream(
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    limit: std.Io.Limit,
) std.Io.Reader.StreamError!usize {
    _ = reader;
    _ = writer;
    _ = limit;
    return error.ReadFailed;
}

/// Test-only wire encoder that concatenates encoded frames in a fixed buffer.
///
/// Each frame payload must be a separate caller-owned buffer, because
/// `Frame.write` copies the payload and rejects aliasing output.
pub fn EncodedStream(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = undefined,
        len: usize = 0,

        const Self = @This();

        pub fn append(self: *Self, f: Frame) !void {
            const encoded = try f.write(self.bytes[self.len..]);
            self.len += encoded.len;
        }

        pub fn reader(self: *const Self) std.Io.Reader {
            return std.Io.Reader.fixed(self.bytes[0..self.len]);
        }
    };
}

/// Copies the first `limit` bytes of `data` (with `splat` repetition) to `out`.
///
/// Drain implementations share this so their offsets stay in wire order and a
/// partial accept is never rewound.
fn copy_wire_bytes(
    out: []u8,
    written: *usize,
    data: []const []const u8,
    splat: usize,
    limit: usize,
) void {
    var remaining = limit;
    for (data[0 .. data.len - 1]) |bytes| {
        if (remaining == 0) return;
        const take = @min(remaining, bytes.len);
        @memcpy(out[written.*..][0..take], bytes[0..take]);
        written.* += take;
        remaining -= take;
    }

    const pattern = data[data.len - 1];
    var copies: usize = 0;
    while (copies < splat and remaining != 0) : (copies += 1) {
        const take = @min(remaining, pattern.len);
        @memcpy(out[written.*..][0..take], pattern[0..take]);
        written.* += take;
        remaining -= take;
    }
}

/// Test-only writer that records wire bytes, drain shape, and failure controls.
///
/// A zero-capacity internal buffer forces every write through `drain`, so
/// `max_iovecs` observes the actual caller slices instead of a copy into the
/// writer buffer. `fail_after` counts accepted bytes; a failed drain still
/// records the bytes it accepted before returning `error.WriteFailed`.
pub const RecordingVecWriter = struct {
    writer: std.Io.Writer,
    out: []u8,
    written: usize = 0,
    drain_calls: usize = 0,
    max_iovecs: usize = 0,
    fail_after: ?usize = null,

    pub fn init(out: []u8) RecordingVecWriter {
        return .{
            .writer = .{
                .vtable = &.{
                    .drain = drain,
                    .flush = std.Io.Writer.noopFlush,
                    .rebase = std.Io.Writer.failingRebase,
                },
                .buffer = &.{},
            },
            .out = out,
        };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *RecordingVecWriter = @alignCast(@fieldParentPtr("writer", w));
        std.debug.assert(w.end == 0);
        std.debug.assert(data.len > 0);
        self.drain_calls += 1;

        var nonempty: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            if (bytes.len != 0) nonempty += 1;
        }
        if (splat != 0 and data[data.len - 1].len != 0) nonempty += 1;
        self.max_iovecs = @max(self.max_iovecs, nonempty);

        const total = std.Io.Writer.countSplat(data, splat);
        var accept = total;
        var partial_failure = false;
        if (self.fail_after) |limit| {
            if (self.written >= limit) return error.WriteFailed;
            const room = limit - self.written;
            if (total > room) {
                accept = room;
                partial_failure = true;
            }
        }

        std.debug.assert(self.written + accept <= self.out.len);
        copy_wire_bytes(self.out, &self.written, data, splat, accept);

        if (partial_failure) return error.WriteFailed;
        return total;
    }
};

/// Test-only buffered writer that fails its flush on demand.
///
/// Small writes stay in `writer.buffer` until `flush`, which is the case the
/// connection's flush latch must cover.
pub const FlushFailWriter = struct {
    writer: std.Io.Writer,
    out: []u8,
    written: usize = 0,
    fail_flush: bool = true,
    flush_calls: usize = 0,

    pub fn init(out: []u8, buffer: []u8) FlushFailWriter {
        return .{
            .writer = .{
                .vtable = &.{
                    .drain = drain,
                    .flush = flush,
                    .rebase = std.Io.Writer.failingRebase,
                },
                .buffer = buffer,
            },
            .out = out,
        };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *FlushFailWriter = @alignCast(@fieldParentPtr("writer", w));
        const total = std.Io.Writer.countSplat(data, splat);

        std.debug.assert(self.written + total <= self.out.len);
        copy_wire_bytes(self.out, &self.written, data, splat, total);
        return total;
    }

    fn flush(w: *std.Io.Writer) std.Io.Writer.Error!void {
        const self: *FlushFailWriter = @alignCast(@fieldParentPtr("writer", w));
        self.flush_calls += 1;
        if (self.fail_flush) return error.WriteFailed;

        const buffered = w.buffer[0..w.end];
        std.debug.assert(self.written + buffered.len <= self.out.len);
        @memcpy(self.out[self.written..][0..buffered.len], buffered);
        self.written += buffered.len;
        w.end = 0;
    }
};

/// One decoded frame from a caller-owned wire buffer.
pub const WireFrame = struct {
    header: zslay.DecodedHeader,
    payload: []const u8,
    consumed: usize,
};

/// Parses the frame starting at `index` and advances past it.
pub fn next_wire_frame(bytes: []const u8, index: *usize) !WireFrame {
    const header = try zslay.decode_header(bytes[index.*..]);
    const payload_start = index.* + header.header_len;
    const payload_len = std.math.cast(usize, header.payload_len) orelse return error.UnexpectedEOF;
    if (payload_len > bytes.len - payload_start) return error.UnexpectedEOF;

    const consumed = header.header_len + payload_len;
    index.* += consumed;
    return .{
        .header = header,
        .payload = bytes[payload_start..][0..payload_len],
        .consumed = consumed,
    };
}

/// Caller-owned connection storage plus a recording writer.
pub fn ConnectionRig(
    comptime frame_capacity: usize,
    comptime node_count: usize,
    comptime write_capacity: usize,
    comptime close_capacity: usize,
    comptime scratch_capacity: usize,
    comptime out_capacity: usize,
) type {
    return struct {
        frame_buffer: [frame_capacity]u8 = undefined,
        tx_nodes: [node_count]zslay.FrameNode = undefined,
        write_buffer: [write_capacity]u8 = undefined,
        close_buffer: [close_capacity]u8 = undefined,
        mask_scratch: [scratch_capacity]u8 = undefined,
        out: [out_capacity]u8 = undefined,
        writer: RecordingVecWriter = undefined,
        ws: connection.WebSocket = undefined,

        const Self = @This();

        pub fn init(self: *Self, reader: *std.Io.Reader, config: connection.Config) !void {
            self.writer = RecordingVecWriter.init(&self.out);
            self.ws = try connection.WebSocket.init(reader, &self.writer.writer, .{
                .frame_buffer = &self.frame_buffer,
                .tx_nodes = &self.tx_nodes,
                .write_buffer = &self.write_buffer,
                .close_buffer = &self.close_buffer,
                .mask_scratch = &self.mask_scratch,
            }, config);
        }

        pub fn bytes(self: *const Self) []const u8 {
            return self.out[0..self.writer.written];
        }
    };
}

/// Masks `f` with `key` and appends the wire bytes to an `EncodedStream`.
pub fn append_masked(stream: anytype, f: Frame, key: MaskingKey) !void {
    var masked = f;
    masked.mask(key);
    try stream.append(masked);
}

/// Caller-owned split storage plus a recording writer.
///
/// Read and write halves use disjoint regions: a read reply borrows read
/// storage while the write half drains it, so sharing would alias queued
/// payload bytes during composition.
pub fn SplitRig(
    comptime frame_capacity: usize,
    comptime node_count: usize,
    comptime compose_capacity: usize,
    comptime close_capacity: usize,
    comptime scratch_capacity: usize,
    comptime out_capacity: usize,
) type {
    return struct {
        frame_buffer: [frame_capacity]u8 = undefined,
        message_buffer: [frame_capacity]u8 = undefined,
        tx_nodes: [node_count]zslay.FrameNode = undefined,
        read_compose_buffer: [compose_capacity]u8 = undefined,
        write_buffer: [compose_capacity]u8 = undefined,
        read_close_buffer: [close_capacity]u8 = undefined,
        write_close_buffer: [close_capacity]u8 = undefined,
        mask_scratch: [scratch_capacity]u8 = undefined,
        out: [out_capacity]u8 = undefined,
        writer: RecordingVecWriter = undefined,
        split: split.Split = undefined,

        const Self = @This();

        pub fn init(self: *Self, reader: *std.Io.Reader, config: split.Config) !void {
            self.writer = RecordingVecWriter.init(&self.out);
            self.split = try split.after_handshake_split(reader, &self.writer.writer, .{
                .read = .{
                    .frame_buffer = &self.frame_buffer,
                    .close_buffer = &self.read_close_buffer,
                    .compose_buffer = &self.read_compose_buffer,
                },
                .write = .{
                    .tx_nodes = &self.tx_nodes,
                    .write_buffer = &self.write_buffer,
                    .close_buffer = &self.write_close_buffer,
                    .mask_scratch = &self.mask_scratch,
                },
            }, config);
        }

        pub fn bytes(self: *const Self) []const u8 {
            return self.out[0..self.writer.written];
        }
    };
}

pub const handshake_sample_key = "dGhlIHNhbXBsZSBub25jZQ==";
pub const handshake_sample_accept = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=";
pub const handshake_valid_request =
    "GET /chat HTTP/1.1\r\n" ++
    "Host: server.example.com\r\n" ++
    "Upgrade: websocket\r\n" ++
    "Connection: Upgrade\r\n" ++
    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
    "Sec-WebSocket-Version: 13\r\n" ++
    "\r\n";
pub const handshake_valid_response =
    "HTTP/1.1 101 Switching Protocols\r\n" ++
    "Upgrade: websocket\r\n" ++
    "Connection: Upgrade\r\n" ++
    "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" ++
    "\r\n";

pub fn build_request_head(
    buffer: []u8,
    method: []const u8,
    connection_value: ?[]const u8,
    upgrade_value: ?[]const u8,
    key: ?[]const u8,
    version: ?[]const u8,
) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try writer.print("{s} /chat HTTP/1.1\r\nHost: server.example.com\r\n", .{method});
    if (connection_value) |value| try writer.print("Connection: {s}\r\n", .{value});
    if (upgrade_value) |value| try writer.print("Upgrade: {s}\r\n", .{value});
    if (key) |value| try writer.print("Sec-WebSocket-Key: {s}\r\n", .{value});
    if (version) |value| try writer.print("Sec-WebSocket-Version: {s}\r\n", .{value});
    try writer.writeAll("\r\n");
    return writer.buffered();
}

pub fn build_response_head(
    buffer: []u8,
    status: []const u8,
    upgrade_value: ?[]const u8,
    connection_value: ?[]const u8,
    accept: ?[]const u8,
) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try writer.print("{s}\r\n", .{status});
    if (upgrade_value) |value| try writer.print("Upgrade: {s}\r\n", .{value});
    if (connection_value) |value| try writer.print("Connection: {s}\r\n", .{value});
    if (accept) |value| try writer.print("Sec-WebSocket-Accept: {s}\r\n", .{value});
    try writer.writeAll("\r\n");
    return writer.buffered();
}
