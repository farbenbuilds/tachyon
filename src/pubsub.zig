//! Bounded zero-allocation topic hub and fanout for application messages.
//!
//! The hub is a registry over caller-owned storage: one open-addressed topic
//! index, stable topic and subscription rows, and a fixed-stride name arena.
//! It never allocates, opens I/O, or owns a queue. Publishing walks one topic's
//! intrusive subscriber list and gives each eligible subscriber a fresh
//! `stream.MessageWriter`, which queues one frame into that connection's bounded
//! transmit ring through `connection.WebSocket.enqueue_frame`.
//!
//! The hub never flushes. A delivery is a successful enqueue, not a wire
//! acknowledgement, and the payload stays borrowed by every queued frame until
//! the caller flushes each connection. `PublishResult` reports backpressured,
//! closed, and other skipped subscribers without mutating the registry.
//!
//! Names are opaque bytes copied into `Storage.names`; they are exact and
//! case-sensitive. The hub is not synchronized: the caller serializes access.
//! Mutating calls are rejected while a publish is in progress, so a nested
//! publish or registry change cannot invalidate the list being walked.
//!
//! Subscribed `*connection.WebSocket` values and every `Storage` backing array
//! must keep a stable address and outlive their subscriptions. The caller must
//! call `Hub.unsubscribe_all` before destroying a connection or moving storage.

const std = @import("std");
const connection = @import("connection.zig");
const stream = @import("stream.zig");

/// Text or binary message kind from the chunked stream layer.
pub const MessageKind = stream.MessageKind;

/// Stable topic slot id. A removed id may be reused by a later topic.
pub const TopicId = enum(u32) {
    none = std.math.maxInt(u32),
    _,
};

/// Free-list terminator and invalid slot id. Valid slots are below the caller
/// capacity, which init bounds by this value.
const no_link: u32 = std.math.maxInt(u32);

/// Hub and subscription errors.
pub const Error = error{
    EmptyTopic,
    TopicTooLong,
    TopicCapacityReached,
    SubscriptionCapacityReached,
    TopicNotFound,
    NotSubscribed,
    PublishInProgress,
};

/// Subscribe adds a name-copy alias rejection to the common errors.
pub const SubscribeError = Error || error{AliasedTopicName};

/// Publish adds a payload alias rejection to the common errors.
pub const PublishError = Error || error{AliasedPayload};

/// Construction errors for the hub and the capacity helpers.
pub const InitError = error{
    InvalidTopicCapacity,
    InvalidSubscriptionCapacity,
    InvalidNameCapacity,
    InvalidIndexCapacity,
    AliasedStorage,
    SizeOverflow,
};

/// Hub construction options.
pub const Options = struct {
    /// Maximum topic-name length and the fixed stride of `Storage.names`.
    max_topic_len: u32,
};

/// Stable topic row. Fields are implementation details of `Hub`.
pub const TopicSlot = struct {
    hash: u64 = 0,
    head: u32 = no_link,
    tail: u32 = no_link,
    subscriber_count: u32 = 0,
    name_len: u32 = 0,
    next_free: u32 = no_link,
    used: bool = false,
};

/// Stable subscription row, linked into one topic's intrusive list.
/// Fields are implementation details of `Hub`.
pub const SubscriptionSlot = struct {
    ws: ?*connection.WebSocket = null,
    topic: TopicId = .none,
    next: u32 = no_link,
    prev: u32 = no_link,
    next_free: u32 = no_link,
    used: bool = false,
};

/// Open-addressed topic-index row with tombstones.
/// Fields are implementation details of `Hub`.
pub const TopicIndexSlot = struct {
    hash: u64 = 0,
    topic: u32 = no_link,
    used: bool = false,
    tombstone: bool = false,
};

/// Caller-owned storage regions. Every slice must keep a stable address and
/// outlive the hub and all of its subscriptions; call `Hub.unsubscribe_all`
/// before destroying a connection or moving the storage.
pub const Storage = struct {
    topics: []TopicSlot,
    subscriptions: []SubscriptionSlot,
    /// Exactly `topics.len * Options.max_topic_len` bytes. Topic slot `i`
    /// owns `names[i * max_topic_len ..][0..max_topic_len]`.
    names: []u8,
    topic_index: []TopicIndexSlot,

    /// True when `bytes` overlaps any byte of this storage.
    ///
    /// Empty slices never overlap. Adjacent regions do not overlap.
    pub fn overlaps(self: Storage, bytes: []const u8) bool {
        const topic_bytes: []const u8 = std.mem.sliceAsBytes(self.topics);
        const subscription_bytes: []const u8 = std.mem.sliceAsBytes(self.subscriptions);
        const index_bytes: []const u8 = std.mem.sliceAsBytes(self.topic_index);
        return ranges_overlap(bytes, topic_bytes) or
            ranges_overlap(bytes, subscription_bytes) or
            ranges_overlap(bytes, self.names) or
            ranges_overlap(bytes, index_bytes);
    }
};

/// Result of a subscribe call.
pub const SubscribeResult = struct {
    topic_id: TopicId,
    /// False when the connection was already subscribed.
    added: bool,
};

/// Borrowed view of one topic.
pub const TopicInfo = struct {
    id: TopicId,
    /// Borrows `Storage.names` until the topic is removed.
    name: []const u8,
    subscriber_count: usize,
};

/// Result of one publish fanout.
pub const PublishResult = struct {
    topic_id: TopicId,
    /// Eligible subscribers after excluding the sender.
    matched: usize,
    /// Subscribers whose frame was successfully enqueued.
    delivered: usize,
    /// `matched - delivered`.
    skipped: usize,
    /// Skipped with `WouldBlock` or `QueueFull`.
    backpressured: usize,
    /// Skipped with `ConnectionClosed`.
    closed: usize,
    /// First delivery error in list order, retained for diagnostics.
    first_error: ?connection.Error,

    /// True when every matched subscriber accepted the frame.
    pub fn is_complete(self: PublishResult) bool {
        return self.skipped == 0;
    }
};

/// Bounded topic registry and fanout hub.
pub const Hub = struct {
    topics: []TopicSlot,
    subscriptions: []SubscriptionSlot,
    names: []u8,
    topic_index: []TopicIndexSlot,
    max_topic_len: u32,

    active_topics: usize = 0,
    active_subscriptions: usize = 0,
    free_topic: u32 = no_link,
    free_subscription: u32 = no_link,
    tombstone_count: usize = 0,
    publish_depth: u32 = 0,

    /// Validates storage and options, then initializes the free lists and
    /// index. All capacity arithmetic is checked.
    pub fn init(storage: Storage, options: Options) InitError!Hub {
        const topic_capacity = storage.topics.len;
        if (topic_capacity == 0) return error.InvalidTopicCapacity;
        if (topic_capacity > std.math.maxInt(u32)) return error.InvalidTopicCapacity;

        const subscription_capacity = storage.subscriptions.len;
        if (subscription_capacity == 0) return error.InvalidSubscriptionCapacity;
        if (subscription_capacity > std.math.maxInt(u32)) return error.InvalidSubscriptionCapacity;

        if (options.max_topic_len == 0) return error.InvalidNameCapacity;

        const name_bytes = try required_name_bytes(topic_capacity, options.max_topic_len);
        if (storage.names.len != name_bytes) return error.InvalidNameCapacity;

        const min_index = try required_index_capacity(topic_capacity);
        if (storage.topic_index.len < min_index or
            !std.math.isPowerOfTwo(storage.topic_index.len))
        {
            return error.InvalidIndexCapacity;
        }

        if (storage_regions_overlap(storage)) return error.AliasedStorage;

        for (storage.topics, 0..) |*slot, i| {
            slot.* = .{ .next_free = if (i + 1 < topic_capacity) @intCast(i + 1) else no_link };
        }
        for (storage.subscriptions, 0..) |*slot, i| {
            slot.* = .{
                .next_free = if (i + 1 < subscription_capacity) @intCast(i + 1) else no_link,
            };
        }
        for (storage.topic_index) |*slot| slot.* = .{};

        return .{
            .topics = storage.topics,
            .subscriptions = storage.subscriptions,
            .names = storage.names,
            .topic_index = storage.topic_index,
            .max_topic_len = options.max_topic_len,
            .free_topic = 0,
            .free_subscription = 0,
        };
    }

    /// Adds `ws` to `name`, copying a new topic name into hub storage.
    ///
    /// Duplicate subscribe is idempotent and returns `added = false` before any
    /// capacity check. Both capacities are checked before either row is
    /// allocated, so a full subscription table never leaves an orphan topic.
    pub fn subscribe(
        self: *Hub,
        ws: *connection.WebSocket,
        name: []const u8,
    ) SubscribeError!SubscribeResult {
        if (self.publish_depth != 0) return error.PublishInProgress;
        try validate_name(name, self.max_topic_len);

        const hash = hash_name(name);
        if (self.find_topic(hash, name)) |tid| {
            if (self.find_subscription(tid, ws) != null) {
                return .{ .topic_id = to_topic_id(tid), .added = false };
            }
            if (self.free_subscription == no_link) return error.SubscriptionCapacityReached;

            const sid = self.alloc_subscription();
            self.subscriptions[@intCast(sid)].ws = ws;
            self.link_subscription(tid, sid);
            return .{ .topic_id = to_topic_id(tid), .added = true };
        }

        if (self.free_subscription == no_link) return error.SubscriptionCapacityReached;
        if (self.free_topic == no_link) return error.TopicCapacityReached;
        if (self.aliases_hub(name)) return error.AliasedTopicName;

        self.maybe_rebuild_index();

        const tid = self.alloc_topic(hash, name);
        const sid = self.alloc_subscription();
        self.subscriptions[@intCast(sid)].ws = ws;
        self.link_subscription(tid, sid);
        self.insert_index(hash, tid);
        return .{ .topic_id = to_topic_id(tid), .added = true };
    }

    /// Removes one subscription. The last unsubscribe removes the topic.
    pub fn unsubscribe(self: *Hub, ws: *connection.WebSocket, name: []const u8) Error!void {
        if (self.publish_depth != 0) return error.PublishInProgress;
        try validate_name(name, self.max_topic_len);

        const tid = self.find_topic(hash_name(name), name) orelse return error.TopicNotFound;
        const sid = self.find_subscription(tid, ws) orelse return error.NotSubscribed;

        self.unlink_subscription(sid);
        self.release_subscription(sid);
        if (self.topics[@intCast(tid)].subscriber_count == 0) self.remove_topic(tid);
        self.maybe_rebuild_index();
    }

    /// Removes every subscription owned by `ws` and returns the count.
    pub fn unsubscribe_all(self: *Hub, ws: *connection.WebSocket) Error!usize {
        if (self.publish_depth != 0) return error.PublishInProgress;

        var removed: usize = 0;
        var raw: usize = 0;
        while (raw < self.subscriptions.len) : (raw += 1) {
            const sub = &self.subscriptions[raw];
            if (!sub.used) continue;
            const sub_ws = sub.ws orelse continue;
            if (sub_ws != ws) continue;

            const tid: u32 = @backingInt(sub.topic);
            self.unlink_subscription(@intCast(raw));
            self.release_subscription(@intCast(raw));
            if (self.topics[@intCast(tid)].subscriber_count == 0) self.remove_topic(tid);
            removed += 1;
        }
        self.maybe_rebuild_index();
        return removed;
    }

    /// Publishes to every subscriber of `name` without sender exclusion.
    pub fn publish(
        self: *Hub,
        name: []const u8,
        payload: []u8,
        kind: MessageKind,
    ) PublishError!PublishResult {
        return self.publish_from(null, name, payload, kind);
    }

    /// Publishes to every subscriber of `name` except the exact `sender`.
    ///
    /// A payload overlapping any hub storage region is rejected globally.
    /// Overlap with one subscriber's connection storage is reported only for
    /// that subscriber as `InvalidLength` by `enqueue_frame`.
    pub fn publish_from(
        self: *Hub,
        sender: ?*connection.WebSocket,
        name: []const u8,
        payload: []u8,
        kind: MessageKind,
    ) PublishError!PublishResult {
        if (self.publish_depth != 0) return error.PublishInProgress;
        try validate_name(name, self.max_topic_len);

        const tid = self.find_topic(hash_name(name), name) orelse return error.TopicNotFound;
        if (self.aliases_hub(payload)) return error.AliasedPayload;

        self.publish_depth = 1;
        defer self.publish_depth = 0;

        const topic = &self.topics[@intCast(tid)];
        var result: PublishResult = .{
            .topic_id = to_topic_id(tid),
            .matched = 0,
            .delivered = 0,
            .skipped = 0,
            .backpressured = 0,
            .closed = 0,
            .first_error = null,
        };

        var sid = topic.head;
        var visited: u32 = 0;
        while (sid != no_link and visited < topic.subscriber_count) : (visited += 1) {
            const sub = &self.subscriptions[@intCast(sid)];
            const sub_ws = sub.ws orelse unreachable;
            sid = sub.next;

            if (sender) |sender_ws| {
                if (sub_ws == sender_ws) continue;
            }
            result.matched += 1;

            var writer = stream.MessageWriter.init(sub_ws, kind);
            writer.write(payload, true) catch |err| {
                result.skipped += 1;
                if (result.first_error == null) result.first_error = err;
                switch (err) {
                    error.WouldBlock, error.QueueFull => result.backpressured += 1,
                    error.ConnectionClosed => result.closed += 1,
                    else => {},
                }
                continue;
            };
            result.delivered += 1;
        }

        std.debug.assert(sid == no_link);
        std.debug.assert(visited == topic.subscriber_count);
        std.debug.assert(result.matched == result.delivered + result.skipped);
        return result;
    }

    /// True when `ws` is subscribed to `name`. Read-only during publish.
    pub fn is_subscribed(
        self: *const Hub,
        ws: *const connection.WebSocket,
        name: []const u8,
    ) bool {
        validate_name(name, self.max_topic_len) catch return false;
        const tid = self.find_topic(hash_name(name), name) orelse return false;
        return self.find_subscription(tid, ws) != null;
    }

    /// Returns the topic view, or null when the name is absent.
    ///
    /// The returned name borrows hub storage until the topic is removed.
    pub fn topic_info(self: *const Hub, name: []const u8) ?TopicInfo {
        validate_name(name, self.max_topic_len) catch return null;
        const tid = self.find_topic(hash_name(name), name) orelse return null;
        const topic = &self.topics[@intCast(tid)];
        return .{
            .id = to_topic_id(tid),
            .name = self.topic_name(tid),
            .subscriber_count = @intCast(topic.subscriber_count),
        };
    }

    pub fn topic_count(self: *const Hub) usize {
        return self.active_topics;
    }

    pub fn subscription_count(self: *const Hub) usize {
        return self.active_subscriptions;
    }

    fn storage_view(self: *const Hub) Storage {
        return .{
            .topics = self.topics,
            .subscriptions = self.subscriptions,
            .names = self.names,
            .topic_index = self.topic_index,
        };
    }

    /// True when `bytes` overlaps the hub object or any storage it owns.
    fn aliases_hub(self: *const Hub, bytes: []const u8) bool {
        return self.storage_view().overlaps(bytes) or
            ranges_overlap(bytes, std.mem.asBytes(self));
    }

    fn find_topic(self: *const Hub, hash: u64, name: []const u8) ?u32 {
        const mask = self.topic_index.len - 1;
        var pos: usize = @as(usize, @truncate(hash)) & mask;
        var probes: usize = 0;
        while (probes < self.topic_index.len) : (probes += 1) {
            const slot = &self.topic_index[pos];
            if (slot.used) {
                if (slot.hash == hash and @as(usize, slot.topic) < self.topics.len) {
                    if (std.mem.eql(u8, self.topic_name(slot.topic), name)) return slot.topic;
                }
            } else if (!slot.tombstone) {
                return null;
            }
            pos = (pos + 1) & mask;
        }
        return null;
    }

    fn find_subscription(
        self: *const Hub,
        tid: u32,
        ws: *const connection.WebSocket,
    ) ?u32 {
        const topic = &self.topics[@intCast(tid)];
        var sid = topic.head;
        var visited: u32 = 0;
        while (sid != no_link and visited < topic.subscriber_count) : (visited += 1) {
            const sub = &self.subscriptions[@intCast(sid)];
            if (sub.ws) |sub_ws| {
                if (sub_ws == ws) return sid;
            }
            sid = sub.next;
        }
        return null;
    }

    fn topic_name(self: *const Hub, tid: u32) []const u8 {
        const topic = &self.topics[@intCast(tid)];
        const offset = @as(usize, tid) * @as(usize, self.max_topic_len);
        return self.names[offset..][0..@as(usize, topic.name_len)];
    }

    fn alloc_topic(self: *Hub, hash: u64, name: []const u8) u32 {
        const tid = self.free_topic;
        std.debug.assert(tid != no_link);

        const slot = &self.topics[@intCast(tid)];
        self.free_topic = slot.next_free;
        slot.* = .{
            .hash = hash,
            .name_len = @intCast(name.len),
            .used = true,
        };

        const offset = @as(usize, tid) * @as(usize, self.max_topic_len);
        @memcpy(self.names[offset..][0..name.len], name);
        self.active_topics += 1;
        return tid;
    }

    fn alloc_subscription(self: *Hub) u32 {
        const sid = self.free_subscription;
        std.debug.assert(sid != no_link);

        const slot = &self.subscriptions[@intCast(sid)];
        self.free_subscription = slot.next_free;
        slot.* = .{ .used = true };
        self.active_subscriptions += 1;
        return sid;
    }

    fn link_subscription(self: *Hub, tid: u32, sid: u32) void {
        const topic = &self.topics[@intCast(tid)];
        const sub = &self.subscriptions[@intCast(sid)];

        sub.topic = to_topic_id(tid);
        sub.next = no_link;
        sub.prev = topic.tail;
        if (topic.tail != no_link) {
            self.subscriptions[@intCast(topic.tail)].next = sid;
        } else {
            topic.head = sid;
        }
        topic.tail = sid;

        std.debug.assert(topic.subscriber_count < std.math.maxInt(u32));
        topic.subscriber_count += 1;
    }

    fn unlink_subscription(self: *Hub, sid: u32) void {
        const sub = &self.subscriptions[@intCast(sid)];
        const tid: u32 = @backingInt(sub.topic);
        const topic = &self.topics[@intCast(tid)];

        if (sub.prev != no_link) {
            self.subscriptions[@intCast(sub.prev)].next = sub.next;
        } else {
            topic.head = sub.next;
        }
        if (sub.next != no_link) {
            self.subscriptions[@intCast(sub.next)].prev = sub.prev;
        } else {
            topic.tail = sub.prev;
        }
        sub.next = no_link;
        sub.prev = no_link;

        std.debug.assert(topic.subscriber_count > 0);
        topic.subscriber_count -= 1;
    }

    fn release_subscription(self: *Hub, sid: u32) void {
        const sub = &self.subscriptions[@intCast(sid)];
        sub.* = .{ .next_free = self.free_subscription };
        self.free_subscription = sid;

        std.debug.assert(self.active_subscriptions > 0);
        self.active_subscriptions -= 1;
    }

    fn remove_topic(self: *Hub, tid: u32) void {
        self.remove_index_topic(tid);

        const slot = &self.topics[@intCast(tid)];
        std.debug.assert(slot.used);
        std.debug.assert(slot.subscriber_count == 0);
        slot.* = .{ .next_free = self.free_topic };
        self.free_topic = tid;

        std.debug.assert(self.active_topics > 0);
        self.active_topics -= 1;
    }

    fn remove_index_topic(self: *Hub, tid: u32) void {
        const mask = self.topic_index.len - 1;
        const hash = self.topics[@intCast(tid)].hash;
        var pos: usize = @as(usize, @truncate(hash)) & mask;
        var probes: usize = 0;
        while (probes < self.topic_index.len) : (probes += 1) {
            const slot = &self.topic_index[pos];
            if (slot.used) {
                if (slot.topic == tid) {
                    slot.* = .{ .tombstone = true };
                    self.tombstone_count += 1;
                    return;
                }
            } else if (!slot.tombstone) {
                break;
            }
            pos = (pos + 1) & mask;
        }

        // A used topic always has one index slot. Missing it means the index
        // invariant was broken internally, not that the caller did anything
        // wrong.
        unreachable;
    }

    fn insert_index(self: *Hub, hash: u64, tid: u32) void {
        const mask = self.topic_index.len - 1;
        var pos: usize = @as(usize, @truncate(hash)) & mask;
        var first_tombstone: ?usize = null;
        var probes: usize = 0;
        while (probes < self.topic_index.len) : (probes += 1) {
            const slot = &self.topic_index[pos];
            if (slot.used) {
                std.debug.assert(slot.topic != tid);
            } else if (slot.tombstone) {
                if (first_tombstone == null) first_tombstone = pos;
            } else {
                const target = first_tombstone orelse pos;
                if (first_tombstone != null) self.tombstone_count -= 1;
                self.topic_index[target] = .{ .hash = hash, .topic = tid, .used = true };
                return;
            }
            pos = (pos + 1) & mask;
        }

        if (first_tombstone) |target| {
            self.tombstone_count -= 1;
            self.topic_index[target] = .{ .hash = hash, .topic = tid, .used = true };
            return;
        }

        // The pre-insertion capacity proof guarantees an empty or tombstone
        // slot: used + tombstones <= 3 * capacity / 4.
        unreachable;
    }

    fn maybe_rebuild_index(self: *Hub) void {
        if (self.tombstone_count <= self.topic_index.len / 4) return;

        for (self.topic_index) |*slot| slot.* = .{};
        self.tombstone_count = 0;
        for (self.topics, 0..) |topic, tid| {
            if (!topic.used) continue;
            self.insert_index(topic.hash, @intCast(tid));
        }
    }
};

/// Bytes required for the fixed-stride name arena.
///
/// `topic_capacity == 0` is rejected here; `Hub.init` additionally bounds the
/// capacity by `maxInt(u32)` because slot ids reserve that value.
pub fn required_name_bytes(topic_capacity: usize, max_topic_len: u32) InitError!usize {
    if (topic_capacity == 0) return error.InvalidTopicCapacity;
    if (max_topic_len == 0) return error.InvalidNameCapacity;
    return std.math.mul(usize, topic_capacity, @as(usize, max_topic_len)) catch {
        return error.SizeOverflow;
    };
}

/// Smallest power-of-two topic-index capacity for `topic_capacity` topics.
///
/// Returns the least power of two greater than or equal to
/// `2 * topic_capacity`. A slice sized to this value passes `Hub.init`'s index
/// checks. `topic_capacity == 0` is rejected here; `Hub.init` additionally
/// bounds the capacity by `maxInt(u32)`. Returns `error.SizeOverflow` when the
/// doubled capacity or its rounded power of two does not fit `usize`.
pub fn required_index_capacity(topic_capacity: usize) InitError!usize {
    if (topic_capacity == 0) return error.InvalidTopicCapacity;

    const doubled = std.math.mul(usize, topic_capacity, 2) catch {
        return error.SizeOverflow;
    };
    return std.math.ceilPowerOfTwo(usize, doubled) catch return error.SizeOverflow;
}

fn validate_name(name: []const u8, max_topic_len: u32) Error!void {
    if (name.len == 0) return error.EmptyTopic;
    if (name.len > @as(usize, max_topic_len)) return error.TopicTooLong;
}

fn hash_name(name: []const u8) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    for (name) |byte| {
        hash ^= @as(u64, byte);
        hash *%= 0x100000001b3;
    }
    return hash;
}

fn to_topic_id(raw: u32) TopicId {
    return @fromBackingInt(raw);
}

fn ranges_overlap(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;

    const a_start = @intFromPtr(a.ptr);
    const b_start = @intFromPtr(b.ptr);
    if (a_start <= b_start) return b_start - a_start < a.len;
    return a_start - b_start < b.len;
}

fn storage_regions_overlap(storage: Storage) bool {
    const topic_bytes: []const u8 = std.mem.sliceAsBytes(storage.topics);
    const subscription_bytes: []const u8 = std.mem.sliceAsBytes(storage.subscriptions);
    const index_bytes: []const u8 = std.mem.sliceAsBytes(storage.topic_index);
    const regions = [_][]const u8{
        topic_bytes,
        subscription_bytes,
        storage.names,
        index_bytes,
    };

    for (regions, 0..) |region, i| {
        for (regions[i + 1 ..]) |other| {
            if (ranges_overlap(region, other)) return true;
        }
    }
    return false;
}

fn has_allocator_field(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            inline for (info.field_types) |field_type| {
                if (field_type == std.mem.Allocator) return true;
            }
            return false;
        },
        else => return false,
    }
}

comptime {
    if (has_allocator_field(Storage) or has_allocator_field(Hub)) {
        @compileError("pubsub storage must not contain an allocator");
    }
}
