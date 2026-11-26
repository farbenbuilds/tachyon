const std = @import("std");
const tachyon = @import("tachyon");

const support = @import("../support.zig");

const message = tachyon.stream;
const connection = tachyon.connection;
const Frame = tachyon.Frame;
const EncodedStream = support.EncodedStream;
const ConnectionRig = support.ConnectionRig;
const append_masked = support.append_masked;
const next_wire_frame = support.next_wire_frame;

fn expect_chunk(chunks: *message.MessageReader) !message.Chunk {
    return switch (try chunks.next()) {
        .chunk => |chunk| chunk,
        else => error.UnexpectedEvent,
    };
}

fn expect_control(chunks: *message.MessageReader) !Frame {
    return switch (try chunks.next()) {
        .control => |incoming| incoming,
        else => error.UnexpectedEvent,
    };
}

fn expect_close(chunks: *message.MessageReader) !Frame {
    return switch (try chunks.next()) {
        .close => |incoming| incoming,
        else => error.UnexpectedEvent,
    };
}

fn wire_opcode(incoming: support.WireFrame) !tachyon.OpCode {
    return tachyon.OpCode.from_wire(incoming.header.header.opcode) orelse error.InvalidOpcode;
}

test "Stream: ping interleaves without disturbing message state" {
    var stream: EncodedStream(64) = .{};
    var first = [_]u8{'a'};
    var ping = [_]u8{'p'};
    var last = [_]u8{'b'};
    try append_masked(&stream, Frame.init(false, .text, null, &first), .{ 0x01, 0x02, 0x03, 0x04 });
    try append_masked(&stream, Frame.ping(&ping), .{ 0x05, 0x06, 0x07, 0x08 });
    try append_masked(&stream, Frame.init(true, .continuation, null, &last), .{ 0x09, 0x0a, 0x0b, 0x0c });

    var reader = stream.reader();
    var rig: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
    try rig.init(&reader, .{ .role = .server, .options = .{ .auto_pong = false } });
    var chunks = message.MessageReader.init(&rig.ws);

    const one = try expect_chunk(&chunks);
    try std.testing.expectEqualStrings("a", one.payload);
    try std.testing.expect(!one.fin);

    const control = try expect_control(&chunks);
    try std.testing.expectEqual(tachyon.OpCode.ping, control.opcode);
    try std.testing.expectEqualStrings("p", control.payload);

    const two = try expect_chunk(&chunks);
    try std.testing.expectEqualStrings("b", two.payload);
    try std.testing.expectEqual(message.MessageKind.text, two.kind);
    try std.testing.expect(two.fin);
    try std.testing.expectEqual(@as(usize, 0), rig.writer.written);
}

test "Stream: auto pong answers an interleaved ping before the next chunk" {
    var stream: EncodedStream(64) = .{};
    var first = [_]u8{'a'};
    var ping = [_]u8{'p'};
    var last = [_]u8{'b'};
    try append_masked(&stream, Frame.init(false, .text, null, &first), .{ 0x01, 0x02, 0x03, 0x04 });
    try append_masked(&stream, Frame.ping(&ping), .{ 0x05, 0x06, 0x07, 0x08 });
    try append_masked(&stream, Frame.init(true, .continuation, null, &last), .{ 0x09, 0x0a, 0x0b, 0x0c });

    var reader = stream.reader();
    var rig: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
    try rig.init(&reader, .{ .role = .server });
    var chunks = message.MessageReader.init(&rig.ws);

    _ = try expect_chunk(&chunks);
    const last_chunk = try expect_chunk(&chunks);
    try std.testing.expectEqualStrings("b", last_chunk.payload);

    var index: usize = 0;
    const pong = try next_wire_frame(rig.bytes(), &index);
    try std.testing.expectEqual(tachyon.OpCode.pong, try wire_opcode(pong));
    try std.testing.expectEqualStrings("p", pong.payload);
    try std.testing.expectEqual(rig.writer.written, index);
}

test "Stream: pong interleaves without disturbing message state" {
    var stream: EncodedStream(64) = .{};
    var first = [_]u8{'a'};
    var pong = [_]u8{'q'};
    var last = [_]u8{'b'};
    try append_masked(&stream, Frame.init(false, .text, null, &first), .{ 0x01, 0x02, 0x03, 0x04 });
    try append_masked(&stream, Frame.pong(&pong), .{ 0x05, 0x06, 0x07, 0x08 });
    try append_masked(&stream, Frame.init(true, .continuation, null, &last), .{ 0x09, 0x0a, 0x0b, 0x0c });

    var reader = stream.reader();
    var rig: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
    try rig.init(&reader, .{ .role = .server });
    var chunks = message.MessageReader.init(&rig.ws);

    _ = try expect_chunk(&chunks);
    const control = try expect_control(&chunks);
    try std.testing.expectEqual(tachyon.OpCode.pong, control.opcode);
    try std.testing.expectEqualStrings("q", control.payload);

    const two = try expect_chunk(&chunks);
    try std.testing.expectEqualStrings("b", two.payload);
    try std.testing.expect(two.fin);
}

test "Stream: control frames between messages are delivered" {
    var stream: EncodedStream(16) = .{};
    var ping = [_]u8{'p'};
    try append_masked(&stream, Frame.ping(&ping), .{ 0x01, 0x02, 0x03, 0x04 });

    var reader = stream.reader();
    var rig: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
    try rig.init(&reader, .{ .role = .server, .options = .{ .auto_pong = false } });
    var chunks = message.MessageReader.init(&rig.ws);

    const control = try expect_control(&chunks);

    try std.testing.expectEqual(tachyon.OpCode.ping, control.opcode);
    try std.testing.expectEqualStrings("p", control.payload);
    try std.testing.expect(chunks.is_idle());
    try std.testing.expectEqual(@as(usize, 0), rig.writer.written);
}

test "Stream: a client that cannot mask receives pings instead of replying" {
    const seed: [connection.mask_seed_len]u8 = @splat(0x31);
    var stream: EncodedStream(16) = .{};
    var ping = [_]u8{'p'};
    try stream.append(Frame.ping(&ping));

    var reader = stream.reader();
    var rig: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
    try rig.init(&reader, .{
        .role = .client,
        .options = .{ .auto_apply_mask = false },
        .mask_keys = connection.MaskKeySource.from_seed(seed),
    });
    var chunks = message.MessageReader.init(&rig.ws);

    const control = try expect_control(&chunks);

    try std.testing.expectEqual(tachyon.OpCode.ping, control.opcode);
    try std.testing.expectEqualStrings("p", control.payload);
    try std.testing.expectEqual(@as(usize, 0), rig.writer.written);
}

test "Stream: close is a close event, not a control event" {
    var stream: EncodedStream(32) = .{};
    var first = [_]u8{'a'};
    var close_storage: [8]u8 = undefined;
    try append_masked(&stream, Frame.init(false, .text, null, &first), .{ 0x01, 0x02, 0x03, 0x04 });
    try append_masked(&stream, try Frame.close(1000, "", &close_storage), .{ 0x05, 0x06, 0x07, 0x08 });

    var reader = stream.reader();
    var rig: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
    try rig.init(&reader, .{ .role = .server });
    var chunks = message.MessageReader.init(&rig.ws);

    _ = try expect_chunk(&chunks);
    const close = try expect_close(&chunks);

    try std.testing.expectEqual(tachyon.OpCode.close, close.opcode);
    try std.testing.expect(chunks.is_closed());
    try std.testing.expectError(error.ConnectionClosed, chunks.next());
}

test "Stream: close payload is the peer payload" {
    var stream: EncodedStream(32) = .{};
    var close_storage: [8]u8 = undefined;
    try append_masked(&stream, try Frame.close(1000, "bye", &close_storage), .{ 0x01, 0x02, 0x03, 0x04 });

    var reader = stream.reader();
    var rig: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
    try rig.init(&reader, .{ .role = .server });
    var chunks = message.MessageReader.init(&rig.ws);

    const close = try expect_close(&chunks);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xe8, 'b', 'y', 'e' }, close.payload);

    var index: usize = 0;
    const echo = try next_wire_frame(rig.bytes(), &index);
    try std.testing.expectEqual(tachyon.OpCode.close, try wire_opcode(echo));
    try std.testing.expectEqualSlices(u8, close.payload, echo.payload);
    try std.testing.expectEqual(rig.writer.written, index);
}

test "Stream: FIN inside a code point returns InvalidUTF8 and latches" {
    var stream: EncodedStream(32) = .{};
    var first = [_]u8{ 'A', 0xc2 };
    var empty = [_]u8{};
    try append_masked(&stream, Frame.init(false, .text, null, &first), .{ 0x01, 0x02, 0x03, 0x04 });
    try append_masked(&stream, Frame.init(true, .continuation, null, &empty), .{ 0x05, 0x06, 0x07, 0x08 });

    var reader = stream.reader();
    var rig: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
    try rig.init(&reader, .{ .role = .server });
    var chunks = message.MessageReader.init(&rig.ws);

    _ = try expect_chunk(&chunks);
    try std.testing.expectError(error.InvalidUTF8, chunks.next());
    try std.testing.expectError(error.InvalidUTF8, chunks.next());
    try std.testing.expect(chunks.is_idle());
}

test "Stream: invalid continuation bytes return InvalidUTF8" {
    var stream: EncodedStream(32) = .{};
    var first = [_]u8{'A'};
    var invalid = [_]u8{0xff};
    try append_masked(&stream, Frame.init(false, .text, null, &first), .{ 0x01, 0x02, 0x03, 0x04 });
    try append_masked(&stream, Frame.init(false, .continuation, null, &invalid), .{ 0x05, 0x06, 0x07, 0x08 });

    var reader = stream.reader();
    var rig: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
    try rig.init(&reader, .{ .role = .server });
    var chunks = message.MessageReader.init(&rig.ws);

    _ = try expect_chunk(&chunks);
    try std.testing.expectError(error.InvalidUTF8, chunks.next());
    try std.testing.expectError(error.InvalidUTF8, chunks.next());
    try std.testing.expect(chunks.is_idle());
}

test "Stream: reset at a frame boundary clears the stream latch" {
    var stream: EncodedStream(32) = .{};
    var invalid = [_]u8{0xff};
    var valid = [_]u8{ 'o', 'k' };
    try append_masked(&stream, Frame.text(&invalid), .{ 0x01, 0x02, 0x03, 0x04 });
    try append_masked(&stream, Frame.text(&valid), .{ 0x05, 0x06, 0x07, 0x08 });

    var reader = stream.reader();
    var rig: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
    try rig.init(&reader, .{ .role = .server });
    var chunks = message.MessageReader.init(&rig.ws);

    try std.testing.expectError(error.InvalidUTF8, chunks.next());
    try std.testing.expect(rig.ws.is_at_wire_boundary());

    chunks.reset();
    const chunk = try expect_chunk(&chunks);
    try std.testing.expectEqualStrings("ok", chunk.payload);
}

test "Stream: unfragmented invalid text propagates the connection error" {
    var stream: EncodedStream(16) = .{};
    var invalid = [_]u8{0xff};
    try append_masked(&stream, Frame.text(&invalid), .{ 0x01, 0x02, 0x03, 0x04 });

    var reader = stream.reader();
    var rig: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
    try rig.init(&reader, .{ .role = .server });
    var chunks = message.MessageReader.init(&rig.ws);

    try std.testing.expectError(error.InvalidUTF8, chunks.next());
    try std.testing.expectError(error.InvalidUTF8, chunks.next());
}

test "Stream: fragmented message at the exclusive limit is accepted" {
    var stream: EncodedStream(32) = .{};
    var first = [_]u8{ 'a', 'b' };
    var last = [_]u8{ 'c', 'd' };
    try append_masked(&stream, Frame.init(false, .text, null, &first), .{ 0x01, 0x02, 0x03, 0x04 });
    try append_masked(&stream, Frame.init(true, .continuation, null, &last), .{ 0x05, 0x06, 0x07, 0x08 });

    var reader = stream.reader();
    var rig: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
    try rig.init(&reader, .{ .role = .server, .options = .{ .max_message_size = 5 } });
    var chunks = message.MessageReader.init(&rig.ws);

    const one = try expect_chunk(&chunks);
    try std.testing.expectEqualStrings("ab", one.payload);
    try std.testing.expect(!one.fin);

    const two = try expect_chunk(&chunks);
    try std.testing.expectEqualStrings("cd", two.payload);
    try std.testing.expect(two.fin);
    try std.testing.expect(chunks.is_idle());
}

test "Stream: fragmented message over the exclusive limit returns FrameTooLarge" {
    var stream: EncodedStream(32) = .{};
    var first = [_]u8{ 'a', 'b', 'c', 'd' };
    var last = [_]u8{'e'};
    try append_masked(&stream, Frame.init(false, .text, null, &first), .{ 0x01, 0x02, 0x03, 0x04 });
    try append_masked(&stream, Frame.init(true, .continuation, null, &last), .{ 0x05, 0x06, 0x07, 0x08 });

    var reader = stream.reader();
    var rig: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
    try rig.init(&reader, .{ .role = .server, .options = .{ .max_message_size = 5 } });
    var chunks = message.MessageReader.init(&rig.ws);

    _ = try expect_chunk(&chunks);
    try std.testing.expectError(error.FrameTooLarge, chunks.next());
    try std.testing.expectError(error.FrameTooLarge, chunks.next());
    try std.testing.expect(chunks.is_idle());
}

test "Stream: zero max message size returns FrameTooLarge without latching" {
    var stream: EncodedStream(16) = .{};
    var valid = [_]u8{ 'o', 'k' };
    try append_masked(&stream, Frame.text(&valid), .{ 0x01, 0x02, 0x03, 0x04 });

    var reader = stream.reader();
    var rig: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
    try rig.init(&reader, .{ .role = .server, .options = .{ .max_message_size = 0 } });
    var chunks = message.MessageReader.init(&rig.ws);

    try std.testing.expectError(error.FrameTooLarge, chunks.next());
    try std.testing.expect(chunks.is_idle());
    try std.testing.expectEqual(@as(?tachyon.WebSocketError, null), rig.ws.read_failure);

    rig.ws.set_max_message_size(64);
    const chunk = try expect_chunk(&chunks);
    try std.testing.expectEqualStrings("ok", chunk.payload);
}

test "Stream: masked inbound with auto_apply_mask off returns PayloadMasked" {
    var stream: EncodedStream(16) = .{};
    var payload = [_]u8{ 'o', 'k' };
    try append_masked(&stream, Frame.text(&payload), .{ 0x01, 0x02, 0x03, 0x04 });

    var reader = stream.reader();
    var rig: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
    try rig.init(&reader, .{ .role = .server, .options = .{ .auto_apply_mask = false } });
    var chunks = message.MessageReader.init(&rig.ws);

    try std.testing.expectError(error.PayloadMasked, chunks.next());
    try std.testing.expectError(error.PayloadMasked, chunks.next());
    try std.testing.expect(chunks.is_idle());
}

test "Stream: masked close with auto_apply_mask off returns PayloadMasked" {
    var stream: EncodedStream(32) = .{};
    var close_storage: [8]u8 = undefined;
    try append_masked(&stream, try Frame.close(1000, "", &close_storage), .{ 0x01, 0x02, 0x03, 0x04 });

    var reader = stream.reader();
    var rig: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
    try rig.init(&reader, .{ .role = .server, .options = .{ .auto_apply_mask = false } });
    var chunks = message.MessageReader.init(&rig.ws);

    // The connection leaves the masked payload untouched, so the stream fails
    // closed instead of handing ciphertext to a caller as a close code.
    try std.testing.expectError(error.PayloadMasked, chunks.next());
    try std.testing.expect(chunks.is_closed());
    try std.testing.expect(!rig.ws.is_closed());
    try std.testing.expectEqual(@as(usize, 0), rig.writer.written);
}

test "Stream: orphan continuation is rejected before the stream state" {
    var stream: EncodedStream(16) = .{};
    var payload = [_]u8{'a'};
    try append_masked(&stream, Frame.init(true, .continuation, null, &payload), .{ 0x01, 0x02, 0x03, 0x04 });

    var reader = stream.reader();
    var rig: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
    try rig.init(&reader, .{ .role = .server });
    var chunks = message.MessageReader.init(&rig.ws);

    try std.testing.expectError(error.ProtocolError, chunks.next());
    try std.testing.expect(chunks.is_idle());
}

test "Stream: close mid-message aborts and is terminal" {
    var stream: EncodedStream(32) = .{};
    var first = [_]u8{'a'};
    var close_storage: [8]u8 = undefined;
    try append_masked(&stream, Frame.init(false, .text, null, &first), .{ 0x01, 0x02, 0x03, 0x04 });
    try append_masked(&stream, try Frame.close(1000, "bye", &close_storage), .{ 0x05, 0x06, 0x07, 0x08 });

    var reader = stream.reader();
    var rig: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
    try rig.init(&reader, .{ .role = .server });
    var chunks = message.MessageReader.init(&rig.ws);

    _ = try expect_chunk(&chunks);
    const close = try expect_close(&chunks);

    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xe8, 'b', 'y', 'e' }, close.payload);
    try std.testing.expect(chunks.is_closed());
    try std.testing.expect(rig.ws.is_closed());
    try std.testing.expectError(error.ConnectionClosed, chunks.next());

    var index: usize = 0;
    const echo = try next_wire_frame(rig.bytes(), &index);
    try std.testing.expectEqual(tachyon.OpCode.close, try wire_opcode(echo));
    try std.testing.expectEqualSlices(u8, close.payload, echo.payload);
}

test "Stream: invalid close code mid-message sends 1002 and latches InvalidCloseCode" {
    var stream: EncodedStream(32) = .{};
    var first = [_]u8{'a'};
    var close_storage: [8]u8 = undefined;
    try append_masked(&stream, Frame.init(false, .text, null, &first), .{ 0x01, 0x02, 0x03, 0x04 });
    try append_masked(&stream, try Frame.close(1005, "", &close_storage), .{ 0x05, 0x06, 0x07, 0x08 });

    var reader = stream.reader();
    var rig: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
    try rig.init(&reader, .{ .role = .server });
    var chunks = message.MessageReader.init(&rig.ws);

    _ = try expect_chunk(&chunks);
    try std.testing.expectError(error.InvalidCloseCode, chunks.next());
    try std.testing.expect(rig.ws.is_closed());
    try std.testing.expect(chunks.is_closed());
    try std.testing.expectError(error.InvalidCloseCode, chunks.next());

    var index: usize = 0;
    const reply = try next_wire_frame(rig.bytes(), &index);
    try std.testing.expectEqual(tachyon.OpCode.close, try wire_opcode(reply));
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xea }, reply.payload);
}

test "Stream: close with invalid UTF-8 reason returns InvalidUTF8 without echo" {
    var stream: EncodedStream(16) = .{};
    var close_storage: [8]u8 = undefined;
    try append_masked(&stream, try Frame.close(1000, &.{0xff}, &close_storage), .{ 0x01, 0x02, 0x03, 0x04 });

    var reader = stream.reader();
    var rig: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
    try rig.init(&reader, .{ .role = .server });
    var chunks = message.MessageReader.init(&rig.ws);

    try std.testing.expectError(error.InvalidUTF8, chunks.next());
    try std.testing.expectEqual(@as(usize, 0), rig.writer.written);
    try std.testing.expectError(error.InvalidUTF8, chunks.next());
    try std.testing.expect(!chunks.is_closed());
}

test "Stream: auto_close off still terminates the stream on a close" {
    var stream: EncodedStream(16) = .{};
    var close_storage: [8]u8 = undefined;
    try append_masked(&stream, try Frame.close(1000, "", &close_storage), .{ 0x01, 0x02, 0x03, 0x04 });

    var reader = stream.reader();
    var rig: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
    try rig.init(&reader, .{ .role = .server, .options = .{ .auto_close = false } });
    var chunks = message.MessageReader.init(&rig.ws);

    _ = try expect_close(&chunks);
    try std.testing.expect(chunks.is_closed());
    try std.testing.expect(!rig.ws.is_closed());
    try std.testing.expectError(error.ConnectionClosed, chunks.next());
}

test "Stream: reset after a clear close leaves the reader terminal with auto_close on" {
    var stream: EncodedStream(16) = .{};
    var close_storage: [8]u8 = undefined;
    try append_masked(&stream, try Frame.close(1000, "", &close_storage), .{ 0x01, 0x02, 0x03, 0x04 });

    var reader = stream.reader();
    var rig: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
    try rig.init(&reader, .{ .role = .server });
    var chunks = message.MessageReader.init(&rig.ws);

    _ = try expect_close(&chunks);
    try std.testing.expect(chunks.is_closed());
    try std.testing.expect(rig.ws.is_closed());

    // A reset clears the stream latch but must not reopen the terminal close.
    chunks.reset();
    try std.testing.expect(chunks.is_closed());
    try std.testing.expectError(error.ConnectionClosed, chunks.next());
}

test "Stream: reset after a clear close leaves the reader terminal with auto_close off" {
    var stream: EncodedStream(16) = .{};
    var close_storage: [8]u8 = undefined;
    try append_masked(&stream, try Frame.close(1000, "", &close_storage), .{ 0x01, 0x02, 0x03, 0x04 });

    var reader = stream.reader();
    var rig: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
    try rig.init(&reader, .{ .role = .server, .options = .{ .auto_close = false } });
    var chunks = message.MessageReader.init(&rig.ws);

    _ = try expect_close(&chunks);
    try std.testing.expect(chunks.is_closed());
    try std.testing.expect(!rig.ws.is_closed());

    chunks.reset();
    try std.testing.expect(chunks.is_closed());
    try std.testing.expectError(error.ConnectionClosed, chunks.next());
    try std.testing.expect(!rig.ws.is_closed());
}

test "Stream: incomplete fragmented message after a read failure stays aborted" {
    var stream: EncodedStream(16) = .{};
    var first = [_]u8{'a'};
    try append_masked(&stream, Frame.init(false, .text, null, &first), .{ 0x01, 0x02, 0x03, 0x04 });

    var reader = stream.reader();
    var rig: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
    try rig.init(&reader, .{ .role = .server });
    var chunks = message.MessageReader.init(&rig.ws);

    const chunk = try expect_chunk(&chunks);
    try std.testing.expectEqualStrings("a", chunk.payload);
    try std.testing.expectEqual(message.MessageKind.text, chunks.message_kind().?);

    try std.testing.expectError(error.UnexpectedEOF, chunks.next());
    try std.testing.expect(chunks.is_idle());

    chunks.reset();
    try std.testing.expect(chunks.is_idle());
    try std.testing.expectError(error.UnexpectedEOF, chunks.next());
    try std.testing.expect(chunks.is_idle());
}
