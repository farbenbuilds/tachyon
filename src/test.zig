//! Unit tests for the tachyon WebSocket error model and frame facade.

const std = @import("std");
const zslay = @import("zslay");
const errors = @import("error.zig");
const frame = @import("frame.zig");

const Frame = frame.Frame;
const MaskingKey = frame.MaskingKey;

const WebSocketError = errors.WebSocketError;
const from_zslay = errors.from_zslay;
const from_zslay_close = errors.from_zslay_close;
const from_zslay_queue = errors.from_zslay_queue;
const invalid_status_code = errors.invalid_status_code;
const from_reader = errors.from_reader;
const from_writer = errors.from_writer;
const from_stream = errors.from_stream;
const to_zslay = errors.to_zslay;
const description = errors.description;
const to_string = errors.to_string;
const to_close_code = errors.to_close_code;
const is_protocol_error = errors.is_protocol_error;
const is_fatal = errors.is_fatal;
const is_utf8_error = errors.is_utf8_error;
const is_eof_error = errors.is_eof_error;

test "Error: fastwebsockets parity contains all 20 upstream error variants" {
    const upstream_variants = [_][]const u8{
        "InvalidFragment",
        "InvalidUTF8",
        "InvalidContinuationFrame",
        "InvalidStatusCode",
        "InvalidUpgradeHeader",
        "InvalidConnectionHeader",
        "ConnectionClosed",
        "InvalidCloseFrame",
        "InvalidCloseCode",
        "UnexpectedEOF",
        "ReservedBitsNotZero",
        "ControlFrameFragmented",
        "PingFrameTooLarge",
        "FrameTooLarge",
        "InvalidSecWebsocketVersion",
        "InvalidValue",
        "MissingSecWebSocketKey",
        "IoError",
        "HTTPError",
        "SendError",
    };

    const err_names = @typeInfo(WebSocketError).error_set.error_names.?;
    try std.testing.expectEqual(@as(usize, 20), upstream_variants.len);

    inline for (upstream_variants) |expected| {
        var found = false;
        for (err_names) |actual| {
            if (std.mem.eql(u8, actual, expected)) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

test "Error: every WebSocketError variant has a description and to_string alias" {
    const all_errors = [_]WebSocketError{
        error.InvalidFragment,
        error.InvalidUtf8,
        error.InvalidUTF8,
        error.InvalidContinuationFrame,
        error.InvalidStatusCode,
        error.InvalidUpgradeHeader,
        error.InvalidConnectionHeader,
        error.ConnectionClosed,
        error.InvalidCloseFrame,
        error.InvalidCloseCode,
        error.UnexpectedEOF,
        error.UnexpectedEof,
        error.ReservedBitsNotZero,
        error.ControlFrameFragmented,
        error.PingFrameTooLarge,
        error.FrameTooLarge,
        error.InvalidSecWebsocketVersion,
        error.InvalidValue,
        error.MissingSecWebSocketKey,
        error.IoError,
        error.HTTPError,
        error.SendError,
        error.InvalidOpcode,
        error.InvalidLength,
        error.BufferTooShort,
        error.ProtocolError,
        error.PayloadMasked,
        error.PayloadNotMasked,
        error.MaskingKeyRequired,
        error.PayloadTooLarge,
        error.QueueFull,
        error.WouldBlock,
        error.EndOfStream,
        error.DecompressionFailed,
        error.DecompressedPayloadTooLarge,
        error.InvalidSecWebSocketAccept,
        error.InvalidHttpRequest,
    };

    const err_names = @typeInfo(WebSocketError).error_set.error_names.?;
    try std.testing.expectEqual(@as(usize, err_names.len), @as(usize, all_errors.len));

    for (all_errors) |err| {
        const desc = description(err);
        try std.testing.expect(desc.len > 0);
        try std.testing.expectEqualStrings(desc, to_string(err));
    }
}

test "Error: to_close_code maps wire protocol violations to 1002" {
    const protocol_violations = [_]WebSocketError{
        error.ProtocolError,
        error.ReservedBitsNotZero,
        error.ControlFrameFragmented,
        error.PingFrameTooLarge,
        error.InvalidCloseFrame,
        error.InvalidCloseCode,
        error.InvalidContinuationFrame,
        error.InvalidFragment,
        error.InvalidOpcode,
        error.InvalidLength,
        error.PayloadMasked,
        error.PayloadNotMasked,
        error.MaskingKeyRequired,
        error.InvalidValue,
        error.DecompressionFailed,
    };

    for (protocol_violations) |err| {
        try std.testing.expectEqual(@as(?zslay.StatusCode, .protocol_error), to_close_code(err));
    }
}

test "Error: to_close_code maps InvalidUtf8 and InvalidUTF8 to 1007" {
    try std.testing.expectEqual(@as(?zslay.StatusCode, .invalid_payload), to_close_code(error.InvalidUtf8));
    try std.testing.expectEqual(@as(?zslay.StatusCode, .invalid_payload), to_close_code(error.InvalidUTF8));
}

test "Error: to_close_code maps frame and payload size limits to 1009" {
    try std.testing.expectEqual(@as(?zslay.StatusCode, .message_too_big), to_close_code(error.FrameTooLarge));
    try std.testing.expectEqual(@as(?zslay.StatusCode, .message_too_big), to_close_code(error.PayloadTooLarge));
    try std.testing.expectEqual(
        @as(?zslay.StatusCode, .message_too_big),
        to_close_code(error.DecompressedPayloadTooLarge),
    );
}

test "Error: to_close_code returns null for handshake, closed, transport, and retryable failures" {
    const non_wire = [_]WebSocketError{
        error.InvalidStatusCode,
        error.InvalidUpgradeHeader,
        error.InvalidConnectionHeader,
        error.MissingSecWebSocketKey,
        error.InvalidSecWebSocketAccept,
        error.InvalidHttpRequest,
        error.HTTPError,
        error.UnexpectedEOF,
        error.UnexpectedEof,
        error.BufferTooShort,
        error.EndOfStream,
        error.WouldBlock,
        error.ConnectionClosed,
        error.QueueFull,
        error.IoError,
        error.SendError,
        error.InvalidSecWebsocketVersion,
    };

    for (non_wire) |err| {
        try std.testing.expectEqual(@as(?zslay.StatusCode, null), to_close_code(err));
    }

    try std.testing.expectEqual(@as(?zslay.StatusCode, null), to_close_code(error.InvalidSecWebsocketVersion));
    try std.testing.expectEqual(@as(?zslay.StatusCode, null), to_close_code(error.ConnectionClosed));
    try std.testing.expectEqual(@as(?zslay.StatusCode, null), to_close_code(error.QueueFull));
    try std.testing.expectEqual(@as(?zslay.StatusCode, null), to_close_code(error.IoError));
    try std.testing.expectEqual(@as(?zslay.StatusCode, null), to_close_code(error.SendError));
}

test "Error: every WebSocketError variant has explicit protocol and fatal classifications" {
    const Case = struct {
        err: WebSocketError,
        protocol: bool,
        fatal: bool,
    };

    const cases = [_]Case{
        .{ .err = error.InvalidFragment, .protocol = true, .fatal = true },
        .{ .err = error.InvalidUtf8, .protocol = true, .fatal = true },
        .{ .err = error.InvalidUTF8, .protocol = true, .fatal = true },
        .{ .err = error.InvalidContinuationFrame, .protocol = true, .fatal = true },
        .{ .err = error.InvalidStatusCode, .protocol = false, .fatal = true },
        .{ .err = error.InvalidUpgradeHeader, .protocol = false, .fatal = true },
        .{ .err = error.InvalidConnectionHeader, .protocol = false, .fatal = true },
        .{ .err = error.ConnectionClosed, .protocol = false, .fatal = true },
        .{ .err = error.InvalidCloseFrame, .protocol = true, .fatal = true },
        .{ .err = error.InvalidCloseCode, .protocol = true, .fatal = true },
        .{ .err = error.UnexpectedEOF, .protocol = false, .fatal = true },
        .{ .err = error.UnexpectedEof, .protocol = false, .fatal = true },
        .{ .err = error.ReservedBitsNotZero, .protocol = true, .fatal = true },
        .{ .err = error.ControlFrameFragmented, .protocol = true, .fatal = true },
        .{ .err = error.PingFrameTooLarge, .protocol = true, .fatal = true },
        .{ .err = error.FrameTooLarge, .protocol = false, .fatal = true },
        .{ .err = error.InvalidSecWebsocketVersion, .protocol = false, .fatal = true },
        .{ .err = error.InvalidValue, .protocol = true, .fatal = true },
        .{ .err = error.MissingSecWebSocketKey, .protocol = false, .fatal = true },
        .{ .err = error.IoError, .protocol = false, .fatal = true },
        .{ .err = error.HTTPError, .protocol = false, .fatal = true },
        .{ .err = error.SendError, .protocol = false, .fatal = true },
        .{ .err = error.InvalidOpcode, .protocol = true, .fatal = true },
        .{ .err = error.InvalidLength, .protocol = true, .fatal = true },
        .{ .err = error.BufferTooShort, .protocol = false, .fatal = false },
        .{ .err = error.ProtocolError, .protocol = true, .fatal = true },
        .{ .err = error.PayloadMasked, .protocol = true, .fatal = true },
        .{ .err = error.PayloadNotMasked, .protocol = true, .fatal = true },
        .{ .err = error.MaskingKeyRequired, .protocol = true, .fatal = true },
        .{ .err = error.PayloadTooLarge, .protocol = false, .fatal = true },
        .{ .err = error.QueueFull, .protocol = false, .fatal = false },
        .{ .err = error.WouldBlock, .protocol = false, .fatal = false },
        .{ .err = error.EndOfStream, .protocol = false, .fatal = true },
        .{ .err = error.DecompressionFailed, .protocol = true, .fatal = true },
        .{ .err = error.DecompressedPayloadTooLarge, .protocol = false, .fatal = true },
        .{ .err = error.InvalidSecWebSocketAccept, .protocol = false, .fatal = true },
        .{ .err = error.InvalidHttpRequest, .protocol = false, .fatal = true },
    };

    const err_names = @typeInfo(WebSocketError).error_set.error_names.?;
    try std.testing.expectEqual(@as(usize, err_names.len), @as(usize, cases.len));

    for (cases) |case| {
        try std.testing.expectEqual(case.protocol, is_protocol_error(case.err));
        try std.testing.expectEqual(case.fatal, is_fatal(case.err));
    }

    try std.testing.expect(!is_fatal(error.QueueFull));
}

test "Error: from_zslay maps all zslay.Error variants and normalizes boundary names" {
    try std.testing.expectEqual(error.InvalidOpcode, from_zslay(error.InvalidOpcode));
    try std.testing.expectEqual(error.InvalidLength, from_zslay(error.InvalidLength));
    try std.testing.expectEqual(error.BufferTooShort, from_zslay(error.BufferTooShort));
    try std.testing.expectEqual(error.ProtocolError, from_zslay(error.ProtocolError));
    try std.testing.expectEqual(error.PayloadMasked, from_zslay(error.PayloadMasked));
    try std.testing.expectEqual(error.PayloadNotMasked, from_zslay(error.PayloadNotMasked));
    try std.testing.expectEqual(error.FrameTooLarge, from_zslay(error.PayloadTooLarge));
    try std.testing.expectEqual(error.MaskingKeyRequired, from_zslay(error.MaskingKeyRequired));
    try std.testing.expectEqual(error.InvalidUTF8, from_zslay(error.InvalidUtf8));
}

test "Error: from_zslay_close maps close payload validation errors" {
    try std.testing.expectEqual(error.InvalidCloseCode, from_zslay_close(error.ProtocolError));
    try std.testing.expectEqual(error.InvalidUTF8, from_zslay_close(error.InvalidUtf8));
    try std.testing.expectEqual(error.BufferTooShort, from_zslay_close(error.BufferTooShort));
}

test "Error: from_zslay_queue maps QueueFull correctly" {
    try std.testing.expectEqual(error.QueueFull, from_zslay_queue(error.QueueFull));
    try std.testing.expectEqual(error.BufferTooShort, from_zslay_queue(error.BufferTooShort));
    try std.testing.expectEqual(error.FrameTooLarge, from_zslay_queue(error.PayloadTooLarge));
}

test "Error: invalid_status_code preserves the rejected status" {
    var status: u16 = 0;
    const err = invalid_status_code(418, &status);

    try std.testing.expectEqual(error.InvalidStatusCode, err);
    try std.testing.expectEqual(@as(u16, 418), status);
}

test "Error: from_reader maps std.Io.Reader failures" {
    try std.testing.expectEqual(error.UnexpectedEOF, from_reader(error.EndOfStream));
    try std.testing.expectEqual(error.IoError, from_reader(error.ReadFailed));
}

test "Error: from_writer maps std.Io.Writer failures" {
    try std.testing.expectEqual(error.IoError, from_writer(error.WriteFailed));
}

test "Error: from_stream maps std.Io.Reader.StreamError failures" {
    try std.testing.expectEqual(error.IoError, from_stream(error.ReadFailed));
    try std.testing.expectEqual(error.IoError, from_stream(error.WriteFailed));
    try std.testing.expectEqual(error.UnexpectedEOF, from_stream(error.EndOfStream));
}

test "Error: boundary descriptions approximate fastwebsockets text for all 20 parity variants" {
    const Case = struct {
        err: WebSocketError,
        expected: []const u8,
    };

    const cases = [_]Case{
        .{ .err = error.InvalidFragment, .expected = "Invalid fragment" },
        .{ .err = error.InvalidUTF8, .expected = "Invalid UTF-8" },
        .{ .err = error.InvalidContinuationFrame, .expected = "Invalid continuation frame" },
        .{ .err = error.InvalidStatusCode, .expected = "Invalid status code" },
        .{ .err = error.InvalidUpgradeHeader, .expected = "Invalid upgrade header" },
        .{ .err = error.InvalidConnectionHeader, .expected = "Invalid connection header" },
        .{ .err = error.ConnectionClosed, .expected = "Connection is closed" },
        .{ .err = error.InvalidCloseFrame, .expected = "Invalid close frame" },
        .{ .err = error.InvalidCloseCode, .expected = "Invalid close code" },
        .{ .err = error.UnexpectedEOF, .expected = "Unexpected EOF" },
        .{ .err = error.ReservedBitsNotZero, .expected = "Reserved bits are not zero" },
        .{ .err = error.ControlFrameFragmented, .expected = "Control frame must not be fragmented" },
        .{ .err = error.PingFrameTooLarge, .expected = "Ping frame too large" },
        .{ .err = error.FrameTooLarge, .expected = "Frame too large" },
        .{ .err = error.InvalidSecWebsocketVersion, .expected = "Sec-Websocket-Version must be 13" },
        .{ .err = error.InvalidValue, .expected = "Invalid value" },
        .{ .err = error.MissingSecWebSocketKey, .expected = "Sec-WebSocket-Key header is missing" },
        .{ .err = error.IoError, .expected = "I/O error" },
        .{ .err = error.HTTPError, .expected = "HTTP error" },
        .{ .err = error.SendError, .expected = "Failed to send frame" },
    };

    try std.testing.expectEqual(@as(usize, 20), cases.len);
    inline for (cases) |case| {
        try std.testing.expectEqualStrings(case.expected, description(case.err));
    }
}

test "Error: to_zslay reverse-maps zslay origin errors" {
    try std.testing.expectEqual(@as(?zslay.Error, error.InvalidOpcode), to_zslay(error.InvalidOpcode));
    try std.testing.expectEqual(@as(?zslay.Error, error.InvalidLength), to_zslay(error.InvalidLength));
    try std.testing.expectEqual(@as(?zslay.Error, error.BufferTooShort), to_zslay(error.BufferTooShort));
    try std.testing.expectEqual(@as(?zslay.Error, error.ProtocolError), to_zslay(error.ProtocolError));
    try std.testing.expectEqual(@as(?zslay.Error, error.PayloadMasked), to_zslay(error.PayloadMasked));
    try std.testing.expectEqual(@as(?zslay.Error, error.PayloadNotMasked), to_zslay(error.PayloadNotMasked));
    try std.testing.expectEqual(@as(?zslay.Error, error.PayloadTooLarge), to_zslay(error.PayloadTooLarge));
    try std.testing.expectEqual(@as(?zslay.Error, error.PayloadTooLarge), to_zslay(error.FrameTooLarge));
    try std.testing.expectEqual(@as(?zslay.Error, error.MaskingKeyRequired), to_zslay(error.MaskingKeyRequired));
    try std.testing.expectEqual(@as(?zslay.Error, error.InvalidUtf8), to_zslay(error.InvalidUtf8));
    try std.testing.expectEqual(@as(?zslay.Error, error.InvalidUtf8), to_zslay(error.InvalidUTF8));

    try std.testing.expectEqual(@as(?zslay.Error, null), to_zslay(error.InvalidFragment));
    try std.testing.expectEqual(@as(?zslay.Error, null), to_zslay(error.ConnectionClosed));
    try std.testing.expectEqual(@as(?zslay.Error, null), to_zslay(error.SendError));
}

test "Error: zslay.Error compiles as direct subset of WebSocketError" {
    const z_err: zslay.Error = error.InvalidOpcode;
    const w_err: WebSocketError = z_err;
    try std.testing.expectEqual(error.InvalidOpcode, w_err);
}

test "Error: is_utf8_error and is_eof_error identify matching errors" {
    try std.testing.expect(is_utf8_error(error.InvalidUtf8));
    try std.testing.expect(is_utf8_error(error.InvalidUTF8));
    try std.testing.expect(!is_utf8_error(error.InvalidFragment));

    try std.testing.expect(is_eof_error(error.UnexpectedEOF));
    try std.testing.expect(is_eof_error(error.UnexpectedEof));
    try std.testing.expect(is_eof_error(error.EndOfStream));
    try std.testing.expect(!is_eof_error(error.ConnectionClosed));
}

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
