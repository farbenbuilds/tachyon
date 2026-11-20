const std = @import("std");
const tachyon = @import("tachyon");

const fragment = tachyon.fragment;
const Frame = tachyon.Frame;
const MaskingKey = tachyon.MaskingKey;

test "Fragments: unfragmented text returns the same FIN frame and payload" {
    var buffer: [32]u8 = undefined;
    var fragments = fragment.Fragments.init(&buffer);
    var payload = [_]u8{ 'h', 'e', 'l', 'l', 'o' };

    const completed = (try fragments.accumulate(Frame.text(&payload))).?;

    try std.testing.expect(completed.fin);
    try std.testing.expectEqual(fragment.OpCode.text, completed.opcode);
    try std.testing.expectEqual(@as(?MaskingKey, null), completed.masking_key);
    try std.testing.expectEqualSlices(u8, &payload, completed.payload);
    // The unfragmented path must borrow the incoming payload, not copy it.
    try std.testing.expectEqual(@intFromPtr(&payload), @intFromPtr(completed.payload.ptr));
    try std.testing.expect(fragments.is_idle());
    try std.testing.expectEqual(@as(usize, 0), fragments.message_len());
}

test "Fragments: unfragmented binary returns arbitrary bytes unchanged" {
    var buffer: [32]u8 = undefined;
    var fragments = fragment.Fragments.init(&buffer);
    var payload = [_]u8{ 0x00, 0xff, 0x80, 0x7f, 0x00 };

    const completed = (try fragments.accumulate(Frame.binary(&payload))).?;

    try std.testing.expect(completed.fin);
    try std.testing.expectEqual(fragment.OpCode.binary, completed.opcode);
    try std.testing.expectEqualSlices(u8, &payload, completed.payload);
    try std.testing.expect(fragments.is_idle());
}

test "Fragments: unfragmented text rejects invalid and truncated UTF-8" {
    var buffer: [32]u8 = undefined;
    var fragments = fragment.Fragments.init(&buffer);
    var invalid = [_]u8{ 0xff, 0xfe };
    var truncated = [_]u8{ 0xf0, 0x90, 0x8d };

    try std.testing.expectError(error.InvalidUTF8, fragments.accumulate(Frame.text(&invalid)));
    try std.testing.expectError(error.InvalidUTF8, fragments.accumulate(Frame.text(&truncated)));

    try std.testing.expect(fragments.is_idle());
    try std.testing.expectEqual(@as(usize, 0), fragments.message_len());
}

test "Fragments: two-part and three-part binary messages assemble on FIN" {
    var buffer: [32]u8 = undefined;

    {
        var fragments = fragment.Fragments.init(&buffer);
        var first = [_]u8{ 'a', 'b', 'c' };
        var second = [_]u8{ 'd', 'e' };

        try std.testing.expect((try fragments.accumulate(Frame.init(false, .binary, null, &first))) == null);
        try std.testing.expectEqual(@as(usize, 3), fragments.message_len());
        try std.testing.expectEqual(@as(?fragment.OpCode, .binary), fragments.message_opcode());

        const completed = (try fragments.accumulate(Frame.init(true, .continuation, null, &second))).?;
        try std.testing.expect(completed.fin);
        try std.testing.expectEqual(fragment.OpCode.binary, completed.opcode);
        try std.testing.expectEqualSlices(u8, "abcde", completed.payload);
        try std.testing.expect(fragments.is_idle());
    }

    {
        var fragments = fragment.Fragments.init(&buffer);
        var a = [_]u8{'a'};
        var b = [_]u8{'b'};
        var c = [_]u8{'c'};

        try std.testing.expect((try fragments.accumulate(Frame.init(false, .binary, null, &a))) == null);
        try std.testing.expect((try fragments.accumulate(Frame.init(false, .continuation, null, &b))) == null);
        const completed = (try fragments.accumulate(Frame.init(true, .continuation, null, &c))).?;

        try std.testing.expect(completed.fin);
        try std.testing.expectEqual(fragment.OpCode.binary, completed.opcode);
        try std.testing.expectEqualSlices(u8, "abc", completed.payload);
        try std.testing.expect(fragments.is_idle());
    }
}

test "Fragments: text split inside a multi-byte code point completes with the original bytes" {
    var buffer: [32]u8 = undefined;
    var fragments = fragment.Fragments.init(&buffer);
    var first = [_]u8{ 'A', 0xc2 };
    var second = [_]u8{ 0xa2, 0xe2 };
    var third = [_]u8{ 0x82, 0xac };

    try std.testing.expect((try fragments.accumulate(Frame.init(false, .text, null, &first))) == null);
    try std.testing.expect((try fragments.accumulate(Frame.init(false, .continuation, null, &second))) == null);
    try std.testing.expectEqual(@as(usize, 4), fragments.message_len());
    const completed = (try fragments.accumulate(Frame.init(true, .continuation, null, &third))).?;

    try std.testing.expect(completed.fin);
    try std.testing.expectEqual(fragment.OpCode.text, completed.opcode);
    try std.testing.expectEqualSlices(u8, "A\xc2\xa2\xe2\x82\xac", completed.payload);
    try std.testing.expect(fragments.is_idle());
}

test "Fragments: text continuation with an invalid byte returns InvalidUTF8 without state change" {
    var buffer: [32]u8 = undefined;
    var fragments = fragment.Fragments.init(&buffer);
    var first = [_]u8{'A'};
    var invalid = [_]u8{0xff};
    var last = [_]u8{'B'};

    try std.testing.expect((try fragments.accumulate(Frame.init(false, .text, null, &first))) == null);
    try std.testing.expectError(
        error.InvalidUTF8,
        fragments.accumulate(Frame.init(false, .continuation, null, &invalid)),
    );

    // The rejected bytes must not be collected and the validator stays usable.
    try std.testing.expectEqual(@as(usize, 1), fragments.message_len());
    try std.testing.expectEqual(@as(?fragment.OpCode, .text), fragments.message_opcode());

    const completed = (try fragments.accumulate(Frame.init(true, .continuation, null, &last))).?;
    try std.testing.expectEqualSlices(u8, "AB", completed.payload);
}

test "Fragments: final text continuation ending inside a code point returns InvalidUTF8" {
    var buffer: [32]u8 = undefined;
    var fragments = fragment.Fragments.init(&buffer);
    var lead = [_]u8{ 0xf0, 0x90 };
    var tail = [_]u8{0x8d};

    try std.testing.expect((try fragments.accumulate(Frame.init(false, .text, null, &lead))) == null);
    try std.testing.expectError(
        error.InvalidUTF8,
        fragments.accumulate(Frame.init(true, .continuation, null, &tail)),
    );

    try std.testing.expectEqual(@as(usize, 2), fragments.message_len());
    try std.testing.expect(!fragments.is_idle());
}

test "Fragments: orphan continuation returns InvalidContinuationFrame" {
    var buffer: [16]u8 = undefined;
    var fragments = fragment.Fragments.init(&buffer);
    var payload = [_]u8{'x'};

    try std.testing.expectError(
        error.InvalidContinuationFrame,
        fragments.accumulate(Frame.init(false, .continuation, null, &payload)),
    );
    try std.testing.expectError(
        error.InvalidContinuationFrame,
        fragments.accumulate(Frame.init(true, .continuation, null, &payload)),
    );

    try std.testing.expect(fragments.is_idle());
    try std.testing.expectEqual(@as(usize, 0), fragments.message_len());
}

test "Fragments: new data frame while a message is active returns InvalidFragment" {
    var buffer: [32]u8 = undefined;
    var fragments = fragment.Fragments.init(&buffer);
    var first = [_]u8{'a'};
    var text = [_]u8{'t'};
    var binary = [_]u8{'b'};

    try std.testing.expect((try fragments.accumulate(Frame.init(false, .binary, null, &first))) == null);
    try std.testing.expectError(
        error.InvalidFragment,
        fragments.accumulate(Frame.init(false, .text, null, &text)),
    );
    try std.testing.expectError(
        error.InvalidFragment,
        fragments.accumulate(Frame.init(true, .text, null, &text)),
    );
    try std.testing.expectError(
        error.InvalidFragment,
        fragments.accumulate(Frame.init(true, .binary, null, &binary)),
    );

    try std.testing.expectEqual(@as(usize, 1), fragments.message_len());
    try std.testing.expectEqual(@as(?fragment.OpCode, .binary), fragments.message_opcode());

    const completed = (try fragments.accumulate(Frame.init(true, .continuation, null, &text))).?;
    try std.testing.expectEqualSlices(u8, "at", completed.payload);
}

test "Fragments: a ping between fragments is returned and the message stays active" {
    var buffer: [32]u8 = undefined;
    var fragments = fragment.Fragments.init(&buffer);
    var first = [_]u8{ 'h', 'e' };
    var ping_payload = [_]u8{'?'};
    var last = [_]u8{ 'l', 'l', 'o' };

    try std.testing.expect((try fragments.accumulate(Frame.init(false, .text, null, &first))) == null);

    const ping = (try fragments.accumulate(Frame.ping(&ping_payload))).?;
    try std.testing.expect(ping.fin);
    try std.testing.expectEqual(fragment.OpCode.ping, ping.opcode);
    try std.testing.expectEqual(@as(?MaskingKey, null), ping.masking_key);
    try std.testing.expectEqualSlices(u8, &ping_payload, ping.payload);
    try std.testing.expect(!fragments.is_idle());
    try std.testing.expectEqual(@as(usize, 2), fragments.message_len());

    const completed = (try fragments.accumulate(Frame.init(true, .continuation, null, &last))).?;
    try std.testing.expectEqualSlices(u8, "hello", completed.payload);
}

test "Fragments: close and pong between fragments are returned unchanged" {
    var buffer: [32]u8 = undefined;
    var fragments = fragment.Fragments.init(&buffer);
    var first = [_]u8{'a'};
    var close_payload = [_]u8{ 0x03, 0xe8 };
    var pong_payload = [_]u8{'p'};
    var last = [_]u8{'b'};

    try std.testing.expect((try fragments.accumulate(Frame.init(false, .binary, null, &first))) == null);

    const close = (try fragments.accumulate(Frame.close_raw(&close_payload))).?;
    try std.testing.expect(close.fin);
    try std.testing.expectEqual(fragment.OpCode.close, close.opcode);
    try std.testing.expectEqual(@as(?MaskingKey, null), close.masking_key);
    try std.testing.expectEqualSlices(u8, &close_payload, close.payload);
    try std.testing.expect(!fragments.is_idle());

    const pong = (try fragments.accumulate(Frame.pong(&pong_payload))).?;
    try std.testing.expect(pong.fin);
    try std.testing.expectEqual(fragment.OpCode.pong, pong.opcode);
    try std.testing.expectEqual(@as(?MaskingKey, null), pong.masking_key);
    try std.testing.expectEqualSlices(u8, &pong_payload, pong.payload);
    try std.testing.expect(!fragments.is_idle());
    try std.testing.expectEqual(@as(usize, 1), fragments.message_len());

    const completed = (try fragments.accumulate(Frame.init(true, .continuation, null, &last))).?;
    try std.testing.expectEqualSlices(u8, "ab", completed.payload);
}

test "Fragments: empty start and empty final continuation produce an empty message" {
    var buffer: [8]u8 = undefined;
    var fragments = fragment.Fragments.init(&buffer);
    var empty: [0]u8 = .{};

    try std.testing.expect((try fragments.accumulate(Frame.init(false, .text, null, &empty))) == null);
    try std.testing.expect(!fragments.is_idle());
    try std.testing.expectEqual(@as(usize, 0), fragments.message_len());

    const completed = (try fragments.accumulate(Frame.init(true, .continuation, null, &empty))).?;
    try std.testing.expect(completed.fin);
    try std.testing.expectEqual(fragment.OpCode.text, completed.opcode);
    try std.testing.expectEqual(@as(usize, 0), completed.payload.len);
    try std.testing.expect(fragments.is_idle());
}

test "Fragments: buffer overflow returns BufferTooShort before committing state" {
    var buffer: [4]u8 = @splat(0xaa);
    var fragments = fragment.Fragments.init(&buffer);
    var oversized = [_]u8{ 1, 2, 3, 4, 5 };

    try std.testing.expectError(
        error.BufferTooShort,
        fragments.accumulate(Frame.init(false, .binary, null, &oversized)),
    );
    try std.testing.expect(fragments.is_idle());
    try std.testing.expectEqual(@as(usize, 0), fragments.message_len());
    for (buffer) |byte| try std.testing.expectEqual(@as(u8, 0xaa), byte);

    var head = [_]u8{ 1, 2, 3 };
    var overflow = [_]u8{ 4, 5 };
    try std.testing.expect((try fragments.accumulate(Frame.init(false, .binary, null, &head))) == null);
    try std.testing.expectError(
        error.BufferTooShort,
        fragments.accumulate(Frame.init(false, .continuation, null, &overflow)),
    );

    // Neither the length nor the untouched tail byte may move on the failure.
    try std.testing.expectEqual(@as(usize, 3), fragments.message_len());
    try std.testing.expectEqual(@as(u8, 0xaa), buffer[3]);

    var last = [_]u8{4};
    const completed = (try fragments.accumulate(Frame.init(true, .continuation, null, &last))).?;
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, completed.payload);
}

test "Fragments: accessors and reset track the in-progress message" {
    var buffer: [16]u8 = undefined;
    var fragments = fragment.Fragments.init(&buffer);
    var first = [_]u8{ 'a', 'b' };
    var second = [_]u8{'c'};
    var empty: [0]u8 = .{};

    try std.testing.expect(fragments.is_idle());
    try std.testing.expectEqual(@as(usize, 0), fragments.message_len());
    try std.testing.expectEqual(@as(?fragment.OpCode, null), fragments.message_opcode());

    try std.testing.expect((try fragments.accumulate(Frame.init(false, .text, null, &first))) == null);
    try std.testing.expect(!fragments.is_idle());
    try std.testing.expectEqual(@as(usize, 2), fragments.message_len());
    try std.testing.expectEqual(@as(?fragment.OpCode, .text), fragments.message_opcode());

    fragments.reset();
    try std.testing.expect(fragments.is_idle());
    try std.testing.expectEqual(@as(usize, 0), fragments.message_len());
    try std.testing.expectEqual(@as(?fragment.OpCode, null), fragments.message_opcode());

    // A reset accumulator starts a fresh message and ignores discarded bytes.
    try std.testing.expect((try fragments.accumulate(Frame.init(false, .binary, null, &second))) == null);
    const completed = (try fragments.accumulate(Frame.init(true, .continuation, null, &empty))).?;
    try std.testing.expectEqual(fragment.OpCode.binary, completed.opcode);
    try std.testing.expectEqualSlices(u8, "c", completed.payload);
}
