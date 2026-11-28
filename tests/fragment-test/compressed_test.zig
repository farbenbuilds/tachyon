const std = @import("std");
const tachyon = @import("tachyon");

const Frame = tachyon.Frame;
const Fragments = tachyon.Fragments;

test "Fragments: compressed message defers UTF8" {
    var buffer: [16]u8 = undefined;
    var fragments = Fragments.init(&buffer);

    var first = [_]u8{0xff};
    var second = [_]u8{0xfe};
    try std.testing.expectEqual(
        @as(?Frame, null),
        try fragments.accumulate(Frame.init_rsv1(false, .text, true, null, &first)),
    );
    try std.testing.expectEqual(@as(usize, 1), fragments.message_len());

    const completed = (try fragments.accumulate(Frame.init_rsv1(
        true,
        .continuation,
        false,
        null,
        &second,
    ))).?;
    try std.testing.expect(completed.rsv1);
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xfe }, completed.payload);
}

test "Fragments: plain text still validates and continuation RSV1 is rejected" {
    var buffer: [16]u8 = undefined;
    var fragments = Fragments.init(&buffer);

    var invalid = [_]u8{0xff};
    try std.testing.expectError(
        error.InvalidUTF8,
        fragments.accumulate(Frame.text(&invalid)),
    );

    var first = [_]u8{0xff};
    try std.testing.expectEqual(
        @as(?Frame, null),
        try fragments.accumulate(Frame.init_rsv1(false, .text, true, null, &first)),
    );
    var second = [_]u8{0xfe};
    try std.testing.expectError(
        error.ProtocolError,
        fragments.accumulate(Frame.init_rsv1(true, .continuation, true, null, &second)),
    );
}
