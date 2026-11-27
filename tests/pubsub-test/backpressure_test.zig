const std = @import("std");
const tachyon = @import("tachyon");

const support = @import("../support.zig");

const Frame = support.Frame;
const ConnectionRig = support.ConnectionRig;
const PubSubRig = support.PubSubRig;
const next_wire_frame = support.next_wire_frame;

test "PubSub: a queued control pauses a subscriber and publish returns WouldBlock" {
    var rig: PubSubRig(1, 1, 8, 2) = .{};
    try rig.init();

    var empty = std.Io.Reader.fixed("");
    var subscriber: ConnectionRig(16, 2, 32, 8, 0, 32) = .{};
    try subscriber.init(&empty, .{
        .role = .server,
        .options = .{
            .backpressure = .{
                .high_water_bytes = 8,
                .high_water_frames = 1,
            },
        },
    });
    _ = try rig.hub.subscribe(&subscriber.ws, "room");

    var pong_payload = [_]u8{ 'p', 'o', 'n', 'g' };
    try subscriber.ws.enqueue_frame(Frame.pong(&pong_payload));
    try std.testing.expect(subscriber.ws.is_backpressured());
    try std.testing.expectEqual(@as(usize, 1), subscriber.ws.tx_pending());
    try std.testing.expectEqual(@as(usize, 1), subscriber.ws.queued_frames());

    var payload = [_]u8{ 'd', 'a', 't', 'a' };
    const result = try rig.hub.publish("room", &payload, .text);
    try std.testing.expectEqual(@as(usize, 1), result.matched);
    try std.testing.expectEqual(@as(usize, 0), result.delivered);
    try std.testing.expectEqual(@as(usize, 1), result.skipped);
    try std.testing.expectEqual(@as(usize, 1), result.backpressured);
    try std.testing.expectEqual(@as(usize, 0), result.closed);
    try std.testing.expectEqual(error.WouldBlock, result.first_error.?);

    // The rejected data frame leaves the ring and the policy untouched.
    try std.testing.expectEqual(@as(usize, 1), subscriber.ws.tx_pending());
    try std.testing.expectEqual(@as(usize, 1), subscriber.ws.queued_frames());
    try std.testing.expectEqual(@as(usize, 0), subscriber.writer.written);

    try subscriber.ws.flush();
    var index: usize = 0;
    const pong = try next_wire_frame(subscriber.bytes(), &index);
    try std.testing.expectEqual(tachyon.OpCode.pong, tachyon.OpCode.from_wire(pong.header.header.opcode).?);
    try std.testing.expectEqualSlices(u8, &pong_payload, pong.payload);
    try std.testing.expectEqual(subscriber.writer.written, index);
}

test "PubSub: a full one-node ring returns QueueFull" {
    var rig: PubSubRig(1, 1, 8, 2) = .{};
    try rig.init();

    var empty = std.Io.Reader.fixed("");
    var subscriber: ConnectionRig(16, 1, 32, 8, 0, 32) = .{};
    try subscriber.init(&empty, .{ .role = .server });
    _ = try rig.hub.subscribe(&subscriber.ws, "room");

    var seed_payload = [_]u8{ 's', 'e', 'e', 'd' };
    try subscriber.ws.enqueue_frame(Frame.text(&seed_payload));
    try std.testing.expectEqual(@as(usize, 1), subscriber.ws.tx_pending());

    var payload = [_]u8{ 'd', 'a', 't', 'a' };
    const result = try rig.hub.publish("room", &payload, .text);
    try std.testing.expectEqual(@as(usize, 1), result.matched);
    try std.testing.expectEqual(@as(usize, 0), result.delivered);
    try std.testing.expectEqual(@as(usize, 1), result.skipped);
    try std.testing.expectEqual(@as(usize, 1), result.backpressured);
    try std.testing.expectEqual(error.QueueFull, result.first_error.?);
    try std.testing.expectEqual(@as(usize, 1), subscriber.ws.tx_pending());
    try std.testing.expectEqual(@as(usize, 0), subscriber.writer.written);

    try subscriber.ws.flush();
    var index: usize = 0;
    const seed = try next_wire_frame(subscriber.bytes(), &index);
    try std.testing.expectEqualSlices(u8, &seed_payload, seed.payload);
    try std.testing.expectEqual(subscriber.writer.written, index);
}

test "PubSub: a closed subscriber is skipped with ConnectionClosed" {
    var rig: PubSubRig(1, 1, 8, 2) = .{};
    try rig.init();

    var empty = std.Io.Reader.fixed("");
    var subscriber: ConnectionRig(16, 2, 32, 8, 0, 32) = .{};
    try subscriber.init(&empty, .{ .role = .server });
    _ = try rig.hub.subscribe(&subscriber.ws, "room");

    var close_storage: [2]u8 = undefined;
    try subscriber.ws.write_frame(try Frame.close(1000, "", &close_storage));
    try std.testing.expect(subscriber.ws.is_closed());
    try std.testing.expectEqual(@as(usize, 0), subscriber.ws.tx_pending());
    const bytes_after_close = subscriber.writer.written;

    var payload = [_]u8{ 'd', 'a', 't', 'a' };
    const result = try rig.hub.publish("room", &payload, .text);
    try std.testing.expectEqual(@as(usize, 1), result.matched);
    try std.testing.expectEqual(@as(usize, 0), result.delivered);
    try std.testing.expectEqual(@as(usize, 1), result.skipped);
    try std.testing.expectEqual(@as(usize, 0), result.backpressured);
    try std.testing.expectEqual(@as(usize, 1), result.closed);
    try std.testing.expectEqual(error.ConnectionClosed, result.first_error.?);
    try std.testing.expectEqual(bytes_after_close, subscriber.writer.written);
    try std.testing.expectEqual(@as(usize, 0), subscriber.ws.tx_pending());
}

test "PubSub: repeated publishes to a paused subscriber never grow the ring" {
    var rig: PubSubRig(1, 1, 8, 2) = .{};
    try rig.init();

    var empty = std.Io.Reader.fixed("");
    var subscriber: ConnectionRig(16, 2, 32, 8, 0, 32) = .{};
    try subscriber.init(&empty, .{
        .role = .server,
        .options = .{
            .backpressure = .{
                .high_water_bytes = 4,
                .high_water_frames = 1,
            },
        },
    });
    _ = try rig.hub.subscribe(&subscriber.ws, "room");

    var pong_payload = [_]u8{'p'};
    try subscriber.ws.enqueue_frame(Frame.pong(&pong_payload));
    try std.testing.expect(subscriber.ws.is_backpressured());

    var payload = [_]u8{ 'd', 'a', 't', 'a' };
    for (0..32) |_| {
        const result = try rig.hub.publish("room", &payload, .text);
        try std.testing.expectEqual(@as(usize, 1), result.matched);
        try std.testing.expectEqual(@as(usize, 0), result.delivered);
        try std.testing.expectEqual(@as(usize, 1), result.skipped);
        try std.testing.expectEqual(@as(usize, 1), result.backpressured);
        try std.testing.expectEqual(error.WouldBlock, result.first_error.?);
        try std.testing.expectEqual(@as(usize, 1), subscriber.ws.tx_pending());
        try std.testing.expectEqual(@as(usize, 1), subscriber.ws.queued_frames());
        try std.testing.expectEqual(@as(usize, 0), subscriber.writer.written);
    }
}

test "PubSub: a skipped subscriber can be unsubscribed and lowers matched" {
    var rig: PubSubRig(1, 2, 8, 2) = .{};
    try rig.init();

    var paused_empty = std.Io.Reader.fixed("");
    var paused: ConnectionRig(16, 2, 32, 8, 0, 32) = .{};
    try paused.init(&paused_empty, .{
        .role = .server,
        .options = .{
            .backpressure = .{
                .high_water_bytes = 4,
                .high_water_frames = 1,
            },
        },
    });

    var active_empty = std.Io.Reader.fixed("");
    var active: ConnectionRig(16, 2, 32, 8, 0, 32) = .{};
    try active.init(&active_empty, .{ .role = .server });

    _ = try rig.hub.subscribe(&paused.ws, "room");
    _ = try rig.hub.subscribe(&active.ws, "room");

    var pong_payload = [_]u8{'p'};
    try paused.ws.enqueue_frame(Frame.pong(&pong_payload));

    var first_payload = [_]u8{ 'f', 'i', 'r', 's', 't' };
    const first = try rig.hub.publish("room", &first_payload, .text);
    try std.testing.expectEqual(@as(usize, 2), first.matched);
    try std.testing.expectEqual(@as(usize, 1), first.delivered);
    try std.testing.expectEqual(@as(usize, 1), first.skipped);
    try std.testing.expectEqual(@as(usize, 1), first.backpressured);

    try rig.hub.unsubscribe(&paused.ws, "room");
    try std.testing.expectEqual(@as(usize, 1), rig.hub.subscription_count());

    var second_payload = [_]u8{ 's', 'e', 'c', 'o', 'n', 'd' };
    const second = try rig.hub.publish("room", &second_payload, .text);
    try std.testing.expectEqual(@as(usize, 1), second.matched);
    try std.testing.expectEqual(@as(usize, 1), second.delivered);
    try std.testing.expectEqual(@as(usize, 0), second.skipped);
    try std.testing.expect(second.is_complete());

    try active.ws.flush();
    var index: usize = 0;
    const first_frame = try next_wire_frame(active.bytes(), &index);
    const second_frame = try next_wire_frame(active.bytes(), &index);
    try std.testing.expectEqualSlices(u8, &first_payload, first_frame.payload);
    try std.testing.expectEqualSlices(u8, &second_payload, second_frame.payload);
    try std.testing.expectEqual(active.writer.written, index);

    try std.testing.expectEqual(@as(usize, 1), paused.ws.tx_pending());
}
