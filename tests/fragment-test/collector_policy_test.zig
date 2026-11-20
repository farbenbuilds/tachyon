const std = @import("std");
const zslay = @import("zslay");
const tachyon = @import("tachyon");

const support = @import("../support.zig");

const fragment = tachyon.fragment;
const frame = tachyon.frame;
const utf8 = tachyon.utf8;
const Frame = tachyon.Frame;
const MaskingKey = tachyon.MaskingKey;
const EncodedStream = support.EncodedStream;

test "FragmentCollector: invalid UTF-8 across fragments returns InvalidUTF8" {
    var stream: EncodedStream(16) = .{};
    var first = [_]u8{'A'};
    var second = [_]u8{0xff};
    try stream.append(Frame.init(false, .text, null, &first));
    try stream.append(Frame.init(true, .continuation, null, &second));

    var reader = stream.reader();
    var frame_buffer: [16]u8 = undefined;
    var message_buffer: [16]u8 = undefined;
    var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 64);

    try std.testing.expectError(error.InvalidUTF8, collector.read_frame());
}

test "FragmentCollector: an orphan continuation returns ProtocolError" {
    var stream: EncodedStream(16) = .{};
    var payload = [_]u8{'x'};
    try stream.append(Frame.init(true, .continuation, null, &payload));

    var reader = stream.reader();
    var frame_buffer: [16]u8 = undefined;
    var message_buffer: [16]u8 = undefined;
    var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 64);

    try std.testing.expectError(error.ProtocolError, collector.read_frame());
}

test "FragmentCollector: reset clears an in-progress message and boundary tracking" {
    var stream: EncodedStream(64) = .{};
    var first = [_]u8{ 'h', 'e' };
    var ping_payload = [_]u8{'?'};
    var fresh = [_]u8{ 'o', 'k' };
    try stream.append(Frame.init(false, .text, null, &first));
    try stream.append(Frame.ping(&ping_payload));
    try stream.append(Frame.text(&fresh));

    var reader = stream.reader();
    var frame_buffer: [64]u8 = undefined;
    var message_buffer: [64]u8 = undefined;
    var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 64);

    try std.testing.expect(collector.is_at_frame_boundary());

    const control = try collector.read_frame();
    try std.testing.expectEqual(fragment.OpCode.ping, control.opcode);
    // The partial text message keeps the collector off a boundary.
    try std.testing.expect(!collector.is_at_frame_boundary());

    collector.reset();
    try std.testing.expect(collector.is_at_frame_boundary());

    const completed = try collector.read_frame();
    try std.testing.expectEqual(fragment.OpCode.text, completed.opcode);
    try std.testing.expectEqualSlices(u8, &fresh, completed.payload);
    try std.testing.expect(collector.is_at_frame_boundary());
}

test "FragmentCollector: reads one complete text frame from a std.Io file reader" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    var payload = [_]u8{ 'f', 'i', 'l', 'e' };
    var stream: EncodedStream(64) = .{};
    try stream.append(Frame.text(&payload));

    {
        const file = try tmp.dir.createFile(io, "fragment.bin", .{});
        defer file.close(io);
        try file.writeStreamingAll(io, stream.bytes[0..stream.len]);
    }

    const file = try tmp.dir.openFile(io, "fragment.bin", .{});
    defer file.close(io);

    var file_buffer: [8]u8 = undefined;
    var file_reader = file.reader(io, &file_buffer);
    var frame_buffer: [64]u8 = undefined;
    var message_buffer: [64]u8 = undefined;
    var collector = try fragment.FragmentCollector.init(
        &file_reader.interface,
        &frame_buffer,
        &message_buffer,
        .client,
        64,
    );

    const completed = try collector.read_frame();
    try std.testing.expectEqual(fragment.OpCode.text, completed.opcode);
    try std.testing.expectEqualSlices(u8, &payload, completed.payload);
    try std.testing.expect(collector.is_at_frame_boundary());
}

test "FragmentCollector: a failed accumulation latches BufferTooShort until reset" {
    var stream: EncodedStream(64) = .{};
    var first = [_]u8{ 'a', 'b', 'c' };
    var second = [_]u8{ 'd', 'e' };
    var fresh = [_]u8{ 'o', 'k' };
    try stream.append(Frame.init(false, .text, null, &first));
    try stream.append(Frame.init(false, .continuation, null, &second));
    try stream.append(Frame.text(&fresh));

    var reader = stream.reader();
    var frame_buffer: [16]u8 = undefined;
    var message_buffer: [4]u8 = undefined;
    var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 64);

    try std.testing.expectError(error.BufferTooShort, collector.read_frame());
    // zslay completed the second frame, so the reader is aligned even though the
    // accumulator rejected the bytes.
    try std.testing.expect(collector.is_at_wire_boundary());
    const seek_after_failure = reader.seek;

    // The failure is terminal: the fresh third frame must stay unread.
    try std.testing.expectError(error.BufferTooShort, collector.read_frame());
    try std.testing.expectEqual(seek_after_failure, reader.seek);

    collector.reset();
    const completed = try collector.read_frame();
    try std.testing.expect(completed.fin);
    try std.testing.expectEqual(fragment.OpCode.text, completed.opcode);
    try std.testing.expectEqualSlices(u8, &fresh, completed.payload);
    try std.testing.expect(collector.is_at_wire_boundary());
    try std.testing.expect(collector.is_at_frame_boundary());
}

test "FragmentCollector: a failed UTF-8 accumulation latches InvalidUTF8 until reset" {
    var stream: EncodedStream(64) = .{};
    var first = [_]u8{'A'};
    var invalid = [_]u8{0xff};
    var fresh = [_]u8{ 'o', 'k' };
    try stream.append(Frame.init(false, .text, null, &first));
    try stream.append(Frame.init(true, .continuation, null, &invalid));
    try stream.append(Frame.text(&fresh));

    var reader = stream.reader();
    var frame_buffer: [16]u8 = undefined;
    var message_buffer: [16]u8 = undefined;
    var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 64);

    try std.testing.expectError(error.InvalidUTF8, collector.read_frame());
    try std.testing.expect(collector.is_at_wire_boundary());
    const seek_after_failure = reader.seek;

    try std.testing.expectError(error.InvalidUTF8, collector.read_frame());
    try std.testing.expectEqual(seek_after_failure, reader.seek);

    collector.reset();
    const completed = try collector.read_frame();
    try std.testing.expectEqual(fragment.OpCode.text, completed.opcode);
    try std.testing.expectEqualSlices(u8, &fresh, completed.payload);
}

test "FragmentCollector: a truncated payload latches UnexpectedEOF while off the wire boundary" {
    var stream: EncodedStream(16) = .{};
    stream.bytes[0] = 0x81;
    stream.bytes[1] = 0x05;
    @memcpy(stream.bytes[2..5], "abc");
    stream.len = 5;

    var reader = stream.reader();
    var frame_buffer: [8]u8 = undefined;
    var message_buffer: [8]u8 = undefined;
    var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 64);

    try std.testing.expectError(error.UnexpectedEOF, collector.read_frame());
    try std.testing.expect(!collector.is_at_wire_boundary());
    const seek_after_failure = reader.seek;

    try std.testing.expectError(error.UnexpectedEOF, collector.read_frame());
    try std.testing.expectEqual(seek_after_failure, reader.seek);
    try std.testing.expect(!collector.is_at_wire_boundary());
}

test "FragmentCollector: fragmented messages accept max_message_size - 1 bytes" {
    var stream: EncodedStream(32) = .{};
    var first = [_]u8{ 'a', 'b', 'c', 'd', 'e' };
    var second = [_]u8{ 'f', 'g', 'h' };
    try stream.append(Frame.init(false, .binary, null, &first));
    try stream.append(Frame.init(true, .continuation, null, &second));

    var reader = stream.reader();
    var frame_buffer: [16]u8 = undefined;
    var message_buffer: [8]u8 = undefined;
    var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 9);

    const completed = try collector.read_frame();
    try std.testing.expect(completed.fin);
    try std.testing.expectEqual(fragment.OpCode.binary, completed.opcode);
    try std.testing.expectEqualSlices(u8, "abcdefgh", completed.payload);
    try std.testing.expect(collector.is_at_frame_boundary());
}

test "FragmentCollector: fragmented messages reject the exclusive max_message_size boundary" {
    var stream: EncodedStream(32) = .{};
    var first = [_]u8{ 'a', 'b', 'c', 'd', 'e' };
    var second = [_]u8{ 'f', 'g', 'h', 'i' };
    try stream.append(Frame.init(false, .binary, null, &first));
    try stream.append(Frame.init(true, .continuation, null, &second));

    var reader = stream.reader();
    var frame_buffer: [16]u8 = undefined;
    var message_buffer: [8]u8 = undefined;
    var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 9);

    try std.testing.expectError(error.FrameTooLarge, collector.read_frame());
}

test "FragmentCollector: init rejects max_message_size above zslay MaxPayloadLen" {
    if (@bitSizeOf(usize) >= 64) {
        var empty: [0]u8 = .{};
        var reader = std.Io.Reader.fixed(&empty);
        var frame_buffer: [16]u8 = undefined;
        var message_buffer: [16]u8 = undefined;
        const too_large: usize = @intCast(zslay.MaxPayloadLen + 1);

        try std.testing.expectError(
            error.InvalidLength,
            fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, too_large),
        );
    }
}

test "FragmentCollector: one-byte limit accepts an empty frame and rejects one byte" {
    {
        var stream: EncodedStream(16) = .{};
        var empty: [0]u8 = .{};
        try stream.append(Frame.text(&empty));

        var reader = stream.reader();
        var frame_buffer: [16]u8 = undefined;
        var message_buffer: [16]u8 = undefined;
        var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 1);

        const completed = try collector.read_frame();
        try std.testing.expect(completed.fin);
        try std.testing.expectEqual(fragment.OpCode.text, completed.opcode);
        try std.testing.expectEqual(@as(usize, 0), completed.payload.len);
    }

    {
        var stream: EncodedStream(16) = .{};
        var payload = [_]u8{'x'};
        try stream.append(Frame.text(&payload));

        var reader = stream.reader();
        var frame_buffer: [16]u8 = undefined;
        var message_buffer: [16]u8 = undefined;
        var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 1);

        try std.testing.expectError(error.FrameTooLarge, collector.read_frame());
    }
}

test "FragmentCollector: server role rejects an unmasked inbound frame" {
    var stream: EncodedStream(16) = .{};
    var payload = [_]u8{'x'};
    try stream.append(Frame.text(&payload));

    var reader = stream.reader();
    var frame_buffer: [16]u8 = undefined;
    var message_buffer: [16]u8 = undefined;
    var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .server, 64);

    try std.testing.expectError(error.PayloadNotMasked, collector.read_frame());
}

test "Fragments: masked payloads are rejected before validation or state change" {
    var buffer: [8]u8 = @splat(0xaa);
    var fragments = fragment.Fragments.init(&buffer);
    const key: MaskingKey = .{ 0x01, 0x02, 0x03, 0x04 };
    // Invalid UTF-8 proves the mask check runs before any validation.
    var payload = [_]u8{0xff};

    try std.testing.expectError(
        error.PayloadMasked,
        fragments.accumulate(Frame.init(false, .text, key, &payload)),
    );
    try std.testing.expectError(
        error.PayloadMasked,
        fragments.accumulate(Frame.init(true, .text, key, &payload)),
    );

    try std.testing.expect(fragments.is_idle());
    try std.testing.expectEqual(@as(usize, 0), fragments.message_len());
    for (buffer) |byte| try std.testing.expectEqual(@as(u8, 0xaa), byte);
}

fn expect_collector_protocol_error(wire: []const u8) !void {
    var reader = std.Io.Reader.fixed(wire);
    var frame_buffer: [64]u8 = undefined;
    var message_buffer: [64]u8 = undefined;
    var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 64);

    try std.testing.expectError(error.ProtocolError, collector.read_frame());
}

test "FragmentCollector: zslay-owned malformed input returns ProtocolError" {
    const cases = [_][]const u8{
        // New text data frame while a fragmented text message is active.
        &.{ 0x01, 0x01, 'a', 0x81, 0x01, 'b' },
        // Fragmented ping control frame (FIN=0).
        &.{ 0x09, 0x00 },
        // Ping control frame with an extended-length marker.
        &.{ 0x89, 0x7e, 0x00, 0x7e },
        // Reserved RSV1 bit set.
        &.{ 0xc1, 0x00 },
        // One-byte close payload.
        &.{ 0x88, 0x01, 0x00 },
    };

    for (cases) |wire| try expect_collector_protocol_error(wire);
}

test "FragmentCollector: close frames pass through without code or reason validation" {
    var stream: EncodedStream(16) = .{};
    var invalid_close = [_]u8{ 0x03, 0xe7 };
    try stream.append(Frame.close_raw(&invalid_close));

    var reader = stream.reader();
    var frame_buffer: [16]u8 = undefined;
    var message_buffer: [16]u8 = undefined;
    var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 64);

    const close = try collector.read_frame();
    try std.testing.expect(close.fin);
    try std.testing.expectEqual(fragment.OpCode.close, close.opcode);
    try std.testing.expectEqualSlices(u8, &invalid_close, close.payload);
    // 999 is not a valid close code; validation belongs to the connection layer.
    try std.testing.expect(!frame.is_valid_close_code(999));
    try std.testing.expect(collector.is_at_wire_boundary());
}

test "FragmentCollector: consecutive text messages reset the UTF-8 carry state" {
    var stream: EncodedStream(64) = .{};
    var first_a = [_]u8{ 'A', 0xc2 };
    var first_b = [_]u8{0xa2};
    var second_a = [_]u8{ 'B', 0xe2 };
    var second_b = [_]u8{ 0x82, 0xac };
    try stream.append(Frame.init(false, .text, null, &first_a));
    try stream.append(Frame.init(true, .continuation, null, &first_b));
    try stream.append(Frame.init(false, .text, null, &second_a));
    try stream.append(Frame.init(true, .continuation, null, &second_b));

    var reader = stream.reader();
    var frame_buffer: [64]u8 = undefined;
    var message_buffer: [64]u8 = undefined;
    var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 64);

    const first = try collector.read_frame();
    try std.testing.expect(first.fin);
    try std.testing.expectEqual(fragment.OpCode.text, first.opcode);
    try std.testing.expectEqualSlices(u8, "A\xc2\xa2", first.payload);

    // A carried split code point would corrupt the second message.
    const second = try collector.read_frame();
    try std.testing.expect(second.fin);
    try std.testing.expectEqual(fragment.OpCode.text, second.opcode);
    try std.testing.expectEqualSlices(u8, "B\xe2\x82\xac", second.payload);
    try std.testing.expect(collector.is_at_frame_boundary());
}

test "FragmentCollector: invalid UTF-8 close reasons pass through unvalidated" {
    var stream: EncodedStream(16) = .{};
    var close_payload = [_]u8{ 0x03, 0xe8, 0xff, 0xfe };
    try stream.append(Frame.close_raw(&close_payload));

    var reader = stream.reader();
    var frame_buffer: [16]u8 = undefined;
    var message_buffer: [16]u8 = undefined;
    var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 64);

    const close = try collector.read_frame();
    try std.testing.expect(close.fin);
    try std.testing.expectEqual(fragment.OpCode.close, close.opcode);
    try std.testing.expectEqualSlices(u8, &close_payload, close.payload);
    // Code 1000 with an invalid reason must pass through: close-reason
    // validation belongs to the connection layer, not the collector.
    try std.testing.expect(!utf8.is_valid(close.payload[2..]));
    try std.testing.expect(collector.is_at_wire_boundary());
}
