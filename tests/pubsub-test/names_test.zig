const std = @import("std");
const tachyon = @import("tachyon");

const support = @import("../support.zig");

const PubSubRig = support.PubSubRig;
const PubSubFleet = support.PubSubFleet;
const next_wire_frame = support.next_wire_frame;

test "PubSub: name length validates empty, one, L, and L+1" {
    var rig: PubSubRig(2, 2, 4, 4) = .{};
    try rig.init();

    var fleet: PubSubFleet(2, 8, 2, 32, 8, 0, 16) = .{};
    try fleet.init(.{ .role = .server });

    var one_byte = [_]u8{'a'};
    var max_bytes = [_]u8{ 'a', 'b', 'c', 'd' };
    var too_long = [_]u8{ 'a', 'b', 'c', 'd', 'e' };
    var empty: [0]u8 = .{};

    try std.testing.expect((try rig.hub.subscribe(fleet.ws(0), &one_byte)).added);
    try std.testing.expect((try rig.hub.subscribe(fleet.ws(1), &max_bytes)).added);

    try std.testing.expectError(
        error.EmptyTopic,
        rig.hub.subscribe(fleet.ws(0), &empty),
    );
    try std.testing.expectError(
        error.TopicTooLong,
        rig.hub.subscribe(fleet.ws(0), &too_long),
    );
    try std.testing.expectError(
        error.EmptyTopic,
        rig.hub.publish(&empty, &one_byte, .text),
    );
    try std.testing.expectError(
        error.TopicTooLong,
        rig.hub.publish(&too_long, &one_byte, .text),
    );
    try std.testing.expectError(
        error.EmptyTopic,
        rig.hub.unsubscribe(fleet.ws(0), &empty),
    );
    try std.testing.expectError(
        error.TopicTooLong,
        rig.hub.unsubscribe(fleet.ws(0), &too_long),
    );

    try std.testing.expectEqual(@as(usize, 2), rig.hub.topic_count());
    try std.testing.expectEqual(@as(usize, 2), rig.hub.subscription_count());
}

test "PubSub: names are copied and case-sensitive" {
    var rig: PubSubRig(2, 2, 8, 4) = .{};
    try rig.init();

    var fleet: PubSubFleet(2, 8, 2, 32, 8, 0, 16) = .{};
    try fleet.init(.{ .role = .server });

    var caller_name = [_]u8{ 'A', 'l', 'p', 'h', 'a' };
    _ = try rig.hub.subscribe(fleet.ws(0), &caller_name);
    @memcpy(caller_name[0..5], "Bravo");

    const original = rig.hub.topic_info("Alpha").?;
    try std.testing.expectEqualStrings("Alpha", original.name);
    try std.testing.expectEqual(@as(usize, 1), original.subscriber_count);
    try std.testing.expect(rig.hub.topic_info("Bravo") == null);

    const lower = try rig.hub.subscribe(fleet.ws(1), "alpha");
    try std.testing.expect(lower.added);
    try std.testing.expectEqual(@as(usize, 2), rig.hub.topic_count());
    try std.testing.expect(original.id != lower.topic_id);

    var upper_payload = [_]u8{'A'};
    var lower_payload = [_]u8{'a'};
    const upper_result = try rig.hub.publish("Alpha", &upper_payload, .text);
    const lower_result = try rig.hub.publish("alpha", &lower_payload, .text);
    try std.testing.expectEqual(@as(usize, 1), upper_result.delivered);
    try std.testing.expectEqual(@as(usize, 1), lower_result.delivered);

    try fleet.rigs[0].ws.flush();
    try fleet.rigs[1].ws.flush();

    var index: usize = 0;
    const upper_frame = try next_wire_frame(fleet.rigs[0].bytes(), &index);
    try std.testing.expectEqualSlices(u8, &upper_payload, upper_frame.payload);
    try std.testing.expectEqual(fleet.rigs[0].writer.written, index);

    index = 0;
    const lower_frame = try next_wire_frame(fleet.rigs[1].bytes(), &index);
    try std.testing.expectEqualSlices(u8, &lower_payload, lower_frame.payload);
    try std.testing.expectEqual(fleet.rigs[1].writer.written, index);
}

test "PubSub: names accept embedded NUL and 0xff bytes" {
    var rig: PubSubRig(1, 1, 4, 2) = .{};
    try rig.init();

    var fleet: PubSubFleet(1, 8, 2, 32, 8, 0, 16) = .{};
    try fleet.init(.{ .role = .server });

    var name = [_]u8{ 'a', 0x00, 'b', 0xff };
    _ = try rig.hub.subscribe(fleet.ws(0), &name);

    const info = rig.hub.topic_info(&name).?;
    try std.testing.expectEqualSlices(u8, &name, info.name);
    try std.testing.expectEqual(@as(usize, 1), info.subscriber_count);

    var payload = [_]u8{'x'};
    try std.testing.expectEqual(@as(usize, 1), (try rig.hub.publish(&name, &payload, .text)).delivered);

    var other = [_]u8{ 'a', 0x00, 'b', 0xfe };
    try std.testing.expectError(
        error.TopicNotFound,
        rig.hub.publish(&other, &payload, .text),
    );
}

test "PubSub: removing a topic invalidates the borrowed info" {
    var rig: PubSubRig(1, 1, 8, 2) = .{};
    try rig.init();

    var fleet: PubSubFleet(1, 8, 2, 32, 8, 0, 16) = .{};
    try fleet.init(.{ .role = .server });

    _ = try rig.hub.subscribe(fleet.ws(0), "alpha");
    const info = rig.hub.topic_info("alpha").?;
    try std.testing.expectEqualStrings("alpha", info.name);
    try std.testing.expectEqual(@as(usize, 1), info.subscriber_count);

    try rig.hub.unsubscribe(fleet.ws(0), "alpha");
    try std.testing.expect(rig.hub.topic_info("alpha") == null);
    try std.testing.expect(!rig.hub.is_subscribed(fleet.ws(0), "alpha"));
    try std.testing.expectEqual(@as(usize, 0), rig.hub.topic_count());

    const replacement = try rig.hub.subscribe(fleet.ws(0), "beta");
    try std.testing.expect(replacement.added);
    try std.testing.expect(rig.hub.topic_info("beta") != null);
    try std.testing.expect(rig.hub.topic_info("alpha") == null);
}

test "PubSub: topic ids are reusable and mutation APIs take names" {
    var rig: PubSubRig(1, 1, 8, 2) = .{};
    try rig.init();

    var fleet: PubSubFleet(1, 8, 2, 32, 8, 0, 16) = .{};
    try fleet.init(.{ .role = .server });

    const first = try rig.hub.subscribe(fleet.ws(0), "alpha");
    try rig.hub.unsubscribe(fleet.ws(0), "alpha");

    const second = try rig.hub.subscribe(fleet.ws(0), "beta");
    try std.testing.expectEqual(first.topic_id, second.topic_id);
    try std.testing.expectEqual(second.topic_id, rig.hub.topic_info("beta").?.id);

    // The stale name from the removed topic cannot address the reused slot.
    try std.testing.expectError(
        error.TopicNotFound,
        rig.hub.unsubscribe(fleet.ws(0), "alpha"),
    );
    // A topic id's textual form is just another name, not a mutation handle.
    try std.testing.expectError(
        error.TopicNotFound,
        rig.hub.unsubscribe(fleet.ws(0), "0"),
    );
    try std.testing.expect(rig.hub.topic_info("alpha") == null);
    try std.testing.expect(!rig.hub.is_subscribed(fleet.ws(0), "alpha"));
    try std.testing.expect(!rig.hub.is_subscribed(fleet.ws(0), "0"));
    try std.testing.expectEqual(@as(usize, 1), rig.hub.topic_count());
    try std.testing.expectEqual(@as(usize, 1), rig.hub.subscription_count());

    try rig.hub.unsubscribe(fleet.ws(0), "beta");
    try std.testing.expectEqual(@as(usize, 0), rig.hub.topic_count());
}
