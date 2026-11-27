const std = @import("std");
const tachyon = @import("tachyon");

const support = @import("../support.zig");

const pubsub = tachyon.pubsub;
const Hub = pubsub.Hub;
const Storage = pubsub.Storage;
const PubSubRig = support.PubSubRig;
const PubSubFleet = support.PubSubFleet;
const next_wire_frame = support.next_wire_frame;

test "PubSub: init rejects zero capacities, name mismatch, and invalid index" {
    var no_topics: [0]pubsub.TopicSlot = .{};
    var one_topic: [1]pubsub.TopicSlot = undefined;
    var two_topics: [2]pubsub.TopicSlot = undefined;
    var no_subscriptions: [0]pubsub.SubscriptionSlot = .{};
    var one_subscription: [1]pubsub.SubscriptionSlot = undefined;
    var no_names: [0]u8 = .{};
    var one_name: [1]u8 = undefined;
    var two_names: [2]u8 = undefined;
    var three_names: [3]u8 = undefined;
    var index_two: [2]pubsub.TopicIndexSlot = undefined;
    var index_three: [3]pubsub.TopicIndexSlot = undefined;

    try std.testing.expectError(error.InvalidTopicCapacity, Hub.init(.{
        .topics = &no_topics,
        .subscriptions = &one_subscription,
        .names = &no_names,
        .topic_index = &index_two,
    }, .{ .max_topic_len = 1 }));

    try std.testing.expectError(error.InvalidSubscriptionCapacity, Hub.init(.{
        .topics = &one_topic,
        .subscriptions = &no_subscriptions,
        .names = &one_name,
        .topic_index = &index_two,
    }, .{ .max_topic_len = 1 }));

    try std.testing.expectError(error.InvalidNameCapacity, Hub.init(.{
        .topics = &one_topic,
        .subscriptions = &one_subscription,
        .names = &no_names,
        .topic_index = &index_two,
    }, .{ .max_topic_len = 0 }));

    // The name arena must be exactly topics * max_topic_len, both short and
    // long allocations are rejected rather than silently resized.
    try std.testing.expectError(error.InvalidNameCapacity, Hub.init(.{
        .topics = &one_topic,
        .subscriptions = &one_subscription,
        .names = &one_name,
        .topic_index = &index_two,
    }, .{ .max_topic_len = 2 }));

    try std.testing.expectError(error.InvalidNameCapacity, Hub.init(.{
        .topics = &one_topic,
        .subscriptions = &one_subscription,
        .names = &three_names,
        .topic_index = &index_two,
    }, .{ .max_topic_len = 2 }));

    // The index must be a power of two and at least twice the topic capacity.
    try std.testing.expectError(error.InvalidIndexCapacity, Hub.init(.{
        .topics = &one_topic,
        .subscriptions = &one_subscription,
        .names = &one_name,
        .topic_index = &index_three,
    }, .{ .max_topic_len = 1 }));

    try std.testing.expectError(error.InvalidIndexCapacity, Hub.init(.{
        .topics = &two_topics,
        .subscriptions = &one_subscription,
        .names = &two_names,
        .topic_index = &index_two,
    }, .{ .max_topic_len = 1 }));
}

test "PubSub: init rejects aliased storage regions" {
    var topics: [1]pubsub.TopicSlot = undefined;
    var subscriptions: [4]pubsub.SubscriptionSlot = undefined;
    var index: [2]pubsub.TopicIndexSlot = undefined;
    var one_name: [1]u8 = undefined;

    const topic_bytes: []u8 = std.mem.sliceAsBytes(&topics);
    try std.testing.expectError(error.AliasedStorage, Hub.init(.{
        .topics = &topics,
        .subscriptions = &subscriptions,
        .names = topic_bytes[0..1],
        .topic_index = &index,
    }, .{ .max_topic_len = 1 }));

    const subscriptions_as_index: [*]pubsub.TopicIndexSlot = @ptrCast(@alignCast(&subscriptions));
    try std.testing.expectError(error.AliasedStorage, Hub.init(.{
        .topics = &topics,
        .subscriptions = &subscriptions,
        .names = &one_name,
        .topic_index = subscriptions_as_index[0..2],
    }, .{ .max_topic_len = 1 }));
}

test "PubSub: init accepts the minimal T=1 S=1 L=1 I=2 configuration" {
    var rig: PubSubRig(1, 1, 1, 2) = .{};
    try rig.init();

    try std.testing.expectEqual(@as(usize, 0), rig.hub.topic_count());
    try std.testing.expectEqual(@as(usize, 0), rig.hub.subscription_count());
    try std.testing.expectEqual(@as(usize, 1), rig.hub.topics.len);
    try std.testing.expectEqual(@as(usize, 1), rig.hub.subscriptions.len);
    try std.testing.expectEqual(@as(usize, 1), rig.hub.names.len);
    try std.testing.expectEqual(@as(usize, 2), rig.hub.topic_index.len);

    var fleet: PubSubFleet(1, 8, 2, 32, 8, 0, 16) = .{};
    try fleet.init(.{ .role = .server });

    var name = [_]u8{'x'};
    const result = try rig.hub.subscribe(fleet.ws(0), &name);
    try std.testing.expect(result.added);
    try std.testing.expectEqual(@as(usize, 1), rig.hub.topic_count());
    try std.testing.expectEqual(@as(usize, 1), rig.hub.subscription_count());
}

test "PubSub: required_name_bytes checks capacity and overflow" {
    try std.testing.expectError(error.InvalidTopicCapacity, pubsub.required_name_bytes(0, 1));
    try std.testing.expectError(error.InvalidNameCapacity, pubsub.required_name_bytes(1, 0));
    try std.testing.expectEqual(@as(usize, 1), try pubsub.required_name_bytes(1, 1));
    try std.testing.expectEqual(@as(usize, 12), try pubsub.required_name_bytes(3, 4));
    try std.testing.expectEqual(@as(usize, 131_072), try pubsub.required_name_bytes(1024, 128));
    try std.testing.expectError(
        error.SizeOverflow,
        pubsub.required_name_bytes(std.math.maxInt(usize), 2),
    );
}

test "PubSub: required_index_capacity rounds up to a power of two" {
    try std.testing.expectError(error.InvalidTopicCapacity, pubsub.required_index_capacity(0));

    const cases = [_][2]usize{
        .{ 1, 2 },
        .{ 2, 4 },
        .{ 3, 8 },
        .{ 4, 8 },
        .{ 5, 16 },
        .{ 8, 16 },
        .{ 9, 32 },
    };
    for (cases) |case| {
        const actual = try pubsub.required_index_capacity(case[0]);
        try std.testing.expectEqual(case[1], actual);
        try std.testing.expect(std.math.isPowerOfTwo(actual));
        try std.testing.expect(actual >= 2 * case[0]);
    }

    try std.testing.expectError(
        error.SizeOverflow,
        pubsub.required_index_capacity(std.math.maxInt(usize)),
    );
    try std.testing.expectError(
        error.SizeOverflow,
        pubsub.required_index_capacity(std.math.maxInt(usize) / 2 + 1),
    );
}

test "PubSub: duplicate subscribe is idempotent even at full subscription capacity" {
    var rig: PubSubRig(1, 1, 4, 2) = .{};
    try rig.init();

    var fleet: PubSubFleet(2, 8, 2, 32, 8, 0, 16) = .{};
    try fleet.init(.{ .role = .server });

    const first = try rig.hub.subscribe(fleet.ws(0), "room");
    try std.testing.expect(first.added);
    try std.testing.expectEqual(@as(usize, 1), rig.hub.subscription_count());

    const duplicate = try rig.hub.subscribe(fleet.ws(0), "room");
    try std.testing.expect(!duplicate.added);
    try std.testing.expectEqual(first.topic_id, duplicate.topic_id);
    try std.testing.expectEqual(@as(usize, 1), rig.hub.topic_count());
    try std.testing.expectEqual(@as(usize, 1), rig.hub.subscription_count());

    try std.testing.expectError(
        error.SubscriptionCapacityReached,
        rig.hub.subscribe(fleet.ws(1), "room"),
    );
    try std.testing.expect(rig.hub.is_subscribed(fleet.ws(0), "room"));
}

test "PubSub: a new topic at full subscription capacity does not orphan" {
    var rig: PubSubRig(2, 1, 4, 4) = .{};
    try rig.init();

    var fleet: PubSubFleet(1, 8, 2, 32, 8, 0, 16) = .{};
    try fleet.init(.{ .role = .server });

    _ = try rig.hub.subscribe(fleet.ws(0), "a");
    try std.testing.expectError(
        error.SubscriptionCapacityReached,
        rig.hub.subscribe(fleet.ws(0), "b"),
    );

    try std.testing.expectEqual(@as(usize, 1), rig.hub.topic_count());
    try std.testing.expectEqual(@as(usize, 1), rig.hub.subscription_count());
    try std.testing.expect(rig.hub.topic_info("b") == null);
    try std.testing.expect(!rig.hub.is_subscribed(fleet.ws(0), "b"));
    try rig.hub.unsubscribe(fleet.ws(0), "a");
}

test "PubSub: a new topic at full topic capacity returns TopicCapacityReached" {
    var rig: PubSubRig(1, 2, 4, 2) = .{};
    try rig.init();

    var fleet: PubSubFleet(2, 8, 2, 32, 8, 0, 16) = .{};
    try fleet.init(.{ .role = .server });

    _ = try rig.hub.subscribe(fleet.ws(0), "a");
    try std.testing.expectError(
        error.TopicCapacityReached,
        rig.hub.subscribe(fleet.ws(1), "b"),
    );

    try std.testing.expectEqual(@as(usize, 1), rig.hub.topic_count());
    try std.testing.expectEqual(@as(usize, 1), rig.hub.subscription_count());
    try std.testing.expect(rig.hub.topic_info("b") == null);
}

test "PubSub: subscribe rejects a name aliasing hub storage" {
    var rig: PubSubRig(2, 2, 8, 4) = .{};
    try rig.init();

    var fleet: PubSubFleet(1, 8, 2, 32, 8, 0, 16) = .{};
    try fleet.init(.{ .role = .server });

    @memcpy(rig.names[0..4], "junk");
    const aliased: []const u8 = rig.names[0..4];

    try std.testing.expectError(
        error.AliasedTopicName,
        rig.hub.subscribe(fleet.ws(0), aliased),
    );
    try std.testing.expectEqual(@as(usize, 0), rig.hub.topic_count());
    try std.testing.expectEqual(@as(usize, 0), rig.hub.subscription_count());
    try std.testing.expect(rig.hub.topic_info(aliased) == null);
    try std.testing.expect(!rig.hub.is_subscribed(fleet.ws(0), aliased));
}

test "PubSub: subscribe rejects a name aliasing the hub object" {
    var rig: PubSubRig(2, 2, 8, 4) = .{};
    try rig.init();

    var fleet: PubSubFleet(1, 8, 2, 32, 8, 0, 16) = .{};
    try fleet.init(.{ .role = .server });

    const hub_bytes: []u8 = std.mem.asBytes(&rig.hub);
    const max_topic_len: usize = @intCast(rig.hub.max_topic_len);
    const storage: Storage = rig.storage();
    var name_len: usize = 1;
    while (name_len <= max_topic_len) : (name_len += 1) {
        const aliased: []const u8 = hub_bytes[0..name_len];

        // The storage region check alone must not reject this name: only the
        // hub-object branch can catch it.
        try std.testing.expect(!storage.overlaps(aliased));
        try std.testing.expectError(
            error.AliasedTopicName,
            rig.hub.subscribe(fleet.ws(0), aliased),
        );
        try std.testing.expectEqual(@as(usize, 0), rig.hub.topic_count());
        try std.testing.expectEqual(@as(usize, 0), rig.hub.subscription_count());
        try std.testing.expect(rig.hub.topic_info(aliased) == null);
        try std.testing.expect(!rig.hub.is_subscribed(fleet.ws(0), aliased));
    }

    // An ordinary stack name still takes the normal path after every rejection.
    var ordinary = [_]u8{ 'r', 'o', 'o', 'm' };
    const subscribed = try rig.hub.subscribe(fleet.ws(0), &ordinary);
    try std.testing.expect(subscribed.added);
    try std.testing.expectEqual(@as(usize, 1), rig.hub.topic_count());
    try std.testing.expectEqual(@as(usize, 1), rig.hub.subscription_count());
    try std.testing.expect(rig.hub.topic_info(&ordinary) != null);
    try std.testing.expect(rig.hub.is_subscribed(fleet.ws(0), &ordinary));
}

test "PubSub: unknown unsubscribe differs from not-subscribed" {
    var rig: PubSubRig(2, 2, 8, 4) = .{};
    try rig.init();

    var fleet: PubSubFleet(2, 8, 2, 32, 8, 0, 16) = .{};
    try fleet.init(.{ .role = .server });

    try std.testing.expectError(
        error.TopicNotFound,
        rig.hub.unsubscribe(fleet.ws(0), "missing"),
    );

    _ = try rig.hub.subscribe(fleet.ws(0), "a");
    try std.testing.expectError(
        error.NotSubscribed,
        rig.hub.unsubscribe(fleet.ws(1), "a"),
    );

    try std.testing.expectEqual(@as(usize, 1), rig.hub.topic_count());
    try std.testing.expectEqual(@as(usize, 1), rig.hub.subscription_count());
}

test "PubSub: last unsubscribe frees the topic and reuses the stable id" {
    var rig: PubSubRig(2, 2, 8, 4) = .{};
    try rig.init();

    var fleet: PubSubFleet(2, 8, 2, 32, 8, 0, 16) = .{};
    try fleet.init(.{ .role = .server });

    const first = try rig.hub.subscribe(fleet.ws(0), "alpha");
    try std.testing.expectEqual(@as(usize, 1), rig.hub.topic_info("alpha").?.subscriber_count);

    try rig.hub.unsubscribe(fleet.ws(0), "alpha");
    try std.testing.expectEqual(@as(usize, 0), rig.hub.topic_count());
    try std.testing.expectEqual(@as(usize, 0), rig.hub.subscription_count());
    try std.testing.expect(rig.hub.topic_info("alpha") == null);
    try std.testing.expect(!rig.hub.is_subscribed(fleet.ws(0), "alpha"));

    const second = try rig.hub.subscribe(fleet.ws(1), "beta");
    try std.testing.expect(second.added);
    try std.testing.expectEqual(first.topic_id, second.topic_id);
    try std.testing.expectEqual(first.topic_id, rig.hub.topic_info("beta").?.id);
}

test "PubSub: unsubscribe_all removes only the target connection" {
    var rig: PubSubRig(2, 3, 4, 4) = .{};
    try rig.init();

    var fleet: PubSubFleet(2, 8, 2, 32, 8, 0, 16) = .{};
    try fleet.init(.{ .role = .server });

    _ = try rig.hub.subscribe(fleet.ws(0), "a");
    _ = try rig.hub.subscribe(fleet.ws(1), "a");
    _ = try rig.hub.subscribe(fleet.ws(0), "b");

    try std.testing.expectEqual(@as(usize, 2), try rig.hub.unsubscribe_all(fleet.ws(0)));
    try std.testing.expectEqual(@as(usize, 1), rig.hub.topic_count());
    try std.testing.expectEqual(@as(usize, 1), rig.hub.subscription_count());
    try std.testing.expect(!rig.hub.is_subscribed(fleet.ws(0), "a"));
    try std.testing.expect(!rig.hub.is_subscribed(fleet.ws(0), "b"));
    try std.testing.expect(rig.hub.is_subscribed(fleet.ws(1), "a"));
    try std.testing.expectEqual(@as(usize, 1), rig.hub.topic_info("a").?.subscriber_count);
    try std.testing.expect(rig.hub.topic_info("b") == null);
    try std.testing.expectEqual(@as(usize, 0), try rig.hub.unsubscribe_all(fleet.ws(0)));
}

test "PubSub: unsubscribe_all removes multiple solely owned topics" {
    var rig: PubSubRig(3, 3, 8, 8) = .{};
    try rig.init();

    var fleet: PubSubFleet(2, 8, 2, 32, 8, 0, 16) = .{};
    try fleet.init(.{ .role = .server });

    _ = try rig.hub.subscribe(fleet.ws(0), "a");
    _ = try rig.hub.subscribe(fleet.ws(0), "b");
    _ = try rig.hub.subscribe(fleet.ws(1), "c");

    try std.testing.expectEqual(@as(usize, 2), try rig.hub.unsubscribe_all(fleet.ws(0)));
    try std.testing.expectEqual(@as(usize, 1), rig.hub.topic_count());
    try std.testing.expectEqual(@as(usize, 1), rig.hub.subscription_count());
    try std.testing.expect(rig.hub.topic_info("a") == null);
    try std.testing.expect(rig.hub.topic_info("b") == null);
    try std.testing.expectEqual(@as(usize, 1), rig.hub.topic_info("c").?.subscriber_count);
    try std.testing.expect(rig.hub.is_subscribed(fleet.ws(1), "c"));
    try std.testing.expect(!rig.hub.is_subscribed(fleet.ws(0), "c"));

    var payload = [_]u8{'c'};
    const result = try rig.hub.publish("c", &payload, .text);
    try std.testing.expectEqual(@as(usize, 1), result.matched);
    try std.testing.expectEqual(@as(usize, 1), result.delivered);

    try fleet.rigs[1].ws.flush();
    var index: usize = 0;
    const frame = try next_wire_frame(fleet.rigs[1].bytes(), &index);
    try std.testing.expectEqualSlices(u8, &payload, frame.payload);
    try std.testing.expectEqual(fleet.rigs[1].writer.written, index);
}

test "PubSub: index churn keeps stable ids" {
    var rig: PubSubRig(2, 2, 8, 4) = .{};
    try rig.init();

    var fleet: PubSubFleet(2, 8, 2, 32, 8, 0, 16) = .{};
    try fleet.init(.{ .role = .server });

    // Each cycle leaves one tombstone, which equals the rebuild floor
    // (topic_index.len / 4 == 1), so the next subscribe reuses both that
    // tombstone and the free topic and subscription rows instead of rebuilding.
    var churn_id: ?pubsub.TopicId = null;
    for (0..4200) |_| {
        const subscribed = try rig.hub.subscribe(fleet.ws(0), "churn");
        try std.testing.expect(subscribed.added);
        if (churn_id) |stable_id| {
            try std.testing.expectEqual(stable_id, subscribed.topic_id);
        } else {
            churn_id = subscribed.topic_id;
        }
        try rig.hub.unsubscribe(fleet.ws(0), "churn");
    }
    try std.testing.expectEqual(@as(usize, 0), rig.hub.topic_count());
    try std.testing.expectEqual(@as(usize, 0), rig.hub.subscription_count());

    _ = try rig.hub.subscribe(fleet.ws(0), "alpha");
    _ = try rig.hub.subscribe(fleet.ws(1), "beta");

    var alpha_payload = [_]u8{'a'};
    var beta_payload = [_]u8{'b'};
    const alpha = try rig.hub.publish("alpha", &alpha_payload, .text);
    const beta = try rig.hub.publish("beta", &beta_payload, .text);
    try std.testing.expectEqual(@as(usize, 1), alpha.matched);
    try std.testing.expectEqual(@as(usize, 1), alpha.delivered);
    try std.testing.expectEqual(@as(usize, 1), beta.matched);
    try std.testing.expectEqual(@as(usize, 1), beta.delivered);

    try fleet.rigs[0].ws.flush();
    try fleet.rigs[1].ws.flush();

    var index: usize = 0;
    const alpha_frame = try next_wire_frame(fleet.rigs[0].bytes(), &index);
    try std.testing.expectEqualSlices(u8, &alpha_payload, alpha_frame.payload);
    try std.testing.expectEqual(fleet.rigs[0].writer.written, index);

    index = 0;
    const beta_frame = try next_wire_frame(fleet.rigs[1].bytes(), &index);
    try std.testing.expectEqualSlices(u8, &beta_payload, beta_frame.payload);
    try std.testing.expectEqual(fleet.rigs[1].writer.written, index);
}

test "PubSub: index rebuild reinserts the surviving topic" {
    var rig: PubSubRig(4, 4, 8, 8) = .{};
    try rig.init();

    var fleet: PubSubFleet(4, 8, 2, 32, 8, 0, 16) = .{};
    try fleet.init(.{ .role = .server });

    _ = try rig.hub.subscribe(fleet.ws(0), "keep");
    _ = try rig.hub.subscribe(fleet.ws(1), "drop1");
    _ = try rig.hub.subscribe(fleet.ws(2), "drop2");
    _ = try rig.hub.subscribe(fleet.ws(3), "drop3");
    try std.testing.expectEqual(@as(usize, 4), rig.hub.topic_count());

    try rig.hub.unsubscribe(fleet.ws(1), "drop1");
    try std.testing.expectEqual(@as(usize, 1), rig.hub.tombstone_count);
    try rig.hub.unsubscribe(fleet.ws(2), "drop2");
    // Two tombstones reach the rebuild floor but do not exceed it, so the
    // index still holds both entries.
    try std.testing.expectEqual(rig.hub.topic_index.len / 4, rig.hub.tombstone_count);

    // The third removal would exceed the floor, so unsubscribe rebuilds the
    // index immediately instead of leaving the excess for the next subscribe.
    try std.testing.expect(rig.hub.tombstone_count + 1 > rig.hub.topic_index.len / 4);
    try rig.hub.unsubscribe(fleet.ws(3), "drop3");
    try std.testing.expectEqual(@as(usize, 0), rig.hub.tombstone_count);
    try std.testing.expectEqual(@as(usize, 1), rig.hub.topic_count());
    try std.testing.expect(rig.hub.topic_info("keep") != null);
    try std.testing.expect(rig.hub.topic_info("drop1") == null);
    try std.testing.expect(rig.hub.topic_info("drop2") == null);
    try std.testing.expect(rig.hub.topic_info("drop3") == null);

    _ = try rig.hub.subscribe(fleet.ws(0), "fresh");
    try std.testing.expectEqual(@as(usize, 2), rig.hub.topic_count());
    try std.testing.expectEqual(@as(usize, 0), rig.hub.tombstone_count);
    try std.testing.expect(rig.hub.topic_info("keep") != null);
    try std.testing.expect(rig.hub.topic_info("fresh") != null);

    var keep_payload = [_]u8{'k'};
    var fresh_payload = [_]u8{'f'};
    const keep = try rig.hub.publish("keep", &keep_payload, .text);
    const fresh = try rig.hub.publish("fresh", &fresh_payload, .text);
    try std.testing.expectEqual(@as(usize, 1), keep.matched);
    try std.testing.expectEqual(@as(usize, 1), keep.delivered);
    try std.testing.expectEqual(@as(usize, 1), fresh.matched);
    try std.testing.expectEqual(@as(usize, 1), fresh.delivered);

    try fleet.rigs[0].ws.flush();

    var index: usize = 0;
    const keep_frame = try next_wire_frame(fleet.rigs[0].bytes(), &index);
    try std.testing.expectEqualSlices(u8, &keep_payload, keep_frame.payload);
    const fresh_frame = try next_wire_frame(fleet.rigs[0].bytes(), &index);
    try std.testing.expectEqualSlices(u8, &fresh_payload, fresh_frame.payload);
    try std.testing.expectEqual(fleet.rigs[0].writer.written, index);
}

test "PubSub: storage overlap check ignores empty and disjoint slices" {
    var rig: PubSubRig(1, 1, 4, 2) = .{};
    try rig.init();
    const storage: Storage = rig.storage();

    var empty: [0]u8 = .{};
    try std.testing.expect(!storage.overlaps(&empty));

    var outside: [4]u8 = undefined;
    try std.testing.expect(!storage.overlaps(&outside));

    try std.testing.expect(storage.overlaps(rig.names[0..1]));
    try std.testing.expect(storage.overlaps(std.mem.sliceAsBytes(&rig.topics)));
    try std.testing.expect(storage.overlaps(std.mem.sliceAsBytes(&rig.topic_index)));
}
