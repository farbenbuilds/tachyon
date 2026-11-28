const std = @import("std");
const tachyon = @import("tachyon");

const support = @import("../support.zig");

const split = tachyon.split;
const Frame = tachyon.Frame;
const MaskingKey = tachyon.MaskingKey;
const WebSocketError = tachyon.WebSocketError;
const EncodedStream = support.EncodedStream;
const next_wire_frame = support.next_wire_frame;
const append_masked = support.append_masked;
const SplitRig = support.SplitRig;

test "Split: FragmentCollectorRead assembles a split code point with an interleaved ping" {
    var stream: EncodedStream(64) = .{};
    var first = [_]u8{ 'A', 0xe2 };
    var ping_payload = [_]u8{'p'};
    var last = [_]u8{ 0x82, 0xac };
    try append_masked(&stream, Frame.init(false, .text, null, &first), .{ 0x01, 0x02, 0x03, 0x04 });
    try append_masked(&stream, Frame.ping(&ping_payload), .{ 0x05, 0x06, 0x07, 0x08 });
    try append_masked(&stream, Frame.init(true, .continuation, null, &last), .{ 0x09, 0x0a, 0x0b, 0x0c });

    var reader = stream.reader();
    var parts: SplitRig(32, 2, 32, 8, 0, 32) = .{};
    try parts.init(&reader, .{ .role = .server });

    var collector = try split.FragmentCollectorRead.init(parts.split.read, &parts.message_buffer);
    const message = try collector.read_frame(&parts.split.write);
    try std.testing.expectEqual(split.OpCode.text, message.opcode);
    try std.testing.expect(message.fin);
    try std.testing.expectEqualSlices(u8, &.{ 'A', 0xe2, 0x82, 0xac }, message.payload);
    try std.testing.expectEqual(@as(usize, 0), collector.message_len());
    try std.testing.expect(collector.is_at_frame_boundary());

    var index: usize = 0;
    const pong = try next_wire_frame(parts.bytes(), &index);
    try std.testing.expectEqual(split.OpCode.pong, split.OpCode.from_wire(pong.header.header.opcode).?);
    try std.testing.expectEqualStrings("p", pong.payload);
    try std.testing.expectEqual(parts.writer.written, index);
}

test "Split: FragmentCollectorRead delivers a ping between fragments without disturbing accumulation" {
    var stream: EncodedStream(64) = .{};
    var first = [_]u8{ 'A', 0xe2 };
    var ping_payload = [_]u8{'p'};
    var last = [_]u8{ 0x82, 0xac };
    try append_masked(&stream, Frame.init(false, .text, null, &first), .{ 0x11, 0x12, 0x13, 0x14 });
    try append_masked(&stream, Frame.ping(&ping_payload), .{ 0x15, 0x16, 0x17, 0x18 });
    try append_masked(&stream, Frame.init(true, .continuation, null, &last), .{ 0x19, 0x1a, 0x1b, 0x1c });

    var reader = stream.reader();
    var parts: SplitRig(32, 2, 32, 8, 0, 32) = .{};
    try parts.init(&reader, .{ .role = .server, .options = .{ .auto_pong = false } });

    var collector = try split.FragmentCollectorRead.init(parts.split.read, &parts.message_buffer);
    const ping = try collector.read_frame(&parts.split.write);
    try std.testing.expectEqual(split.OpCode.ping, ping.opcode);
    try std.testing.expectEqualStrings("p", ping.payload);
    try std.testing.expectEqual(@as(usize, 2), collector.message_len());
    try std.testing.expect(!collector.is_at_frame_boundary());

    const message = try collector.read_frame(&parts.split.write);
    try std.testing.expectEqualSlices(u8, &.{ 'A', 0xe2, 0x82, 0xac }, message.payload);
    try std.testing.expectEqual(@as(usize, 0), collector.message_len());
    try std.testing.expect(collector.is_at_frame_boundary());
    try std.testing.expectEqual(@as(usize, 0), parts.writer.written);
}

test "Split: FragmentCollectorRead rejects a message buffer overlapping the read frame buffer" {
    var empty = std.Io.Reader.fixed("");
    var parts: SplitRig(16, 1, 32, 8, 0, 8) = .{};
    try parts.init(&empty, .{ .role = .server });

    try std.testing.expectError(
        error.InvalidLength,
        split.FragmentCollectorRead.init(parts.split.read, parts.frame_buffer[0..8]),
    );
}

test "Split: FragmentCollectorRead rejects a message buffer overlapping the read close buffer" {
    var empty = std.Io.Reader.fixed("");
    var parts: SplitRig(16, 1, 32, 8, 0, 8) = .{};
    try parts.init(&empty, .{ .role = .server });

    try std.testing.expectError(
        error.InvalidLength,
        split.FragmentCollectorRead.init(parts.split.read, parts.read_close_buffer[0..8]),
    );
}

test "Split: FragmentCollectorRead rejects a message buffer overlapping the shared writer buffer" {
    var input: [16]u8 = undefined;
    var reader = std.Io.Reader.fixed(&input);
    var output: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    var frame_buffer: [16]u8 = undefined;
    var close_buffer: [8]u8 = undefined;
    var compose_buffer: [32]u8 = undefined;
    const read = try split.WebSocketRead.init(&reader, &writer, .{
        .frame_buffer = &frame_buffer,
        .close_buffer = &close_buffer,
        .compose_buffer = &compose_buffer,
    }, .{ .role = .server });

    try std.testing.expectError(
        error.InvalidLength,
        split.FragmentCollectorRead.init(read, writer.buffer[0..8]),
    );
}

test "Split: FragmentCollectorRead ping-only after a close write returns ConnectionClosed without extra read" {
    var stream: EncodedStream(32) = .{};
    var first_ping = [_]u8{'?'};
    var second_ping = [_]u8{'!'};
    try append_masked(&stream, Frame.ping(&first_ping), .{ 0x10, 0x20, 0x30, 0x40 });
    try append_masked(&stream, Frame.ping(&second_ping), .{ 0x50, 0x60, 0x70, 0x80 });

    var reader = stream.reader();
    var parts: SplitRig(32, 2, 32, 8, 0, 32) = .{};
    try parts.init(&reader, .{ .role = .server });
    var collector = try split.FragmentCollectorRead.init(parts.split.read, &parts.message_buffer);

    var close_storage: [2]u8 = undefined;
    try parts.split.write.write_frame(try Frame.close(1000, "", &close_storage));
    const output_after_close = parts.writer.written;

    try std.testing.expectError(error.ConnectionClosed, collector.read_frame(&parts.split.write));
    try std.testing.expectEqual(@as(?WebSocketError, null), collector.failure);
    try std.testing.expectEqual(output_after_close, parts.writer.written);
    try std.testing.expectEqual(@as(usize, 7), reader.seek);
    try std.testing.expectEqual(@as(usize, 7), reader.buffered().len);
}

test "Split: FragmentCollectorRead reset clears an in-progress message and boundary tracking" {
    var stream: EncodedStream(64) = .{};
    var first = [_]u8{ 'h', 'e' };
    var ping_payload = [_]u8{'p'};
    var text_payload = [_]u8{ 'o', 'k' };
    try append_masked(&stream, Frame.init(false, .text, null, &first), .{ 0x21, 0x22, 0x23, 0x24 });
    try append_masked(&stream, Frame.ping(&ping_payload), .{ 0x25, 0x26, 0x27, 0x28 });
    try append_masked(&stream, Frame.text(&text_payload), .{ 0x29, 0x2a, 0x2b, 0x2c });

    var reader = stream.reader();
    var parts: SplitRig(32, 2, 32, 8, 0, 32) = .{};
    try parts.init(&reader, .{ .role = .server, .options = .{ .auto_pong = false } });

    var collector = try split.FragmentCollectorRead.init(parts.split.read, &parts.message_buffer);
    const ping = try collector.read_frame(&parts.split.write);
    try std.testing.expectEqual(split.OpCode.ping, ping.opcode);
    try std.testing.expectEqual(@as(usize, 2), collector.message_len());
    try std.testing.expect(!collector.is_at_frame_boundary());

    collector.reset();
    try std.testing.expectEqual(@as(usize, 0), collector.message_len());
    try std.testing.expect(collector.is_at_frame_boundary());

    const message = try collector.read_frame(&parts.split.write);
    try std.testing.expectEqual(split.OpCode.text, message.opcode);
    try std.testing.expectEqualStrings("ok", message.payload);
    try std.testing.expectEqual(@as(usize, 0), parts.writer.written);
}

test "Split: FragmentCollectorRead latches an accumulation failure until reset" {
    var stream: EncodedStream(16) = .{};
    var payload = [_]u8{ 'a', 'b', 'c', 'd', 'e' };
    try append_masked(&stream, Frame.init(false, .text, null, &payload), .{ 0x31, 0x32, 0x33, 0x34 });

    var reader = stream.reader();
    var parts: SplitRig(16, 1, 32, 8, 0, 8) = .{};
    try parts.init(&reader, .{ .role = .server });

    var collector = try split.FragmentCollectorRead.init(parts.split.read, parts.message_buffer[0..4]);

    try std.testing.expectError(error.BufferTooShort, collector.read_frame(&parts.split.write));
    try std.testing.expectEqual(@as(?WebSocketError, error.BufferTooShort), collector.failure);
    const seek_after_failure = reader.seek;

    try std.testing.expectError(error.BufferTooShort, collector.read_frame(&parts.split.write));
    try std.testing.expectEqual(seek_after_failure, reader.seek);
    try std.testing.expectEqual(@as(?WebSocketError, error.BufferTooShort), collector.failure);

    collector.reset();
    try std.testing.expectEqual(@as(?WebSocketError, null), collector.failure);
    try std.testing.expect(collector.is_at_frame_boundary());
}

test "Split: FragmentCollectorRead does not latch ConnectionClosed before a peer close" {
    var stream: EncodedStream(64) = .{};
    var local_close_storage: [8]u8 = undefined;
    var text_payload = [_]u8{ 'o', 'k' };
    var peer_close_storage: [8]u8 = undefined;
    try append_masked(&stream, Frame.text(&text_payload), .{ 0x71, 0x72, 0x73, 0x74 });
    try append_masked(&stream, try Frame.close(1000, "peer", &peer_close_storage), .{ 0x75, 0x76, 0x77, 0x78 });

    var reader = stream.reader();
    var parts: SplitRig(32, 2, 32, 8, 0, 32) = .{};
    try parts.init(&reader, .{ .role = .server });

    try parts.split.write_frame(try Frame.close(1000, "local", &local_close_storage));

    var collector = try split.FragmentCollectorRead.init(parts.split.read, &parts.message_buffer);

    try std.testing.expectError(error.ConnectionClosed, collector.read_frame(&parts.split.write));
    try std.testing.expectEqual(@as(?WebSocketError, null), collector.failure);

    const received = try collector.read_frame(&parts.split.write);
    try std.testing.expectEqual(split.OpCode.close, received.opcode);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xe8, 'p', 'e', 'e', 'r' }, received.payload);
    try std.testing.expectEqual(@as(?WebSocketError, null), collector.failure);
}

test "Split: FragmentCollectorRead does not latch a zero-max FrameTooLarge" {
    var stream: EncodedStream(16) = .{};
    var text_payload = [_]u8{ 'o', 'k' };
    try append_masked(&stream, Frame.text(&text_payload), .{ 0x79, 0x7a, 0x7b, 0x7c });

    var reader = stream.reader();
    var parts: SplitRig(16, 1, 32, 8, 0, 8) = .{};
    try parts.init(&reader, .{ .role = .server, .options = .{ .max_message_size = 0 } });

    var collector = try split.FragmentCollectorRead.init(parts.split.read, &parts.message_buffer);

    try std.testing.expectError(error.FrameTooLarge, collector.read_frame(&parts.split.write));
    try std.testing.expectEqual(@as(?WebSocketError, null), collector.failure);
    try std.testing.expectEqual(@as(usize, 0), reader.seek);

    collector.read.set_max_message_size(8);
    const received = try collector.read_frame(&parts.split.write);
    try std.testing.expectEqual(split.OpCode.text, received.opcode);
    try std.testing.expectEqualStrings("ok", received.payload);
    try std.testing.expectEqual(@as(?WebSocketError, null), collector.failure);
}

test "Split: public module re-exports the split surface" {
    const root = @import("tachyon");

    try std.testing.expect(root.Split == split.Split);
    try std.testing.expect(root.WebSocketRead == split.WebSocketRead);
    try std.testing.expect(root.WebSocketWrite == split.WebSocketWrite);
    try std.testing.expect(root.FragmentCollectorRead == split.FragmentCollectorRead);
    try std.testing.expect(root.SplitStorage == split.Storage);
    try std.testing.expect(root.SplitReadStorage == split.ReadStorage);
    try std.testing.expect(root.SplitWriteStorage == split.WriteStorage);
    try std.testing.expect(root.SplitOptions == split.Options);
    try std.testing.expect(root.SplitConfig == split.Config);
    try std.testing.expect(root.after_handshake_split == split.after_handshake_split);
}

test "Split: setters apply to both halves and remain reachable on each half" {
    var empty = std.Io.Reader.fixed("");
    var parts: SplitRig(16, 2, 32, 8, 0, 64) = .{};
    try parts.init(&empty, .{ .role = .server });

    // The split-level setters reach the half that owns each option. Inbound
    // close and pong policy belong to the read half; vectored writes belong to
    // the write half; masking and the writev threshold are shared.
    try std.testing.expect(parts.split.read.inner.options.auto_close);
    try std.testing.expect(parts.split.write.inner.options.auto_close);

    parts.split.set_auto_close(false);
    try std.testing.expect(!parts.split.read.inner.options.auto_close);
    try std.testing.expect(parts.split.write.inner.options.auto_close);

    parts.split.set_auto_pong(false);
    try std.testing.expect(!parts.split.read.inner.options.auto_pong);
    try std.testing.expect(parts.split.write.inner.options.auto_pong);

    parts.split.set_auto_apply_mask(false);
    try std.testing.expect(!parts.split.read.inner.options.auto_apply_mask);
    try std.testing.expect(!parts.split.write.inner.options.auto_apply_mask);

    parts.split.set_writev(false);
    try std.testing.expect(parts.split.read.inner.options.writev);
    try std.testing.expect(!parts.split.write.inner.options.writev);

    parts.split.set_writev_threshold(7);
    try std.testing.expectEqual(@as(usize, 7), parts.split.read.inner.options.writev_threshold);
    try std.testing.expectEqual(@as(usize, 7), parts.split.write.inner.options.writev_threshold);

    parts.split.set_max_message_size(123);
    try std.testing.expectEqual(@as(usize, 123), parts.split.read.max_message_size());
    try std.testing.expectEqual(@as(usize, 123), parts.split.write.max_message_size());

    parts.split.read.set_max_message_size(45);
    try std.testing.expectEqual(@as(usize, 45), parts.split.read.max_message_size());
    try std.testing.expectEqual(@as(usize, 123), parts.split.write.max_message_size());

    parts.split.write.set_max_message_size(67);
    try std.testing.expectEqual(@as(usize, 45), parts.split.read.max_message_size());
    try std.testing.expectEqual(@as(usize, 67), parts.split.write.max_message_size());

    parts.split.set_max_message_size(128);
    try std.testing.expectEqual(@as(usize, 128), parts.split.read.max_message_size());
    try std.testing.expectEqual(@as(usize, 128), parts.split.write.max_message_size());

    parts.split.read.set_writev_threshold(0);
    parts.split.read.set_auto_apply_mask(true);
    parts.split.read.set_auto_close(true);
    parts.split.read.set_auto_pong(true);
    parts.split.write.set_writev(false);
    parts.split.write.set_writev_threshold(0);
    parts.split.write.set_auto_apply_mask(true);
    parts.split.set_writev(false);
    parts.split.set_writev_threshold(0);
    parts.split.set_auto_apply_mask(true);

    var payload = [_]u8{ 'a', 'b', 'c', 'd' };
    try parts.split.write_frame(Frame.text(&payload));
    try std.testing.expectEqual(@as(usize, 1), parts.writer.max_iovecs);
    try std.testing.expectEqual(@as(usize, 1), parts.writer.drain_calls);
}

test "Split: server read honors the exclusive maximum at short and extended lengths" {
    var stream: EncodedStream(512) = .{};
    const lengths = [_]usize{ 0, 1, 125, 126 };
    const keys = [_]MaskingKey{
        .{ 0x01, 0x02, 0x03, 0x04 },
        .{ 0x05, 0x06, 0x07, 0x08 },
        .{ 0x09, 0x0a, 0x0b, 0x0c },
        .{ 0x0d, 0x0e, 0x0f, 0x10 },
    };
    for (lengths, keys) |len, key| {
        var payload: [126]u8 = @splat(0x41);
        try append_masked(&stream, Frame.binary(payload[0..len]), key);
    }

    var max_payload: [127]u8 = @splat(0x41);
    try append_masked(&stream, Frame.binary(&max_payload), .{ 0x11, 0x12, 0x13, 0x14 });

    var reader = stream.reader();
    var parts: SplitRig(126, 2, 32, 8, 0, 8) = .{};
    try parts.init(&reader, .{ .role = .server, .options = .{ .max_message_size = 127 } });

    const expected: [126]u8 = @splat(0x41);
    for (lengths) |len| {
        const received = try parts.split.read_frame();
        try std.testing.expectEqual(split.OpCode.binary, received.opcode);
        try std.testing.expectEqual(len, received.payload.len);
        try std.testing.expectEqualSlices(u8, expected[0..len], received.payload);
    }

    try std.testing.expectError(error.FrameTooLarge, parts.split.read_frame());
}

test "Split: FragmentCollectorRead rejects a message buffer overlapping the reader buffer" {
    var input: [16]u8 = undefined;
    var reader = std.Io.Reader.fixed(&input);
    var parts: SplitRig(16, 1, 32, 8, 0, 8) = .{};
    try parts.init(&reader, .{ .role = .server });

    try std.testing.expectError(
        error.InvalidLength,
        split.FragmentCollectorRead.init(parts.split.read, &input),
    );
}
