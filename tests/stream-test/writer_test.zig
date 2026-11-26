const std = @import("std");
const zslay = @import("zslay");
const tachyon = @import("tachyon");

const support = @import("../support.zig");

const message = tachyon.stream;
const connection = tachyon.connection;
const Frame = tachyon.Frame;
const ConnectionRig = support.ConnectionRig;
const FlushFailWriter = support.FlushFailWriter;
const next_wire_frame = support.next_wire_frame;

fn wire_opcode(incoming: support.WireFrame) !tachyon.OpCode {
    return tachyon.OpCode.from_wire(incoming.header.header.opcode) orelse error.InvalidOpcode;
}

test "Stream: single chunk fin writes one unfragmented frame" {
    var empty = std.Io.Reader.fixed("");
    var rig: ConnectionRig(16, 2, 64, 8, 0, 64) = .{};
    try rig.init(&empty, .{ .role = .server });
    var writer = message.MessageWriter.init(&rig.ws, .text);

    var payload = [_]u8{ 'h', 'e', 'l', 'l', 'o' };
    try writer.write(&payload, true);
    try writer.flush();

    var index: usize = 0;
    const wire = try next_wire_frame(rig.bytes(), &index);
    try std.testing.expectEqual(tachyon.OpCode.text, try wire_opcode(wire));
    try std.testing.expect(wire.header.header.fin);
    try std.testing.expectEqualSlices(u8, &payload, wire.payload);
    try std.testing.expectEqual(rig.writer.written, index);
    try std.testing.expect(writer.is_finished());
}

test "Stream: chunks preserve fragmentation order" {
    var empty = std.Io.Reader.fixed("");
    var rig: ConnectionRig(16, 4, 64, 8, 0, 64) = .{};
    try rig.init(&empty, .{ .role = .server });
    var writer = message.MessageWriter.init(&rig.ws, .text);

    var first = [_]u8{ 'a', 'b' };
    var second = [_]u8{ 'c', 'd' };
    var third = [_]u8{ 'e', 'f' };
    try writer.write(&first, false);
    try writer.write(&second, false);
    try writer.write(&third, true);
    try writer.flush();

    var index: usize = 0;
    const one = try next_wire_frame(rig.bytes(), &index);
    const two = try next_wire_frame(rig.bytes(), &index);
    const three = try next_wire_frame(rig.bytes(), &index);

    try std.testing.expectEqual(tachyon.OpCode.text, try wire_opcode(one));
    try std.testing.expectEqual(tachyon.OpCode.continuation, try wire_opcode(two));
    try std.testing.expectEqual(tachyon.OpCode.continuation, try wire_opcode(three));
    try std.testing.expect(!one.header.header.fin);
    try std.testing.expect(!two.header.header.fin);
    try std.testing.expect(three.header.header.fin);
    try std.testing.expectEqualSlices(u8, &first, one.payload);
    try std.testing.expectEqualSlices(u8, &second, two.payload);
    try std.testing.expectEqualSlices(u8, &third, three.payload);
    try std.testing.expectEqual(rig.writer.written, index);
}

test "Stream: finish emits an empty FIN continuation" {
    var empty = std.Io.Reader.fixed("");
    var rig: ConnectionRig(16, 2, 64, 8, 0, 64) = .{};
    try rig.init(&empty, .{ .role = .server });
    var writer = message.MessageWriter.init(&rig.ws, .text);

    var payload = [_]u8{ 'a', 'b' };
    try writer.write(&payload, false);
    try writer.finish();
    try writer.flush();

    var index: usize = 0;
    const one = try next_wire_frame(rig.bytes(), &index);
    const two = try next_wire_frame(rig.bytes(), &index);

    try std.testing.expectEqual(tachyon.OpCode.text, try wire_opcode(one));
    try std.testing.expect(!one.header.header.fin);
    try std.testing.expectEqual(tachyon.OpCode.continuation, try wire_opcode(two));
    try std.testing.expect(two.header.header.fin);
    try std.testing.expectEqual(@as(usize, 0), two.payload.len);
    try std.testing.expectEqual(rig.writer.written, index);
}

test "Stream: writer with no chunks and finish sends an empty message" {
    var empty = std.Io.Reader.fixed("");
    var rig: ConnectionRig(16, 2, 64, 8, 0, 64) = .{};
    try rig.init(&empty, .{ .role = .server });
    var writer = message.MessageWriter.init(&rig.ws, .text);

    try writer.finish();
    try writer.flush();

    var index: usize = 0;
    const wire = try next_wire_frame(rig.bytes(), &index);
    try std.testing.expectEqual(tachyon.OpCode.text, try wire_opcode(wire));
    try std.testing.expect(wire.header.header.fin);
    try std.testing.expectEqual(@as(usize, 0), wire.payload.len);
}

test "Stream: writer rejects writes after finish" {
    var empty = std.Io.Reader.fixed("");
    var rig: ConnectionRig(16, 2, 64, 8, 0, 64) = .{};
    try rig.init(&empty, .{ .role = .server });
    var writer = message.MessageWriter.init(&rig.ws, .text);

    var payload = [_]u8{'a'};
    try writer.write(&payload, true);
    try std.testing.expectError(error.InvalidFragment, writer.write(&payload, false));
    try std.testing.expect(writer.is_finished());

    try writer.flush();
    var index: usize = 0;
    _ = try next_wire_frame(rig.bytes(), &index);
    try std.testing.expectEqual(rig.writer.written, index);
}

test "Stream: finish after finish is rejected without queueing" {
    var empty = std.Io.Reader.fixed("");
    var rig: ConnectionRig(16, 2, 64, 8, 0, 64) = .{};
    try rig.init(&empty, .{ .role = .server });
    var writer = message.MessageWriter.init(&rig.ws, .text);

    var payload = [_]u8{'a'};
    try writer.write(&payload, true);
    const queued = rig.ws.queued_frames();
    try std.testing.expectError(error.InvalidFragment, writer.finish());
    try std.testing.expectEqual(queued, rig.ws.queued_frames());
    try std.testing.expect(writer.is_finished());

    try writer.flush();
}

test "Stream: first chunk WouldBlock keeps the writer unstarted and retries as text" {
    var empty = std.Io.Reader.fixed("");
    var rig: ConnectionRig(16, 2, 64, 8, 0, 64) = .{};
    try rig.init(&empty, .{
        .role = .server,
        .options = .{
            .backpressure = .{
                .high_water_bytes = 8,
                .high_water_frames = 1,
            },
        },
    });

    // An empty ring admits one frame, so seed a control frame to put the policy
    // in the backpressured phase before the writer starts.
    var keepalive = [_]u8{'k'};
    try rig.ws.enqueue_frame(Frame.pong(&keepalive));

    var writer = message.MessageWriter.init(&rig.ws, .text);
    var first = [_]u8{'a'};
    try std.testing.expectError(error.WouldBlock, writer.write(&first, true));
    try std.testing.expect(!writer.is_started());

    try writer.flush();
    try writer.write(&first, true);
    try writer.flush();

    var index: usize = 0;
    const seeded = try next_wire_frame(rig.bytes(), &index);
    try std.testing.expectEqual(tachyon.OpCode.pong, try wire_opcode(seeded));
    const wire = try next_wire_frame(rig.bytes(), &index);
    try std.testing.expectEqual(tachyon.OpCode.text, try wire_opcode(wire));
    try std.testing.expect(wire.header.header.fin);
    try std.testing.expectEqual(rig.writer.written, index);
}

test "Stream: binary chunks use the binary opcode" {
    var empty = std.Io.Reader.fixed("");
    var rig: ConnectionRig(16, 2, 64, 8, 0, 64) = .{};
    try rig.init(&empty, .{ .role = .server });
    var writer = message.MessageWriter.init(&rig.ws, .binary);

    var first = [_]u8{0xff};
    var second = [_]u8{0x80};
    try writer.write(&first, false);
    try writer.write(&second, true);
    try writer.flush();

    var index: usize = 0;
    const one = try next_wire_frame(rig.bytes(), &index);
    const two = try next_wire_frame(rig.bytes(), &index);
    try std.testing.expectEqual(tachyon.OpCode.binary, try wire_opcode(one));
    try std.testing.expectEqual(tachyon.OpCode.continuation, try wire_opcode(two));
    try std.testing.expectEqualSlices(u8, &first, one.payload);
    try std.testing.expectEqualSlices(u8, &second, two.payload);
}

test "Stream: client chunks are masked exactly once" {
    const seed: [connection.mask_seed_len]u8 = @splat(0x52);
    var empty = std.Io.Reader.fixed("");
    var rig: ConnectionRig(16, 2, 64, 8, 0, 64) = .{};
    try rig.init(&empty, .{
        .role = .client,
        .mask_keys = connection.MaskKeySource.from_seed(seed),
    });
    var writer = message.MessageWriter.init(&rig.ws, .text);

    var first = [_]u8{ 'a', 'b' };
    var second = [_]u8{ 'c', 'd' };
    try writer.write(&first, false);
    try writer.write(&second, true);
    try writer.flush();

    var index: usize = 0;
    const one = try next_wire_frame(rig.bytes(), &index);
    const two = try next_wire_frame(rig.bytes(), &index);

    try std.testing.expect(one.header.header.mask);
    try std.testing.expect(two.header.header.mask);
    const one_key = one.header.masking_key.?;
    const two_key = two.header.masking_key.?;

    var plain_one: [2]u8 = undefined;
    var plain_two: [2]u8 = undefined;
    @memcpy(&plain_one, one.payload);
    @memcpy(&plain_two, two.payload);
    zslay.mask(&plain_one, one_key, 0);
    zslay.mask(&plain_two, two_key, 0);

    try std.testing.expectEqualSlices(u8, &first, &plain_one);
    try std.testing.expectEqualSlices(u8, &second, &plain_two);
    try std.testing.expectEqual(rig.writer.written, index);
}

test "Stream: payload aliasing the read frame buffer is rejected and state does not advance" {
    var empty = std.Io.Reader.fixed("");
    var rig: ConnectionRig(16, 2, 64, 8, 0, 64) = .{};
    try rig.init(&empty, .{ .role = .server });
    var writer = message.MessageWriter.init(&rig.ws, .text);

    try std.testing.expectError(error.InvalidLength, writer.write(rig.frame_buffer[0..3], false));
    try std.testing.expect(!writer.is_started());

    var payload = [_]u8{'a'};
    try writer.write(&payload, true);
    try writer.flush();

    var index: usize = 0;
    const wire = try next_wire_frame(rig.bytes(), &index);
    try std.testing.expectEqual(tachyon.OpCode.text, try wire_opcode(wire));
    try std.testing.expectEqualSlices(u8, &payload, wire.payload);
}

test "Stream: write after close returns ConnectionClosed and state does not advance" {
    var empty = std.Io.Reader.fixed("");
    var rig: ConnectionRig(16, 2, 64, 8, 0, 64) = .{};
    try rig.init(&empty, .{ .role = .server });

    var close_storage: [8]u8 = undefined;
    try rig.ws.write_frame(try Frame.close(1000, "", &close_storage));

    var writer = message.MessageWriter.init(&rig.ws, .text);
    var payload = [_]u8{'a'};
    try std.testing.expectError(error.ConnectionClosed, writer.write(&payload, false));
    try std.testing.expect(!writer.is_started());

    var index: usize = 0;
    const wire = try next_wire_frame(rig.bytes(), &index);
    try std.testing.expectEqual(tachyon.OpCode.close, try wire_opcode(wire));
    try std.testing.expectEqual(rig.writer.written, index);
}

test "Stream: writer chunk at 65536 bytes is accepted at the limit" {
    var empty = std.Io.Reader.fixed("");
    var rig: ConnectionRig(16, 2, 64, 8, 0, 66000) = .{};
    try rig.init(&empty, .{
        .role = .server,
        .options = .{ .max_message_size = 65537 },
    });
    var writer = message.MessageWriter.init(&rig.ws, .binary);

    var payload: [65536]u8 = undefined;
    for (&payload, 0..) |*byte, index| byte.* = @intCast(index & 0xff);

    try writer.write(&payload, true);
    try writer.flush();

    var index: usize = 0;
    const wire = try next_wire_frame(rig.bytes(), &index);
    try std.testing.expectEqual(tachyon.OpCode.binary, try wire_opcode(wire));
    try std.testing.expect(wire.header.header.fin);
    try std.testing.expectEqual(@as(usize, 65536), wire.payload.len);
    try std.testing.expectEqualSlices(u8, &payload, wire.payload);
}

test "Stream: WouldBlock does not advance writer state and retry preserves order" {
    var empty = std.Io.Reader.fixed("");
    var rig: ConnectionRig(16, 4, 64, 8, 0, 64) = .{};
    try rig.init(&empty, .{
        .role = .server,
        .options = .{
            .backpressure = .{
                .high_water_bytes = 1000,
                .high_water_frames = 2,
                .low_water_frames = 1,
            },
        },
    });
    var writer = message.MessageWriter.init(&rig.ws, .text);

    var first = [_]u8{'1'};
    var second = [_]u8{'2'};
    var third = [_]u8{'3'};
    var fourth = [_]u8{'4'};
    try writer.write(&first, false);
    try writer.write(&second, false);
    try std.testing.expectEqual(@as(usize, 2), rig.ws.queued_frames());

    try std.testing.expectError(error.WouldBlock, writer.write(&third, false));
    try std.testing.expectEqual(@as(usize, 2), rig.ws.queued_frames());
    try std.testing.expect(writer.is_started());
    try std.testing.expect(!writer.is_finished());
    const next = try writer.state.spec(false);
    try std.testing.expectEqual(tachyon.OpCode.continuation, next.opcode);

    try writer.flush();
    try writer.write(&third, false);
    try writer.write(&fourth, true);
    try writer.flush();

    var index: usize = 0;
    const one = try next_wire_frame(rig.bytes(), &index);
    const two = try next_wire_frame(rig.bytes(), &index);
    const three = try next_wire_frame(rig.bytes(), &index);
    const four = try next_wire_frame(rig.bytes(), &index);

    try std.testing.expectEqualSlices(u8, "1", one.payload);
    try std.testing.expectEqualSlices(u8, "2", two.payload);
    try std.testing.expectEqualSlices(u8, "3", three.payload);
    try std.testing.expectEqualSlices(u8, "4", four.payload);
    try std.testing.expectEqual(tachyon.OpCode.text, try wire_opcode(one));
    try std.testing.expectEqual(tachyon.OpCode.continuation, try wire_opcode(two));
    try std.testing.expectEqual(tachyon.OpCode.continuation, try wire_opcode(three));
    try std.testing.expectEqual(tachyon.OpCode.continuation, try wire_opcode(four));
    try std.testing.expect(four.header.header.fin);
}

test "Stream: QueueFull without watermarks does not advance writer state" {
    var empty = std.Io.Reader.fixed("");
    var rig: ConnectionRig(16, 1, 64, 8, 0, 64) = .{};
    try rig.init(&empty, .{ .role = .server });
    var writer = message.MessageWriter.init(&rig.ws, .text);

    var first = [_]u8{'1'};
    var second = [_]u8{'2'};
    try writer.write(&first, false);
    try std.testing.expectError(error.QueueFull, writer.write(&second, true));
    try std.testing.expectEqual(@as(usize, 1), rig.ws.queued_frames());
    try std.testing.expect(writer.is_started());
    try std.testing.expect(!writer.is_finished());
    const next = try writer.state.spec(false);
    try std.testing.expectEqual(tachyon.OpCode.continuation, next.opcode);

    try writer.flush();
    try writer.write(&second, true);
    try writer.flush();

    var index: usize = 0;
    const one = try next_wire_frame(rig.bytes(), &index);
    const two = try next_wire_frame(rig.bytes(), &index);
    try std.testing.expectEqualSlices(u8, &first, one.payload);
    try std.testing.expectEqualSlices(u8, &second, two.payload);
    try std.testing.expect(two.header.header.fin);
}

test "Stream: backpressure counters charge each chunk and clear on flush" {
    var empty = std.Io.Reader.fixed("");
    var rig: ConnectionRig(16, 5, 64, 8, 0, 64) = .{};
    try rig.init(&empty, .{
        .role = .server,
        .options = .{
            .backpressure = .{
                .high_water_bytes = 100,
                .high_water_frames = 4,
            },
        },
    });
    var writer = message.MessageWriter.init(&rig.ws, .text);

    var first = [_]u8{ 'a', 'a' };
    var second = [_]u8{ 'b', 'b', 'b' };
    var third = [_]u8{ 'c', 'c', 'c', 'c' };
    try writer.write(&first, false);
    try writer.write(&second, false);
    try writer.write(&third, false);

    try std.testing.expectEqual(@as(usize, 9), rig.ws.queued_bytes());
    try std.testing.expectEqual(@as(usize, 3), rig.ws.queued_frames());

    try writer.flush();
    try std.testing.expectEqual(@as(usize, 0), rig.ws.queued_bytes());
    try std.testing.expectEqual(@as(usize, 0), rig.ws.queued_frames());
}

test "Stream: message-limit overflow returns FrameTooLarge and does not advance" {
    var empty = std.Io.Reader.fixed("");
    var rig: ConnectionRig(16, 2, 64, 8, 0, 64) = .{};
    try rig.init(&empty, .{ .role = .server, .options = .{ .max_message_size = 5 } });
    var writer = message.MessageWriter.init(&rig.ws, .text);

    var first = [_]u8{ 'a', 'b', 'c', 'd' };
    var second = [_]u8{'e'};
    try writer.write(&first, false);
    try std.testing.expectError(error.FrameTooLarge, writer.write(&second, true));
    try std.testing.expect(writer.is_started());
    try std.testing.expect(!writer.is_finished());
    const next = try writer.state.spec(false);
    try std.testing.expectEqual(tachyon.OpCode.continuation, next.opcode);
    try std.testing.expectEqual(@as(usize, 1), rig.ws.queued_frames());

    // A partial message cannot be abandoned in place; the transport must be
    // discarded and `reset_tx` called before reuse.
    try std.testing.expectError(error.FrameTooLarge, writer.write(&second, true));
}

test "Stream: flush failure latches the connection error" {
    var reader = std.Io.Reader.fixed("");
    var out: [64]u8 = undefined;
    var buffer: [64]u8 = undefined;
    var failing = FlushFailWriter.init(&out, &buffer);

    var frame_buffer: [16]u8 = undefined;
    var tx_nodes: [2]zslay.FrameNode = undefined;
    var write_buffer: [64]u8 = undefined;
    var close_buffer: [8]u8 = undefined;
    var mask_scratch: [0]u8 = .{};

    var ws = try connection.WebSocket.init(&reader, &failing.writer, .{
        .frame_buffer = &frame_buffer,
        .tx_nodes = &tx_nodes,
        .write_buffer = &write_buffer,
        .close_buffer = &close_buffer,
        .mask_scratch = &mask_scratch,
    }, .{ .role = .server });

    var writer = message.MessageWriter.init(&ws, .text);
    var payload = [_]u8{'a'};
    try writer.write(&payload, true);

    try std.testing.expectError(error.IoError, writer.flush());
    try std.testing.expectEqual(@as(?tachyon.WebSocketError, error.IoError), ws.write_failure);
    try std.testing.expectEqual(@as(usize, 1), failing.flush_calls);

    try std.testing.expectError(error.IoError, writer.flush());
    try std.testing.expectEqual(@as(usize, 1), failing.flush_calls);
}
