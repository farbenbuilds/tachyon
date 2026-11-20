const std = @import("std");
const tachyon = @import("tachyon");

const backpressure = tachyon.backpressure;
const Action = backpressure.Action;
const Charge = backpressure.Charge;
const Flow = backpressure.Flow;
const Limits = backpressure.Limits;
const Phase = backpressure.Phase;
const State = backpressure.State;

test "Backpressure: rejects zero and inverted watermarks" {
    try std.testing.expectError(
        error.InvalidWaterMarks,
        (Limits{ .high_water_bytes = 0, .high_water_frames = 1 }).validate(),
    );
    try std.testing.expectError(
        error.InvalidWaterMarks,
        (Limits{ .high_water_bytes = 8, .high_water_frames = 0 }).validate(),
    );
    try std.testing.expectError(
        error.InvalidWaterMarks,
        (Limits{
            .high_water_bytes = 8,
            .low_water_bytes = 9,
            .high_water_frames = 4,
        }).validate(),
    );
    try std.testing.expectError(
        error.InvalidWaterMarks,
        (Limits{
            .high_water_bytes = 8,
            .high_water_frames = 4,
            .low_water_frames = 5,
        }).validate(),
    );

    const valid = try (Limits{
        .high_water_bytes = 8,
        .low_water_bytes = 2,
        .high_water_frames = 4,
        .low_water_frames = 1,
    }).validate();
    try std.testing.expectEqual(@as(usize, 2), valid.low_water_bytes);
}

test "Backpressure: crossing the byte mark pauses the producer" {
    var flow = try Flow.init(.{
        .high_water_bytes = 8,
        .low_water_bytes = 2,
        .high_water_frames = 4,
        .low_water_frames = 1,
    });

    try std.testing.expectEqual(Action.write, try flow.enqueue_data(Charge.frame(3)));
    try std.testing.expectEqual(Phase.writable, flow.state.phase);

    try std.testing.expectEqual(Action.pause_producer, try flow.enqueue_data(Charge.frame(5)));
    try std.testing.expectEqual(Phase.backpressured, flow.state.phase);
    try std.testing.expect(!flow.can_write_data());

    try std.testing.expectError(error.WouldBlock, flow.enqueue_data(Charge.frame(1)));
    try std.testing.expectEqual(@as(usize, 8), flow.state.queued_bytes);
    try std.testing.expectEqual(@as(usize, 2), flow.state.queued_frames);

    try std.testing.expectEqual(Action.none, try flow.enqueue_control(Charge.frame(1)));
    try std.testing.expectEqual(@as(usize, 9), flow.state.queued_bytes);
    try std.testing.expectEqual(@as(usize, 3), flow.state.queued_frames);
    try std.testing.expect(flow.is_backpressured());
}

test "Backpressure: resumes only after both counters reach their low marks" {
    var flow = try Flow.init(.{
        .high_water_bytes = 8,
        .low_water_bytes = 4,
        .high_water_frames = 3,
        .low_water_frames = 1,
    });

    try std.testing.expectEqual(Action.write, try flow.enqueue_data(Charge.frame(4)));
    try std.testing.expectEqual(Action.pause_producer, try flow.enqueue_data(Charge.frame(4)));
    try std.testing.expectEqual(Action.none, try flow.enqueue_control(Charge.frame(2)));
    try std.testing.expectEqual(@as(usize, 3), flow.state.queued_frames);

    try std.testing.expectEqual(Action.none, try flow.flushed(.{ .bytes = 6 }));
    try std.testing.expectEqual(Phase.backpressured, flow.state.phase);

    try std.testing.expectEqual(Action.resume_producer, try flow.flushed(.{ .frames = 2 }));
    try std.testing.expectEqual(Phase.writable, flow.state.phase);
    try std.testing.expectEqual(@as(usize, 4), flow.state.queued_bytes);
    try std.testing.expectEqual(@as(usize, 1), flow.state.queued_frames);
}

test "Backpressure: non-empty queue rejects a frame that cannot fit" {
    var flow = try Flow.init(.{
        .high_water_bytes = 8,
        .high_water_frames = 4,
    });

    try std.testing.expectEqual(Action.write, try flow.enqueue_data(Charge.frame(3)));
    try std.testing.expectError(error.WouldBlock, flow.enqueue_data(Charge.frame(6)));
    try std.testing.expectEqual(@as(usize, 3), flow.state.queued_bytes);
    try std.testing.expectEqual(@as(usize, 1), flow.state.queued_frames);

    try std.testing.expectEqual(Action.none, try flow.flushed(.{ .bytes = 3, .frames = 1 }));
    try std.testing.expectEqual(Phase.writable, flow.state.phase);

    // An empty queue admits one oversized frame so WouldBlock never becomes a
    // retry loop with nothing for flush to drain.
    try std.testing.expectEqual(Action.pause_producer, try flow.enqueue_data(Charge.frame(12)));
    try std.testing.expectEqual(@as(usize, 12), flow.state.queued_bytes);
    try std.testing.expectEqual(Phase.backpressured, flow.state.phase);

    try std.testing.expectEqual(Action.resume_producer, try flow.flushed(.{ .bytes = 12, .frames = 1 }));
    try std.testing.expectEqual(Phase.writable, flow.state.phase);
}

test "Backpressure: frame mark works below the byte mark" {
    var flow = try Flow.init(.{
        .high_water_bytes = 100,
        .high_water_frames = 2,
        .low_water_frames = 1,
    });

    try std.testing.expectEqual(Action.write, try flow.enqueue_data(Charge.frame(1)));
    try std.testing.expectEqual(Action.pause_producer, try flow.enqueue_data(Charge.frame(1)));
    try std.testing.expectEqual(Phase.backpressured, flow.state.phase);
    try std.testing.expectEqual(Action.resume_producer, try flow.flushed(.{ .bytes = 2, .frames = 1 }));
    try std.testing.expectEqual(Phase.writable, flow.state.phase);
}

test "Backpressure: a close waits for queued frames" {
    var flow = try Flow.init(.{
        .high_water_bytes = 4,
        .high_water_frames = 2,
        .low_water_frames = 1,
    });

    try std.testing.expectEqual(Action.write, try flow.enqueue_data(Charge.frame(2)));
    try std.testing.expectEqual(Action.none, try flow.close());
    try std.testing.expectEqual(Phase.closing, flow.state.phase);
    try std.testing.expectError(error.StreamClosed, flow.enqueue_data(Charge.frame(1)));

    try std.testing.expectEqual(Action.close_transport, try flow.flushed(.{ .bytes = 2, .frames = 1 }));
    try std.testing.expectEqual(Phase.closed, flow.state.phase);
}

test "Backpressure: a close on an idle queue closes immediately" {
    var flow = try Flow.init(.{
        .high_water_bytes = 8,
        .high_water_frames = 2,
    });

    try std.testing.expectEqual(Action.close_transport, try flow.close());
    try std.testing.expectEqual(Phase.closed, flow.state.phase);

    try std.testing.expectEqual(Action.none, try flow.enqueue_control(Charge.frame(1)));
    try std.testing.expectEqual(@as(usize, 1), flow.state.queued_frames);
    try std.testing.expectEqual(Action.none, try flow.flushed(.{ .bytes = 1, .frames = 1 }));
    try std.testing.expectEqual(Phase.closed, flow.state.phase);
}

test "Backpressure: a zero-length data frame still charges a frame" {
    var flow = try Flow.init(.{
        .high_water_bytes = 8,
        .high_water_frames = 2,
    });

    try std.testing.expectEqual(Action.write, try flow.enqueue_data(Charge.frame(0)));
    try std.testing.expectEqual(@as(usize, 0), flow.state.queued_bytes);
    try std.testing.expectEqual(@as(usize, 1), flow.state.queued_frames);
    try std.testing.expectEqual(Action.none, try flow.flushed(.{ .frames = 1 }));
    try std.testing.expectEqual(Phase.writable, flow.state.phase);
}

test "Backpressure: abort is terminal" {
    var flow = try Flow.init(.{
        .high_water_bytes = 8,
        .high_water_frames = 2,
    });

    try std.testing.expectEqual(Action.terminate_transport, try flow.abort());
    try std.testing.expectEqual(Phase.aborted, flow.state.phase);
    try std.testing.expectError(error.StreamClosed, flow.enqueue_data(Charge.frame(1)));
    try std.testing.expectError(error.StreamClosed, flow.enqueue_control(Charge.frame(1)));
    try std.testing.expectEqual(Action.none, try flow.abort());
}

test "Backpressure: overflow and over-flush fail closed" {
    const limits = try (Limits{
        .high_water_bytes = std.math.maxInt(usize),
        .high_water_frames = 2,
    }).validate();

    const overflow_state = State{
        .queued_bytes = std.math.maxInt(usize),
        .queued_frames = 0,
        .limits = limits,
    };
    try std.testing.expectError(
        error.ByteCountOverflow,
        backpressure.transition(overflow_state, .{ .data = Charge.frame(1) }),
    );

    const frame_overflow_state = State{
        .queued_bytes = 0,
        .queued_frames = std.math.maxInt(usize),
        .limits = limits,
    };
    try std.testing.expectError(
        error.ByteCountOverflow,
        backpressure.transition(frame_overflow_state, .{ .data = Charge.frame(1) }),
    );

    const full_state = State{
        .queued_bytes = 2,
        .queued_frames = 1,
        .limits = limits,
    };
    try std.testing.expectError(
        error.FlushExceedsQueue,
        backpressure.transition(full_state, .{ .flushed = .{ .bytes = 3 } }),
    );
    try std.testing.expectError(
        error.FlushExceedsQueue,
        backpressure.transition(full_state, .{ .flushed = .{ .frames = 2 } }),
    );
}

test "Backpressure: reset keeps limits and clears the phase" {
    var flow = try Flow.init(.{
        .high_water_bytes = 4,
        .high_water_frames = 2,
    });
    const limits = flow.state.limits;

    try std.testing.expectEqual(Action.pause_producer, try flow.enqueue_data(Charge.frame(4)));
    try std.testing.expect(flow.is_backpressured());

    flow.reset();

    try std.testing.expectEqual(Phase.writable, flow.state.phase);
    try std.testing.expectEqual(@as(usize, 0), flow.state.queued_bytes);
    try std.testing.expectEqual(@as(usize, 0), flow.state.queued_frames);
    try std.testing.expectEqual(limits.high_water_bytes, flow.state.limits.high_water_bytes);
}
