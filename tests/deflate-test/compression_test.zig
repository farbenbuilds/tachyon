const std = @import("std");
const tachyon = @import("tachyon");

const Deflater = tachyon.Deflater;
const DeflaterStorage = tachyon.DeflaterStorage;
const Inflater = tachyon.Inflater;
const InflaterStorage = tachyon.InflaterStorage;
const Frame = tachyon.Frame;
const ReaderState = tachyon.stream.ReaderState;

fn codecCloseCode(err: tachyon.DeflateError) ?tachyon.zslay.StatusCode {
    return switch (err) {
        error.MessageTooLarge => tachyon.to_close_code(error.FrameTooLarge),
        error.InvalidCompressedData, error.CompressionFailed => tachyon.to_close_code(error.ProtocolError),
        else => null,
    };
}

test "Compression: compressed fragmented text roundtrips and validates after inflate" {
    const text = "The quick brown fox jumps over the lazy dog.";

    var deflater_storage: DeflaterStorage = undefined;
    var deflater = try Deflater.init(&deflater_storage, .{});
    var compressed: [2048]u8 = undefined;
    const compressed_slice = try deflater.compress(text, &compressed);

    var mutable: [2048]u8 = undefined;
    @memcpy(mutable[0..compressed_slice.len], compressed_slice);
    const split_at = compressed_slice.len / 2;

    var state = ReaderState.init();
    const first = try state.accept(Frame.init_rsv1(
        false,
        .text,
        true,
        null,
        mutable[0..split_at],
    ));
    try std.testing.expect(first.rsv1);
    try std.testing.expect(!first.fin);
    try std.testing.expect(state.is_compressed());

    const second = try state.accept(Frame.init_rsv1(
        true,
        .continuation,
        false,
        null,
        mutable[split_at..compressed_slice.len],
    ));
    try std.testing.expect(!second.rsv1);
    try std.testing.expect(second.fin);
    try std.testing.expect(!state.is_compressed());

    var wire: [2048]u8 = undefined;
    @memcpy(wire[0..first.payload.len], first.payload);
    @memcpy(wire[first.payload.len..][0..second.payload.len], second.payload);
    const wire_len = first.payload.len + second.payload.len;

    var inflater_storage: InflaterStorage = undefined;
    var inflater = try Inflater.init(&inflater_storage, .{});
    var plain: [256]u8 = undefined;
    const decompressed = try inflater.decompress(wire[0..wire_len], &plain);
    try tachyon.validate_utf8(decompressed);
    try std.testing.expectEqualStrings(text, decompressed);
}

test "Compression: decompressed output cap maps to 1009" {
    var input: [100]u8 = @splat('x');
    var deflater_storage: DeflaterStorage = undefined;
    var deflater = try Deflater.init(&deflater_storage, .{});
    var compressed: [2048]u8 = undefined;
    const compressed_slice = try deflater.compress(&input, &compressed);

    var inflater_storage: InflaterStorage = undefined;
    var inflater = try Inflater.init(&inflater_storage, .{});
    var output: [10]u8 = undefined;
    _ = inflater.decompress(compressed_slice, &output) catch |err| {
        try std.testing.expectEqual(
            @as(?tachyon.zslay.StatusCode, .message_too_big),
            codecCloseCode(err),
        );
        return;
    };
    return error.TestExpectedError;
}
