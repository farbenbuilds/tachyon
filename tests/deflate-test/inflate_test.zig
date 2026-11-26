const std = @import("std");
const tachyon = @import("tachyon");
const support = @import("../support.zig");

const Deflater = tachyon.Deflater;
const DeflaterStorage = tachyon.DeflaterStorage;
const Inflater = tachyon.Inflater;
const InflaterStorage = tachyon.InflaterStorage;
const max_compressed_len = tachyon.max_compressed_len;

test "Deflate: exactly-full output succeeds and one byte short fails" {
    const message = "exactly full output";
    var sender_storage: DeflaterStorage = undefined;
    var sender = try Deflater.init(&sender_storage, .{});
    var wire: [2048]u8 = undefined;
    const compressed = try sender.compress(message, &wire);

    var receiver_storage: InflaterStorage = undefined;
    var receiver = try Inflater.init(&receiver_storage, .{});
    var output: [2048]u8 = undefined;

    try std.testing.expectEqualSlices(u8, message, try receiver.decompress(compressed, output[0..message.len]));

    try receiver.reset();
    try std.testing.expectError(
        error.MessageTooLarge,
        receiver.decompress(compressed, output[0 .. message.len - 1]),
    );
    try std.testing.expectError(
        error.MessageTooLarge,
        receiver.decompress(compressed, output[0..message.len]),
    );

    try receiver.reset();
    try std.testing.expectEqualSlices(u8, message, try receiver.decompress(compressed, output[0..message.len]));
}

test "Deflate: caps a decompression bomb at 64 KiB and latches" {
    const allocator = std.testing.allocator;
    const plain_len = 1024 * 1024;
    const output_len = 64 * 1024;

    const plain = try allocator.alloc(u8, plain_len);
    defer allocator.free(plain);
    const wire = try allocator.alloc(u8, try max_compressed_len(plain_len));
    defer allocator.free(wire);
    const output = try allocator.alloc(u8, output_len);
    defer allocator.free(output);

    @memset(plain, 'A');

    var sender_storage: DeflaterStorage = undefined;
    var sender = try Deflater.init(&sender_storage, .{});
    const compressed = try sender.compress(plain, wire);
    try std.testing.expect(compressed.len < output_len);

    var receiver_storage: InflaterStorage = undefined;
    var receiver = try Inflater.init(&receiver_storage, .{});
    try std.testing.expectError(error.MessageTooLarge, receiver.decompress(compressed, output));
    try std.testing.expectError(error.MessageTooLarge, receiver.decompress(compressed, output));

    try receiver.reset();
    const empty = try receiver.decompress(&.{0x00}, output[0..0]);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "Deflate: rejects structurally invalid streams without panic" {
    // Malformed input that leaves a non-clean block boundary fails closed.
    // DEFLATE has no checksum, so some truncated or corrupted streams still
    // decode to a shorter or wrong message; output is always untrusted. The
    // adapter-boundary and Hello-truncation tests below cover those decodes.
    const malformed = [_][]const u8{
        &.{0x06}, // reserved block type
        &.{ 0x01, 0x00, 0x00, 0xff, 0xff }, // final stored block: BFINAL is prohibited by RFC 7692
        &.{ 0x00, 0x05, 0x00, 0x00, 0x00 }, // stored block with bad NLEN
        &.{ 0x00, 0x05, 0x00, 0xfa, 0xff }, // truncated stored block payload
        &.{0x04}, // truncated dynamic block header
        &.{ 0xff, 0xff, 0xff, 0xff }, // garbage
    };

    var receiver_storage: InflaterStorage = undefined;
    var receiver = try Inflater.init(&receiver_storage, .{});
    var output: [1024]u8 = undefined;

    for (malformed) |input| {
        try receiver.reset();
        try std.testing.expectError(error.InvalidCompressedData, receiver.decompress(input, &output));
        try std.testing.expectError(error.InvalidCompressedData, receiver.decompress(input, &output));
    }

    try receiver.reset();
    const empty = try receiver.decompress(&.{0x00}, &output);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "Deflate: rejects the RFC 7692 Hello vector cut to six bytes" {
    const truncated = [_]u8{ 0xf2, 0x48, 0xcd, 0xc9, 0xc9, 0x07 };
    var receiver_storage: InflaterStorage = undefined;
    var receiver = try Inflater.init(&receiver_storage, .{});
    var output: [16]u8 = undefined;

    // The payload reaches a block boundary with an unconsumed byte still in the
    // reader, so the compressed stream did not end where the block stream did.
    // This is a structural check, not an integrity check.
    try std.testing.expectError(error.InvalidCompressedData, receiver.decompress(&truncated, &output));
}

test "Deflate: rejects a sender payload missing its final byte" {
    const message = "sender payload missing its final byte";
    var sender_storage: DeflaterStorage = undefined;
    var sender = try Deflater.init(&sender_storage, .{});
    var wire: [2048]u8 = undefined;
    const compressed = try sender.compress(message, &wire);

    var receiver_storage: InflaterStorage = undefined;
    var receiver = try Inflater.init(&receiver_storage, .{});
    var output: [2048]u8 = undefined;

    // A fresh inflater must reject the payload because the final sender byte is
    // missing, leaving the decoder at a boundary with unconsumed input.
    try std.testing.expectError(
        error.InvalidCompressedData,
        receiver.decompress(compressed[0 .. compressed.len - 1], &output),
    );
}

test "Deflate: rejects a BFINAL stream with InvalidCompressedData" {
    const allocator = std.testing.allocator;
    const message_len = 64 * 1024;

    const message = try allocator.alloc(u8, message_len);
    defer allocator.free(message);
    @memset(message, 'A');
    const wire = try allocator.alloc(u8, try max_compressed_len(message_len));
    defer allocator.free(wire);
    const output = try allocator.alloc(u8, message_len);
    defer allocator.free(output);

    // Produce a stream that ends with BFINAL=1 instead of the RFC 7692 sync
    // flush. RFC 7692 forbids BFINAL because end-of-message travels out of band.
    var wire_writer = std.Io.Writer.fixed(wire);
    var history: [std.compress.flate.max_window_len]u8 = undefined;
    var compressor = try std.compress.flate.Compress.init(&wire_writer, &history, .raw, .default);
    try compressor.writer.writeAll(message);
    try compressor.finish();
    const final_wire = wire_writer.buffered();

    var receiver_storage: InflaterStorage = undefined;
    var receiver = try Inflater.init(&receiver_storage, .{});

    // A BFINAL block that overflows reports InvalidCompressedData ahead of
    // MessageTooLarge because RFC 7692 rejects the stream regardless of size.
    try std.testing.expectError(
        error.InvalidCompressedData,
        receiver.decompress(final_wire, output[0 .. message_len - 1]),
    );

    try receiver.reset();
    try std.testing.expectError(error.InvalidCompressedData, receiver.decompress(final_wire, output));
}

test "Deflate: a non-final block overflow reports MessageTooLarge before a later BFINAL" {
    const allocator = std.testing.allocator;
    const first_len = 128 * 1024;
    const second_len = 64;

    const first = try allocator.alloc(u8, first_len);
    defer allocator.free(first);
    @memset(first, 'A');
    const second = try allocator.alloc(u8, second_len);
    defer allocator.free(second);
    @memset(second, 'B');
    const wire = try allocator.alloc(u8, try max_compressed_len(first_len + second_len));
    defer allocator.free(wire);
    const output = try allocator.alloc(u8, 1024);
    defer allocator.free(output);

    // The first flush leaves a non-final block that expands past the 64 KiB
    // decoder window. The output bound overflows before the decoder can read
    // the later BFINAL block header, so the precedence is MessageTooLarge.
    var wire_writer = std.Io.Writer.fixed(wire);
    var history: [std.compress.flate.max_window_len]u8 = undefined;
    var compressor = try std.compress.flate.Compress.init(&wire_writer, &history, .raw, .default);
    try compressor.writer.writeAll(first);
    try compressor.writer.flush();
    try compressor.writer.writeAll(second);
    try compressor.finish();
    const final_wire = wire_writer.buffered();

    var receiver_storage: InflaterStorage = undefined;
    var receiver = try Inflater.init(&receiver_storage, .{});
    try std.testing.expectError(error.MessageTooLarge, receiver.decompress(final_wire, output));
}

test "Deflate: rejects receiver input and output aliasing storage" {
    var inflater_storage: InflaterStorage = undefined;
    var inflater = try Inflater.init(&inflater_storage, .{});
    var buffer: [64]u8 = undefined;
    @memset(&buffer, 0xf2);
    var output: [1024]u8 = undefined;

    try std.testing.expectError(error.AliasedBuffer, inflater.decompress(&buffer, &buffer));

    const storage_input: []const u8 = std.mem.asBytes(&inflater_storage);
    try std.testing.expectError(error.AliasedBuffer, inflater.decompress(storage_input, &output));

    const storage_output: []u8 = std.mem.asBytes(&inflater_storage);
    try std.testing.expectError(error.AliasedBuffer, inflater.decompress(&buffer, storage_output));

    // Empty input never aliases and still decodes as an empty message.
    try std.testing.expectEqual(@as(usize, 0), (try inflater.decompress(&.{}, &output)).len);
}

test "Deflate: a latched failure takes precedence over alias detection" {
    var inflater_storage: InflaterStorage = undefined;
    var inflater = try Inflater.init(&inflater_storage, .{});
    var output: [1024]u8 = undefined;

    // A reserved block type latches a fatal failure before any output.
    try std.testing.expectError(error.InvalidCompressedData, inflater.decompress(&.{0x06}, &output));

    var aliased: [64]u8 = undefined;
    @memset(&aliased, 0x06);
    try std.testing.expectError(error.InvalidCompressedData, inflater.decompress(&aliased, &aliased));

    try inflater.reset();
    try std.testing.expectError(error.AliasedBuffer, inflater.decompress(&aliased, &aliased));
}

test "Deflate: adapter boundaries reject or bound truncated decodes" {
    const allocator = std.testing.allocator;
    const message_len = 8192;

    const message = try allocator.alloc(u8, message_len);
    defer allocator.free(message);
    const wire = try allocator.alloc(u8, try max_compressed_len(message_len));
    defer allocator.free(wire);
    const output = try allocator.alloc(u8, message_len);
    defer allocator.free(output);

    support.fill_deterministic(message, 0xabcd_ef01_2345_6789);

    var sender_storage: DeflaterStorage = undefined;
    var sender = try Deflater.init(&sender_storage, .{});
    const compressed = try sender.compress(message, wire);
    try std.testing.expect(compressed.len > 65);

    var receiver_storage: InflaterStorage = undefined;
    var receiver = try Inflater.init(&receiver_storage, .{});
    const boundaries = [_]usize{ 0, 1, 2, 3, 4, 15, 16, 17, 31, 32, 33, 63, 64, 65, compressed.len - 1 };

    for (boundaries) |len| {
        try receiver.reset();
        const result = receiver.decompress(compressed[0..len], output);
        if (result) |plain| {
            // A successful decode is not evidence of integrity: DEFLATE has no
            // checksum, so the output may be shorter than or different from the
            // original message. Only the caller-provided output bound holds.
            try std.testing.expect(plain.len <= message.len);
        } else |err| {
            try std.testing.expect(err == error.InvalidCompressedData or err == error.MessageTooLarge);
        }
    }

    try receiver.reset();
    try std.testing.expectEqualSlices(u8, message, try receiver.decompress(compressed, output));
}

test "Deflate: decodes the RFC 7692 Hello vector at both window bounds" {
    const wire = [_]u8{ 0xf2, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00 };
    var output: [16]u8 = undefined;

    var small_storage: InflaterStorage = undefined;
    var small = try Inflater.init(&small_storage, .{ .window_bits = 8 });
    try std.testing.expectEqualStrings("Hello", try small.decompress(&wire, &output));

    var full_storage: InflaterStorage = undefined;
    var full = try Inflater.init(&full_storage, .{ .window_bits = 15 });
    try std.testing.expectEqualStrings("Hello", try full.decompress(&wire, &output));
}

test "Deflate: one-byte Hello truncation decodes to wrong untrusted output" {
    var receiver_storage: InflaterStorage = undefined;
    var receiver = try Inflater.init(&receiver_storage, .{});
    var output: [16]u8 = undefined;

    // DEFLATE has no integrity check. The RFC 7692 tail completes this one-byte
    // truncated compressed stream as something structurally valid, so it decodes
    // to "H". That output is wrong and untrusted, not a recovered message.
    const plain = try receiver.decompress(&.{0xf2}, &output);
    try std.testing.expectEqualStrings("H", plain);
}
