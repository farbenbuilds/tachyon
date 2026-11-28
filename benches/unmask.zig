//! Repeated XOR-mask benchmark.
//!
//! Allocates a 64 MiB payload, runs `tachyon.unmask` over it repeatedly, and
//! prints throughput in bytes/sec and GB/s. The buffer is allocated through the
//! process allocator; the codec itself performs no allocation.

const std = @import("std");
const tachyon = @import("tachyon");

const buffer_len: usize = 64 * 1024 * 1024;
const iterations: usize = 32;
const key: tachyon.MaskingKey = .{ 0x12, 0x34, 0x56, 0x78 };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const buffer = try init.gpa.alloc(u8, buffer_len);
    defer init.gpa.free(buffer);
    @memset(buffer, 0x5a);

    // Warm the code path and fault in the pages before timing.
    tachyon.unmask(buffer, key);

    const start = std.Io.Clock.Timestamp.now(io, .awake);
    var round: usize = 0;
    while (round < iterations) : (round += 1) {
        tachyon.unmask(buffer, key);
    }
    const end = std.Io.Clock.Timestamp.now(io, .awake);

    const elapsed_ns = start.durationTo(end).raw.toNanoseconds();
    const denominator: u64 = if (elapsed_ns <= 0) 1 else @intCast(elapsed_ns);
    const bytes: u64 = @as(u64, buffer_len) * iterations;
    const bytes_per_sec = bytes * std.time.ns_per_s / denominator;
    const gb_per_sec = @as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(denominator));

    std.debug.print("bytes/sec {d}\n", .{bytes_per_sec});
    std.debug.print("GB/s {d:.2}\n", .{gb_per_sec});
}
