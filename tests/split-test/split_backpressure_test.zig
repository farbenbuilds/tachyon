const std = @import("std");
const tachyon = @import("tachyon");

const support = @import("../support.zig");

const Frame = tachyon.Frame;
const WebSocketError = tachyon.WebSocketError;
const SplitRig = support.SplitRig;
const EncodedStream = support.EncodedStream;
const append_masked = support.append_masked;

test "Split: custom sink WouldBlock becomes a terminal send failure" {
    const BlockingSink = struct {
        pub fn send_obligation(self: *@This(), outgoing: Frame) WebSocketError!void {
            _ = self;
            _ = outgoing;
            return error.WouldBlock;
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

    var peer = EncodedStream(32){};
    var ping_payload = [_]u8{'p'};
    try append_masked(&peer, Frame.ping(&ping_payload), .{ 3, 2, 1, 0 });
    var reader = peer.reader();

    var parts: SplitRig(16, 3, 32, 8, 0, 32) = .{};
    try parts.init(&reader, .{ .role = .server });

    var sink: BlockingSink = .{};
    try std.testing.expectError(error.SendError, parts.split.read_frame_with(&sink));
    try std.testing.expectEqual(
        @as(?WebSocketError, error.SendError),
        parts.split.read.inner.read_failure,
    );
}

test "Split: write-half backpressure does not gate split reads" {
    var peer = EncodedStream(64){};
    var peer_payload = [_]u8{ 'p', 'e', 'e', 'r' };
    try append_masked(&peer, Frame.text(&peer_payload), .{ 4, 3, 2, 1 });
    var reader = peer.reader();

    var server: SplitRig(16, 3, 64, 8, 0, 64) = .{};
    try server.init(&reader, .{
        .role = .server,
        .options = .{
            .backpressure = .{
                .high_water_bytes = 8,
                .low_water_bytes = 2,
                .high_water_frames = 2,
                .low_water_frames = 1,
            },
        },
    });

    var first = [_]u8{ 'a', 'a', 'a' };
    var second = [_]u8{ 'b', 'b', 'b' };
    var third = [_]u8{ 'c', 'c', 'c' };

    try server.split.enqueue_frame(Frame.text(&first));
    try server.split.enqueue_frame(Frame.text(&second));
    try std.testing.expect(server.split.is_backpressured());
    try std.testing.expectEqual(@as(usize, 2), server.split.queued_frames());
    try std.testing.expectEqual(@as(usize, 6), server.split.queued_bytes());

    try std.testing.expectError(error.WouldBlock, server.split.enqueue_frame(Frame.text(&third)));

    // Outbound pressure does not block the read half; a peer close or ping
    // must remain deliverable while the producer is paused.
    const incoming = try server.split.read_frame();
    try std.testing.expectEqualSlices(u8, "peer", incoming.payload);

    try server.split.flush();
    try std.testing.expect(!server.split.is_backpressured());
    try std.testing.expectEqual(@as(usize, 0), server.split.queued_frames());
}

test "Split: fragment collector reads while the write half is backpressured" {
    var peer = EncodedStream(64){};
    var peer_payload = [_]u8{ 'p', 'e', 'e', 'r' };
    try append_masked(&peer, Frame.text(&peer_payload), .{ 9, 8, 7, 6 });
    var reader = peer.reader();

    var server: SplitRig(16, 3, 64, 8, 0, 64) = .{};
    try server.init(&reader, .{
        .role = .server,
        .options = .{
            .backpressure = .{
                .high_water_bytes = 4,
                .high_water_frames = 2,
                .low_water_frames = 1,
            },
        },
    });

    var collector = try tachyon.FragmentCollectorRead.init(server.split.read, &server.message_buffer);

    var first = [_]u8{ 'a', 'a' };
    var second = [_]u8{ 'b', 'b' };
    try server.split.enqueue_frame(Frame.text(&first));
    try server.split.enqueue_frame(Frame.text(&second));
    try std.testing.expect(server.split.is_backpressured());

    const incoming = try collector.read_frame(&server.split.write);
    try std.testing.expectEqualSlices(u8, "peer", incoming.payload);
    try std.testing.expect(collector.failure == null);

    try server.split.flush();
    try std.testing.expectEqual(@as(usize, 0), server.split.queued_frames());
}
