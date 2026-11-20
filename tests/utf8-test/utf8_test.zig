const std = @import("std");
const zslay = @import("zslay");
const tachyon = @import("tachyon");

const support = @import("../support.zig");

const utf8 = tachyon.utf8;
const Frame = tachyon.Frame;
const read_failed_stream = support.read_failed_stream;

fn validate_utf8_across_split(bytes: []const u8, split_at: usize) zslay.Error!void {
    var state: utf8.State = .{};
    state = try state.feed(bytes[0..split_at]);
    state = try state.feed(bytes[split_at..]);
    try state.finish();
}

test "UTF-8: accepts the full valid boundary corpus" {
    const valid = [_][]const u8{
        "",
        &.{0x00},
        &.{0x7f},
        &.{ 0xc2, 0x80 },
        &.{ 0xdf, 0xbf },
        &.{ 0xe0, 0xa0, 0x80 },
        &.{ 0xed, 0x9f, 0xbf },
        &.{ 0xee, 0x80, 0x80 },
        &.{ 0xef, 0xbf, 0xbf },
        &.{ 0xef, 0xbf, 0xbe },
        &.{ 0xf0, 0x90, 0x80, 0x80 },
        &.{ 0xf4, 0x8f, 0xbf, 0xbf },
        &.{ 0xef, 0xbb, 0xbf },
        "A\xc2\xa2\xe2\x82\xac\xf0\x9f\x92\xa9",
    };

    for (valid) |bytes| {
        try utf8.validate(bytes);
        try std.testing.expect(utf8.is_valid(bytes));

        var split_at: usize = 0;
        while (split_at <= bytes.len) : (split_at += 1) {
            try validate_utf8_across_split(bytes, split_at);
        }

        var state: utf8.State = .{};
        for (bytes) |byte| {
            const one = [1]u8{byte};
            state = try state.feed(&one);
        }
        try state.finish();
    }
}

test "UTF-8: accepts valid text across every chunk boundary" {
    const text = "A\xc2\xa2\xe2\x82\xac\xf0\x90\x8d\x88";

    try utf8.validate(text);
    try std.testing.expect(utf8.is_valid(text));
    try std.testing.expect(!utf8.is_valid("\xff"));

    var split_at: usize = 0;
    while (split_at <= text.len) : (split_at += 1) {
        try validate_utf8_across_split(text, split_at);
    }

    const chunk_sizes = [_]usize{ 1, 2, 3, 4, 7 };
    for (chunk_sizes) |size| {
        var state: utf8.State = .{};
        var i: usize = 0;
        while (i < text.len) : (i += size) {
            const end = @min(i + size, text.len);
            state = try state.feed(text[i..end]);
        }
        try state.finish();
    }

    var byte_state: utf8.State = .{};
    for (text) |byte| {
        const one = [1]u8{byte};
        byte_state = try byte_state.feed(&one);
    }
    try byte_state.finish();
}

test "UTF-8: tracks completion across a split code point" {
    var state: utf8.State = .{};
    state = try state.feed("\xc2");
    try std.testing.expect(!state.is_complete());
    try std.testing.expectError(error.InvalidUtf8, state.finish());

    state = try state.feed("\xa2");
    try std.testing.expect(state.is_complete());
    try state.finish();
}

test "UTF-8: rejects malformed sequences at every chunk split" {
    const invalid = [_][]const u8{
        &.{0x80},
        &.{ 0x80, 0x80 },
        &.{ 0x9f, 0x92, 0xa9 },
        &.{ 0xc0, 0x80 },
        &.{ 0xc1, 0xbf },
        &.{ 0xe0, 0x80, 0x80 },
        &.{ 0xe0, 0x9f, 0xbf },
        &.{ 0xf0, 0x80, 0x80, 0x80 },
        &.{ 0xf0, 0x8f, 0xbf, 0xbf },
        &.{ 0xed, 0xa0, 0x80 },
        &.{ 0xed, 0xbf, 0xbf },
        &.{ 0xf4, 0x90, 0x80, 0x80 },
        &.{ 0xf5, 0x80, 0x80, 0x80 },
        &.{ 0xf7, 0xbf, 0xbf, 0xbf },
        &.{ 0xf8, 0x88, 0x80, 0x80, 0x80 },
        &.{0xf8},
        &.{0xfd},
        &.{0xfe},
        &.{0xff},
        &.{ 0xe2, 0x28, 0xa1 },
        &.{ 0xe2, 0x82, 0x41 },
        &.{ 0xf0, 0x9f, 0x92, 0x41 },
        &.{ 0xf0, 0x41, 0x80, 0x80 },
        &.{ 0xc2, 0x41 },
        &.{0xc2},
        &.{0xdf},
        &.{0xe0},
        &.{ 0xe0, 0xa0 },
        &.{ 0xe2, 0x82 },
        &.{ 0xed, 0x9f },
        &.{0xf0},
        &.{ 0xf0, 0x90 },
        &.{ 0xf0, 0x90, 0x8d },
        &.{ 0xf4, 0x8f, 0xbf },
        &.{0xc0},
        &.{0xc1},
        &.{0xf5},
        &.{0xf7},
        &.{ 0x41, 0xc2 },
        &.{ 0x41, 0xff },
        &.{ 0xc2, 0xa2, 0x80 },
        &.{ 0xe2, 0x82, 0xac, 0xff },
        &.{ 0xff, 0x41 },
        &.{ 0x80, 0xc2, 0xa2 },
    };

    for (invalid) |bytes| {
        try std.testing.expectError(error.InvalidUtf8, utf8.validate(bytes));
        try std.testing.expect(!utf8.is_valid(bytes));

        var split_at: usize = 0;
        while (split_at <= bytes.len) : (split_at += 1) {
            try std.testing.expectError(error.InvalidUtf8, validate_utf8_across_split(bytes, split_at));
        }
    }
}

test "UTF-8: a failed feed leaves the prior state unchanged" {
    var state: utf8.State = .{};
    state = try state.feed(&.{ 0xf0, 0x90 });
    try std.testing.expect(!state.is_complete());

    try std.testing.expectError(error.InvalidUtf8, state.feed(&.{0x41}));
    try std.testing.expect(!state.is_complete());

    state = try state.feed(&.{ 0x8d, 0x88 });
    try state.finish();

    var complete: utf8.State = .{};
    try std.testing.expectError(error.InvalidUtf8, complete.feed(&.{0xff}));
    try complete.finish();
}

test "UTF-8: validate_reader follows arbitrary std.Io.Reader chunks" {
    const text = "A\xc2\xa2\xe2\x82\xac\xf0\x90\x8d\x88";
    const chunk_sizes = [_]usize{ 1, 2, 3, 4, 5, text.len };

    for (chunk_sizes) |size| {
        var buffer: [16]u8 = undefined;
        var reader = std.Io.Reader.fixed(text);
        try utf8.validate_reader(&reader, buffer[0..size]);
    }

    var buffer: [16]u8 = undefined;
    var invalid = std.Io.Reader.fixed("\xe2\x28\xa1");
    try std.testing.expectError(error.InvalidUtf8, utf8.validate_reader(&invalid, &buffer));

    var truncated = std.Io.Reader.fixed("\xf0\x90\x8d");
    try std.testing.expectError(error.InvalidUtf8, utf8.validate_reader(&truncated, &buffer));

    var empty = std.Io.Reader.fixed("");
    try utf8.validate_reader(&empty, &buffer);

    var zero: [0]u8 = .{};
    var zero_reader = std.Io.Reader.fixed("A");
    try std.testing.expectError(error.BufferTooShort, utf8.validate_reader(&zero_reader, &zero));
}

test "UTF-8: validate_reader honors a limited std.Io.Reader" {
    const text = "A\xc2\xa2\xe2\x82\xac\xf0\x90\x8d\x88";
    var source = std.Io.Reader.fixed(text ++ "trailing");
    var limit_buffer: [4]u8 = undefined;
    var limited = std.Io.Reader.limited(&source, .limited(text.len), &limit_buffer);
    var chunk_buffer: [3]u8 = undefined;

    try utf8.validate_reader(&limited.interface, &chunk_buffer);

    var tail: [8]u8 = undefined;
    const n = try source.readSliceShort(&tail);
    try std.testing.expectEqualStrings("trailing", tail[0..n]);
}

test "UTF-8: validate_reader follows a std.Io file payload" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    const text = "A\xc2\xa2\xe2\x82\xac\xf0\x90\x8d\x88";

    {
        const file = try tmp.dir.createFile(io, "utf8.txt", .{});
        defer file.close(io);
        try file.writeStreamingAll(io, text);
    }

    const file = try tmp.dir.openFile(io, "utf8.txt", .{});
    defer file.close(io);

    var file_buffer: [8]u8 = undefined;
    var chunk_buffer: [3]u8 = undefined;
    var file_reader = file.reader(io, &file_buffer);
    try utf8.validate_reader(&file_reader.interface, &chunk_buffer);
}

test "UTF-8: empty chunks are no-ops and finish is idempotent" {
    var state: utf8.State = .{};
    state = try state.feed("\xe2");
    state = try state.feed("");
    try std.testing.expect(!state.is_complete());

    state = try state.feed("\x82");
    state = try state.feed("");
    state = try state.feed("\xac");
    try state.finish();
    try state.finish();
    try std.testing.expect(state.is_complete());
}

test "UTF-8: validate_reader propagates read failures" {
    var reader = std.Io.Reader{
        .vtable = &.{ .stream = read_failed_stream },
        .buffer = &.{},
        .seek = 0,
        .end = 0,
    };
    var buffer: [4]u8 = undefined;
    try std.testing.expectError(error.ReadFailed, utf8.validate_reader(&reader, &buffer));
}

test "UTF-8: streaming result matches std.unicode for random inputs" {
    var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
    const random = prng.random();

    var iteration: usize = 0;
    while (iteration < 10_000) : (iteration += 1) {
        var bytes: [16]u8 = undefined;
        const len = random.uintLessThan(usize, bytes.len + 1);
        random.bytes(bytes[0..len]);

        const expected = std.unicode.utf8ValidateSlice(bytes[0..len]);
        var state: utf8.State = .{};
        var i: usize = 0;
        while (i < len) {
            const take = @min(random.uintLessThan(usize, 4) + 1, len - i);
            state = state.feed(bytes[i..][0..take]) catch |err| {
                try std.testing.expectEqual(error.InvalidUtf8, err);
                try std.testing.expect(!expected);
                break;
            };
            i += take;
        } else {
            const accepted = if (state.finish()) |_| true else |_| false;
            try std.testing.expectEqual(expected, accepted);
        }
    }
}

test "UTF-8: Frame.is_utf8 validates unmasked payloads and rejects ciphertext" {
    const valid = "A\xc2\xa2\xe2\x82\xac\xf0\x9f\x92\xa9";
    const invalid = "\xe2\x28\xa1";

    var valid_payload: [valid.len]u8 = undefined;
    @memcpy(&valid_payload, valid);
    const valid_frame = Frame.text(&valid_payload);
    try std.testing.expect(valid_frame.is_utf8());

    var invalid_payload: [invalid.len]u8 = undefined;
    @memcpy(&invalid_payload, invalid);
    const invalid_frame = Frame.text(&invalid_payload);
    try std.testing.expect(!invalid_frame.is_utf8());

    var payload = [_]u8{ 'A', 'B' };
    var masked = Frame.text(&payload);
    masked.mask(.{ 0x00, 0x00, 0x00, 0x00 });
    try std.testing.expect(!masked.is_utf8());
    masked.unmask();
    try std.testing.expect(masked.is_utf8());
}

fn validate_utf8_partition(bytes: []const u8, mask: u16) zslay.Error!void {
    var state: utf8.State = .{};
    var start: usize = 0;
    var i: usize = 0;
    while (i + 1 < bytes.len) : (i += 1) {
        if (mask & (@as(u16, 1) << @intCast(i)) == 0) continue;
        state = try state.feed(bytes[start .. i + 1]);
        start = i + 1;
    }
    state = try state.feed(bytes[start..]);
    try state.finish();
}

test "UTF-8: every partition of short valid and invalid messages agrees" {
    const valid = [_][]const u8{
        "",
        "A",
        "\xc2\xa2",
        "\xe2\x82\xac",
        "\xf0\x90\x8d\x88",
        "\xef\xbb\xbf",
        "A\xc2\xa2\xe2\x82\xac",
    };
    const invalid = [_][]const u8{
        "\x80",
        "\x80\x80",
        "\xc0\x80",
        "\xc1\xbf",
        "\xe0\x80\x80",
        "\xe0\x9f\xbf",
        "\xf0\x80\x80\x80",
        "\xf0\x8f\xbf\xbf",
        "\xed\xa0\x80",
        "\xed\xbf\xbf",
        "\xf4\x90\x80\x80",
        "\xf5\x80\x80\x80",
        "\xf7\xbf\xbf\xbf",
        "\xf8\x88\x80\x80\x80",
        "\xe2\x28\xa1",
        "\xe2\x82\x41",
        "\xf0\x9f\x92\x41",
        "\xf0\x41\x80\x80",
        "\xc2",
        "\xdf",
        "\xe0\xa0",
        "\xe2\x82",
        "\xed\x9f",
        "\xf0\x90",
        "\xf0\x90\x8d",
        "\xf4\x8f\xbf",
        "\x41\xc2",
        "\x41\xff",
        "\xff\x41",
        "\xc2\xa2\x80",
        "\x80\xc2\xa2",
    };

    for (valid) |bytes| {
        const partitions = if (bytes.len == 0) 1 else @as(usize, 1) << @intCast(bytes.len - 1);
        var mask: usize = 0;
        while (mask < partitions) : (mask += 1) {
            try validate_utf8_partition(bytes, @intCast(mask));
        }
    }

    for (invalid) |bytes| {
        const partitions = if (bytes.len == 0) 1 else @as(usize, 1) << @intCast(bytes.len - 1);
        var mask: usize = 0;
        while (mask < partitions) : (mask += 1) {
            try std.testing.expectError(error.InvalidUtf8, validate_utf8_partition(bytes, @intCast(mask)));
        }
    }
}
