const std = @import("std");
const zslay = @import("zslay");
const tachyon = @import("tachyon");

const support = @import("../support.zig");

const connection = tachyon.connection;
const split = tachyon.split;
const Frame = tachyon.Frame;
const MaskingKey = tachyon.MaskingKey;
const WebSocketError = tachyon.WebSocketError;
const EncodedStream = support.EncodedStream;
const next_wire_frame = support.next_wire_frame;
const append_masked = support.append_masked;
const SplitRig = support.SplitRig;

test "Split: server pair reads a masked client frame and writes an unmasked reply" {
    var stream: EncodedStream(32) = .{};
    var inbound = [_]u8{ 'h', 'i' };
    try append_masked(&stream, Frame.text(&inbound), .{ 0x01, 0x02, 0x03, 0x04 });

    var reader = stream.reader();
    var parts: SplitRig(64, 2, 32, 8, 0, 64) = .{};
    try parts.init(&reader, .{ .role = .server });

    const received = try parts.split.read_frame();
    try std.testing.expectEqual(split.OpCode.text, received.opcode);
    try std.testing.expect(received.fin);
    try std.testing.expectEqual(@as(?split.MaskingKey, null), received.masking_key);
    try std.testing.expectEqualStrings("hi", received.payload);
    try std.testing.expectEqual(@as(usize, 0), parts.writer.written);

    var outbound = [_]u8{ 'o', 'k' };
    try parts.split.write_frame(Frame.text(&outbound));
    try parts.split.flush();

    var index: usize = 0;
    const wire = try next_wire_frame(parts.bytes(), &index);
    try std.testing.expectEqual(split.OpCode.text, split.OpCode.from_wire(wire.header.header.opcode).?);
    try std.testing.expect(!wire.header.header.mask);
    try std.testing.expectEqual(@as(?split.MaskingKey, null), wire.header.masking_key);
    try std.testing.expectEqualStrings("ok", wire.payload);
    try std.testing.expectEqual(parts.writer.written, index);
}

test "Split: client pair masks writes on the key schedule and reads clear inbound frames" {
    const seed: [connection.mask_seed_len]u8 = @splat(0x2a);
    var empty = std.Io.Reader.fixed("");
    var parts: SplitRig(32, 2, 64, 8, 16, 64) = .{};
    try parts.init(&empty, .{
        .role = .client,
        .mask_keys = connection.MaskKeySource.from_seed(seed),
    });

    var expected_keys = connection.MaskKeySource.from_seed(seed);
    const first_key = expected_keys.next();

    var first_payload = [_]u8{ 'h', 'i' };
    try parts.split.write_frame(Frame.text(&first_payload));

    var index: usize = 0;
    const first = try next_wire_frame(parts.bytes(), &index);
    try std.testing.expect(first.header.header.mask);
    try std.testing.expectEqualSlices(u8, &first_key, &first.header.masking_key.?);
    try std.testing.expectEqual(@as(u8, 'h' ^ first_key[0]), first.payload[0]);
    try std.testing.expectEqual(@as(u8, 'i' ^ first_key[1]), first.payload[1]);

    var plaintext: [2]u8 = undefined;
    @memcpy(&plaintext, first.payload);
    zslay.mask(&plaintext, first_key, 0);
    try std.testing.expectEqualStrings("hi", &plaintext);

    const written_after_first = parts.writer.written;
    var inbound: EncodedStream(16) = .{};
    var inbound_payload = [_]u8{ 'o', 'k' };
    try inbound.append(Frame.text(&inbound_payload));
    empty = inbound.reader();

    const received = try parts.split.read_frame();
    try std.testing.expectEqual(split.OpCode.text, received.opcode);
    try std.testing.expectEqual(@as(?split.MaskingKey, null), received.masking_key);
    try std.testing.expectEqualStrings("ok", received.payload);
    try std.testing.expectEqual(written_after_first, parts.writer.written);

    var second_payload = [_]u8{ 'g', 'o' };
    try parts.split.write_frame(Frame.text(&second_payload));

    const second_key = expected_keys.next();
    const second = try next_wire_frame(parts.bytes(), &index);
    try std.testing.expect(second.header.header.mask);
    try std.testing.expectEqualSlices(u8, &second_key, &second.header.masking_key.?);
    try std.testing.expectEqual(parts.writer.written, index);
}

test "Split: read_frame forwards an exact pong through the write half and suppresses the ping" {
    var stream: EncodedStream(32) = .{};
    var ping_payload = [_]u8{ 'h', 'i' };
    var text_payload = [_]u8{ 'o', 'k' };
    try append_masked(&stream, Frame.ping(&ping_payload), .{ 0x01, 0x02, 0x03, 0x04 });
    try append_masked(&stream, Frame.text(&text_payload), .{ 0x05, 0x06, 0x07, 0x08 });

    var reader = stream.reader();
    var parts: SplitRig(32, 2, 32, 8, 0, 32) = .{};
    try parts.init(&reader, .{ .role = .server });

    const received = try parts.split.read_frame();
    try std.testing.expectEqual(split.OpCode.text, received.opcode);
    try std.testing.expectEqualStrings("ok", received.payload);

    var index: usize = 0;
    const pong = try next_wire_frame(parts.bytes(), &index);
    try std.testing.expectEqual(split.OpCode.pong, split.OpCode.from_wire(pong.header.header.opcode).?);
    try std.testing.expect(!pong.header.header.mask);
    try std.testing.expectEqual(@as(?split.MaskingKey, null), pong.header.masking_key);
    try std.testing.expectEqualStrings("hi", pong.payload);
    try std.testing.expectEqual(parts.writer.written, index);
    try std.testing.expectEqual(@as(usize, 0), parts.split.write.tx_pending());
}

test "Split: auto_pong off delivers the ping and writes nothing" {
    var stream: EncodedStream(16) = .{};
    var ping_payload = [_]u8{ 'h', 'i' };
    try append_masked(&stream, Frame.ping(&ping_payload), .{ 0x09, 0x0a, 0x0b, 0x0c });

    var reader = stream.reader();
    var parts: SplitRig(16, 1, 32, 8, 0, 16) = .{};
    try parts.init(&reader, .{ .role = .server, .options = .{ .auto_pong = false } });

    const received = try parts.split.read_frame();
    try std.testing.expectEqual(split.OpCode.ping, received.opcode);
    try std.testing.expect(received.fin);
    try std.testing.expectEqual(@as(?split.MaskingKey, null), received.masking_key);
    try std.testing.expectEqualStrings("hi", received.payload);
    try std.testing.expectEqual(@as(usize, 0), parts.writer.written);
    try std.testing.expect(!parts.split.is_closed());
    try std.testing.expect(parts.split.is_at_wire_boundary());
}

test "Split: auto_close echoes a valid close through the write half and gates later reads" {
    var stream: EncodedStream(32) = .{};
    var close_storage: [8]u8 = undefined;
    var text_payload = [_]u8{'x'};
    try append_masked(&stream, try Frame.close(1000, "bye", &close_storage), .{ 0xa1, 0xb2, 0xc3, 0xd4 });
    try append_masked(&stream, Frame.text(&text_payload), .{ 0x11, 0x22, 0x33, 0x44 });

    var reader = stream.reader();
    var parts: SplitRig(32, 2, 32, 8, 0, 32) = .{};
    try parts.init(&reader, .{ .role = .server });

    const received = try parts.split.read_frame();
    try std.testing.expectEqual(split.OpCode.close, received.opcode);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xe8, 'b', 'y', 'e' }, received.payload);
    try std.testing.expect(parts.split.write.is_closed());
    try std.testing.expect(parts.split.is_closed());

    var index: usize = 0;
    const echo = try next_wire_frame(parts.bytes(), &index);
    try std.testing.expectEqual(split.OpCode.close, split.OpCode.from_wire(echo.header.header.opcode).?);
    try std.testing.expect(!echo.header.header.mask);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xe8, 'b', 'y', 'e' }, echo.payload);
    try std.testing.expectEqual(parts.writer.written, index);

    const written_after_close = parts.writer.written;
    try std.testing.expectError(error.ConnectionClosed, parts.split.read_frame());
    try std.testing.expectEqual(written_after_close, parts.writer.written);
}

test "Split: invalid close code sends a masked 1002 with the reason and closes the write half" {
    const seed: [connection.mask_seed_len]u8 = @splat(0x48);
    var stream: EncodedStream(16) = .{};
    var payload = [_]u8{ 0x03, 0xe7, 'b', 'a', 'd' };
    try stream.append(Frame.close_raw(&payload));

    var reader = stream.reader();
    var parts: SplitRig(16, 2, 32, 8, 0, 32) = .{};
    try parts.init(&reader, .{
        .role = .client,
        .mask_keys = connection.MaskKeySource.from_seed(seed),
    });

    try std.testing.expectError(error.InvalidCloseCode, parts.split.read_frame());
    try std.testing.expect(parts.split.write.is_closed());

    var index: usize = 0;
    const reply = try next_wire_frame(parts.bytes(), &index);
    try std.testing.expect(reply.header.header.mask);
    const key = reply.header.masking_key.?;
    try std.testing.expectEqual(@as(usize, 5), reply.payload.len);

    var plaintext: [5]u8 = undefined;
    @memcpy(&plaintext, reply.payload);
    zslay.mask(&plaintext, key, 0);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xea, 'b', 'a', 'd' }, &plaintext);
    try std.testing.expectEqual(parts.writer.written, index);
}

test "Split: successful 1002 through an external sink is terminal and latched" {
    const CountingSink = struct {
        sent: usize = 0,

        pub fn send_obligation(self: *@This(), outgoing: Frame) WebSocketError!void {
            _ = outgoing;
            self.sent += 1;
        }

        pub fn is_closed(self: *const @This()) bool {
            _ = self;
            return false;
        }

        pub fn failure(self: *const @This()) ?WebSocketError {
            _ = self;
            return null;
        }
    };

    var stream: EncodedStream(32) = .{};
    var close_payload = [_]u8{ 0x03, 0xe7, 'b', 'a', 'd' };
    var trailing = [_]u8{'x'};
    try append_masked(&stream, Frame.close_raw(&close_payload), .{ 0x81, 0x82, 0x83, 0x84 });
    try append_masked(&stream, Frame.text(&trailing), .{ 0x85, 0x86, 0x87, 0x88 });

    var reader = stream.reader();
    var parts: SplitRig(32, 2, 32, 8, 0, 32) = .{};
    try parts.init(&reader, .{ .role = .server });

    var sink: CountingSink = .{};
    try std.testing.expectError(error.InvalidCloseCode, parts.split.read_frame_with(&sink));
    try std.testing.expectEqual(@as(usize, 1), sink.sent);
    try std.testing.expectEqual(@as(?WebSocketError, error.InvalidCloseCode), parts.split.read.inner.read_failure);
    try std.testing.expect(parts.split.read.inner.is_closed());
    try std.testing.expect(parts.split.is_closed());
    const seek_after_first = reader.seek;

    var text = [_]u8{'y'};
    try std.testing.expectError(error.ConnectionClosed, parts.split.write_frame(Frame.text(&text)));

    try std.testing.expectError(error.InvalidCloseCode, parts.split.read_frame_with(&sink));
    try std.testing.expectEqual(seek_after_first, reader.seek);
    try std.testing.expectEqual(@as(usize, 1), sink.sent);
}

test "Split: successful 1002 through the internal write half latches InvalidCloseCode" {
    const seed: [connection.mask_seed_len]u8 = @splat(0x47);
    const wire_key: MaskingKey = .{ 0x21, 0x22, 0x23, 0x24 };
    var stream: EncodedStream(16) = .{};
    var payload = [_]u8{ 0x03, 0xe7, 'b', 'a', 'd' };
    var trailing = [_]u8{ 'o', 'k' };
    try stream.append(Frame.close_raw(&payload));
    try append_masked(&stream, Frame.text(&trailing), wire_key);

    var reader = stream.reader();
    var parts: SplitRig(16, 2, 32, 8, 0, 32) = .{};
    try parts.init(&reader, .{
        .role = .client,
        .mask_keys = connection.MaskKeySource.from_seed(seed),
    });

    try std.testing.expectError(error.InvalidCloseCode, parts.split.read_frame());
    try std.testing.expectEqual(@as(?WebSocketError, error.InvalidCloseCode), parts.split.read.inner.read_failure);
    try std.testing.expectEqual(@as(?WebSocketError, null), parts.split.write.failure());
    try std.testing.expect(parts.split.write.is_closed());
    const seek_after_first = reader.seek;

    try std.testing.expectError(error.InvalidCloseCode, parts.split.read_frame());
    try std.testing.expectEqual(seek_after_first, reader.seek);
}

test "Split: invalid UTF-8 close reason returns InvalidUTF8 with no output" {
    var stream: EncodedStream(16) = .{};
    var payload = [_]u8{ 0x03, 0xe8, 0xff };
    try append_masked(&stream, Frame.close_raw(&payload), .{ 0x1a, 0x2b, 0x3c, 0x4d });

    var reader = stream.reader();
    var parts: SplitRig(16, 2, 32, 8, 0, 16) = .{};
    try parts.init(&reader, .{ .role = .server });

    try std.testing.expectError(error.InvalidUTF8, parts.split.read_frame());
    try std.testing.expectEqual(@as(usize, 0), parts.writer.written);
    try std.testing.expect(!parts.split.write.is_closed());
    try std.testing.expect(parts.split.is_at_wire_boundary());
    const seek_after_failure = reader.seek;

    try std.testing.expectError(error.InvalidUTF8, parts.split.read_frame());
    try std.testing.expectEqual(seek_after_failure, reader.seek);
    try std.testing.expectEqual(@as(usize, 0), parts.writer.written);
}

test "Split: client auto_apply_mask off delivers control frames without replies" {
    const seed: [connection.mask_seed_len]u8 = @splat(0x3c);
    var stream: EncodedStream(32) = .{};
    var ping_payload = [_]u8{ 'h', 'i' };
    var close_storage: [8]u8 = undefined;
    var text_payload = [_]u8{'x'};
    try stream.append(Frame.ping(&ping_payload));
    try stream.append(try Frame.close(1000, "bye", &close_storage));
    try stream.append(Frame.text(&text_payload));

    var reader = stream.reader();
    var parts: SplitRig(32, 2, 32, 8, 0, 32) = .{};
    try parts.init(&reader, .{
        .role = .client,
        .options = .{ .auto_apply_mask = false },
        .mask_keys = connection.MaskKeySource.from_seed(seed),
    });

    const ping = try parts.split.read_frame();
    try std.testing.expectEqual(split.OpCode.ping, ping.opcode);
    try std.testing.expectEqualStrings("hi", ping.payload);
    try std.testing.expectEqual(@as(usize, 0), parts.writer.written);
    try std.testing.expect(!parts.split.is_closed());

    const close = try parts.split.read_frame();
    try std.testing.expectEqual(split.OpCode.close, close.opcode);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xe8, 'b', 'y', 'e' }, close.payload);
    try std.testing.expectEqual(@as(usize, 0), parts.writer.written);
    try std.testing.expect(parts.split.is_closed());
    try std.testing.expect(!parts.split.write.is_closed());

    try std.testing.expectError(error.ConnectionClosed, parts.split.read_frame());
    try std.testing.expectEqual(@as(usize, 0), parts.writer.written);
}

test "Split: auto_apply_mask off delivers masked frames and skips control policy" {
    const key: MaskingKey = .{ 0x11, 0x22, 0x33, 0x44 };
    var stream: EncodedStream(64) = .{};
    var text_payload = [_]u8{ 'h', 'i' };
    var ping_payload = [_]u8{'p'};
    var close_storage: [8]u8 = undefined;
    try append_masked(&stream, Frame.text(&text_payload), key);
    try append_masked(&stream, Frame.ping(&ping_payload), key);
    try append_masked(&stream, try Frame.close(1000, "bye", &close_storage), key);

    var reader = stream.reader();
    var parts: SplitRig(32, 2, 32, 8, 0, 8) = .{};
    try parts.init(&reader, .{ .role = .server, .options = .{ .auto_apply_mask = false } });

    var plaintext: [8]u8 = undefined;

    const text = try parts.split.read_frame();
    try std.testing.expectEqual(split.OpCode.text, text.opcode);
    try std.testing.expectEqual(@as(?split.MaskingKey, key), text.masking_key);
    @memcpy(plaintext[0..text.payload.len], text.payload);
    zslay.mask(plaintext[0..text.payload.len], key, 0);
    try std.testing.expectEqualStrings("hi", plaintext[0..text.payload.len]);

    const ping = try parts.split.read_frame();
    try std.testing.expectEqual(split.OpCode.ping, ping.opcode);
    try std.testing.expectEqual(@as(?split.MaskingKey, key), ping.masking_key);
    @memcpy(plaintext[0..ping.payload.len], ping.payload);
    zslay.mask(plaintext[0..ping.payload.len], key, 0);
    try std.testing.expectEqualStrings("p", plaintext[0..ping.payload.len]);
    try std.testing.expectEqual(@as(usize, 0), parts.writer.written);

    const close = try parts.split.read_frame();
    try std.testing.expectEqual(split.OpCode.close, close.opcode);
    try std.testing.expectEqual(@as(?split.MaskingKey, key), close.masking_key);
    @memcpy(plaintext[0..close.payload.len], close.payload);
    zslay.mask(plaintext[0..close.payload.len], key, 0);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xe8, 'b', 'y', 'e' }, plaintext[0..close.payload.len]);
    try std.testing.expectEqual(@as(usize, 0), parts.writer.written);
    try std.testing.expect(!parts.split.is_closed());
}

test "Split: automatic pong prepare failure latches the read half" {
    const seed: [connection.mask_seed_len]u8 = @splat(0x4e);
    var stream: EncodedStream(16) = .{};
    var ping_payload = [_]u8{ 'p', 'i', 'n', 'g' };
    try stream.append(Frame.ping(&ping_payload));

    var reader = stream.reader();
    var parts: SplitRig(16, 2, 32, 8, 0, 16) = .{};
    try parts.init(&reader, .{
        .role = .client,
        .mask_keys = connection.MaskKeySource.from_seed(seed),
    });
    parts.split.write.set_auto_apply_mask(false);

    try std.testing.expectError(error.PayloadNotMasked, parts.split.read_frame());
    try std.testing.expectEqual(@as(?WebSocketError, error.PayloadNotMasked), parts.split.read.inner.read_failure);
    try std.testing.expectEqual(@as(?WebSocketError, null), parts.split.write.failure());
    try std.testing.expectEqual(@as(usize, 0), parts.writer.written);

    try std.testing.expectError(error.PayloadNotMasked, parts.split.read_frame());
    try std.testing.expectEqual(@as(?WebSocketError, error.PayloadNotMasked), parts.split.read.inner.read_failure);
    try std.testing.expectEqual(@as(usize, 0), parts.writer.written);
}

test "Split: failed 1002 send leaves the read latch clear until reset_tx" {
    const seed: [connection.mask_seed_len]u8 = @splat(0x5e);
    var stream: EncodedStream(32) = .{};
    var close_payload = [_]u8{ 0x03, 0xe7, 'b', 'a', 'd' };
    var text_payload = [_]u8{ 'o', 'k' };
    try stream.append(Frame.close_raw(&close_payload));
    try stream.append(Frame.text(&text_payload));

    var reader = stream.reader();
    var parts: SplitRig(16, 2, 32, 8, 0, 16) = .{};
    try parts.init(&reader, .{
        .role = .client,
        .mask_keys = connection.MaskKeySource.from_seed(seed),
    });
    parts.writer.fail_after = 0;

    try std.testing.expectError(error.IoError, parts.split.read_frame());
    try std.testing.expectEqual(@as(?WebSocketError, null), parts.split.read.inner.read_failure);
    try std.testing.expectEqual(@as(?WebSocketError, error.IoError), parts.split.write.failure());
    try std.testing.expectEqual(@as(usize, 0), parts.writer.written);

    parts.split.reset_tx();
    try std.testing.expectEqual(@as(?WebSocketError, null), parts.split.write.failure());

    const received = try parts.split.read_frame();
    try std.testing.expectEqual(split.OpCode.text, received.opcode);
    try std.testing.expectEqualStrings("ok", received.payload);
}

test "Split: FragmentCollectorRead does not latch a sink transport failure" {
    var stream: EncodedStream(32) = .{};
    var ping_payload = [_]u8{'p'};
    var text_payload = [_]u8{ 'o', 'k' };
    try append_masked(&stream, Frame.ping(&ping_payload), .{ 0x91, 0x92, 0x93, 0x94 });
    try append_masked(&stream, Frame.text(&text_payload), .{ 0x95, 0x96, 0x97, 0x98 });

    var reader = stream.reader();
    var parts: SplitRig(32, 2, 32, 8, 0, 32) = .{};
    try parts.init(&reader, .{ .role = .server });
    parts.writer.fail_after = 0;

    var collector = try split.FragmentCollectorRead.init(parts.split.read, &parts.message_buffer);

    try std.testing.expectError(error.IoError, collector.read_frame(&parts.split.write));
    try std.testing.expectEqual(@as(?WebSocketError, null), collector.failure);
    try std.testing.expectEqual(@as(?WebSocketError, null), collector.read.inner.read_failure);
    try std.testing.expectEqual(@as(?WebSocketError, null), parts.split.read.inner.read_failure);
    try std.testing.expectEqual(@as(?WebSocketError, error.IoError), parts.split.write.failure());
    try std.testing.expectEqual(@as(usize, 0), parts.writer.written);

    parts.split.reset_tx();

    const received = try collector.read_frame(&parts.split.write);
    try std.testing.expectEqual(split.OpCode.text, received.opcode);
    try std.testing.expectEqualStrings("ok", received.payload);
}

test "Split: read_frame_with an external sink records the close in the read half" {
    const CountingSink = struct {
        sent: usize = 0,

        pub fn send_obligation(self: *@This(), outgoing: Frame) WebSocketError!void {
            _ = outgoing;
            self.sent += 1;
        }

        pub fn is_closed(self: *const @This()) bool {
            _ = self;
            return false;
        }

        pub fn failure(self: *const @This()) ?WebSocketError {
            _ = self;
            return null;
        }
    };

    var stream: EncodedStream(32) = .{};
    var close_storage: [8]u8 = undefined;
    var trailing = [_]u8{'x'};
    try append_masked(&stream, try Frame.close(1000, "bye", &close_storage), .{ 0x61, 0x62, 0x63, 0x64 });
    try append_masked(&stream, Frame.text(&trailing), .{ 0x65, 0x66, 0x67, 0x68 });

    var reader = stream.reader();
    var parts: SplitRig(32, 2, 32, 8, 0, 32) = .{};
    try parts.init(&reader, .{ .role = .server });

    var sink: CountingSink = .{};
    const received = try parts.split.read_frame_with(&sink);
    try std.testing.expectEqual(split.OpCode.close, received.opcode);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xe8, 'b', 'y', 'e' }, received.payload);
    try std.testing.expectEqual(@as(usize, 1), sink.sent);
    try std.testing.expect(parts.split.is_closed());
    try std.testing.expectEqual(@as(usize, 0), parts.writer.written);

    var text = [_]u8{'x'};
    try std.testing.expectError(error.ConnectionClosed, parts.split.write_frame(Frame.text(&text)));
    try std.testing.expectError(error.ConnectionClosed, parts.split.read_frame());
}

test "Split: client pong masking uses the write-half key schedule" {
    const seed: [connection.mask_seed_len]u8 = @splat(0x6e);
    var stream: EncodedStream(32) = .{};
    var ping_payload = [_]u8{ 'p', 'i', 'n', 'g' };
    var text_payload = [_]u8{ 'o', 'k' };
    try stream.append(Frame.ping(&ping_payload));
    try stream.append(Frame.text(&text_payload));

    var reader = stream.reader();
    var parts: SplitRig(32, 2, 32, 8, 16, 32) = .{};
    try parts.init(&reader, .{
        .role = .client,
        .mask_keys = connection.MaskKeySource.from_seed(seed),
    });

    var expected_keys = connection.MaskKeySource.from_seed(seed);
    const expected_key = expected_keys.next();

    const received = try parts.split.read_frame();
    try std.testing.expectEqual(split.OpCode.text, received.opcode);
    try std.testing.expectEqualStrings("ok", received.payload);

    var index: usize = 0;
    const pong = try next_wire_frame(parts.bytes(), &index);
    try std.testing.expectEqual(split.OpCode.pong, split.OpCode.from_wire(pong.header.header.opcode).?);
    try std.testing.expect(pong.header.header.mask);
    try std.testing.expectEqualSlices(u8, &expected_key, &pong.header.masking_key.?);

    var plaintext: [4]u8 = undefined;
    @memcpy(&plaintext, pong.payload);
    zslay.mask(&plaintext, expected_key, 0);
    try std.testing.expectEqualStrings("ping", &plaintext);
    try std.testing.expectEqual(parts.writer.written, index);
}

test "Split: rejects read and write storage that overlap" {
    var reader = std.Io.Reader.fixed("");
    var out: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out);

    var shared: [32]u8 = undefined;
    var read_close: [2]u8 = undefined;
    var compose: [32]u8 = undefined;
    var write_close: [2]u8 = undefined;
    var nodes: [1]zslay.FrameNode = undefined;

    try std.testing.expectError(error.InvalidLength, split.after_handshake_split(&reader, &writer, .{
        .read = .{
            .frame_buffer = &shared,
            .close_buffer = &read_close,
            .compose_buffer = &compose,
        },
        .write = .{
            .tx_nodes = &nodes,
            .write_buffer = &shared,
            .close_buffer = &write_close,
        },
    }, .{ .role = .server }));
}
