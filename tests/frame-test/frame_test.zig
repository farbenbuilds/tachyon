const std = @import("std");
const zslay = @import("zslay");
const tachyon = @import("tachyon");

const frame = tachyon.frame;
const Frame = tachyon.Frame;
const MaskingKey = tachyon.MaskingKey;

test "Frame: encodes an unmasked short text header" {
    var payload = [_]u8{ 'h', 'e', 'l', 'l', 'o' };
    const f = Frame.text(&payload);
    var head: zslay.FrameHeaderBuffer = undefined;

    const head_len = try f.fmt_head(&head);

    try std.testing.expectEqual(@as(usize, 2), head_len);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x81, 0x05 },
        head[0..head_len],
    );
}

test "Mask: round trips a masked short header and payload" {
    var payload = [_]u8{ 'h', 'i' };
    const key: MaskingKey = .{ 0x0a, 0x0b, 0x0c, 0x0d };
    var f = Frame.text(&payload);
    f.mask(key);

    var head: zslay.FrameHeaderBuffer = undefined;
    const head_len = try f.fmt_head(&head);

    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x81, 0x82, 0x0a, 0x0b, 0x0c, 0x0d },
        head[0..head_len],
    );
    try std.testing.expectEqualSlices(u8, &.{ 0x62, 0x62 }, f.payload);

    f.unmask();

    try std.testing.expectEqual(@as(?MaskingKey, null), f.masking_key);
    try std.testing.expectEqualSlices(u8, &.{ 'h', 'i' }, f.payload);
}

test "Frame: encodes extended 16-bit and 64-bit lengths" {
    var payload: [70_000]u8 = @splat(0);
    var head: zslay.FrameHeaderBuffer = undefined;

    const head_126 = try Frame.binary(payload[0..126]).fmt_head(&head);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x82, 0x7e, 0x00, 0x7e },
        head[0..head_126],
    );

    const head_65535 = try Frame.binary(payload[0..65535]).fmt_head(&head);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x82, 0x7e, 0xff, 0xff },
        head[0..head_65535],
    );

    const head_65536 = try Frame.binary(payload[0..65536]).fmt_head(&head);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x82, 0x7f, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00 },
        head[0..head_65536],
    );

    const head_70000 = try Frame.binary(payload[0..70_000]).fmt_head(&head);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x82, 0x7f, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x11, 0x70 },
        head[0..head_70000],
    );
}

test "Frame: encodes an empty payload header" {
    var payload: [0]u8 = @splat(0);
    const f = Frame.binary(&payload);
    var head: zslay.FrameHeaderBuffer = undefined;

    const head_len = try f.fmt_head(&head);

    try std.testing.expectEqual(@as(usize, 2), head_len);
    try std.testing.expectEqualSlices(u8, &.{ 0x82, 0x00 }, head[0..head_len]);
}

test "Frame: leaves reserved bits clear for every opcode" {
    const opcodes = [_]frame.OpCode{ .continuation, .text, .binary, .close, .ping, .pong };
    const key: MaskingKey = .{ 0x11, 0x22, 0x33, 0x44 };
    var payload = [_]u8{0};
    var head: zslay.FrameHeaderBuffer = undefined;

    for (opcodes) |op| {
        // FIN | RSV(0) | opcode nibble. Exact equality proves every RSV bit is
        // clear, not just the two bits a mask would catch.
        const expected_head0: u8 = 0x80 | frame.opcode_to_u8(op);

        const unmasked = Frame.init(true, op, null, &payload);
        const unmasked_len = try unmasked.fmt_head(&head);
        try std.testing.expectEqual(@as(usize, 2), unmasked_len);
        try std.testing.expectEqual(expected_head0, head[0]);

        // Mask through the facade so the shared payload is ciphertext only while
        // the masked header is inspected, then restore it for the next opcode.
        var masked = Frame.init(true, op, null, &payload);
        masked.mask(key);
        const masked_len = try masked.fmt_head(&head);
        try std.testing.expectEqual(@as(usize, 6), masked_len);
        try std.testing.expectEqual(expected_head0, head[0]);
        try std.testing.expect(head[1] & 0x80 != 0);
        masked.unmask();
        try std.testing.expectEqualSlices(u8, &.{0}, &payload);
    }
}

test "Frame: writes a masked close frame through a fixed writer" {
    var payload = [_]u8{ 0x03, 0xe8, 'b', 'y', 'e' };
    var f = Frame.close_raw(&payload);
    f.mask(.{ 0x37, 0xfa, 0x21, 0x3d });

    var out: [64]u8 = @splat(0);
    var writer = std.Io.Writer.fixed(&out);
    try f.writev(&writer);

    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x88, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x34, 0x12, 0x43, 0x44, 0x52 },
        out[0..writer.end],
    );
}

test "Frame: writes through a std.Io file writer" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    var payload = [_]u8{ 'f', 'i', 'l', 'e' };
    const f = Frame.text(&payload);

    const file = try tmp.dir.createFile(io, "frame.bin", .{});
    defer file.close(io);

    var write_buffer: [64]u8 = undefined;
    var file_writer = file.writer(io, &write_buffer);
    try f.writev(&file_writer.interface);
    try file_writer.flush();

    const bytes = try tmp.dir.readFileAlloc(
        io,
        "frame.bin",
        std.testing.allocator,
        .limited(64),
    );
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x81, 0x04, 'f', 'i', 'l', 'e' },
        bytes,
    );
}

test "Frame: writes a masked close frame through a std.Io file writer" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    const key: MaskingKey = .{ 0x11, 0x22, 0x33, 0x44 };
    var storage: [5]u8 = @splat(0);
    var f = try Frame.close(1000, "bye", &storage);
    f.mask(key);

    const file = try tmp.dir.createFile(io, "masked.bin", .{});
    defer file.close(io);

    var write_buffer: [64]u8 = undefined;
    var file_writer = file.writer(io, &write_buffer);
    try f.writev(&file_writer.interface);
    try file_writer.flush();

    const bytes = try tmp.dir.readFileAlloc(
        io,
        "masked.bin",
        std.testing.allocator,
        .limited(64),
    );
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x88, 0x85, 0x11, 0x22, 0x33, 0x44, 0x12, 0xca, 0x51, 0x3d, 0x74 },
        bytes,
    );
}

test "Frame: writev writes unmasked extended-length frames" {
    var payload: [65536]u8 = @splat(0x5a);
    var out: [65546]u8 = @splat(0);

    var writer = std.Io.Writer.fixed(&out);
    try Frame.binary(payload[0..126]).writev(&writer);
    try std.testing.expectEqual(@as(usize, 130), writer.end);
    try std.testing.expectEqualSlices(u8, &.{ 0x82, 0x7e, 0x00, 0x7e }, out[0..4]);
    try std.testing.expectEqual(@as(u8, 0x5a), out[4]);
    try std.testing.expectEqual(@as(u8, 0x5a), out[129]);

    writer = std.Io.Writer.fixed(&out);
    try Frame.binary(payload[0..65535]).writev(&writer);
    try std.testing.expectEqual(@as(usize, 65539), writer.end);
    try std.testing.expectEqualSlices(u8, &.{ 0x82, 0x7e, 0xff, 0xff }, out[0..4]);
    try std.testing.expectEqual(@as(u8, 0x5a), out[65538]);

    writer = std.Io.Writer.fixed(&out);
    try Frame.binary(payload[0..65536]).writev(&writer);
    try std.testing.expectEqual(@as(usize, 65546), writer.end);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x82, 0x7f, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00 },
        out[0..10],
    );
    try std.testing.expectEqual(@as(u8, 0x5a), out[65545]);
}

test "Frame: writev writes masked extended-length frames" {
    const key: MaskingKey = .{ 0x11, 0x22, 0x33, 0x44 };
    var payload: [65536]u8 = @splat(0x5a);
    var out: [65550]u8 = @splat(0);

    var writer = std.Io.Writer.fixed(&out);
    var f = Frame.binary(payload[0..126]);
    f.mask(key);
    try f.writev(&writer);
    try std.testing.expectEqual(@as(usize, 134), writer.end);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x82, 0xfe, 0x00, 0x7e, 0x11, 0x22, 0x33, 0x44 },
        out[0..8],
    );
    try std.testing.expectEqual(@as(u8, 0x4b), out[8]);
    try std.testing.expectEqual(@as(u8, 0x78), out[133]);
    f.unmask();

    writer = std.Io.Writer.fixed(&out);
    f = Frame.binary(payload[0..65535]);
    f.mask(key);
    try f.writev(&writer);
    try std.testing.expectEqual(@as(usize, 65543), writer.end);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x82, 0xfe, 0xff, 0xff, 0x11, 0x22, 0x33, 0x44 },
        out[0..8],
    );
    try std.testing.expectEqual(@as(u8, 0x69), out[65542]);
    f.unmask();

    writer = std.Io.Writer.fixed(&out);
    f = Frame.binary(payload[0..65536]);
    f.mask(key);
    try f.writev(&writer);
    try std.testing.expectEqual(@as(usize, 65550), writer.end);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x82, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x11, 0x22, 0x33, 0x44 },
        out[0..14],
    );
    try std.testing.expectEqual(@as(u8, 0x1e), out[65549]);
    f.unmask();
}

/// Test-only writer whose drain accepts at most one byte per call.
///
/// A zero-capacity internal buffer forces every `writeVec` through `drain`, so
/// `writeVecAll` has to retry partial writes instead of copying into the
/// writer buffer. Each call appends one byte to `out`, so repeated calls fill
/// the destination buffer in wire order and the test can assert the full frame.
const OneByteDrainWriter = struct {
    writer: std.Io.Writer,
    out: []u8,
    written: usize = 0,
    drain_calls: usize = 0,

    fn init(out: []u8) OneByteDrainWriter {
        return .{
            .writer = .{
                .vtable = &.{
                    .drain = drain,
                    .flush = std.Io.Writer.noopFlush,
                    .rebase = std.Io.Writer.failingRebase,
                },
                .buffer = &.{},
            },
            .out = out,
        };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *OneByteDrainWriter = @alignCast(@fieldParentPtr("writer", w));

        // The zero-capacity buffer means the writer never buffers bytes itself.
        std.debug.assert(w.end == 0);
        std.debug.assert(data.len > 0);
        self.drain_calls += 1;

        // Consume the first byte in wire order; the last slice repeats `splat`
        // times, and `writeVecAll` retries from the new position next call.
        for (data[0 .. data.len - 1]) |bytes| {
            if (bytes.len != 0) return self.accept(bytes[0]);
        }
        if (splat != 0 and data[data.len - 1].len != 0) {
            return self.accept(data[data.len - 1][0]);
        }
        return 0;
    }

    fn accept(self: *OneByteDrainWriter, byte: u8) usize {
        std.debug.assert(self.written < self.out.len);

        self.out[self.written] = byte;
        self.written += 1;
        return 1;
    }
};

test "Frame: writev retries one-byte drains until the frame is complete" {
    var payload = [_]u8{ 'h', 'e', 'l', 'l', 'o' };
    const f = Frame.text(&payload);

    var out: [64]u8 = @splat(0);
    var partial = OneByteDrainWriter.init(&out);
    try f.writev(&partial.writer);

    const expected = [_]u8{ 0x81, 0x05, 'h', 'e', 'l', 'l', 'o' };
    try std.testing.expectEqual(expected.len, partial.written);
    try std.testing.expectEqualSlices(u8, &expected, out[0..partial.written]);
    // One accepted byte per drain proves the retry loop, not a single bulk copy.
    try std.testing.expectEqual(expected.len, partial.drain_calls);
}

test "Frame: writev writes zero-byte and one-byte payloads through a partial drain" {
    var empty: [0]u8 = @splat(0);
    var one = [_]u8{'x'};
    var out: [16]u8 = @splat(0);

    var partial = OneByteDrainWriter.init(&out);
    try Frame.text(&empty).writev(&partial.writer);
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 0x00 }, out[0..partial.written]);
    try std.testing.expectEqual(@as(usize, 2), partial.drain_calls);

    partial = OneByteDrainWriter.init(&out);
    try Frame.text(&one).writev(&partial.writer);
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 0x01, 'x' }, out[0..partial.written]);
    try std.testing.expectEqual(@as(usize, 3), partial.drain_calls);
}

test "Frame: write returns the encoded slice and rejects a short buffer" {
    var payload = [_]u8{ 'h', 'i' };
    const f = Frame.text(&payload);

    var out: [16]u8 = @splat(0);
    const encoded = try f.write(&out);
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 0x02, 'h', 'i' }, encoded);

    var small: [3]u8 = @splat(0);
    try std.testing.expectError(error.BufferTooShort, f.write(&small));
}

test "Frame: write rejects a buffer that fits the header but not the payload" {
    var payload = [_]u8{ 'h', 'i' };
    const f = Frame.text(&payload);

    var header_only: [2]u8 = @splat(0);
    try std.testing.expectError(error.BufferTooShort, f.write(&header_only));

    var one_payload_byte_missing: [3]u8 = @splat(0);
    try std.testing.expectError(error.BufferTooShort, f.write(&one_payload_byte_missing));

    var exact: [4]u8 = @splat(0);
    const encoded = try f.write(&exact);
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 0x02, 'h', 'i' }, encoded);
}

test "Close: encodes a big-endian code and reason" {
    var storage: [16]u8 = @splat(0);
    const f = try Frame.close(1000, "bye", &storage);

    try std.testing.expectEqual(true, f.fin);
    try std.testing.expectEqual(frame.OpCode.close, f.opcode);
    try std.testing.expectEqual(@as(?MaskingKey, null), f.masking_key);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xe8, 'b', 'y', 'e' }, f.payload);
}

test "Close: rejects storage smaller than the payload" {
    var storage: [4]u8 = @splat(0);
    try std.testing.expectError(error.BufferTooShort, Frame.close(1000, "bye", &storage));
}

test "Close: writes an empty reason into exact storage" {
    var empty: [2]u8 = @splat(0);
    const f = try Frame.close(1000, "", &empty);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xe8 }, f.payload);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xe8 }, &empty);

    var exact: [5]u8 = @splat(0);
    const with_reason = try Frame.close(1001, "bye", &exact);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xe9, 'b', 'y', 'e' }, with_reason.payload);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xe9, 'b', 'y', 'e' }, &exact);

    var zero: [0]u8 = @splat(0);
    try std.testing.expectError(error.BufferTooShort, Frame.close(1000, "", &zero));

    var one: [1]u8 = @splat(0);
    try std.testing.expectError(error.BufferTooShort, Frame.close(1000, "", &one));
}

test "Close: reserved codes 1005, 1006, and 1015 round-trip but are not allowed" {
    const cases = [_]struct { code: u16, alias: frame.CloseCode }{
        .{ .code = 1005, .alias = .no_status_rcvd },
        .{ .code = 1006, .alias = .abnormal_closure },
        .{ .code = 1015, .alias = .tls_handshake },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case.alias, frame.close_code_from_u16(case.code));
        try std.testing.expectEqual(case.code, frame.close_code_to_u16(case.alias));
        try std.testing.expect(!frame.is_valid_close_code(case.code));
        try std.testing.expect(!frame.is_allowed(case.alias));
    }
}

test "Close: validate_close_payload rejects one-byte, invalid, oversized, and non-UTF-8 payloads" {
    try frame.validate_close_payload(&[_]u8{});
    try frame.validate_close_payload(&.{ 0x03, 0xe8 });
    try frame.validate_close_payload(&.{ 0x03, 0xe8, 'o', 'k' });

    try std.testing.expectError(error.ProtocolError, frame.validate_close_payload(&.{0x03}));
    try std.testing.expectError(error.ProtocolError, frame.validate_close_payload(&.{ 0x03, 0xec }));
    try std.testing.expectError(
        error.InvalidUtf8,
        frame.validate_close_payload(&.{ 0x03, 0xe8, 0xff, 0xfe }),
    );

    var at_limit: [125]u8 = @splat('a');
    at_limit[0] = 0x03;
    at_limit[1] = 0xe8;
    try frame.validate_close_payload(&at_limit);

    var over_limit: [126]u8 = @splat('a');
    over_limit[0] = 0x03;
    over_limit[1] = 0xe8;
    try std.testing.expectError(error.ProtocolError, frame.validate_close_payload(&over_limit));
}

test "Frame: is_utf8 accepts valid payloads and rejects invalid ones" {
    var valid = [_]u8{ 'o', 'k' };
    var invalid = [_]u8{ 0xff, 0xfe };

    try std.testing.expect(Frame.text(&valid).is_utf8());
    try std.testing.expect(!Frame.text(&invalid).is_utf8());
}

test "Frame: opcode_from_u8 round trips and rejects unknown values" {
    const opcodes = [_]frame.OpCode{ .continuation, .text, .binary, .close, .ping, .pong };

    for (opcodes) |op| {
        try std.testing.expectEqual(op, try frame.opcode_from_u8(frame.opcode_to_u8(op)));
    }

    try std.testing.expectError(error.InvalidValue, frame.opcode_from_u8(0x03));
    try std.testing.expectError(error.InvalidValue, frame.opcode_from_u8(0x0f));
}

test "Close: conversions round trip and validity boundaries" {
    try std.testing.expectEqual(frame.CloseCode.normal_closure, frame.close_code_from_u16(1000));
    try std.testing.expectEqual(@as(u16, 1000), frame.close_code_to_u16(.normal_closure));
    try std.testing.expectEqual(@as(u16, 4000), frame.close_code_to_u16(frame.close_code_from_u16(4000)));

    const cases = [_]struct { code: u16, valid: bool }{
        .{ .code = 999, .valid = false },
        .{ .code = 1000, .valid = true },
        .{ .code = 1003, .valid = true },
        .{ .code = 1004, .valid = false },
        .{ .code = 1007, .valid = true },
        .{ .code = 1014, .valid = true },
        .{ .code = 2999, .valid = false },
        .{ .code = 3000, .valid = true },
        .{ .code = 4999, .valid = true },
        .{ .code = 5000, .valid = false },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case.valid, frame.is_valid_close_code(case.code));
        try std.testing.expectEqual(
            case.valid,
            frame.is_allowed(frame.close_code_from_u16(case.code)),
        );
    }
}

test "Frame: rejects oversized and fragmented control frames" {
    var payload_125: [125]u8 = @splat(0);
    var payload_126: [126]u8 = @splat(0);
    var head: zslay.FrameHeaderBuffer = undefined;

    try std.testing.expectEqual(@as(usize, 2), try Frame.ping(&payload_125).fmt_head(&head));
    try std.testing.expectError(error.ProtocolError, Frame.ping(&payload_126).fmt_head(&head));
    try std.testing.expectError(
        error.ProtocolError,
        Frame.init(false, .ping, null, payload_125[0..1]).fmt_head(&head),
    );
}

test "Frame: header_len agrees with fmt_head at length boundaries" {
    var payload: [65536]u8 = @splat(0);
    const key: MaskingKey = .{ 0x01, 0x02, 0x03, 0x04 };
    const lengths = [_]usize{ 0, 1, 125, 126, 127, 65535, 65536 };
    const expected = [_]usize{ 2, 2, 2, 4, 4, 4, 10 };

    var head: zslay.FrameHeaderBuffer = undefined;
    for (lengths, expected) |len, want| {
        const unmasked = Frame.init(true, .binary, null, payload[0..len]);
        try std.testing.expectEqual(want, try unmasked.header_len());
        try std.testing.expectEqual(want, try frame.header_len(len, false));
        try std.testing.expectEqual(want, try unmasked.fmt_head(&head));

        const masked = Frame.init(true, .binary, key, payload[0..len]);
        try std.testing.expectEqual(want + 4, try masked.header_len());
        try std.testing.expectEqual(want + 4, try frame.header_len(len, true));
        try std.testing.expectEqual(want + 4, try masked.fmt_head(&head));
    }
}

test "Mask: unmask_at matches unmask for a chunked payload" {
    const key: MaskingKey = .{ 0x11, 0x22, 0x33, 0x44 };
    var whole = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    var chunked = whole;

    frame.unmask(&whole, key);
    frame.unmask_at(chunked[0..3], key, 0);
    frame.unmask_at(chunked[3..7], key, 3);
    frame.unmask_at(chunked[7..], key, 7);

    try std.testing.expectEqualSlices(u8, &whole, &chunked);
}
