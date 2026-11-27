const std = @import("std");
const tachyon = @import("tachyon");

const support = @import("../support.zig");

const pubsub = tachyon.pubsub;
const ConnectionRig = support.ConnectionRig;
const PubSubRig = support.PubSubRig;
const PubSubFleet = support.PubSubFleet;
const next_wire_frame = support.next_wire_frame;

fn expect_single_frame(rig: anytype, expected_opcode: tachyon.OpCode, expected: []const u8) !void {
    var index: usize = 0;
    const wire = try next_wire_frame(rig.bytes(), &index);
    try std.testing.expect(wire.header.header.fin);
    try std.testing.expectEqual(expected_opcode, tachyon.OpCode.from_wire(wire.header.header.opcode).?);
    try std.testing.expectEqualSlices(u8, expected, wire.payload);
    try std.testing.expectEqual(rig.writer.written, index);
}

test "PubSub: fanout queues one FIN text frame per subscriber" {
    var rig: PubSubRig(1, 3, 8, 2) = .{};
    try rig.init();

    var fleet: PubSubFleet(3, 8, 2, 32, 8, 0, 32) = .{};
    try fleet.init(.{ .role = .server });

    for (0..3) |index| {
        const result = try rig.hub.subscribe(fleet.ws(index), "room");
        try std.testing.expect(result.added);
    }

    var payload = [_]u8{ 'h', 'e', 'l', 'l', 'o' };
    const result = try rig.hub.publish("room", &payload, .text);
    try std.testing.expectEqual(@as(usize, 3), result.matched);
    try std.testing.expectEqual(@as(usize, 3), result.delivered);
    try std.testing.expectEqual(@as(usize, 0), result.skipped);
    try std.testing.expectEqual(@as(usize, 0), result.backpressured);
    try std.testing.expectEqual(@as(usize, 0), result.closed);
    try std.testing.expect(result.first_error == null);
    try std.testing.expect(result.is_complete());

    for (0..3) |index| {
        try std.testing.expectEqual(@as(usize, 0), fleet.rigs[index].writer.written);
        try std.testing.expectEqual(@as(usize, 1), fleet.rigs[index].ws.tx_pending());
        try std.testing.expectEqual(@as(usize, 1), fleet.rigs[index].ws.queued_frames());
    }

    for (0..3) |index| {
        try fleet.rigs[index].ws.flush();
        try expect_single_frame(&fleet.rigs[index], .text, &payload);
    }
}

test "PubSub: binary and empty payloads preserve kind and length" {
    var rig: PubSubRig(1, 1, 8, 2) = .{};
    try rig.init();

    var fleet: PubSubFleet(1, 8, 2, 32, 8, 0, 32) = .{};
    try fleet.init(.{ .role = .server });
    _ = try rig.hub.subscribe(fleet.ws(0), "room");

    var binary_payload = [_]u8{ 0x00, 0x01, 0xff };
    const binary = try rig.hub.publish("room", &binary_payload, .binary);
    try std.testing.expectEqual(@as(usize, 1), binary.delivered);
    try fleet.rigs[0].ws.flush();
    try expect_single_frame(&fleet.rigs[0], .binary, &binary_payload);

    var empty_payload: [0]u8 = .{};
    const empty = try rig.hub.publish("room", &empty_payload, .text);
    try std.testing.expectEqual(@as(usize, 1), empty.delivered);
    try std.testing.expectEqual(@as(usize, 0), empty_payload.len);
    try fleet.rigs[0].ws.flush();

    var index: usize = 0;
    _ = try next_wire_frame(fleet.rigs[0].bytes(), &index);
    const empty_frame = try next_wire_frame(fleet.rigs[0].bytes(), &index);
    try std.testing.expect(empty_frame.header.header.fin);
    try std.testing.expectEqual(tachyon.OpCode.text, tachyon.OpCode.from_wire(empty_frame.header.header.opcode).?);
    try std.testing.expectEqual(@as(usize, 0), empty_frame.payload.len);
    try std.testing.expectEqual(fleet.rigs[0].writer.written, index);
}

test "PubSub: publish and publish_from apply exact sender exclusion" {
    var rig: PubSubRig(1, 3, 8, 2) = .{};
    try rig.init();

    var fleet: PubSubFleet(3, 8, 2, 32, 8, 0, 32) = .{};
    try fleet.init(.{ .role = .server });

    for (0..3) |index| {
        _ = try rig.hub.subscribe(fleet.ws(index), "room");
    }

    var from_payload = [_]u8{ 'f', 'r', 'o', 'm' };
    const from = try rig.hub.publish_from(fleet.ws(0), "room", &from_payload, .text);
    try std.testing.expectEqual(@as(usize, 2), from.matched);
    try std.testing.expectEqual(@as(usize, 2), from.delivered);
    try std.testing.expectEqual(@as(usize, 0), fleet.rigs[0].ws.tx_pending());
    try std.testing.expectEqual(@as(usize, 1), fleet.rigs[1].ws.tx_pending());
    try std.testing.expectEqual(@as(usize, 1), fleet.rigs[2].ws.tx_pending());

    var all_payload = [_]u8{ 'a', 'l', 'l' };
    const all = try rig.hub.publish("room", &all_payload, .text);
    try std.testing.expectEqual(@as(usize, 3), all.matched);
    try std.testing.expectEqual(@as(usize, 3), all.delivered);
    try std.testing.expectEqual(@as(usize, 1), fleet.rigs[0].ws.tx_pending());
    try std.testing.expectEqual(@as(usize, 2), fleet.rigs[1].ws.tx_pending());

    for (0..3) |index| {
        try fleet.rigs[index].ws.flush();
    }

    try expect_single_frame(&fleet.rigs[0], .text, &all_payload);
    for (1..3) |index| {
        var index_bytes: usize = 0;
        const first = try next_wire_frame(fleet.rigs[index].bytes(), &index_bytes);
        const second = try next_wire_frame(fleet.rigs[index].bytes(), &index_bytes);
        try std.testing.expectEqualSlices(u8, &from_payload, first.payload);
        try std.testing.expectEqualSlices(u8, &all_payload, second.payload);
        try std.testing.expectEqual(fleet.rigs[index].writer.written, index_bytes);
    }
}

test "PubSub: hot topic fanout never touches cold subscribers" {
    var rig: PubSubRig(2, 67, 8, 4) = .{};
    try rig.init();

    var fleet: PubSubFleet(67, 8, 2, 32, 8, 0, 16) = .{};
    try fleet.init(.{ .role = .server });

    for (0..3) |index| {
        _ = try rig.hub.subscribe(fleet.ws(index), "hot");
    }
    for (3..67) |index| {
        _ = try rig.hub.subscribe(fleet.ws(index), "cold");
    }

    var payload = [_]u8{ 'h', 'o', 't' };
    const result = try rig.hub.publish("hot", &payload, .text);
    try std.testing.expectEqual(@as(usize, 3), result.matched);
    try std.testing.expectEqual(@as(usize, 3), result.delivered);
    try std.testing.expect(result.is_complete());

    for (0..3) |index| {
        try std.testing.expectEqual(@as(usize, 1), fleet.rigs[index].ws.tx_pending());
    }
    for (3..67) |index| {
        try std.testing.expectEqual(@as(usize, 0), fleet.rigs[index].writer.written);
        try std.testing.expectEqual(@as(usize, 0), fleet.rigs[index].ws.tx_pending());
        try std.testing.expectEqual(@as(usize, 0), fleet.rigs[index].ws.queued_frames());
    }

    try std.testing.expectEqual(@as(usize, 2), rig.hub.topic_count());
    try std.testing.expectEqual(@as(usize, 67), rig.hub.subscription_count());
}

test "PubSub: the payload is borrowed until each subscriber flushes" {
    var rig: PubSubRig(1, 1, 8, 2) = .{};
    try rig.init();

    var fleet: PubSubFleet(1, 8, 2, 32, 8, 0, 32) = .{};
    try fleet.init(.{ .role = .server });
    _ = try rig.hub.subscribe(fleet.ws(0), "room");

    var payload = [_]u8{ 'b', 'o', 'r', 'r', 'o', 'w' };
    const result = try rig.hub.publish("room", &payload, .text);
    try std.testing.expectEqual(@as(usize, 1), result.delivered);

    // No copy has reached the transport and the payload is still only readable
    // through the caller's buffer; the queued node borrows it.
    try std.testing.expectEqual(@as(usize, 0), fleet.rigs[0].writer.written);
    try std.testing.expectEqual(@as(usize, 1), fleet.rigs[0].ws.tx_pending());

    try fleet.rigs[0].ws.flush();
    try expect_single_frame(&fleet.rigs[0], .text, &payload);
}

test "PubSub: payload overlapping hub storage returns AliasedPayload" {
    var rig: PubSubRig(1, 1, 8, 2) = .{};
    try rig.init();

    var fleet: PubSubFleet(1, 8, 2, 32, 8, 0, 32) = .{};
    try fleet.init(.{ .role = .server });
    _ = try rig.hub.subscribe(fleet.ws(0), "room");

    const names_payload: []u8 = rig.names[0..4];
    try std.testing.expectError(
        error.AliasedPayload,
        rig.hub.publish("room", names_payload, .text),
    );

    const topics_payload: []u8 = std.mem.sliceAsBytes(&rig.topics);
    try std.testing.expectError(
        error.AliasedPayload,
        rig.hub.publish("room", topics_payload[0..4], .text),
    );

    const index_payload: []u8 = std.mem.sliceAsBytes(&rig.topic_index);
    try std.testing.expectError(
        error.AliasedPayload,
        rig.hub.publish("room", index_payload[0..4], .text),
    );

    try std.testing.expectEqual(@as(usize, 0), fleet.rigs[0].ws.tx_pending());
    try std.testing.expectEqual(@as(usize, 0), fleet.rigs[0].writer.written);
    try std.testing.expectEqual(@as(usize, 1), rig.hub.topic_count());
    try std.testing.expectEqual(@as(u32, 0), rig.hub.publish_depth);
}

test "PubSub: publish rejects payloads aliasing the hub object or subscriptions" {
    var rig: PubSubRig(1, 1, 8, 2) = .{};
    try rig.init();

    var fleet: PubSubFleet(1, 8, 2, 32, 8, 0, 32) = .{};
    try fleet.init(.{ .role = .server });
    _ = try rig.hub.subscribe(fleet.ws(0), "room");

    const storage: pubsub.Storage = rig.storage();
    const hub_payload: []u8 = std.mem.asBytes(&rig.hub)[0..1];
    // Only the hub-object branch can reject this payload.
    try std.testing.expect(!storage.overlaps(hub_payload));
    try std.testing.expectError(
        error.AliasedPayload,
        rig.hub.publish("room", hub_payload, .text),
    );
    try std.testing.expectEqual(@as(usize, 0), fleet.rigs[0].ws.tx_pending());
    try std.testing.expectEqual(@as(usize, 0), fleet.rigs[0].ws.queued_frames());
    try std.testing.expectEqual(@as(usize, 0), fleet.rigs[0].writer.written);

    const subscriptions_payload: []u8 = std.mem.sliceAsBytes(&rig.subscriptions)[0..1];
    try std.testing.expect(storage.overlaps(subscriptions_payload));
    try std.testing.expectError(
        error.AliasedPayload,
        rig.hub.publish("room", subscriptions_payload, .text),
    );
    try std.testing.expectEqual(@as(usize, 0), fleet.rigs[0].ws.tx_pending());
    try std.testing.expectEqual(@as(usize, 0), fleet.rigs[0].ws.queued_frames());
    try std.testing.expectEqual(@as(usize, 0), fleet.rigs[0].writer.written);

    // No queued or wire bytes may appear after the rejected publishes.
    try fleet.rigs[0].ws.flush();
    try std.testing.expectEqual(@as(usize, 0), fleet.rigs[0].writer.written);
    try std.testing.expectEqual(@as(usize, 1), rig.hub.topic_count());
    try std.testing.expectEqual(@as(usize, 1), rig.hub.subscription_count());
    try std.testing.expect(rig.hub.is_subscribed(fleet.ws(0), "room"));
    try std.testing.expectEqual(@as(u32, 0), rig.hub.publish_depth);

    var ordinary = [_]u8{ 'o', 'k' };
    const result = try rig.hub.publish("room", &ordinary, .text);
    try std.testing.expectEqual(@as(usize, 1), result.matched);
    try std.testing.expectEqual(@as(usize, 1), result.delivered);
    try std.testing.expect(result.is_complete());

    try fleet.rigs[0].ws.flush();
    try expect_single_frame(&fleet.rigs[0], .text, &ordinary);
}

test "PubSub: payload aliasing one subscriber storage skips only that subscriber" {
    var rig: PubSubRig(1, 3, 8, 2) = .{};
    try rig.init();

    var fleet: PubSubFleet(3, 8, 2, 32, 8, 0, 32) = .{};
    try fleet.init(.{ .role = .server });

    for (0..3) |index| {
        _ = try rig.hub.subscribe(fleet.ws(index), "room");
    }

    const payload: []u8 = fleet.rigs[0].write_buffer[0..4];
    @memcpy(payload, "skip");

    const result = try rig.hub.publish("room", payload, .text);
    try std.testing.expectEqual(@as(usize, 3), result.matched);
    try std.testing.expectEqual(@as(usize, 2), result.delivered);
    try std.testing.expectEqual(@as(usize, 1), result.skipped);
    try std.testing.expectEqual(@as(usize, 0), result.backpressured);
    try std.testing.expectEqual(@as(usize, 0), result.closed);
    try std.testing.expectEqual(error.InvalidLength, result.first_error.?);

    try std.testing.expectEqual(@as(usize, 0), fleet.rigs[0].ws.tx_pending());
    try std.testing.expectEqual(@as(usize, 0), fleet.rigs[0].writer.written);
    try std.testing.expectEqual(@as(usize, 1), fleet.rigs[1].ws.tx_pending());
    try std.testing.expectEqual(@as(usize, 1), fleet.rigs[2].ws.tx_pending());

    try fleet.rigs[1].ws.flush();
    try fleet.rigs[2].ws.flush();
    try expect_single_frame(&fleet.rigs[1], .text, "skip");
    try expect_single_frame(&fleet.rigs[2], .text, "skip");
}

test "PubSub: multi-topic subscriber queues frames in publish order" {
    var rig: PubSubRig(2, 2, 8, 4) = .{};
    try rig.init();

    var fleet: PubSubFleet(1, 8, 4, 32, 8, 0, 32) = .{};
    try fleet.init(.{ .role = .server });

    _ = try rig.hub.subscribe(fleet.ws(0), "a");
    _ = try rig.hub.subscribe(fleet.ws(0), "b");

    var first_payload = [_]u8{ 'o', 'n', 'e' };
    var second_payload = [_]u8{ 't', 'w', 'o' };
    _ = try rig.hub.publish("a", &first_payload, .text);
    _ = try rig.hub.publish("b", &second_payload, .text);

    try std.testing.expectEqual(@as(usize, 2), fleet.rigs[0].ws.tx_pending());
    try std.testing.expectEqual(@as(usize, 0), fleet.rigs[0].writer.written);

    try fleet.rigs[0].ws.flush();

    var index: usize = 0;
    const first = try next_wire_frame(fleet.rigs[0].bytes(), &index);
    const second = try next_wire_frame(fleet.rigs[0].bytes(), &index);
    try std.testing.expectEqualSlices(u8, &first_payload, first.payload);
    try std.testing.expectEqualSlices(u8, &second_payload, second.payload);
    try std.testing.expectEqual(fleet.rigs[0].writer.written, index);
}

test "PubSub: payload boundaries produce complete single frames" {
    var rig: PubSubRig(1, 1, 8, 2) = .{};
    try rig.init();

    var empty = std.Io.Reader.fixed("");
    var subscriber: ConnectionRig(16, 2, 32, 8, 0, 132_000) = .{};
    try subscriber.init(&empty, .{ .role = .server });
    _ = try rig.hub.subscribe(&subscriber.ws, "room");

    const lengths = [_]usize{ 0, 1, 125, 126, 127, 65535, 65536 };
    var payload: [65536]u8 = undefined;
    support.fill_deterministic(&payload, 0x51);

    for (lengths) |len| {
        const result = try rig.hub.publish("room", payload[0..len], .text);
        try std.testing.expectEqual(@as(usize, 1), result.delivered);
        try subscriber.ws.flush();
    }

    var index: usize = 0;
    for (lengths) |len| {
        const wire = try next_wire_frame(subscriber.bytes(), &index);
        try std.testing.expect(wire.header.header.fin);
        try std.testing.expectEqual(tachyon.OpCode.text, tachyon.OpCode.from_wire(wire.header.header.opcode).?);
        try std.testing.expectEqual(len, wire.payload.len);
        try std.testing.expectEqualSlices(u8, payload[0..len], wire.payload);
    }
    try std.testing.expectEqual(subscriber.writer.written, index);
}
