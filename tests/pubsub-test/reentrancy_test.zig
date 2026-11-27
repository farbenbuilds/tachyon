const std = @import("std");
const tachyon = @import("tachyon");

const support = @import("../support.zig");

const Frame = support.Frame;
const PubSubRig = support.PubSubRig;
const PubSubFleet = support.PubSubFleet;

test "PubSub: publish_depth rejects every mutating entry point" {
    var rig: PubSubRig(2, 2, 8, 4) = .{};
    try rig.init();

    var fleet: PubSubFleet(2, 8, 2, 32, 8, 0, 32) = .{};
    try fleet.init(.{ .role = .server });

    _ = try rig.hub.subscribe(fleet.ws(0), "room");
    _ = try rig.hub.subscribe(fleet.ws(1), "room");
    const topics_before = rig.hub.topic_count();
    const subscriptions_before = rig.hub.subscription_count();

    rig.hub.publish_depth = 1;
    defer rig.hub.publish_depth = 0;

    var payload = [_]u8{'x'};
    try std.testing.expectError(
        error.PublishInProgress,
        rig.hub.subscribe(fleet.ws(0), "other"),
    );
    try std.testing.expectError(
        error.PublishInProgress,
        rig.hub.unsubscribe(fleet.ws(0), "room"),
    );
    try std.testing.expectError(
        error.PublishInProgress,
        rig.hub.unsubscribe_all(fleet.ws(0)),
    );
    try std.testing.expectError(
        error.PublishInProgress,
        rig.hub.publish("room", &payload, .text),
    );
    try std.testing.expectError(
        error.PublishInProgress,
        rig.hub.publish_from(fleet.ws(0), "room", &payload, .text),
    );

    try std.testing.expectEqual(topics_before, rig.hub.topic_count());
    try std.testing.expectEqual(subscriptions_before, rig.hub.subscription_count());
    try std.testing.expect(rig.hub.topic_info("room") != null);
    try std.testing.expect(rig.hub.topic_info("other") == null);
    try std.testing.expect(rig.hub.is_subscribed(fleet.ws(0), "room"));
    try std.testing.expect(rig.hub.is_subscribed(fleet.ws(1), "room"));
    try std.testing.expectEqual(@as(usize, 0), fleet.rigs[0].ws.tx_pending());
    try std.testing.expectEqual(@as(usize, 0), fleet.rigs[1].ws.tx_pending());
}

test "PubSub: a normal publish clears the reentrancy guard" {
    var rig: PubSubRig(2, 2, 8, 4) = .{};
    try rig.init();

    var fleet: PubSubFleet(2, 8, 2, 32, 8, 0, 32) = .{};
    try fleet.init(.{ .role = .server });
    _ = try rig.hub.subscribe(fleet.ws(0), "room");

    var payload = [_]u8{'x'};
    const result = try rig.hub.publish("room", &payload, .text);
    try std.testing.expectEqual(@as(usize, 1), result.delivered);
    try std.testing.expectEqual(@as(u32, 0), rig.hub.publish_depth);

    // The guard is cleared even though the delivered frame is still queued.
    try std.testing.expectEqual(@as(usize, 1), fleet.rigs[0].ws.tx_pending());
    const subscribe_result = try rig.hub.subscribe(fleet.ws(1), "next");
    try std.testing.expect(subscribe_result.added);
}

test "PubSub: a failed topic lookup does not latch the guard" {
    var rig: PubSubRig(1, 1, 8, 2) = .{};
    try rig.init();

    var fleet: PubSubFleet(1, 8, 2, 32, 8, 0, 32) = .{};
    try fleet.init(.{ .role = .server });

    var payload = [_]u8{'x'};
    try std.testing.expectError(
        error.TopicNotFound,
        rig.hub.publish("missing", &payload, .text),
    );
    try std.testing.expectEqual(@as(u32, 0), rig.hub.publish_depth);

    try std.testing.expectError(
        error.EmptyTopic,
        rig.hub.publish("", &payload, .text),
    );
    try std.testing.expectEqual(@as(u32, 0), rig.hub.publish_depth);

    _ = try rig.hub.subscribe(fleet.ws(0), "room");
    const result = try rig.hub.publish("room", &payload, .text);
    try std.testing.expectEqual(@as(usize, 1), result.delivered);
    try std.testing.expectEqual(@as(u32, 0), rig.hub.publish_depth);
}

test "PubSub: a closed subscriber does not mutate topic or subscription counts" {
    var rig: PubSubRig(1, 2, 8, 2) = .{};
    try rig.init();

    var fleet: PubSubFleet(2, 8, 2, 32, 8, 0, 32) = .{};
    try fleet.init(.{ .role = .server });
    _ = try rig.hub.subscribe(fleet.ws(0), "room");
    _ = try rig.hub.subscribe(fleet.ws(1), "room");

    var close_storage: [2]u8 = undefined;
    try fleet.rigs[0].ws.write_frame(try Frame.close(1000, "", &close_storage));

    var payload = [_]u8{'x'};
    const result = try rig.hub.publish("room", &payload, .text);
    try std.testing.expectEqual(@as(usize, 2), result.matched);
    try std.testing.expectEqual(@as(usize, 1), result.delivered);
    try std.testing.expectEqual(@as(usize, 1), result.skipped);
    try std.testing.expectEqual(@as(usize, 1), result.closed);

    try std.testing.expectEqual(@as(usize, 1), rig.hub.topic_count());
    try std.testing.expectEqual(@as(usize, 2), rig.hub.subscription_count());
    try std.testing.expectEqual(@as(usize, 2), rig.hub.topic_info("room").?.subscriber_count);
    try std.testing.expect(rig.hub.is_subscribed(fleet.ws(0), "room"));

    try rig.hub.unsubscribe(fleet.ws(0), "room");
    try std.testing.expectEqual(@as(usize, 1), rig.hub.subscription_count());
    try std.testing.expectEqual(@as(usize, 1), rig.hub.topic_info("room").?.subscriber_count);
    try rig.hub.unsubscribe(fleet.ws(1), "room");
    try std.testing.expectEqual(@as(usize, 0), rig.hub.topic_count());
}
