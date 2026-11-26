const std = @import("std");
const tachyon = @import("tachyon");

const message = tachyon.stream;
const Frame = tachyon.Frame;

test "Stream: root exports the chunked message surface" {
    try std.testing.expect(tachyon.MessageReader == tachyon.stream.MessageReader);
    try std.testing.expect(tachyon.MessageWriter == tachyon.stream.MessageWriter);
    try std.testing.expect(tachyon.MessageKind == tachyon.stream.MessageKind);
    try std.testing.expect(tachyon.MessageChunk == tachyon.stream.Chunk);
    try std.testing.expect(tachyon.MessageEvent == tachyon.stream.Event);
}

test "ReaderState: start, continuation, and finish transitions" {
    var state = message.ReaderState.init();
    try std.testing.expect(state.is_idle());

    var first = [_]u8{'a'};
    const one = try state.accept(Frame.init(false, .text, null, &first));
    try std.testing.expectEqual(message.MessageKind.text, one.kind);
    try std.testing.expect(!one.fin);
    try std.testing.expectEqualStrings("a", one.payload);
    try std.testing.expect(!state.is_idle());
    try std.testing.expectEqual(message.MessageKind.text, state.message_kind().?);

    var last = [_]u8{'b'};
    const two = try state.accept(Frame.init(true, .continuation, null, &last));
    try std.testing.expectEqual(message.MessageKind.text, two.kind);
    try std.testing.expect(two.fin);
    try std.testing.expectEqualStrings("b", two.payload);
    try std.testing.expect(state.is_idle());
}

test "ReaderState: split code point and finish" {
    var state = message.ReaderState.init();
    var first = [_]u8{ 'A', 0xc2 };
    var last = [_]u8{0xa2};

    _ = try state.accept(Frame.init(false, .text, null, &first));
    const two = try state.accept(Frame.init(true, .continuation, null, &last));
    try std.testing.expectEqualSlices(u8, &last, two.payload);
    try std.testing.expect(two.fin);
    try std.testing.expect(state.is_idle());

    var partial = [_]u8{ 'A', 0xc2 };
    try std.testing.expectError(error.InvalidUTF8, state.accept(Frame.init(true, .text, null, &partial)));
    try std.testing.expect(state.is_idle());
}

test "ReaderState: orphan continuation and new data mid-message" {
    var state = message.ReaderState.init();
    var orphan = [_]u8{'x'};
    try std.testing.expectError(
        error.InvalidContinuationFrame,
        state.accept(Frame.init(true, .continuation, null, &orphan)),
    );
    try std.testing.expect(state.is_idle());

    var first = [_]u8{'a'};
    _ = try state.accept(Frame.init(false, .text, null, &first));
    try std.testing.expectEqual(message.MessageKind.text, state.message_kind().?);

    var second = [_]u8{'b'};
    try std.testing.expectError(error.InvalidFragment, state.accept(Frame.init(false, .text, null, &second)));
    try std.testing.expectEqual(message.MessageKind.text, state.message_kind().?);

    var last = [_]u8{'c'};
    const chunk = try state.accept(Frame.init(true, .continuation, null, &last));
    try std.testing.expectEqualStrings("c", chunk.payload);
    try std.testing.expect(state.is_idle());
}

test "ReaderState: masked frames are rejected before the opcode switch" {
    var state = message.ReaderState.init();
    var first = [_]u8{'a'};
    _ = try state.accept(Frame.init(false, .text, null, &first));

    // A masked continuation mid-message still reports mask policy first, and
    // the in-progress message is left untouched.
    var payload = [_]u8{'b'};
    try std.testing.expectError(
        error.PayloadMasked,
        state.accept(Frame.init(true, .continuation, .{ 0x01, 0x02, 0x03, 0x04 }, &payload)),
    );
    try std.testing.expectEqual(message.MessageKind.text, state.message_kind().?);
}

test "ReaderState: control frames are rejected as invalid fragments" {
    var state = message.ReaderState.init();
    var ping = [_]u8{'p'};
    try std.testing.expectError(error.InvalidFragment, state.accept(Frame.ping(&ping)));
    try std.testing.expect(state.is_idle());
}

test "ReaderState: binary bypasses UTF-8" {
    var state = message.ReaderState.init();
    var invalid = [_]u8{ 0xff, 0xfe };

    const chunk = try state.accept(Frame.init(true, .binary, null, &invalid));
    try std.testing.expectEqual(message.MessageKind.binary, chunk.kind);
    try std.testing.expect(chunk.fin);
    try std.testing.expectEqualSlices(u8, &invalid, chunk.payload);
    try std.testing.expect(state.is_idle());
}

test "WriterState: spec transitions and finished rejection" {
    var text = message.WriterState.init(.text);
    try std.testing.expectEqual(tachyon.OpCode.text, (try text.spec(true)).opcode);

    text.note_queued(try text.spec(false));
    try std.testing.expect(text.is_started());
    try std.testing.expect(!text.is_finished());
    try std.testing.expectEqual(tachyon.OpCode.continuation, (try text.spec(true)).opcode);

    text.note_queued(try text.spec(true));
    try std.testing.expect(text.is_finished());
    try std.testing.expectError(error.InvalidFragment, text.spec(false));

    var binary = message.WriterState.init(.binary);
    try std.testing.expectEqual(tachyon.OpCode.binary, (try binary.spec(true)).opcode);

    var reset = message.WriterState.init(.binary);
    reset.note_queued(try reset.spec(false));
    reset.reset();
    try std.testing.expect(!reset.is_started());
    try std.testing.expect(!reset.is_finished());
    try std.testing.expectEqual(tachyon.OpCode.binary, (try reset.spec(true)).opcode);
}

test "WriterState: spec is pure and note_queued commits" {
    var state = message.WriterState.init(.text);

    const first = try state.spec(false);
    const second = try state.spec(false);
    try std.testing.expectEqual(first.opcode, second.opcode);
    try std.testing.expectEqual(first.fin, second.fin);
    try std.testing.expect(!state.is_started());

    state.note_queued(first);
    try std.testing.expect(state.is_started());

    const next = try state.spec(false);
    try std.testing.expectEqual(tachyon.OpCode.continuation, next.opcode);
    state.note_queued(next);
    try std.testing.expect(!state.is_finished());

    const last = try state.spec(true);
    state.note_queued(last);
    try std.testing.expect(state.is_finished());
}
