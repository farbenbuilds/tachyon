const std = @import("std");
const tachyon = @import("tachyon");
const support = @import("../support.zig");

const Deflater = tachyon.Deflater;
const DeflaterStorage = tachyon.DeflaterStorage;
const Inflater = tachyon.Inflater;
const InflaterStorage = tachyon.InflaterStorage;
const max_compressed_len = tachyon.max_compressed_len;

const max_boundary_len: usize = 65_536;
const text_pattern = "The quick brown fox jumps over the lazy dog. ";

fn fillText(buf: []u8) void {
    for (buf, 0..) |*byte, index| {
        byte.* = text_pattern[index % text_pattern.len];
    }
}

fn expectRoundtrip(message: []const u8, wire: []u8, output: []u8) !void {
    var deflater_storage: DeflaterStorage = undefined;
    var deflater = try Deflater.init(&deflater_storage, .{});
    var inflater_storage: InflaterStorage = undefined;
    var inflater = try Inflater.init(&inflater_storage, .{});

    const compressed = try deflater.compress(message, wire);
    try std.testing.expect(compressed.len <= try max_compressed_len(message.len));

    const plain = try inflater.decompress(compressed, output);
    try std.testing.expectEqualSlices(u8, message, plain);
}

test "Deflate: roundtrips text at boundary lengths" {
    const allocator = std.testing.allocator;
    const wire_capacity = try max_compressed_len(max_boundary_len);

    const plain = try allocator.alloc(u8, max_boundary_len);
    defer allocator.free(plain);
    const wire = try allocator.alloc(u8, wire_capacity);
    defer allocator.free(wire);
    const output = try allocator.alloc(u8, max_boundary_len);
    defer allocator.free(output);

    const lengths = [_]usize{ 0, 1, 125, 126, 127, 65_535, 65_536 };
    for (lengths) |len| {
        fillText(plain[0..len]);
        try expectRoundtrip(plain[0..len], wire, output[0..len]);
    }
}

test "Deflate: roundtrips binary at boundary lengths" {
    const allocator = std.testing.allocator;
    const wire_capacity = try max_compressed_len(max_boundary_len);

    const plain = try allocator.alloc(u8, max_boundary_len);
    defer allocator.free(plain);
    const wire = try allocator.alloc(u8, wire_capacity);
    defer allocator.free(wire);
    const output = try allocator.alloc(u8, max_boundary_len);
    defer allocator.free(output);

    const lengths = [_]usize{ 0, 1, 125, 126, 127, 65_535, 65_536 };
    for (lengths) |len| {
        support.fill_deterministic(plain[0..len], @as(u64, len) +% 1);
        try expectRoundtrip(plain[0..len], wire, output[0..len]);
    }
}

test "Deflate: roundtrips incompressible data within the bound" {
    const allocator = std.testing.allocator;

    const plain = try allocator.alloc(u8, max_boundary_len);
    defer allocator.free(plain);
    const wire = try allocator.alloc(u8, try max_compressed_len(max_boundary_len));
    defer allocator.free(wire);
    const output = try allocator.alloc(u8, max_boundary_len);
    defer allocator.free(output);

    support.fill_deterministic(plain, 0x5eed_cafe_f00d_1234);
    try expectRoundtrip(plain, wire, output);
}

test "Deflate: roundtrips across multiple decoder windows" {
    const allocator = std.testing.allocator;
    const lengths = [_]usize{ 131_072, 1_048_576 };

    var deflater_storage: DeflaterStorage = undefined;
    var deflater = try Deflater.init(&deflater_storage, .{});
    var inflater_storage: InflaterStorage = undefined;
    var inflater = try Inflater.init(&inflater_storage, .{});

    for (lengths) |len| {
        const message = try allocator.alloc(u8, len);
        defer allocator.free(message);
        const wire = try allocator.alloc(u8, try max_compressed_len(len));
        defer allocator.free(wire);
        const output = try allocator.alloc(u8, len);
        defer allocator.free(output);

        // A repeating text pattern keeps Debug compression and decoding fast
        // while still forcing the decoder past its 64 KiB window buffer.
        fillText(message);

        // Start each message from a fresh sender context so the stream is
        // self-contained after the receiver resets below.
        try deflater.reset();
        const compressed = try deflater.compress(message, wire);

        try inflater.reset();
        try std.testing.expectEqualSlices(u8, message, try inflater.decompress(compressed, output));

        try inflater.reset();
        try std.testing.expectError(error.MessageTooLarge, inflater.decompress(compressed, output[0 .. len - 1]));

        try inflater.reset();
        try std.testing.expectEqualSlices(u8, message, try inflater.decompress(compressed, output));
    }
}

test "Deflate: empty message uses the canonical one-byte payload" {
    var deflater_storage: DeflaterStorage = undefined;
    var deflater = try Deflater.init(&deflater_storage, .{});
    var wire: [16]u8 = undefined;

    const compressed = try deflater.compress("", &wire);
    try std.testing.expectEqualSlices(u8, &.{0x00}, compressed);

    var inflater_storage: InflaterStorage = undefined;
    var inflater = try Inflater.init(&inflater_storage, .{});
    var output: [16]u8 = undefined;

    const plain = try inflater.decompress(compressed, &output);
    try std.testing.expectEqual(@as(usize, 0), plain.len);

    try inflater.reset();
    // A zero-length wire payload is also an empty message; the canonical sender
    // form remains the one-byte 0x00 payload above.
    try std.testing.expectEqual(@as(usize, 0), (try inflater.decompress(&.{}, &output)).len);
}

test "Deflate: context takeover carries history across three messages" {
    const allocator = std.testing.allocator;
    const message_len: usize = 32_768;

    const first = try allocator.alloc(u8, message_len);
    defer allocator.free(first);
    const second = try allocator.alloc(u8, message_len);
    defer allocator.free(second);
    const third = try allocator.alloc(u8, message_len + 4);
    defer allocator.free(third);
    const wire = try allocator.alloc(u8, try max_compressed_len(message_len + 4));
    defer allocator.free(wire);
    const output = try allocator.alloc(u8, message_len + 4);
    defer allocator.free(output);

    support.fill_deterministic(first, 0x1234_5678_9abc_def0);
    @memcpy(second, first);
    @memcpy(third[0..message_len], first);
    @memcpy(third[message_len..], "tail");

    var deflater_storage: DeflaterStorage = undefined;
    var deflater = try Deflater.init(&deflater_storage, .{});
    var inflater_storage: InflaterStorage = undefined;
    var inflater = try Inflater.init(&inflater_storage, .{});

    const first_wire = try deflater.compress(first, wire);
    try std.testing.expectEqualSlices(u8, first, try inflater.decompress(first_wire, output));

    const second_wire = try deflater.compress(second, wire);
    try std.testing.expect(second_wire.len < 1024);
    try std.testing.expectEqualSlices(u8, second, try inflater.decompress(second_wire, output));

    var fresh_storage: InflaterStorage = undefined;
    var fresh = try Inflater.init(&fresh_storage, .{});
    try std.testing.expectError(error.InvalidCompressedData, fresh.decompress(second_wire, output));

    const third_wire = try deflater.compress(third, wire);
    try std.testing.expectEqualSlices(u8, third, try inflater.decompress(third_wire, output));
}

test "Deflate: no context takeover produces independent repeatable messages" {
    const allocator = std.testing.allocator;
    const message_len: usize = 4096;

    const message = try allocator.alloc(u8, message_len);
    defer allocator.free(message);
    const wire_a = try allocator.alloc(u8, try max_compressed_len(message_len));
    defer allocator.free(wire_a);
    const wire_b = try allocator.alloc(u8, try max_compressed_len(message_len));
    defer allocator.free(wire_b);
    const wire_c = try allocator.alloc(u8, try max_compressed_len(message_len));
    defer allocator.free(wire_c);
    const output = try allocator.alloc(u8, message_len);
    defer allocator.free(output);

    support.fill_deterministic(message, 0xfeed_face_dead_beef);

    var deflater_storage: DeflaterStorage = undefined;
    var deflater = try Deflater.init(&deflater_storage, .{ .no_context_takeover = true });
    var inflater_storage: InflaterStorage = undefined;
    var inflater = try Inflater.init(&inflater_storage, .{ .no_context_takeover = true });

    const first = try deflater.compress(message, wire_a);
    const second = try deflater.compress(message, wire_b);
    try std.testing.expectEqualSlices(u8, first, second);

    try std.testing.expectEqualSlices(u8, message, try inflater.decompress(first, output));
    try std.testing.expectEqualSlices(u8, message, try inflater.decompress(second, output));

    try deflater.reset();
    const third = try deflater.compress(message, wire_c);
    try std.testing.expectEqualSlices(u8, first, third);
}

test "Deflate: reset discards sender and receiver history" {
    const allocator = std.testing.allocator;
    const message_len: usize = 8192;

    const message = try allocator.alloc(u8, message_len);
    defer allocator.free(message);
    const wire_first = try allocator.alloc(u8, try max_compressed_len(message_len));
    defer allocator.free(wire_first);
    const wire_second = try allocator.alloc(u8, try max_compressed_len(message_len));
    defer allocator.free(wire_second);
    const wire_fresh = try allocator.alloc(u8, try max_compressed_len(message_len));
    defer allocator.free(wire_fresh);
    const output = try allocator.alloc(u8, message_len);
    defer allocator.free(output);

    support.fill_deterministic(message, 0x0ddc_0ffe_e15e_beef);

    var deflater_storage: DeflaterStorage = undefined;
    var deflater = try Deflater.init(&deflater_storage, .{});
    var inflater_storage: InflaterStorage = undefined;
    var inflater = try Inflater.init(&inflater_storage, .{});

    const first = try deflater.compress(message, wire_first);
    try std.testing.expectEqualSlices(u8, message, try inflater.decompress(first, output));

    const second = try deflater.compress(message, wire_second);
    try std.testing.expect(second.len < 1024);
    try std.testing.expectEqualSlices(u8, message, try inflater.decompress(second, output));

    try inflater.reset();
    try std.testing.expectError(error.InvalidCompressedData, inflater.decompress(second, output));

    try deflater.reset();
    const fresh = try deflater.compress(message, wire_fresh);
    try std.testing.expectEqualSlices(u8, first, fresh);
}

test "Deflate: receiver reset discards history the latched message depends on" {
    const allocator = std.testing.allocator;
    const message_len: usize = 32_768;

    const message = try allocator.alloc(u8, message_len);
    defer allocator.free(message);
    const duplicate = try allocator.alloc(u8, message_len);
    defer allocator.free(duplicate);
    const wire = try allocator.alloc(u8, try max_compressed_len(message_len));
    defer allocator.free(wire);
    const output = try allocator.alloc(u8, message_len);
    defer allocator.free(output);

    support.fill_deterministic(message, 0x6a09_e667_f3bc_c908);
    @memcpy(duplicate, message);

    var deflater_storage: DeflaterStorage = undefined;
    var deflater = try Deflater.init(&deflater_storage, .{});
    var inflater_storage: InflaterStorage = undefined;
    var inflater = try Inflater.init(&inflater_storage, .{});

    const first_wire = try deflater.compress(message, wire);
    try std.testing.expectEqualSlices(u8, message, try inflater.decompress(first_wire, output));

    const second_wire = try deflater.compress(duplicate, wire);
    try std.testing.expect(second_wire.len < 1024);
    try std.testing.expectError(error.MessageTooLarge, inflater.decompress(second_wire, output[0 .. message_len - 1]));

    // The latch clears on reset, but reset also discards the history that the
    // context-dependent second message references. The session is unrecoverable.
    try inflater.reset();
    try std.testing.expectError(error.InvalidCompressedData, inflater.decompress(second_wire, output));
}

test "Deflate: short sender output does not latch and preserves context" {
    const allocator = std.testing.allocator;
    const message_len: usize = 4096;

    const message = try allocator.alloc(u8, message_len);
    defer allocator.free(message);
    const related = try allocator.alloc(u8, message_len + 4);
    defer allocator.free(related);
    const wire_first = try allocator.alloc(u8, try max_compressed_len(message_len + 4));
    defer allocator.free(wire_first);
    const wire_related = try allocator.alloc(u8, try max_compressed_len(message_len + 4));
    defer allocator.free(wire_related);
    const wire_fresh = try allocator.alloc(u8, try max_compressed_len(message_len + 4));
    defer allocator.free(wire_fresh);
    const output = try allocator.alloc(u8, message_len + 4);
    defer allocator.free(output);

    support.fill_deterministic(message, 0xbb67_ae85_84ca_a73b);
    @memcpy(related[0..message_len], message);
    @memcpy(related[message_len..], "tail");

    var deflater_storage: DeflaterStorage = undefined;
    var deflater = try Deflater.init(&deflater_storage, .{});
    var inflater_storage: InflaterStorage = undefined;
    var inflater = try Inflater.init(&inflater_storage, .{});
    var tiny: [16]u8 = undefined;

    try std.testing.expectError(error.OutputTooShort, deflater.compress(message, &tiny));

    const first = try deflater.compress(message, wire_first);
    const second = try deflater.compress(related, wire_related);

    // Both messages decode only if the short-buffer attempt left the sender
    // context intact for the context-dependent second message.
    try std.testing.expectEqualSlices(u8, message, try inflater.decompress(first, output));
    try std.testing.expectEqualSlices(u8, related, try inflater.decompress(second, output));

    try deflater.reset();
    const fresh = try deflater.compress(message, wire_fresh);
    try std.testing.expectEqualSlices(u8, first, fresh);
    try std.testing.expectError(error.OutputTooShort, deflater.compress(message, &tiny));
}

test "Deflate: rejects sender input and output aliasing storage" {
    var deflater_storage: DeflaterStorage = undefined;
    var deflater = try Deflater.init(&deflater_storage, .{});
    var buffer: [64]u8 = undefined;
    @memset(&buffer, 'x');
    var wire: [1024]u8 = undefined;

    try std.testing.expectError(error.AliasedBuffer, deflater.compress(&buffer, &buffer));

    const storage_input: []const u8 = std.mem.asBytes(&deflater_storage);
    try std.testing.expectError(error.AliasedBuffer, deflater.compress(storage_input, &wire));

    const storage_output: []u8 = std.mem.asBytes(&deflater_storage);
    try std.testing.expectError(error.AliasedBuffer, deflater.compress(&buffer, storage_output));
}

test "Deflate: validates window bits and bounds" {
    var deflater_storage: DeflaterStorage = undefined;
    try std.testing.expectError(error.UnsupportedWindowBits, Deflater.init(&deflater_storage, .{ .window_bits = 14 }));
    try std.testing.expectError(error.UnsupportedWindowBits, Deflater.init(&deflater_storage, .{ .window_bits = 8 }));
    try std.testing.expectError(error.UnsupportedWindowBits, Deflater.init(&deflater_storage, .{ .window_bits = 0 }));
    _ = try Deflater.init(&deflater_storage, .{ .window_bits = 15 });

    var inflater_storage: InflaterStorage = undefined;
    _ = try Inflater.init(&inflater_storage, .{ .window_bits = 8 });
    _ = try Inflater.init(&inflater_storage, .{ .window_bits = 15 });
    try std.testing.expectError(error.UnsupportedWindowBits, Inflater.init(&inflater_storage, .{ .window_bits = 7 }));
    try std.testing.expectError(error.UnsupportedWindowBits, Inflater.init(&inflater_storage, .{ .window_bits = 0 }));

    try std.testing.expectEqual(@as(usize, 1), try max_compressed_len(0));

    // This value fits `input + input / 4`, so only the second addition can
    // overflow.
    const overflow_len = (std.math.maxInt(usize) / 5) * 4;
    try std.testing.expectError(error.SizeOverflow, max_compressed_len(overflow_len));
    try std.testing.expectError(error.SizeOverflow, max_compressed_len(std.math.maxInt(usize)));
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x00, 0xff, 0xff }, &tachyon.sync_tail);
}
