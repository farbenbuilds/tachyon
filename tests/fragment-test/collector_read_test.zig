const std = @import("std");
const tachyon = @import("tachyon");

const support = @import("../support.zig");

const fragment = tachyon.fragment;
const Frame = tachyon.Frame;
const MaskingKey = tachyon.MaskingKey;
const EncodedStream = support.EncodedStream;
const read_failed_stream = support.read_failed_stream;

test "FragmentCollector: unfragmented text returns the exact payload" {
    var stream: EncodedStream(64) = .{};
    var payload = [_]u8{ 'h', 'e', 'l', 'l', 'o' };
    try stream.append(Frame.text(&payload));

    var reader = stream.reader();
    var frame_buffer: [64]u8 = undefined;
    var message_buffer: [64]u8 = undefined;
    var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 64);

    const completed = try collector.read_frame();
    try std.testing.expect(completed.fin);
    try std.testing.expectEqual(fragment.OpCode.text, completed.opcode);
    try std.testing.expectEqualSlices(u8, &payload, completed.payload);
    try std.testing.expect(collector.is_at_frame_boundary());
}

test "FragmentCollector: reassembles text split inside a code point" {
    var stream: EncodedStream(64) = .{};
    var first = [_]u8{ 'A', 0xc2 };
    var second = [_]u8{ 0xa2, 0xe2 };
    var third = [_]u8{ 0x82, 0xac };
    try stream.append(Frame.init(false, .text, null, &first));
    try stream.append(Frame.init(false, .continuation, null, &second));
    try stream.append(Frame.init(true, .continuation, null, &third));

    var reader = stream.reader();
    var frame_buffer: [64]u8 = undefined;
    var message_buffer: [64]u8 = undefined;
    var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 64);

    const completed = try collector.read_frame();
    try std.testing.expect(completed.fin);
    try std.testing.expectEqual(fragment.OpCode.text, completed.opcode);
    try std.testing.expectEqualSlices(u8, "A\xc2\xa2\xe2\x82\xac", completed.payload);
    try std.testing.expect(collector.is_at_frame_boundary());
}

test "FragmentCollector: aggregated binary over the limit returns FrameTooLarge" {
    var stream: EncodedStream(64) = .{};
    var first = [_]u8{ 'a', 'b', 'c', 'd', 'e' };
    var second = [_]u8{ 'f', 'g', 'h', 'i', 'j' };
    try stream.append(Frame.init(false, .binary, null, &first));
    try stream.append(Frame.init(true, .continuation, null, &second));

    var reader = stream.reader();
    var frame_buffer: [64]u8 = undefined;
    var message_buffer: [64]u8 = undefined;
    // Two five-byte fragments exceed a nine-byte exclusive message limit.
    var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 9);

    try std.testing.expectError(error.FrameTooLarge, collector.read_frame());
}

test "FragmentCollector: aggregated text over the limit returns FrameTooLarge" {
    var stream: EncodedStream(64) = .{};
    var first = [_]u8{ 'a', 'b', 'c', 'd', 'e' };
    var second = [_]u8{ 'f', 'g', 'h', 'i', 'j' };
    try stream.append(Frame.init(false, .text, null, &first));
    try stream.append(Frame.init(true, .continuation, null, &second));

    var reader = stream.reader();
    var frame_buffer: [64]u8 = undefined;
    var message_buffer: [64]u8 = undefined;
    var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 9);

    try std.testing.expectError(error.FrameTooLarge, collector.read_frame());
}

test "FragmentCollector: exclusive message limit accepts below and rejects the boundary" {
    var payload: [130]u8 = @splat(0x41);
    const accepted_lengths = [_]usize{ 0, 1, 125, 126, 127, 129 };

    for (accepted_lengths) |len| {
        var stream: EncodedStream(256) = .{};
        try stream.append(Frame.binary(payload[0..len]));

        var reader = stream.reader();
        var frame_buffer: [256]u8 = undefined;
        var message_buffer: [256]u8 = undefined;
        var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 130);

        const completed = try collector.read_frame();
        try std.testing.expectEqual(len, completed.payload.len);
        try std.testing.expectEqualSlices(u8, payload[0..len], completed.payload);
    }

    var stream: EncodedStream(256) = .{};
    try stream.append(Frame.binary(payload[0..130]));

    var reader = stream.reader();
    var frame_buffer: [256]u8 = undefined;
    var message_buffer: [256]u8 = undefined;
    var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 130);

    try std.testing.expectError(error.FrameTooLarge, collector.read_frame());
}

test "FragmentCollector: 16-bit and 64-bit length boundaries follow the exclusive limit" {
    var payload: [65536]u8 = @splat(0x5a);
    var frame_buffer: [65536]u8 = undefined;
    var message_buffer: [16]u8 = undefined;

    // 65536 is accepted when the exclusive limit is 65537.
    {
        var stream: EncodedStream(65546) = .{};
        try stream.append(Frame.binary(&payload));

        var reader = stream.reader();
        var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 65537);
        const completed = try collector.read_frame();
        try std.testing.expectEqual(@as(usize, 65536), completed.payload.len);
    }

    // 65535 is accepted when the exclusive limit is 65536.
    {
        var stream: EncodedStream(65545) = .{};
        try stream.append(Frame.binary(payload[0..65535]));

        var reader = stream.reader();
        var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 65536);
        const completed = try collector.read_frame();
        try std.testing.expectEqual(@as(usize, 65535), completed.payload.len);
    }

    // 65536 is rejected when the exclusive limit is 65536.
    {
        var stream: EncodedStream(65546) = .{};
        try stream.append(Frame.binary(&payload));

        var reader = stream.reader();
        var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 65536);
        try std.testing.expectError(error.FrameTooLarge, collector.read_frame());
    }
}

test "FragmentCollector: zero max_message_size rejects an empty frame before reading" {
    var stream: EncodedStream(16) = .{};
    var empty: [0]u8 = .{};
    try stream.append(Frame.text(&empty));

    var reader = stream.reader();
    var frame_buffer: [16]u8 = undefined;
    var message_buffer: [16]u8 = undefined;
    var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 0);

    try std.testing.expectError(error.FrameTooLarge, collector.read_frame());
    try std.testing.expectEqual(@as(usize, 0), reader.seek);
}

test "FragmentCollector: server-role collector unmasks a masked client text frame" {
    var stream: EncodedStream(64) = .{};
    var payload = [_]u8{ 's', 'e', 'c', 'r', 'e', 't' };
    const plaintext = [_]u8{ 's', 'e', 'c', 'r', 'e', 't' };
    var masked = Frame.text(&payload);
    masked.mask(.{ 0x11, 0x22, 0x33, 0x44 });
    try stream.append(masked);

    var reader = stream.reader();
    var frame_buffer: [64]u8 = undefined;
    var message_buffer: [64]u8 = undefined;
    var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .server, 64);

    const completed = try collector.read_frame();
    try std.testing.expectEqual(fragment.OpCode.text, completed.opcode);
    try std.testing.expectEqual(@as(?MaskingKey, null), completed.masking_key);
    try std.testing.expectEqualSlices(u8, &plaintext, completed.payload);
}

test "FragmentCollector: client-role collector rejects a masked inbound frame" {
    var stream: EncodedStream(64) = .{};
    var payload = [_]u8{'x'};
    var masked = Frame.text(&payload);
    masked.mask(.{ 0xaa, 0xbb, 0xcc, 0xdd });
    try stream.append(masked);

    var reader = stream.reader();
    var frame_buffer: [64]u8 = undefined;
    var message_buffer: [64]u8 = undefined;
    var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 64);

    try std.testing.expectError(error.PayloadMasked, collector.read_frame());
}

test "FragmentCollector: truncated header and payload return UnexpectedEOF" {
    {
        var stream: EncodedStream(16) = .{};
        stream.bytes[0] = 0x81;
        stream.len = 1;

        var reader = stream.reader();
        var frame_buffer: [16]u8 = undefined;
        var message_buffer: [16]u8 = undefined;
        var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 64);

        try std.testing.expectError(error.UnexpectedEOF, collector.read_frame());
        try std.testing.expect(!collector.is_at_wire_boundary());
    }

    {
        var stream: EncodedStream(16) = .{};
        stream.bytes[0] = 0x81;
        stream.bytes[1] = 0x05;
        @memcpy(stream.bytes[2..5], "abc");
        stream.len = 5;

        var reader = stream.reader();
        var frame_buffer: [16]u8 = undefined;
        var message_buffer: [16]u8 = undefined;
        var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 64);

        try std.testing.expectError(error.UnexpectedEOF, collector.read_frame());
        try std.testing.expect(!collector.is_at_wire_boundary());
    }
}

test "FragmentCollector: rejects a message buffer overlapping the frame buffer" {
    var reader = std.Io.Reader.fixed("");
    var shared: [16]u8 = undefined;

    try std.testing.expectError(error.InvalidLength, fragment.FragmentCollector.init(
        &reader,
        &shared,
        &shared,
        .client,
        64,
    ));
}

test "FragmentCollector: rejects buffers overlapping the reader buffer" {
    var shared: [16]u8 = undefined;
    var reader = std.Io.Reader.fixed(&shared);
    var frame_buffer: [16]u8 = undefined;
    var message_buffer: [16]u8 = undefined;

    try std.testing.expectError(error.InvalidLength, fragment.FragmentCollector.init(
        &reader,
        &shared,
        &message_buffer,
        .client,
        64,
    ));
    try std.testing.expectError(error.InvalidLength, fragment.FragmentCollector.init(
        &reader,
        &frame_buffer,
        &shared,
        .client,
        64,
    ));
}

test "FragmentCollector: a failed reader returns IoError" {
    var reader = std.Io.Reader{
        .vtable = &.{ .stream = read_failed_stream },
        .buffer = &.{},
        .seek = 0,
        .end = 0,
    };
    var frame_buffer: [16]u8 = undefined;
    var message_buffer: [16]u8 = undefined;
    var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 64);

    try std.testing.expectError(error.IoError, collector.read_frame());
}

test "FragmentCollector: a frame larger than frame_buffer returns BufferTooShort" {
    var stream: EncodedStream(32) = .{};
    var payload = [_]u8{ 'a', 'b', 'c', 'd', 'e' };
    try stream.append(Frame.binary(&payload));

    var reader = stream.reader();
    var frame_buffer: [4]u8 = undefined;
    var message_buffer: [32]u8 = undefined;
    var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 64);

    try std.testing.expectError(error.BufferTooShort, collector.read_frame());
    // Only the two header bytes may be consumed; the payload stays unread.
    try std.testing.expectEqual(@as(usize, 2), reader.seek);
}

test "FragmentCollector: a message larger than message_buffer returns BufferTooShort" {
    var stream: EncodedStream(32) = .{};
    var first = [_]u8{ 'a', 'b', 'c' };
    var second = [_]u8{ 'd', 'e' };
    try stream.append(Frame.init(false, .binary, null, &first));
    try stream.append(Frame.init(true, .continuation, null, &second));

    var reader = stream.reader();
    var frame_buffer: [8]u8 = undefined;
    var message_buffer: [4]u8 = undefined;
    var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 64);

    try std.testing.expectError(error.BufferTooShort, collector.read_frame());
}

test "FragmentCollector: a ping between fragments is delivered before the completed message" {
    var stream: EncodedStream(64) = .{};
    var first = [_]u8{ 'h', 'e' };
    var ping_payload = [_]u8{'?'};
    var last = [_]u8{ 'l', 'l', 'o' };
    try stream.append(Frame.init(false, .text, null, &first));
    try stream.append(Frame.ping(&ping_payload));
    try stream.append(Frame.init(true, .continuation, null, &last));

    var reader = stream.reader();
    var frame_buffer: [64]u8 = undefined;
    var message_buffer: [64]u8 = undefined;
    var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 64);

    const control = try collector.read_frame();
    try std.testing.expect(control.fin);
    try std.testing.expectEqual(fragment.OpCode.ping, control.opcode);
    try std.testing.expectEqual(@as(?MaskingKey, null), control.masking_key);
    try std.testing.expectEqualSlices(u8, &ping_payload, control.payload);
    // The reader is aligned to the next frame, but the message is still open.
    try std.testing.expect(collector.is_at_wire_boundary());
    try std.testing.expect(!collector.is_at_frame_boundary());

    const completed = try collector.read_frame();
    try std.testing.expectEqual(fragment.OpCode.text, completed.opcode);
    try std.testing.expectEqualSlices(u8, "hello", completed.payload);
    try std.testing.expect(collector.is_at_wire_boundary());
    try std.testing.expect(collector.is_at_frame_boundary());
}

test "FragmentCollector: invalid UTF-8 in an unfragmented text frame returns InvalidUTF8" {
    var stream: EncodedStream(16) = .{};
    var payload = [_]u8{0xff};
    try stream.append(Frame.text(&payload));

    var reader = stream.reader();
    var frame_buffer: [16]u8 = undefined;
    var message_buffer: [16]u8 = undefined;
    var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 64);

    try std.testing.expectError(error.InvalidUTF8, collector.read_frame());
}
