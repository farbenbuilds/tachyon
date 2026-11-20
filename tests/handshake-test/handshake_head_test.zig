const std = @import("std");
const tachyon = @import("tachyon");

const support = @import("../support.zig");

const handshake = tachyon.handshake;
const handshake_valid_request = support.handshake_valid_request;

test "Handshake: read_head leaves coalesced frame bytes buffered" {
    const wire = handshake_valid_request ++ "\x81\x02hi";
    var reader = std.Io.Reader.fixed(wire);
    var storage: [256]u8 = undefined;

    const head = try handshake.read_head(&reader, &storage);
    try std.testing.expectEqualStrings(handshake_valid_request, head);

    var wire_frame: [4]u8 = undefined;
    try reader.readSliceAll(&wire_frame);
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 0x02, 'h', 'i' }, &wire_frame);
}

test "Handshake: read_head is independent of the reader buffer size" {
    const wire = handshake_valid_request ++ "\x81\x02hi";
    var source = std.Io.Reader.fixed(wire);
    var tiny_buffer: [1]u8 = undefined;
    var limited = std.Io.Reader.limited(&source, .limited(wire.len), &tiny_buffer);
    var storage: [256]u8 = undefined;

    const head = try handshake.read_head(&limited.interface, &storage);
    try std.testing.expectEqualStrings(handshake_valid_request, head);

    var wire_frame: [4]u8 = undefined;
    try limited.interface.readSliceAll(&wire_frame);
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 0x02, 'h', 'i' }, &wire_frame);
}

test "Handshake: read_head rejects short buffers, bare LF, and truncated heads" {
    var reader = std.Io.Reader.fixed(handshake_valid_request);
    var small: [8]u8 = undefined;
    try std.testing.expectError(error.BufferTooShort, handshake.read_head(&reader, &small));

    var empty: [0]u8 = undefined;
    var empty_reader = std.Io.Reader.fixed("");
    try std.testing.expectError(error.BufferTooShort, handshake.read_head(&empty_reader, &empty));

    var bare_lf = std.Io.Reader.fixed("GET / HTTP/1.1\n\n");
    var storage: [64]u8 = undefined;
    try std.testing.expectError(error.InvalidHttpRequest, handshake.read_head(&bare_lf, &storage));

    var embedded_cr = std.Io.Reader.fixed("GET / HTTP/1.1\r\nX: a\rb\r\n\r\n");
    try std.testing.expectError(error.InvalidHttpRequest, handshake.read_head(&embedded_cr, &storage));

    var truncated = std.Io.Reader.fixed("GET / HTTP/1.1\r\n");
    try std.testing.expectError(error.UnexpectedEOF, handshake.read_head(&truncated, &storage));

    var overlap_reader = std.Io.Reader.fixed(handshake_valid_request);
    try std.testing.expectError(
        error.BufferTooShort,
        handshake.read_head(&overlap_reader, overlap_reader.buffer[0..64]),
    );

    var zero_buffer = std.Io.Reader.failing;
    try std.testing.expectError(error.IoError, handshake.read_head(&zero_buffer, &storage));

    var read_failed = std.Io.Reader.failing;
    var failing_storage: [4]u8 = undefined;
    read_failed.buffer = &failing_storage;
    try std.testing.expectError(error.IoError, handshake.read_head(&read_failed, &storage));
}

test "Handshake: read_head accepts an exact-fit buffer and rejects one byte short" {
    var exact: [handshake_valid_request.len]u8 = undefined;
    var exact_reader = std.Io.Reader.fixed(handshake_valid_request);
    const head = try handshake.read_head(&exact_reader, &exact);
    try std.testing.expectEqualStrings(handshake_valid_request, head);

    var short: [handshake_valid_request.len - 1]u8 = undefined;
    var short_reader = std.Io.Reader.fixed(handshake_valid_request);
    try std.testing.expectError(error.BufferTooShort, handshake.read_head(&short_reader, &short));
}
