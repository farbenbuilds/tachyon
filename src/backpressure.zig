//! Bounded flow-control policy for the connection write path.
//!
//! zslay owns the transmit ring and its `QueueFull` capacity bound. This module
//! is the policy layer above that ring: it tracks queued payload bytes and
//! frames, enters a backpressured phase at the high-water marks, and returns to
//! the writable phase only after both counters fall to their low-water marks.
//! It never stores a frame, masks a payload, or drains a transport, so there is
//! no second queue and no hidden allocation.
//!
//! A connection updates the policy when a frame enters and leaves zslay's
//! queue. While the policy is backpressured, data-frame admission returns
//! `error.WouldBlock`, so a slow consumer applies pressure to its producer
//! instead of growing an unbounded backlog. Control frames bypass the paused
//! phase so pong and close obligations stay deliverable. Read pacing stays with
//! the caller: the raw connection has no inbound queue, and the planned
//! streaming layer can reuse the same high/low marks per chunk.
//! Transport suspension remains with `std.Io`: a writer call may await
//! readiness, but this layer never spins, sleeps, or opens an event loop.
//!
//! The high-water marks are thresholds, not hard caps. A frame admitted into
//! an empty queue may itself exceed the byte mark, and the frame that reaches a
//! mark is committed before the producer pauses. A non-empty queue refuses a
//! data frame whose projected totals would exceed a high mark, so a retryable
//! `WouldBlock` always has queued bytes that `flush` can drain. zslay's
//! caller-owned transmit nodes remain the authoritative capacity bound; the
//! policy high mark must fit inside that capacity.

const std = @import("std");

/// Rejection of a zero high-water mark or an inverted mark pair.
pub const InitError = error{InvalidWaterMarks};

/// Byte and frame watermarks for one connection.
///
/// A low mark must not exceed its high mark. The low marks default to zero so
/// a queue resumes only after it is fully drained unless the caller asks for
/// earlier resumption. Both high marks must be nonzero.
pub const Limits = struct {
    high_water_bytes: usize,
    low_water_bytes: usize = 0,
    high_water_frames: usize,
    low_water_frames: usize = 0,

    /// Returns these limits after checking the watermark ordering.
    pub fn validate(self: Limits) InitError!Limits {
        if (self.high_water_bytes == 0 or self.high_water_frames == 0) {
            return error.InvalidWaterMarks;
        }
        if (self.low_water_bytes > self.high_water_bytes) return error.InvalidWaterMarks;
        if (self.low_water_frames > self.high_water_frames) return error.InvalidWaterMarks;
        return self;
    }
};

/// Flow-control phase.
pub const Phase = enum(u8) {
    writable,
    backpressured,
    closing,
    closed,
    aborted,
};

/// Counters added or removed by one queue operation.
///
/// `bytes` counts payload bytes, not frame headers; the frame counter bounds
/// header overhead. A zero-length frame still charges one frame.
pub const Charge = struct {
    bytes: usize = 0,
    frames: usize = 0,

    pub fn frame(payload_len: usize) Charge {
        return .{ .bytes = payload_len, .frames = 1 };
    }
};

/// Immutable policy state.
pub const State = struct {
    queued_bytes: usize = 0,
    queued_frames: usize = 0,
    limits: Limits,
    phase: Phase = .writable,

    pub fn init(limits: Limits) InitError!State {
        return .{ .limits = try limits.validate() };
    }

    /// True while a new data frame may be admitted.
    pub fn can_write_data(self: State) bool {
        return self.phase == .writable;
    }

    /// True when neither a queued frame nor a queued payload byte remains.
    pub fn is_idle(self: State) bool {
        return self.queued_bytes == 0 and self.queued_frames == 0;
    }
};

/// One policy event.
pub const Event = union(enum) {
    /// Admit one data frame. Rejected while backpressured or when a non-empty
    /// queue cannot fit the frame without crossing a high mark.
    data: Charge,
    /// Admit one control frame. Allowed while backpressured, closing, or closed.
    control: Charge,
    /// Account for drained payload bytes and completed frames.
    flushed: Charge,
    /// Begin a graceful close after queued frames drain.
    close,
    /// Terminate immediately and discard the flow state.
    abort,
};

/// Action requested by a transition. The connection consumes the resulting
/// state and ignores these actions; they are the standalone `Flow` contract.
/// `close_transport` and `terminate_transport` are advisory because split and
/// native wrappers keep transport lifetime with the caller.
pub const Action = enum(u8) {
    none,
    write,
    pause_producer,
    resume_producer,
    close_transport,
    terminate_transport,
};

pub const Transition = struct {
    next_action: Action,
    new_state: State,
};

pub const TransitionError = error{
    ByteCountOverflow,
    FlushExceedsQueue,
    StreamClosed,
    WouldBlock,
};

/// Computes the next flow-control state without mutating external state.
pub fn transition(current: State, event: Event) TransitionError!Transition {
    return switch (event) {
        .abort => abort_transition(current),
        .close => close_transition(current),
        .data => |charge| enqueue_transition(current, charge, .data),
        .control => |charge| enqueue_transition(current, charge, .control),
        .flushed => |charge| flush_transition(current, charge),
    };
}

const FrameKind = enum { data, control };

fn enqueue_transition(current: State, charge: Charge, kind: FrameKind) TransitionError!Transition {
    if (current.phase == .aborted) return error.StreamClosed;
    if (kind == .data) {
        if (current.phase == .closing or current.phase == .closed) return error.StreamClosed;
        if (current.phase == .backpressured) return error.WouldBlock;
    }

    const queued_bytes = std.math.add(usize, current.queued_bytes, charge.bytes) catch {
        return error.ByteCountOverflow;
    };
    const queued_frames = std.math.add(usize, current.queued_frames, charge.frames) catch {
        return error.ByteCountOverflow;
    };

    // A non-empty queue that cannot fit the next data frame waits for a drain.
    // An empty queue always admits one frame, even when that frame alone is
    // larger than the mark, so a retryable WouldBlock always has drainable
    // bytes behind it. Control frames never take this path.
    if (kind == .data and !current.is_idle()) {
        if (queued_bytes > current.limits.high_water_bytes or
            queued_frames > current.limits.high_water_frames)
        {
            return error.WouldBlock;
        }
    }

    var new_state = current;
    new_state.queued_bytes = queued_bytes;
    new_state.queued_frames = queued_frames;

    if (current.phase == .closing or current.phase == .closed) {
        return .{ .next_action = .none, .new_state = new_state };
    }
    if (current.phase == .backpressured) {
        return .{ .next_action = .none, .new_state = new_state };
    }
    if (queued_bytes >= current.limits.high_water_bytes or
        queued_frames >= current.limits.high_water_frames)
    {
        new_state.phase = .backpressured;
        return .{ .next_action = .pause_producer, .new_state = new_state };
    }
    return .{ .next_action = .write, .new_state = new_state };
}

fn flush_transition(current: State, charge: Charge) TransitionError!Transition {
    if (charge.bytes > current.queued_bytes or charge.frames > current.queued_frames) {
        return error.FlushExceedsQueue;
    }

    var new_state = current;
    new_state.queued_bytes -= charge.bytes;
    new_state.queued_frames -= charge.frames;

    if (current.phase == .closed or current.phase == .aborted) {
        return .{ .next_action = .none, .new_state = new_state };
    }
    if (current.phase == .closing and new_state.is_idle()) {
        new_state.phase = .closed;
        return .{ .next_action = .close_transport, .new_state = new_state };
    }
    if (current.phase == .backpressured and
        new_state.queued_bytes <= current.limits.low_water_bytes and
        new_state.queued_frames <= current.limits.low_water_frames)
    {
        new_state.phase = .writable;
        return .{ .next_action = .resume_producer, .new_state = new_state };
    }
    return .{ .next_action = .none, .new_state = new_state };
}

fn close_transition(current: State) TransitionError!Transition {
    if (current.phase == .closed or current.phase == .aborted) {
        return .{ .next_action = .none, .new_state = current };
    }
    if (!current.is_idle()) {
        return .{ .next_action = .none, .new_state = with_phase(current, .closing) };
    }
    return .{ .next_action = .close_transport, .new_state = with_phase(current, .closed) };
}

fn abort_transition(current: State) TransitionError!Transition {
    if (current.phase == .closed or current.phase == .aborted) {
        return .{ .next_action = .none, .new_state = current };
    }
    return .{ .next_action = .terminate_transport, .new_state = with_phase(current, .aborted) };
}

fn with_phase(current: State, phase: Phase) State {
    var next = current;
    next.phase = phase;
    return next;
}

/// Mutable convenience facade over `State`.
///
/// A connection owns one `Flow` when the caller configures watermarks. The
/// pure `transition` function remains the single implementation of the policy.
pub const Flow = struct {
    state: State,

    pub fn init(limits: Limits) InitError!Flow {
        return .{ .state = try State.init(limits) };
    }

    /// Admit one data frame.
    ///
    /// Returns `error.WouldBlock` in the backpressured phase or when a
    /// non-empty queue cannot fit the frame without crossing a high mark. The
    /// phase can still read as writable after the second rejection because the
    /// refusal did not mutate the state; callers should treat `WouldBlock`, not
    /// `is_backpressured()`, as the admission result.
    pub fn enqueue_data(self: *Flow, charge: Charge) TransitionError!Action {
        return self.apply(.{ .data = charge });
    }

    pub fn enqueue_control(self: *Flow, charge: Charge) TransitionError!Action {
        return self.apply(.{ .control = charge });
    }

    pub fn flushed(self: *Flow, charge: Charge) TransitionError!Action {
        return self.apply(.{ .flushed = charge });
    }

    pub fn close(self: *Flow) TransitionError!Action {
        return self.apply(.close);
    }

    pub fn abort(self: *Flow) TransitionError!Action {
        return self.apply(.abort);
    }

    pub fn can_write_data(self: *const Flow) bool {
        return self.state.can_write_data();
    }

    pub fn is_backpressured(self: *const Flow) bool {
        return self.state.phase == .backpressured;
    }

    pub fn is_idle(self: *const Flow) bool {
        return self.state.is_idle();
    }

    /// Clears counters and returns to the writable phase, keeping the limits.
    pub fn reset(self: *Flow) void {
        self.state = .{ .limits = self.state.limits };
    }

    fn apply(self: *Flow, event: Event) TransitionError!Action {
        const result = try transition(self.state, event);
        self.state = result.new_state;
        return result.next_action;
    }
};
