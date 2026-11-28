const std = @import("std");
const tachyon = @import("tachyon");

const support = @import("../support.zig");

const connection = tachyon.connection;
const split = tachyon.split;
const Frame = tachyon.Frame;
const WebSocketError = tachyon.WebSocketError;
const EncodedStream = support.EncodedStream;
const next_wire_frame = support.next_wire_frame;
const append_masked = support.append_masked;
const SplitRig = support.SplitRig;

test "Split: truncated header and payload latch UnexpectedEOF until reset" {
    {
        var wire = [_]u8{0x81};
        var reader = std.Io.Reader.fixed(&wire);
        var parts: SplitRig(16, 1, 32, 8, 0, 8) = .{};
        try parts.init(&reader, .{ .role = .server });

        try std.testing.expectError(error.UnexpectedEOF, parts.split.read_frame());
        try std.testing.expectEqual(@as(usize, 1), reader.seek);
        try std.testing.expect(!parts.split.is_at_wire_boundary());
        try std.testing.expectError(error.UnexpectedEOF, parts.split.read_frame());
        try std.testing.expectEqual(@as(usize, 1), reader.seek);

        parts.split.reset();
        try std.testing.expect(parts.split.is_at_wire_boundary());

        // The truncated transport is discarded; the caller positions the
        // reader at a fresh frame boundary after reset.
        var fresh: EncodedStream(16) = .{};
        var payload = [_]u8{ 'o', 'k' };
        try append_masked(&fresh, Frame.text(&payload), .{ 0x0a, 0x0b, 0x0c, 0x0d });
        reader = fresh.reader();

        const received = try parts.split.read_frame();
        try std.testing.expectEqualStrings("ok", received.payload);
    }

    {
        // Masked header with a three-byte payload, but only two bytes follow.
        var wire = [_]u8{ 0x81, 0x83, 0x01, 0x02, 0x03, 0x04, 'a', 'b' };
        var reader = std.Io.Reader.fixed(&wire);
        var parts: SplitRig(16, 1, 32, 8, 0, 8) = .{};
        try parts.init(&reader, .{ .role = .server });

        try std.testing.expectError(error.UnexpectedEOF, parts.split.read_frame());
        try std.testing.expectEqual(@as(usize, 8), reader.seek);
        try std.testing.expect(!parts.split.is_at_wire_boundary());
        try std.testing.expectError(error.UnexpectedEOF, parts.split.read_frame());
        try std.testing.expectEqual(@as(usize, 8), reader.seek);

        parts.split.reset();
        try std.testing.expect(parts.split.is_at_wire_boundary());

        var fresh: EncodedStream(16) = .{};
        var payload = [_]u8{ 'o', 'k' };
        try append_masked(&fresh, Frame.text(&payload), .{ 0x1a, 0x2b, 0x3c, 0x4d });
        reader = fresh.reader();

        const received = try parts.split.read_frame();
        try std.testing.expectEqualStrings("ok", received.payload);
    }
}

test "Split: ping-only after a close write returns ConnectionClosed without pong or extra read" {
    var stream: EncodedStream(32) = .{};
    var first_ping = [_]u8{'?'};
    var second_ping = [_]u8{'!'};
    try append_masked(&stream, Frame.ping(&first_ping), .{ 0x10, 0x20, 0x30, 0x40 });
    try append_masked(&stream, Frame.ping(&second_ping), .{ 0x50, 0x60, 0x70, 0x80 });

    var reader = stream.reader();
    var parts: SplitRig(32, 2, 32, 8, 0, 32) = .{};
    try parts.init(&reader, .{ .role = .server });

    var close_storage: [2]u8 = undefined;
    try parts.split.write.write_frame(try Frame.close(1000, "", &close_storage));
    const output_after_close = parts.writer.written;

    try std.testing.expectError(error.ConnectionClosed, parts.split.read_frame());
    try std.testing.expectEqual(output_after_close, parts.writer.written);
    try std.testing.expectEqual(@as(usize, 7), reader.seek);
    try std.testing.expectEqual(@as(usize, 7), reader.buffered().len);

    var index: usize = 0;
    const close = try next_wire_frame(parts.bytes(), &index);
    try std.testing.expectEqual(split.OpCode.close, split.OpCode.from_wire(close.header.header.opcode).?);
    try std.testing.expectEqual(parts.writer.written, index);
}

test "Split: automatic obligations remain RSV1-free" {
    var stream: EncodedStream(32) = .{};
    var ping_payload = [_]u8{'p'};
    var text_payload = [_]u8{ 'o', 'k' };
    try append_masked(&stream, Frame.ping(&ping_payload), .{ 0x61, 0x62, 0x63, 0x64 });
    try append_masked(&stream, Frame.text(&text_payload), .{ 0x65, 0x66, 0x67, 0x68 });

    var reader = stream.reader();
    var parts: SplitRig(32, 2, 32, 8, 0, 32) = .{};
    try parts.init(&reader, .{
        .role = .server,
        .options = .{ .allow_rsv1 = true },
    });

    const received = try parts.split.read_frame();
    try std.testing.expectEqualStrings("ok", received.payload);
    var index: usize = 0;
    const pong = try next_wire_frame(parts.bytes(), &index);
    try std.testing.expect(!pong.header.header.rsv1);
    try std.testing.expectEqual(split.OpCode.pong, split.OpCode.from_wire(pong.header.header.opcode).?);
}

test "Split: zero max_message_size rejects before consuming and does not latch" {
    var stream: EncodedStream(16) = .{};
    var payload = [_]u8{ 'o', 'k' };
    try append_masked(&stream, Frame.text(&payload), .{ 0x31, 0x32, 0x33, 0x34 });

    var reader = stream.reader();
    var parts: SplitRig(16, 1, 32, 8, 0, 8) = .{};
    try parts.init(&reader, .{ .role = .server, .options = .{ .max_message_size = 0 } });

    try std.testing.expectError(error.FrameTooLarge, parts.split.read_frame());
    try std.testing.expectEqual(@as(usize, 0), reader.seek);
    try std.testing.expectError(error.FrameTooLarge, parts.split.read_frame());
    try std.testing.expectEqual(@as(usize, 0), reader.seek);

    parts.split.set_max_message_size(8);
    try std.testing.expectEqual(@as(usize, 8), parts.split.read.max_message_size());
    try std.testing.expectEqual(@as(usize, 8), parts.split.write.max_message_size());

    const received = try parts.split.read_frame();
    try std.testing.expectEqualStrings("ok", received.payload);
}

test "Split: a write failure latches, blocks reads, and reset_tx clears it" {
    const seed: [connection.mask_seed_len]u8 = @splat(0x5d);
    var stream: EncodedStream(16) = .{};
    var inbound = [_]u8{ 'o', 'k' };
    try stream.append(Frame.text(&inbound));

    var reader = stream.reader();
    var parts: SplitRig(16, 2, 32, 8, 0, 16) = .{};
    try parts.init(&reader, .{
        .role = .client,
        .mask_keys = connection.MaskKeySource.from_seed(seed),
    });
    parts.writer.fail_after = 0;

    var payload = [_]u8{ 'h', 'i' };
    try std.testing.expectError(error.IoError, parts.split.write_frame(Frame.text(&payload)));
    try std.testing.expectEqual(@as(?WebSocketError, error.IoError), parts.split.write.failure());
    try std.testing.expectEqual(@as(usize, 1), parts.split.write.tx_pending());
    try std.testing.expectEqual(@as(usize, 0), parts.writer.written);

    try std.testing.expectError(error.IoError, parts.split.read_frame());
    try std.testing.expectEqual(@as(usize, 0), reader.seek);

    parts.split.reset_tx();
    try std.testing.expectEqual(@as(?WebSocketError, null), parts.split.write.failure());
    try std.testing.expectEqual(@as(usize, 0), parts.split.write.tx_pending());
    try std.testing.expect(!parts.split.is_closed());

    const received = try parts.split.read_frame();
    try std.testing.expectEqualStrings("ok", received.payload);
}

test "Split: write_frame after close rejects data but serializes repeated closes" {
    var empty = std.Io.Reader.fixed("");
    var parts: SplitRig(16, 2, 32, 8, 0, 64) = .{};
    try parts.init(&empty, .{ .role = .server });

    var first_close_storage: [8]u8 = undefined;
    try parts.split.write_frame(try Frame.close(1000, "a", &first_close_storage));
    const after_first_close = parts.writer.written;
    try std.testing.expect(parts.split.write.is_closed());

    var text = [_]u8{'x'};
    try std.testing.expectError(error.ConnectionClosed, parts.split.write_frame(Frame.text(&text)));
    try std.testing.expectEqual(after_first_close, parts.writer.written);

    var second_close_storage: [8]u8 = undefined;
    try parts.split.write_frame(try Frame.close(1000, "b", &second_close_storage));
    try std.testing.expect(parts.split.write.is_closed());
    try std.testing.expectEqual(@as(usize, 0), parts.split.write.tx_pending());

    var index: usize = 0;
    const first = try next_wire_frame(parts.bytes(), &index);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xe8, 'a' }, first.payload);
    const second = try next_wire_frame(parts.bytes(), &index);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xe8, 'b' }, second.payload);
    try std.testing.expectEqual(parts.writer.written, index);
}
