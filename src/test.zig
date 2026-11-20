//! Unit tests for the tachyon WebSocket error model and frame facade.

const std = @import("std");
const zslay = @import("zslay");
const connection = @import("connection.zig");
const errors = @import("error.zig");
const fragment = @import("fragment.zig");
const frame = @import("frame.zig");
const split = @import("split.zig");
const utf8 = @import("utf8.zig");

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

fn read_failed_stream(
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    limit: std.Io.Limit,
) std.Io.Reader.StreamError!usize {
    _ = reader;
    _ = writer;
    _ = limit;
    return error.ReadFailed;
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

/// Test-only wire encoder that concatenates encoded frames in a fixed buffer.
///
/// Each frame payload must be a separate caller-owned buffer, because
/// `Frame.write` copies the payload and rejects aliasing output.
fn EncodedStream(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = undefined,
        len: usize = 0,

        const Self = @This();

        fn append(self: *Self, f: Frame) !void {
            const encoded = try f.write(self.bytes[self.len..]);
            self.len += encoded.len;
        }

        fn reader(self: *const Self) std.Io.Reader {
            return std.Io.Reader.fixed(self.bytes[0..self.len]);
        }
    };
}

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

test "FragmentCollector: unfragmented text returns the exact payload" {
    var stream: EncodedStream(64) = .{};
    var payload = [_]u8{ 'h', 'e', 'l', 'l', 'o' };
    try stream.append(Frame.text(&payload));

    var reader = stream.reader();
    var frame_buffer: [64]u8 = undefined;
    var message_buffer: [64]u8 = undefined;
    var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 64);

    const completed = try collector.read_frame();
    try std.testing.expect(completed.fin);
    try std.testing.expectEqual(fragment.OpCode.text, completed.opcode);
    try std.testing.expectEqualSlices(u8, &payload, completed.payload);
    try std.testing.expect(collector.is_at_frame_boundary());
}

test "FragmentCollector: reassembles text split inside a code point" {
    var stream: EncodedStream(64) = .{};
    var first = [_]u8{ 'A', 0xc2 };
    var second = [_]u8{ 0xa2, 0xe2 };
    var third = [_]u8{ 0x82, 0xac };
    try stream.append(Frame.init(false, .text, null, &first));
    try stream.append(Frame.init(false, .continuation, null, &second));
    try stream.append(Frame.init(true, .continuation, null, &third));

    var reader = stream.reader();
    var frame_buffer: [64]u8 = undefined;
    var message_buffer: [64]u8 = undefined;
    var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 64);

    const completed = try collector.read_frame();
    try std.testing.expect(completed.fin);
    try std.testing.expectEqual(fragment.OpCode.text, completed.opcode);
    try std.testing.expectEqualSlices(u8, "A\xc2\xa2\xe2\x82\xac", completed.payload);
    try std.testing.expect(collector.is_at_frame_boundary());
}

test "FragmentCollector: aggregated binary over the limit returns FrameTooLarge" {
    var stream: EncodedStream(64) = .{};
    var first = [_]u8{ 'a', 'b', 'c', 'd', 'e' };
    var second = [_]u8{ 'f', 'g', 'h', 'i', 'j' };
    try stream.append(Frame.init(false, .binary, null, &first));
    try stream.append(Frame.init(true, .continuation, null, &second));

    var reader = stream.reader();
    var frame_buffer: [64]u8 = undefined;
    var message_buffer: [64]u8 = undefined;
    // Two five-byte fragments exceed a nine-byte exclusive message limit.
    var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 9);

    try std.testing.expectError(error.FrameTooLarge, collector.read_frame());
}

test "FragmentCollector: aggregated text over the limit returns FrameTooLarge" {
    var stream: EncodedStream(64) = .{};
    var first = [_]u8{ 'a', 'b', 'c', 'd', 'e' };
    var second = [_]u8{ 'f', 'g', 'h', 'i', 'j' };
    try stream.append(Frame.init(false, .text, null, &first));
    try stream.append(Frame.init(true, .continuation, null, &second));

    var reader = stream.reader();
    var frame_buffer: [64]u8 = undefined;
    var message_buffer: [64]u8 = undefined;
    var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 9);

    try std.testing.expectError(error.FrameTooLarge, collector.read_frame());
}

test "FragmentCollector: exclusive message limit accepts below and rejects the boundary" {
    var payload: [130]u8 = @splat(0x41);
    const accepted_lengths = [_]usize{ 0, 1, 125, 126, 127, 129 };

    for (accepted_lengths) |len| {
        var stream: EncodedStream(256) = .{};
        try stream.append(Frame.binary(payload[0..len]));

        var reader = stream.reader();
        var frame_buffer: [256]u8 = undefined;
        var message_buffer: [256]u8 = undefined;
        var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 130);

        const completed = try collector.read_frame();
        try std.testing.expectEqual(len, completed.payload.len);
        try std.testing.expectEqualSlices(u8, payload[0..len], completed.payload);
    }

    var stream: EncodedStream(256) = .{};
    try stream.append(Frame.binary(payload[0..130]));

    var reader = stream.reader();
    var frame_buffer: [256]u8 = undefined;
    var message_buffer: [256]u8 = undefined;
    var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 130);

    try std.testing.expectError(error.FrameTooLarge, collector.read_frame());
}

test "FragmentCollector: 16-bit and 64-bit length boundaries follow the exclusive limit" {
    var payload: [65536]u8 = @splat(0x5a);
    var frame_buffer: [65536]u8 = undefined;
    var message_buffer: [16]u8 = undefined;

    // 65536 is accepted when the exclusive limit is 65537.
    {
        var stream: EncodedStream(65546) = .{};
        try stream.append(Frame.binary(&payload));

        var reader = stream.reader();
        var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 65537);
        const completed = try collector.read_frame();
        try std.testing.expectEqual(@as(usize, 65536), completed.payload.len);
    }

    // 65535 is accepted when the exclusive limit is 65536.
    {
        var stream: EncodedStream(65545) = .{};
        try stream.append(Frame.binary(payload[0..65535]));

        var reader = stream.reader();
        var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 65536);
        const completed = try collector.read_frame();
        try std.testing.expectEqual(@as(usize, 65535), completed.payload.len);
    }

    // 65536 is rejected when the exclusive limit is 65536.
    {
        var stream: EncodedStream(65546) = .{};
        try stream.append(Frame.binary(&payload));

        var reader = stream.reader();
        var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 65536);
        try std.testing.expectError(error.FrameTooLarge, collector.read_frame());
    }
}

test "FragmentCollector: zero max_message_size rejects an empty frame before reading" {
    var stream: EncodedStream(16) = .{};
    var empty: [0]u8 = .{};
    try stream.append(Frame.text(&empty));

    var reader = stream.reader();
    var frame_buffer: [16]u8 = undefined;
    var message_buffer: [16]u8 = undefined;
    var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 0);

    try std.testing.expectError(error.FrameTooLarge, collector.read_frame());
    try std.testing.expectEqual(@as(usize, 0), reader.seek);
}

test "FragmentCollector: server-role collector unmasks a masked client text frame" {
    var stream: EncodedStream(64) = .{};
    var payload = [_]u8{ 's', 'e', 'c', 'r', 'e', 't' };
    const plaintext = [_]u8{ 's', 'e', 'c', 'r', 'e', 't' };
    var masked = Frame.text(&payload);
    masked.mask(.{ 0x11, 0x22, 0x33, 0x44 });
    try stream.append(masked);

    var reader = stream.reader();
    var frame_buffer: [64]u8 = undefined;
    var message_buffer: [64]u8 = undefined;
    var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .server, 64);

    const completed = try collector.read_frame();
    try std.testing.expectEqual(fragment.OpCode.text, completed.opcode);
    try std.testing.expectEqual(@as(?MaskingKey, null), completed.masking_key);
    try std.testing.expectEqualSlices(u8, &plaintext, completed.payload);
}

test "FragmentCollector: client-role collector rejects a masked inbound frame" {
    var stream: EncodedStream(64) = .{};
    var payload = [_]u8{'x'};
    var masked = Frame.text(&payload);
    masked.mask(.{ 0xaa, 0xbb, 0xcc, 0xdd });
    try stream.append(masked);

    var reader = stream.reader();
    var frame_buffer: [64]u8 = undefined;
    var message_buffer: [64]u8 = undefined;
    var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 64);

    try std.testing.expectError(error.PayloadMasked, collector.read_frame());
}

test "FragmentCollector: truncated header and payload return UnexpectedEOF" {
    {
        var stream: EncodedStream(16) = .{};
        stream.bytes[0] = 0x81;
        stream.len = 1;

        var reader = stream.reader();
        var frame_buffer: [16]u8 = undefined;
        var message_buffer: [16]u8 = undefined;
        var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 64);

        try std.testing.expectError(error.UnexpectedEOF, collector.read_frame());
    }

    {
        var stream: EncodedStream(16) = .{};
        stream.bytes[0] = 0x81;
        stream.bytes[1] = 0x05;
        @memcpy(stream.bytes[2..5], "abc");
        stream.len = 5;

        var reader = stream.reader();
        var frame_buffer: [16]u8 = undefined;
        var message_buffer: [16]u8 = undefined;
        var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 64);

        try std.testing.expectError(error.UnexpectedEOF, collector.read_frame());
        try std.testing.expect(!collector.is_at_wire_boundary());
    }
}

test "FragmentCollector: a failed reader returns IoError" {
    var reader = std.Io.Reader{
        .vtable = &.{ .stream = read_failed_stream },
        .buffer = &.{},
        .seek = 0,
        .end = 0,
    };
    var frame_buffer: [16]u8 = undefined;
    var message_buffer: [16]u8 = undefined;
    var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 64);

    try std.testing.expectError(error.IoError, collector.read_frame());
}

test "FragmentCollector: a frame larger than frame_buffer returns BufferTooShort" {
    var stream: EncodedStream(32) = .{};
    var payload = [_]u8{ 'a', 'b', 'c', 'd', 'e' };
    try stream.append(Frame.binary(&payload));

    var reader = stream.reader();
    var frame_buffer: [4]u8 = undefined;
    var message_buffer: [32]u8 = undefined;
    var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 64);

    try std.testing.expectError(error.BufferTooShort, collector.read_frame());
    // Only the two header bytes may be consumed; the payload stays unread.
    try std.testing.expectEqual(@as(usize, 2), reader.seek);
}

test "FragmentCollector: a message larger than message_buffer returns BufferTooShort" {
    var stream: EncodedStream(32) = .{};
    var first = [_]u8{ 'a', 'b', 'c' };
    var second = [_]u8{ 'd', 'e' };
    try stream.append(Frame.init(false, .binary, null, &first));
    try stream.append(Frame.init(true, .continuation, null, &second));

    var reader = stream.reader();
    var frame_buffer: [8]u8 = undefined;
    var message_buffer: [4]u8 = undefined;
    var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 64);

    try std.testing.expectError(error.BufferTooShort, collector.read_frame());
}

test "FragmentCollector: a ping between fragments is delivered before the completed message" {
    var stream: EncodedStream(64) = .{};
    var first = [_]u8{ 'h', 'e' };
    var ping_payload = [_]u8{'?'};
    var last = [_]u8{ 'l', 'l', 'o' };
    try stream.append(Frame.init(false, .text, null, &first));
    try stream.append(Frame.ping(&ping_payload));
    try stream.append(Frame.init(true, .continuation, null, &last));

    var reader = stream.reader();
    var frame_buffer: [64]u8 = undefined;
    var message_buffer: [64]u8 = undefined;
    var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 64);

    const control = try collector.read_frame();
    try std.testing.expect(control.fin);
    try std.testing.expectEqual(fragment.OpCode.ping, control.opcode);
    try std.testing.expectEqual(@as(?MaskingKey, null), control.masking_key);
    try std.testing.expectEqualSlices(u8, &ping_payload, control.payload);
    // The reader is aligned to the next frame, but the message is still open.
    try std.testing.expect(collector.is_at_wire_boundary());
    try std.testing.expect(!collector.is_at_frame_boundary());

    const completed = try collector.read_frame();
    try std.testing.expectEqual(fragment.OpCode.text, completed.opcode);
    try std.testing.expectEqualSlices(u8, "hello", completed.payload);
    try std.testing.expect(collector.is_at_wire_boundary());
    try std.testing.expect(collector.is_at_frame_boundary());
}

test "FragmentCollector: invalid UTF-8 in an unfragmented text frame returns InvalidUTF8" {
    var stream: EncodedStream(16) = .{};
    var payload = [_]u8{0xff};
    try stream.append(Frame.text(&payload));

    var reader = stream.reader();
    var frame_buffer: [16]u8 = undefined;
    var message_buffer: [16]u8 = undefined;
    var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 64);

    try std.testing.expectError(error.InvalidUTF8, collector.read_frame());
}

test "FragmentCollector: invalid UTF-8 across fragments returns InvalidUTF8" {
    var stream: EncodedStream(16) = .{};
    var first = [_]u8{'A'};
    var second = [_]u8{0xff};
    try stream.append(Frame.init(false, .text, null, &first));
    try stream.append(Frame.init(true, .continuation, null, &second));

    var reader = stream.reader();
    var frame_buffer: [16]u8 = undefined;
    var message_buffer: [16]u8 = undefined;
    var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 64);

    try std.testing.expectError(error.InvalidUTF8, collector.read_frame());
}

test "FragmentCollector: an orphan continuation returns ProtocolError" {
    var stream: EncodedStream(16) = .{};
    var payload = [_]u8{'x'};
    try stream.append(Frame.init(true, .continuation, null, &payload));

    var reader = stream.reader();
    var frame_buffer: [16]u8 = undefined;
    var message_buffer: [16]u8 = undefined;
    var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 64);

    try std.testing.expectError(error.ProtocolError, collector.read_frame());
}

test "FragmentCollector: reset clears an in-progress message and boundary tracking" {
    var stream: EncodedStream(64) = .{};
    var first = [_]u8{ 'h', 'e' };
    var ping_payload = [_]u8{'?'};
    var fresh = [_]u8{ 'o', 'k' };
    try stream.append(Frame.init(false, .text, null, &first));
    try stream.append(Frame.ping(&ping_payload));
    try stream.append(Frame.text(&fresh));

    var reader = stream.reader();
    var frame_buffer: [64]u8 = undefined;
    var message_buffer: [64]u8 = undefined;
    var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 64);

    try std.testing.expect(collector.is_at_frame_boundary());

    const control = try collector.read_frame();
    try std.testing.expectEqual(fragment.OpCode.ping, control.opcode);
    // The partial text message keeps the collector off a boundary.
    try std.testing.expect(!collector.is_at_frame_boundary());

    collector.reset();
    try std.testing.expect(collector.is_at_frame_boundary());

    const completed = try collector.read_frame();
    try std.testing.expectEqual(fragment.OpCode.text, completed.opcode);
    try std.testing.expectEqualSlices(u8, &fresh, completed.payload);
    try std.testing.expect(collector.is_at_frame_boundary());
}

test "FragmentCollector: reads one complete text frame from a std.Io file reader" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    var payload = [_]u8{ 'f', 'i', 'l', 'e' };
    var stream: EncodedStream(64) = .{};
    try stream.append(Frame.text(&payload));

    {
        const file = try tmp.dir.createFile(io, "fragment.bin", .{});
        defer file.close(io);
        try file.writeStreamingAll(io, stream.bytes[0..stream.len]);
    }

    const file = try tmp.dir.openFile(io, "fragment.bin", .{});
    defer file.close(io);

    var file_buffer: [8]u8 = undefined;
    var file_reader = file.reader(io, &file_buffer);
    var frame_buffer: [64]u8 = undefined;
    var message_buffer: [64]u8 = undefined;
    var collector = try fragment.FragmentCollector.init(
        &file_reader.interface,
        &frame_buffer,
        &message_buffer,
        .client,
        64,
    );

    const completed = try collector.read_frame();
    try std.testing.expectEqual(fragment.OpCode.text, completed.opcode);
    try std.testing.expectEqualSlices(u8, &payload, completed.payload);
    try std.testing.expect(collector.is_at_frame_boundary());
}

test "FragmentCollector: a failed accumulation latches BufferTooShort until reset" {
    var stream: EncodedStream(64) = .{};
    var first = [_]u8{ 'a', 'b', 'c' };
    var second = [_]u8{ 'd', 'e' };
    var fresh = [_]u8{ 'o', 'k' };
    try stream.append(Frame.init(false, .text, null, &first));
    try stream.append(Frame.init(false, .continuation, null, &second));
    try stream.append(Frame.text(&fresh));

    var reader = stream.reader();
    var frame_buffer: [16]u8 = undefined;
    var message_buffer: [4]u8 = undefined;
    var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 64);

    try std.testing.expectError(error.BufferTooShort, collector.read_frame());
    // zslay completed the second frame, so the reader is aligned even though the
    // accumulator rejected the bytes.
    try std.testing.expect(collector.is_at_wire_boundary());
    const seek_after_failure = reader.seek;

    // The failure is terminal: the fresh third frame must stay unread.
    try std.testing.expectError(error.BufferTooShort, collector.read_frame());
    try std.testing.expectEqual(seek_after_failure, reader.seek);

    collector.reset();
    const completed = try collector.read_frame();
    try std.testing.expect(completed.fin);
    try std.testing.expectEqual(fragment.OpCode.text, completed.opcode);
    try std.testing.expectEqualSlices(u8, &fresh, completed.payload);
    try std.testing.expect(collector.is_at_wire_boundary());
    try std.testing.expect(collector.is_at_frame_boundary());
}

test "FragmentCollector: a failed UTF-8 accumulation latches InvalidUTF8 until reset" {
    var stream: EncodedStream(64) = .{};
    var first = [_]u8{'A'};
    var invalid = [_]u8{0xff};
    var fresh = [_]u8{ 'o', 'k' };
    try stream.append(Frame.init(false, .text, null, &first));
    try stream.append(Frame.init(true, .continuation, null, &invalid));
    try stream.append(Frame.text(&fresh));

    var reader = stream.reader();
    var frame_buffer: [16]u8 = undefined;
    var message_buffer: [16]u8 = undefined;
    var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 64);

    try std.testing.expectError(error.InvalidUTF8, collector.read_frame());
    try std.testing.expect(collector.is_at_wire_boundary());
    const seek_after_failure = reader.seek;

    try std.testing.expectError(error.InvalidUTF8, collector.read_frame());
    try std.testing.expectEqual(seek_after_failure, reader.seek);

    collector.reset();
    const completed = try collector.read_frame();
    try std.testing.expectEqual(fragment.OpCode.text, completed.opcode);
    try std.testing.expectEqualSlices(u8, &fresh, completed.payload);
}

test "FragmentCollector: a truncated payload latches UnexpectedEOF while off the wire boundary" {
    var stream: EncodedStream(16) = .{};
    stream.bytes[0] = 0x81;
    stream.bytes[1] = 0x05;
    @memcpy(stream.bytes[2..5], "abc");
    stream.len = 5;

    var reader = stream.reader();
    var frame_buffer: [8]u8 = undefined;
    var message_buffer: [8]u8 = undefined;
    var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 64);

    try std.testing.expectError(error.UnexpectedEOF, collector.read_frame());
    try std.testing.expect(!collector.is_at_wire_boundary());
    const seek_after_failure = reader.seek;

    try std.testing.expectError(error.UnexpectedEOF, collector.read_frame());
    try std.testing.expectEqual(seek_after_failure, reader.seek);
    try std.testing.expect(!collector.is_at_wire_boundary());
}

test "FragmentCollector: fragmented messages accept max_message_size - 1 bytes" {
    var stream: EncodedStream(32) = .{};
    var first = [_]u8{ 'a', 'b', 'c', 'd', 'e' };
    var second = [_]u8{ 'f', 'g', 'h' };
    try stream.append(Frame.init(false, .binary, null, &first));
    try stream.append(Frame.init(true, .continuation, null, &second));

    var reader = stream.reader();
    var frame_buffer: [16]u8 = undefined;
    var message_buffer: [8]u8 = undefined;
    var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 9);

    const completed = try collector.read_frame();
    try std.testing.expect(completed.fin);
    try std.testing.expectEqual(fragment.OpCode.binary, completed.opcode);
    try std.testing.expectEqualSlices(u8, "abcdefgh", completed.payload);
    try std.testing.expect(collector.is_at_frame_boundary());
}

test "FragmentCollector: fragmented messages reject the exclusive max_message_size boundary" {
    var stream: EncodedStream(32) = .{};
    var first = [_]u8{ 'a', 'b', 'c', 'd', 'e' };
    var second = [_]u8{ 'f', 'g', 'h', 'i' };
    try stream.append(Frame.init(false, .binary, null, &first));
    try stream.append(Frame.init(true, .continuation, null, &second));

    var reader = stream.reader();
    var frame_buffer: [16]u8 = undefined;
    var message_buffer: [8]u8 = undefined;
    var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 9);

    try std.testing.expectError(error.FrameTooLarge, collector.read_frame());
}

test "FragmentCollector: init rejects max_message_size above zslay MaxPayloadLen" {
    if (@bitSizeOf(usize) >= 64) {
        var empty: [0]u8 = .{};
        var reader = std.Io.Reader.fixed(&empty);
        var frame_buffer: [16]u8 = undefined;
        var message_buffer: [16]u8 = undefined;
        const too_large: usize = @intCast(zslay.MaxPayloadLen + 1);

        try std.testing.expectError(
            error.InvalidLength,
            fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, too_large),
        );
    }
}

test "FragmentCollector: one-byte limit accepts an empty frame and rejects one byte" {
    {
        var stream: EncodedStream(16) = .{};
        var empty: [0]u8 = .{};
        try stream.append(Frame.text(&empty));

        var reader = stream.reader();
        var frame_buffer: [16]u8 = undefined;
        var message_buffer: [16]u8 = undefined;
        var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 1);

        const completed = try collector.read_frame();
        try std.testing.expect(completed.fin);
        try std.testing.expectEqual(fragment.OpCode.text, completed.opcode);
        try std.testing.expectEqual(@as(usize, 0), completed.payload.len);
    }

    {
        var stream: EncodedStream(16) = .{};
        var payload = [_]u8{'x'};
        try stream.append(Frame.text(&payload));

        var reader = stream.reader();
        var frame_buffer: [16]u8 = undefined;
        var message_buffer: [16]u8 = undefined;
        var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 1);

        try std.testing.expectError(error.FrameTooLarge, collector.read_frame());
    }
}

test "FragmentCollector: server role rejects an unmasked inbound frame" {
    var stream: EncodedStream(16) = .{};
    var payload = [_]u8{'x'};
    try stream.append(Frame.text(&payload));

    var reader = stream.reader();
    var frame_buffer: [16]u8 = undefined;
    var message_buffer: [16]u8 = undefined;
    var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .server, 64);

    try std.testing.expectError(error.PayloadNotMasked, collector.read_frame());
}

test "Fragments: masked payloads are rejected before validation or state change" {
    var buffer: [8]u8 = @splat(0xaa);
    var fragments = fragment.Fragments.init(&buffer);
    const key: MaskingKey = .{ 0x01, 0x02, 0x03, 0x04 };
    // Invalid UTF-8 proves the mask check runs before any validation.
    var payload = [_]u8{0xff};

    try std.testing.expectError(
        error.PayloadMasked,
        fragments.accumulate(Frame.init(false, .text, key, &payload)),
    );
    try std.testing.expectError(
        error.PayloadMasked,
        fragments.accumulate(Frame.init(true, .text, key, &payload)),
    );

    try std.testing.expect(fragments.is_idle());
    try std.testing.expectEqual(@as(usize, 0), fragments.message_len());
    for (buffer) |byte| try std.testing.expectEqual(@as(u8, 0xaa), byte);
}

fn expect_collector_protocol_error(wire: []const u8) !void {
    var reader = std.Io.Reader.fixed(wire);
    var frame_buffer: [64]u8 = undefined;
    var message_buffer: [64]u8 = undefined;
    var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 64);

    try std.testing.expectError(error.ProtocolError, collector.read_frame());
}

test "FragmentCollector: zslay-owned malformed input returns ProtocolError" {
    const cases = [_][]const u8{
        // New text data frame while a fragmented text message is active.
        &.{ 0x01, 0x01, 'a', 0x81, 0x01, 'b' },
        // Fragmented ping control frame (FIN=0).
        &.{ 0x09, 0x00 },
        // Ping control frame with an extended-length marker.
        &.{ 0x89, 0x7e, 0x00, 0x7e },
        // Reserved RSV1 bit set.
        &.{ 0xc1, 0x00 },
        // One-byte close payload.
        &.{ 0x88, 0x01, 0x00 },
    };

    for (cases) |wire| try expect_collector_protocol_error(wire);
}

test "FragmentCollector: close frames pass through without code or reason validation" {
    var stream: EncodedStream(16) = .{};
    var invalid_close = [_]u8{ 0x03, 0xe7 };
    try stream.append(Frame.close_raw(&invalid_close));

    var reader = stream.reader();
    var frame_buffer: [16]u8 = undefined;
    var message_buffer: [16]u8 = undefined;
    var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 64);

    const close = try collector.read_frame();
    try std.testing.expect(close.fin);
    try std.testing.expectEqual(fragment.OpCode.close, close.opcode);
    try std.testing.expectEqualSlices(u8, &invalid_close, close.payload);
    // 999 is not a valid close code; validation belongs to the connection layer.
    try std.testing.expect(!frame.is_valid_close_code(999));
    try std.testing.expect(collector.is_at_wire_boundary());
}

test "FragmentCollector: consecutive text messages reset the UTF-8 carry state" {
    var stream: EncodedStream(64) = .{};
    var first_a = [_]u8{ 'A', 0xc2 };
    var first_b = [_]u8{0xa2};
    var second_a = [_]u8{ 'B', 0xe2 };
    var second_b = [_]u8{ 0x82, 0xac };
    try stream.append(Frame.init(false, .text, null, &first_a));
    try stream.append(Frame.init(true, .continuation, null, &first_b));
    try stream.append(Frame.init(false, .text, null, &second_a));
    try stream.append(Frame.init(true, .continuation, null, &second_b));

    var reader = stream.reader();
    var frame_buffer: [64]u8 = undefined;
    var message_buffer: [64]u8 = undefined;
    var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 64);

    const first = try collector.read_frame();
    try std.testing.expect(first.fin);
    try std.testing.expectEqual(fragment.OpCode.text, first.opcode);
    try std.testing.expectEqualSlices(u8, "A\xc2\xa2", first.payload);

    // A carried split code point would corrupt the second message.
    const second = try collector.read_frame();
    try std.testing.expect(second.fin);
    try std.testing.expectEqual(fragment.OpCode.text, second.opcode);
    try std.testing.expectEqualSlices(u8, "B\xe2\x82\xac", second.payload);
    try std.testing.expect(collector.is_at_frame_boundary());
}

test "FragmentCollector: invalid UTF-8 close reasons pass through unvalidated" {
    var stream: EncodedStream(16) = .{};
    var close_payload = [_]u8{ 0x03, 0xe8, 0xff, 0xfe };
    try stream.append(Frame.close_raw(&close_payload));

    var reader = stream.reader();
    var frame_buffer: [16]u8 = undefined;
    var message_buffer: [16]u8 = undefined;
    var collector = try fragment.FragmentCollector.init(&reader, &frame_buffer, &message_buffer, .client, 64);

    const close = try collector.read_frame();
    try std.testing.expect(close.fin);
    try std.testing.expectEqual(fragment.OpCode.close, close.opcode);
    try std.testing.expectEqualSlices(u8, &close_payload, close.payload);
    // Code 1000 with an invalid reason must pass through: close-reason
    // validation belongs to the connection layer, not the collector.
    try std.testing.expect(!utf8.is_valid(close.payload[2..]));
    try std.testing.expect(collector.is_at_wire_boundary());
}

/// Copies the first `limit` bytes of `data` (with `splat` repetition) to `out`.
///
/// Drain implementations share this so their offsets stay in wire order and a
/// partial accept is never rewound.
fn copy_wire_bytes(
    out: []u8,
    written: *usize,
    data: []const []const u8,
    splat: usize,
    limit: usize,
) void {
    var remaining = limit;
    for (data[0 .. data.len - 1]) |bytes| {
        if (remaining == 0) return;
        const take = @min(remaining, bytes.len);
        @memcpy(out[written.*..][0..take], bytes[0..take]);
        written.* += take;
        remaining -= take;
    }

    const pattern = data[data.len - 1];
    var copies: usize = 0;
    while (copies < splat and remaining != 0) : (copies += 1) {
        const take = @min(remaining, pattern.len);
        @memcpy(out[written.*..][0..take], pattern[0..take]);
        written.* += take;
        remaining -= take;
    }
}

/// Test-only writer that records wire bytes, drain shape, and failure controls.
///
/// A zero-capacity internal buffer forces every write through `drain`, so
/// `max_iovecs` observes the actual caller slices instead of a copy into the
/// writer buffer. `fail_after` counts accepted bytes; a failed drain still
/// records the bytes it accepted before returning `error.WriteFailed`.
const RecordingVecWriter = struct {
    writer: std.Io.Writer,
    out: []u8,
    written: usize = 0,
    drain_calls: usize = 0,
    max_iovecs: usize = 0,
    fail_after: ?usize = null,

    fn init(out: []u8) RecordingVecWriter {
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
        const self: *RecordingVecWriter = @alignCast(@fieldParentPtr("writer", w));
        std.debug.assert(w.end == 0);
        std.debug.assert(data.len > 0);
        self.drain_calls += 1;

        var nonempty: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            if (bytes.len != 0) nonempty += 1;
        }
        if (splat != 0 and data[data.len - 1].len != 0) nonempty += 1;
        self.max_iovecs = @max(self.max_iovecs, nonempty);

        const total = std.Io.Writer.countSplat(data, splat);
        var accept = total;
        var partial_failure = false;
        if (self.fail_after) |limit| {
            if (self.written >= limit) return error.WriteFailed;
            const room = limit - self.written;
            if (total > room) {
                accept = room;
                partial_failure = true;
            }
        }

        std.debug.assert(self.written + accept <= self.out.len);
        copy_wire_bytes(self.out, &self.written, data, splat, accept);

        if (partial_failure) return error.WriteFailed;
        return total;
    }
};

/// Test-only buffered writer that fails its flush on demand.
///
/// Small writes stay in `writer.buffer` until `flush`, which is the case the
/// connection's flush latch must cover.
const FlushFailWriter = struct {
    writer: std.Io.Writer,
    out: []u8,
    written: usize = 0,
    fail_flush: bool = true,
    flush_calls: usize = 0,

    fn init(out: []u8, buffer: []u8) FlushFailWriter {
        return .{
            .writer = .{
                .vtable = &.{
                    .drain = drain,
                    .flush = flush,
                    .rebase = std.Io.Writer.failingRebase,
                },
                .buffer = buffer,
            },
            .out = out,
        };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *FlushFailWriter = @alignCast(@fieldParentPtr("writer", w));
        const total = std.Io.Writer.countSplat(data, splat);

        std.debug.assert(self.written + total <= self.out.len);
        copy_wire_bytes(self.out, &self.written, data, splat, total);
        return total;
    }

    fn flush(w: *std.Io.Writer) std.Io.Writer.Error!void {
        const self: *FlushFailWriter = @alignCast(@fieldParentPtr("writer", w));
        self.flush_calls += 1;
        if (self.fail_flush) return error.WriteFailed;

        const buffered = w.buffer[0..w.end];
        std.debug.assert(self.written + buffered.len <= self.out.len);
        @memcpy(self.out[self.written..][0..buffered.len], buffered);
        self.written += buffered.len;
        w.end = 0;
    }
};

/// One decoded frame from a caller-owned wire buffer.
const WireFrame = struct {
    header: zslay.DecodedHeader,
    payload: []const u8,
    consumed: usize,
};

/// Parses the frame starting at `index` and advances past it.
fn next_wire_frame(bytes: []const u8, index: *usize) !WireFrame {
    const header = try zslay.decode_header(bytes[index.*..]);
    const payload_start = index.* + header.header_len;
    const payload_len = std.math.cast(usize, header.payload_len) orelse return error.UnexpectedEOF;
    if (payload_len > bytes.len - payload_start) return error.UnexpectedEOF;

    const consumed = header.header_len + payload_len;
    index.* += consumed;
    return .{
        .header = header,
        .payload = bytes[payload_start..][0..payload_len],
        .consumed = consumed,
    };
}

/// Caller-owned connection storage plus a recording writer.
fn ConnectionRig(
    comptime frame_capacity: usize,
    comptime node_count: usize,
    comptime write_capacity: usize,
    comptime close_capacity: usize,
    comptime scratch_capacity: usize,
    comptime out_capacity: usize,
) type {
    return struct {
        frame_buffer: [frame_capacity]u8 = undefined,
        tx_nodes: [node_count]zslay.FrameNode = undefined,
        write_buffer: [write_capacity]u8 = undefined,
        close_buffer: [close_capacity]u8 = undefined,
        mask_scratch: [scratch_capacity]u8 = undefined,
        out: [out_capacity]u8 = undefined,
        writer: RecordingVecWriter = undefined,
        ws: connection.WebSocket = undefined,

        const Self = @This();

        fn init(self: *Self, reader: *std.Io.Reader, config: connection.Config) !void {
            self.writer = RecordingVecWriter.init(&self.out);
            self.ws = try connection.WebSocket.init(reader, &self.writer.writer, .{
                .frame_buffer = &self.frame_buffer,
                .tx_nodes = &self.tx_nodes,
                .write_buffer = &self.write_buffer,
                .close_buffer = &self.close_buffer,
                .mask_scratch = &self.mask_scratch,
            }, config);
        }

        fn bytes(self: *const Self) []const u8 {
            return self.out[0..self.writer.written];
        }
    };
}

test "WebSocket: client masks outbound frames and server reads them back" {
    const seed: [connection.mask_seed_len]u8 = @splat(0x42);
    var empty = std.Io.Reader.fixed("");
    var client: ConnectionRig(64, 2, 64, 8, 0, 64) = .{};
    try client.init(&empty, .{
        .role = .client,
        .mask_keys = connection.MaskKeySource.from_seed(seed),
    });

    var payload = [_]u8{ 'h', 'i' };
    try client.ws.write_frame(Frame.text(&payload));

    var index: usize = 0;
    const first = try next_wire_frame(client.bytes(), &index);
    try std.testing.expect(first.header.header.mask);
    const key = first.header.masking_key.?;
    try std.testing.expectEqual(@as(usize, 2), first.payload.len);
    try std.testing.expectEqual(@as(u8, 'h' ^ key[0]), first.payload[0]);
    try std.testing.expectEqual(@as(u8, 'i' ^ key[1]), first.payload[1]);
    try std.testing.expectEqual(client.writer.written, index);

    var plaintext: [2]u8 = undefined;
    @memcpy(&plaintext, first.payload);
    zslay.mask(&plaintext, key, 0);
    try std.testing.expectEqualStrings("hi", &plaintext);
    try std.testing.expectEqualStrings("hi", &payload);

    var server_reader = std.Io.Reader.fixed(client.bytes());
    var server: ConnectionRig(64, 2, 64, 8, 0, 64) = .{};
    try server.init(&server_reader, .{ .role = .server });

    const received = try server.ws.read_frame();
    try std.testing.expectEqual(connection.OpCode.text, received.opcode);
    try std.testing.expectEqual(@as(?connection.MaskingKey, null), received.masking_key);
    try std.testing.expectEqualStrings("hi", received.payload);
    try std.testing.expectEqual(@as(usize, 0), server.writer.written);
}

test "WebSocket: server writes unmasked text and close frames" {
    var empty = std.Io.Reader.fixed("");
    var server: ConnectionRig(64, 2, 64, 125, 0, 128) = .{};
    try server.init(&empty, .{ .role = .server });

    var text = [_]u8{ 'o', 'k' };
    try server.ws.write_frame(Frame.text(&text));

    var close_storage: [8]u8 = undefined;
    const close = try Frame.close(1000, "bye", &close_storage);
    try server.ws.write_frame(close);

    var index: usize = 0;
    const text_frame = try next_wire_frame(server.bytes(), &index);
    try std.testing.expect(!text_frame.header.header.mask);
    try std.testing.expectEqual(@as(?connection.MaskingKey, null), text_frame.header.masking_key);
    try std.testing.expectEqualStrings("ok", text_frame.payload);

    const close_frame = try next_wire_frame(server.bytes(), &index);
    try std.testing.expect(!close_frame.header.header.mask);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xe8, 'b', 'y', 'e' }, close_frame.payload);
    try std.testing.expectEqual(server.writer.written, index);
    try std.testing.expect(server.ws.is_closed());
}

test "WebSocket: client rejects a masked inbound frame and latches" {
    const seed: [connection.mask_seed_len]u8 = @splat(0x24);
    var stream: EncodedStream(32) = .{};
    var payload = [_]u8{'x'};
    var masked = Frame.text(&payload);
    masked.mask(.{ 0x01, 0x02, 0x03, 0x04 });
    try stream.append(masked);

    var reader = stream.reader();
    var client: ConnectionRig(16, 1, 32, 8, 0, 8) = .{};
    try client.init(&reader, .{
        .role = .client,
        .mask_keys = connection.MaskKeySource.from_seed(seed),
    });

    try std.testing.expectError(error.PayloadMasked, client.ws.read_frame());
    const seek_after_failure = reader.seek;
    try std.testing.expectError(error.PayloadMasked, client.ws.read_frame());
    try std.testing.expectEqual(seek_after_failure, reader.seek);
    try std.testing.expect(!client.ws.is_at_wire_boundary());
}

test "WebSocket: server rejects an unmasked inbound frame and latches" {
    var stream: EncodedStream(16) = .{};
    var payload = [_]u8{'x'};
    try stream.append(Frame.text(&payload));

    var reader = stream.reader();
    var server: ConnectionRig(16, 1, 32, 8, 0, 8) = .{};
    try server.init(&reader, .{ .role = .server });

    try std.testing.expectError(error.PayloadNotMasked, server.ws.read_frame());
    const seek_after_failure = reader.seek;
    try std.testing.expectError(error.PayloadNotMasked, server.ws.read_frame());
    try std.testing.expectEqual(seek_after_failure, reader.seek);
}

test "WebSocket: write rejects a pre-masked payload" {
    const seed: [connection.mask_seed_len]u8 = @splat(0x33);
    var empty = std.Io.Reader.fixed("");
    var client: ConnectionRig(16, 2, 64, 8, 0, 32) = .{};
    try client.init(&empty, .{
        .role = .client,
        .mask_keys = connection.MaskKeySource.from_seed(seed),
    });

    var payload = [_]u8{'x'};
    var premasked = Frame.text(&payload);
    premasked.mask(.{ 0x11, 0x22, 0x33, 0x44 });

    try std.testing.expectError(error.PayloadMasked, client.ws.write_frame(premasked));
    try std.testing.expectEqual(@as(usize, 0), client.writer.written);
    try std.testing.expectEqual(@as(usize, 0), client.ws.tx_pending());
    try std.testing.expect(!client.ws.is_closed());
}

test "WebSocket: mask key source is deterministic per seed" {
    const seed: [connection.mask_seed_len]u8 = @splat(0x11);
    const other_seed: [connection.mask_seed_len]u8 = @splat(0x22);

    var same_a = connection.MaskKeySource.from_seed(seed);
    var same_b = connection.MaskKeySource.from_seed(seed);
    var different = connection.MaskKeySource.from_seed(other_seed);

    var saw_difference = false;
    for (0..4) |_| {
        const key_a = same_a.next();
        const key_b = same_b.next();
        const key_other = different.next();
        try std.testing.expectEqualSlices(u8, &key_a, &key_b);
        if (!std.mem.eql(u8, &key_a, &key_other)) saw_difference = true;
    }
    try std.testing.expect(saw_difference);
}

test "WebSocket: client init requires a mask source" {
    var empty = std.Io.Reader.fixed("");
    var out: [8]u8 = undefined;
    var writer = RecordingVecWriter.init(&out);
    var frame_buffer: [16]u8 = undefined;
    var tx_nodes: [1]zslay.FrameNode = undefined;
    var write_buffer: [16]u8 = undefined;
    var close_buffer: [2]u8 = undefined;

    try std.testing.expectError(error.MaskingKeyRequired, connection.WebSocket.init(
        &empty,
        &writer.writer,
        .{
            .frame_buffer = &frame_buffer,
            .tx_nodes = &tx_nodes,
            .write_buffer = &write_buffer,
            .close_buffer = &close_buffer,
        },
        .{ .role = .client },
    ));

    try std.testing.expectError(error.MaskingKeyRequired, connection.WebSocket.init(
        &empty,
        &writer.writer,
        .{
            .frame_buffer = &frame_buffer,
            .tx_nodes = &tx_nodes,
            .write_buffer = &write_buffer,
            .close_buffer = &close_buffer,
        },
        .{ .role = .client, .options = .{ .auto_apply_mask = false } },
    ));
}

test "WebSocket: client with auto_apply_mask off cannot write" {
    const seed: [connection.mask_seed_len]u8 = @splat(0x6e);
    var empty = std.Io.Reader.fixed("");
    var client: ConnectionRig(16, 2, 64, 8, 0, 32) = .{};
    try client.init(&empty, .{
        .role = .client,
        .mask_keys = connection.MaskKeySource.from_seed(seed),
    });
    client.ws.set_auto_apply_mask(false);

    var payload = [_]u8{'x'};
    try std.testing.expectError(error.PayloadNotMasked, client.ws.write_frame(Frame.text(&payload)));
    try std.testing.expectEqual(@as(usize, 0), client.writer.written);
    try std.testing.expectEqual(@as(usize, 0), client.ws.tx_pending());
    try std.testing.expect(!client.ws.is_closed());

    client.ws.set_auto_apply_mask(true);
    try client.ws.write_frame(Frame.text(&payload));
    try std.testing.expect(client.writer.written > 0);
}

test "WebSocket: public module re-exports the connection layer" {
    const root = @import("root.zig");

    try std.testing.expect(root.WebSocket == connection.WebSocket);
    try std.testing.expect(root.ConnectionOptions == connection.Options);
    try std.testing.expect(root.ConnectionConfig == connection.Config);
    try std.testing.expect(root.ConnectionStorage == connection.Storage);
    try std.testing.expect(root.MaskKeySource == connection.MaskKeySource);
    try std.testing.expectEqual(connection.default_max_message_size, root.default_max_message_size);
    try std.testing.expectEqual(connection.default_writev_threshold, root.default_writev_threshold);
}

test "WebSocket: options default to fastwebsockets values" {
    const options: connection.Options = .{};

    try std.testing.expect(options.auto_apply_mask);
    try std.testing.expect(options.auto_close);
    try std.testing.expect(options.auto_pong);
    try std.testing.expect(options.writev);
    try std.testing.expectEqual(@as(usize, 1024), options.writev_threshold);
    try std.testing.expectEqual(@as(usize, 64 << 20), options.max_message_size);
    try std.testing.expectEqual(@as(usize, 64 << 20), connection.default_max_message_size);
    try std.testing.expectEqual(@as(usize, 1024), connection.default_writev_threshold);
}

test "WebSocket: connection and fragment defaults agree" {
    try std.testing.expectEqual(fragment.default_max_message_size, connection.default_max_message_size);
}

test "WebSocket: role, pending, and limit accessors track state" {
    var empty = std.Io.Reader.fixed("");
    var server: ConnectionRig(16, 1, 64, 8, 0, 16) = .{};
    try server.init(&empty, .{ .role = .server });

    try std.testing.expectEqual(connection.Role.server, server.ws.role());
    try std.testing.expectEqual(@as(usize, 0), server.ws.tx_pending());
    try std.testing.expectEqual(connection.default_max_message_size, server.ws.max_message_size());
    try std.testing.expect(server.ws.is_at_wire_boundary());
    try std.testing.expect(!server.ws.is_closed());

    var payload = [_]u8{'x'};
    try server.ws.write_frame(Frame.text(&payload));

    try std.testing.expectEqual(connection.Role.server, server.ws.role());
    try std.testing.expectEqual(@as(usize, 0), server.ws.tx_pending());
    try std.testing.expect(server.ws.is_at_wire_boundary());
}

/// Masks `f` with `key` and appends the wire bytes to an `EncodedStream`.
fn append_masked(stream: anytype, f: Frame, key: MaskingKey) !void {
    var masked = f;
    masked.mask(key);
    try stream.append(masked);
}

test "WebSocket: auto_pong suppresses ping and sends an exact pong" {
    var stream: EncodedStream(32) = .{};
    var ping_payload = [_]u8{ 'h', 'i' };
    var text_payload = [_]u8{ 'o', 'k' };
    try append_masked(&stream, Frame.ping(&ping_payload), .{ 0x01, 0x02, 0x03, 0x04 });
    try append_masked(&stream, Frame.text(&text_payload), .{ 0x05, 0x06, 0x07, 0x08 });

    var reader = stream.reader();
    var server: ConnectionRig(32, 2, 64, 8, 0, 32) = .{};
    try server.init(&reader, .{ .role = .server });

    const received = try server.ws.read_frame();
    try std.testing.expectEqual(connection.OpCode.text, received.opcode);
    try std.testing.expectEqualStrings("ok", received.payload);

    var index: usize = 0;
    const pong = try next_wire_frame(server.bytes(), &index);
    try std.testing.expectEqual(connection.OpCode.pong, connection.OpCode.from_wire(pong.header.header.opcode).?);
    try std.testing.expect(!pong.header.header.mask);
    try std.testing.expectEqual(@as(?connection.MaskingKey, null), pong.header.masking_key);
    try std.testing.expectEqualStrings("hi", pong.payload);
    try std.testing.expectEqual(server.writer.written, index);
}

test "WebSocket: auto_pong off delivers the ping and sends nothing" {
    var stream: EncodedStream(16) = .{};
    var payload = [_]u8{ 'h', 'i' };
    try append_masked(&stream, Frame.ping(&payload), .{ 0x09, 0x0a, 0x0b, 0x0c });

    var reader = stream.reader();
    var server: ConnectionRig(16, 1, 64, 8, 0, 8) = .{};
    try server.init(&reader, .{ .role = .server, .options = .{ .auto_pong = false } });

    const received = try server.ws.read_frame();
    try std.testing.expectEqual(connection.OpCode.ping, received.opcode);
    try std.testing.expect(received.fin);
    try std.testing.expectEqual(@as(?connection.MaskingKey, null), received.masking_key);
    try std.testing.expectEqualStrings("hi", received.payload);
    try std.testing.expectEqual(@as(usize, 0), server.writer.written);
}

test "WebSocket: auto_apply_mask off delivers masked frames and skips control policy" {
    const key: MaskingKey = .{ 0x11, 0x22, 0x33, 0x44 };
    var stream: EncodedStream(64) = .{};
    var text_payload = [_]u8{ 'h', 'i' };
    var ping_payload = [_]u8{'p'};
    var close_storage: [8]u8 = undefined;
    try append_masked(&stream, Frame.text(&text_payload), key);
    try append_masked(&stream, Frame.ping(&ping_payload), key);
    try append_masked(&stream, try Frame.close(1000, "bye", &close_storage), key);

    var reader = stream.reader();
    var server: ConnectionRig(32, 2, 64, 8, 0, 8) = .{};
    try server.init(&reader, .{ .role = .server, .options = .{ .auto_apply_mask = false } });

    var plaintext: [8]u8 = undefined;

    const text = try server.ws.read_frame();
    try std.testing.expectEqual(connection.OpCode.text, text.opcode);
    try std.testing.expectEqual(@as(?connection.MaskingKey, key), text.masking_key);
    @memcpy(plaintext[0..text.payload.len], text.payload);
    zslay.mask(plaintext[0..text.payload.len], key, 0);
    try std.testing.expectEqualStrings("hi", plaintext[0..text.payload.len]);

    const ping = try server.ws.read_frame();
    try std.testing.expectEqual(connection.OpCode.ping, ping.opcode);
    try std.testing.expectEqual(@as(?connection.MaskingKey, key), ping.masking_key);
    @memcpy(plaintext[0..ping.payload.len], ping.payload);
    zslay.mask(plaintext[0..ping.payload.len], key, 0);
    try std.testing.expectEqualStrings("p", plaintext[0..ping.payload.len]);
    try std.testing.expectEqual(@as(usize, 0), server.writer.written);

    const close = try server.ws.read_frame();
    try std.testing.expectEqual(connection.OpCode.close, close.opcode);
    try std.testing.expectEqual(@as(?connection.MaskingKey, key), close.masking_key);
    @memcpy(plaintext[0..close.payload.len], close.payload);
    zslay.mask(plaintext[0..close.payload.len], key, 0);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xe8, 'b', 'y', 'e' }, plaintext[0..close.payload.len]);
    try std.testing.expectEqual(@as(usize, 0), server.writer.written);
    try std.testing.expect(!server.ws.is_closed());
}

test "WebSocket: client with auto_apply_mask off delivers control frames without replying" {
    const seed: [connection.mask_seed_len]u8 = @splat(0x3c);
    var stream: EncodedStream(32) = .{};
    var ping_payload = [_]u8{ 'h', 'i' };
    var close_storage: [8]u8 = undefined;
    var trailing_payload = [_]u8{'x'};
    try stream.append(Frame.ping(&ping_payload));
    try stream.append(try Frame.close(1000, "bye", &close_storage));
    try stream.append(Frame.text(&trailing_payload));

    var reader = stream.reader();
    var client: ConnectionRig(32, 2, 64, 8, 0, 32) = .{};
    try client.init(&reader, .{
        .role = .client,
        .options = .{ .auto_apply_mask = false },
        .mask_keys = connection.MaskKeySource.from_seed(seed),
    });

    const ping = try client.ws.read_frame();
    try std.testing.expectEqual(connection.OpCode.ping, ping.opcode);
    try std.testing.expectEqualStrings("hi", ping.payload);
    try std.testing.expectEqual(@as(usize, 0), client.writer.written);
    try std.testing.expect(!client.ws.is_closed());

    const close = try client.ws.read_frame();
    try std.testing.expectEqual(connection.OpCode.close, close.opcode);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xe8, 'b', 'y', 'e' }, close.payload);
    try std.testing.expectEqual(@as(usize, 0), client.writer.written);

    // Neither an automatic pong nor a close echo may latch this client's read,
    // but the validated close still makes the connection terminal.
    try std.testing.expectEqual(@as(?WebSocketError, null), client.ws.read_failure);
    try std.testing.expectEqual(@as(?WebSocketError, null), client.ws.write_failure);
    try std.testing.expect(client.ws.is_closed());

    try std.testing.expectError(error.ConnectionClosed, client.ws.read_frame());
    try std.testing.expectEqual(@as(usize, 0), client.writer.written);
}

test "WebSocket: suppressed invalid close reply is terminal" {
    const seed: [connection.mask_seed_len]u8 = @splat(0x3d);
    var stream: EncodedStream(32) = .{};
    var close_storage: [8]u8 = undefined;
    var trailing_payload = [_]u8{'x'};
    try stream.append(try Frame.close(999, "bad", &close_storage));
    try stream.append(Frame.text(&trailing_payload));

    var reader = stream.reader();
    var client: ConnectionRig(32, 2, 64, 8, 0, 32) = .{};
    try client.init(&reader, .{
        .role = .client,
        .options = .{ .auto_apply_mask = false },
        .mask_keys = connection.MaskKeySource.from_seed(seed),
    });

    try std.testing.expectError(error.InvalidCloseCode, client.ws.read_frame());
    try std.testing.expectEqual(@as(usize, 0), client.writer.written);
    try std.testing.expectEqual(@as(?WebSocketError, null), client.ws.write_failure);
    try std.testing.expect(client.ws.is_closed());

    // The invalid close was fully consumed, so the wire boundary is clean; the
    // reset clears only the latched read failure and keeps `closed`.
    client.ws.reset();

    try std.testing.expectError(error.ConnectionClosed, client.ws.read_frame());
    try std.testing.expectEqual(@as(usize, 0), client.writer.written);
}

test "WebSocket: auto_pong masks a client pong with a fresh key" {
    const seed: [connection.mask_seed_len]u8 = @splat(0x55);
    var stream: EncodedStream(32) = .{};
    var ping_payload = [_]u8{ 'h', 'i' };
    var text_payload = [_]u8{ 'o', 'k' };
    try stream.append(Frame.ping(&ping_payload));
    try stream.append(Frame.text(&text_payload));

    var reader = stream.reader();
    var client: ConnectionRig(32, 2, 64, 8, 0, 64) = .{};
    try client.init(&reader, .{
        .role = .client,
        .mask_keys = connection.MaskKeySource.from_seed(seed),
    });

    var outbound = [_]u8{'a'};
    try client.ws.write_frame(Frame.text(&outbound));

    const received = try client.ws.read_frame();
    try std.testing.expectEqual(connection.OpCode.text, received.opcode);
    try std.testing.expectEqualStrings("ok", received.payload);

    var expected_keys = connection.MaskKeySource.from_seed(seed);
    const text_key = expected_keys.next();
    const pong_key = expected_keys.next();

    var index: usize = 0;
    const text_frame = try next_wire_frame(client.bytes(), &index);
    try std.testing.expectEqual(connection.OpCode.text, connection.OpCode.from_wire(text_frame.header.header.opcode).?);
    try std.testing.expectEqualSlices(u8, &text_key, &text_frame.header.masking_key.?);

    const pong = try next_wire_frame(client.bytes(), &index);
    try std.testing.expectEqual(connection.OpCode.pong, connection.OpCode.from_wire(pong.header.header.opcode).?);
    try std.testing.expect(pong.header.header.mask);
    const key = pong.header.masking_key.?;
    try std.testing.expectEqualSlices(u8, &pong_key, &key);
    try std.testing.expectEqual(@as(usize, 2), pong.payload.len);
    try std.testing.expectEqual(@as(u8, 'h' ^ key[0]), pong.payload[0]);
    try std.testing.expectEqual(@as(u8, 'i' ^ key[1]), pong.payload[1]);
}

test "WebSocket: auto_pong preserves an in-progress fragmented message" {
    var stream: EncodedStream(64) = .{};
    var first = [_]u8{ 'h', 'e' };
    var ping_payload = [_]u8{'p'};
    var last = [_]u8{ 'l', 'l', 'o' };
    try append_masked(&stream, Frame.init(false, .text, null, &first), .{ 0x01, 0x02, 0x03, 0x04 });
    try append_masked(&stream, Frame.ping(&ping_payload), .{ 0x05, 0x06, 0x07, 0x08 });
    try append_masked(&stream, Frame.init(true, .continuation, null, &last), .{ 0x09, 0x0a, 0x0b, 0x0c });

    var reader = stream.reader();
    var server: ConnectionRig(32, 2, 64, 8, 0, 32) = .{};
    try server.init(&reader, .{ .role = .server });

    const start = try server.ws.read_frame();
    try std.testing.expectEqual(connection.OpCode.text, start.opcode);
    try std.testing.expect(!start.fin);
    try std.testing.expectEqualStrings("he", start.payload);
    try std.testing.expectEqual(connection.OpCode.text, server.ws.conn.rx_fragment.opcode.?);
    try std.testing.expectEqual(@as(u64, 2), server.ws.conn.rx_fragment.message_len);

    const tail = try server.ws.read_frame();
    try std.testing.expectEqual(connection.OpCode.continuation, tail.opcode);
    try std.testing.expect(tail.fin);
    try std.testing.expectEqualStrings("llo", tail.payload);
    try std.testing.expectEqual(@as(?connection.OpCode, null), server.ws.conn.rx_fragment.opcode);
    try std.testing.expectEqual(@as(u64, 0), server.ws.conn.rx_fragment.message_len);
    try std.testing.expect(server.ws.is_at_wire_boundary());

    var index: usize = 0;
    const pong = try next_wire_frame(server.bytes(), &index);
    try std.testing.expectEqual(connection.OpCode.pong, connection.OpCode.from_wire(pong.header.header.opcode).?);
    try std.testing.expectEqualStrings("p", pong.payload);
    try std.testing.expectEqual(server.writer.written, index);
}

test "WebSocket: ping after close is suppressed without a pong" {
    var stream: EncodedStream(32) = .{};
    var ping_payload = [_]u8{'?'};
    var text_payload = [_]u8{'x'};
    try append_masked(&stream, Frame.ping(&ping_payload), .{ 0x10, 0x20, 0x30, 0x40 });
    try append_masked(&stream, Frame.text(&text_payload), .{ 0x50, 0x60, 0x70, 0x80 });

    var reader = stream.reader();
    var server: ConnectionRig(32, 2, 64, 8, 0, 32) = .{};
    try server.init(&reader, .{ .role = .server });

    var close_storage: [2]u8 = undefined;
    try server.ws.write_frame(try Frame.close(1000, "", &close_storage));
    const output_after_close = server.writer.written;

    try std.testing.expectError(error.ConnectionClosed, server.ws.read_frame());
    try std.testing.expectEqual(output_after_close, server.writer.written);
    try std.testing.expect(server.ws.is_closed());
}

test "WebSocket: valid close is returned and echoed with the exact payload" {
    var stream: EncodedStream(32) = .{};
    var close_storage: [8]u8 = undefined;
    try append_masked(&stream, try Frame.close(1000, "bye", &close_storage), .{ 0xa1, 0xb2, 0xc3, 0xd4 });

    var reader = stream.reader();
    var server: ConnectionRig(32, 2, 64, 8, 0, 32) = .{};
    try server.init(&reader, .{ .role = .server });

    const received = try server.ws.read_frame();
    try std.testing.expectEqual(connection.OpCode.close, received.opcode);
    try std.testing.expectEqual(@as(?connection.MaskingKey, null), received.masking_key);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xe8, 'b', 'y', 'e' }, received.payload);
    try std.testing.expect(server.ws.is_closed());

    var index: usize = 0;
    const echo = try next_wire_frame(server.bytes(), &index);
    try std.testing.expectEqual(connection.OpCode.close, connection.OpCode.from_wire(echo.header.header.opcode).?);
    try std.testing.expect(!echo.header.header.mask);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xe8, 'b', 'y', 'e' }, echo.payload);
    try std.testing.expectEqual(server.writer.written, index);
}

test "WebSocket: client echoes a valid close with a masked exact payload" {
    const seed: [connection.mask_seed_len]u8 = @splat(0x47);
    var stream: EncodedStream(32) = .{};
    var close_storage: [8]u8 = undefined;
    try stream.append(try Frame.close(1000, "bye", &close_storage));

    var reader = stream.reader();
    var client: ConnectionRig(32, 2, 64, 8, 0, 32) = .{};
    try client.init(&reader, .{
        .role = .client,
        .mask_keys = connection.MaskKeySource.from_seed(seed),
    });

    const received = try client.ws.read_frame();
    try std.testing.expectEqual(connection.OpCode.close, received.opcode);
    try std.testing.expectEqual(@as(?connection.MaskingKey, null), received.masking_key);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xe8, 'b', 'y', 'e' }, received.payload);
    try std.testing.expect(client.ws.is_closed());

    var index: usize = 0;
    const echo = try next_wire_frame(client.bytes(), &index);
    try std.testing.expect(echo.header.header.mask);
    const key = echo.header.masking_key.?;
    try std.testing.expectEqual(@as(usize, 5), echo.payload.len);

    var plaintext: [5]u8 = undefined;
    @memcpy(&plaintext, echo.payload);
    zslay.mask(&plaintext, key, 0);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xe8, 'b', 'y', 'e' }, &plaintext);
    try std.testing.expectEqual(client.writer.written, index);
}

test "WebSocket: client sends a masked 1002 for an invalid close code" {
    const seed: [connection.mask_seed_len]u8 = @splat(0x48);
    var stream: EncodedStream(32) = .{};
    var payload = [_]u8{ 0x03, 0xe7, 'b', 'a', 'd' };
    try stream.append(Frame.close_raw(&payload));

    var reader = stream.reader();
    var client: ConnectionRig(32, 2, 64, 8, 0, 32) = .{};
    try client.init(&reader, .{
        .role = .client,
        .mask_keys = connection.MaskKeySource.from_seed(seed),
    });

    try std.testing.expectError(error.InvalidCloseCode, client.ws.read_frame());
    try std.testing.expect(client.ws.is_closed());

    var index: usize = 0;
    const reply = try next_wire_frame(client.bytes(), &index);
    try std.testing.expect(reply.header.header.mask);
    const key = reply.header.masking_key.?;
    try std.testing.expectEqual(@as(usize, 5), reply.payload.len);

    var plaintext: [5]u8 = undefined;
    @memcpy(&plaintext, reply.payload);
    zslay.mask(&plaintext, key, 0);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xea, 'b', 'a', 'd' }, &plaintext);
    try std.testing.expectEqual(client.writer.written, index);
}

test "WebSocket: invalid close plus failed 1002 send leaves the read latch clear" {
    const seed: [connection.mask_seed_len]u8 = @splat(0x46);
    var stream: EncodedStream(32) = .{};
    var close_payload = [_]u8{ 0x03, 0xe7, 'b', 'a', 'd' };
    var text_payload = [_]u8{ 'o', 'k' };
    try stream.append(Frame.close_raw(&close_payload));
    try stream.append(Frame.text(&text_payload));

    var reader = stream.reader();
    var client: ConnectionRig(16, 2, 32, 8, 0, 16) = .{};
    try client.init(&reader, .{
        .role = .client,
        .mask_keys = connection.MaskKeySource.from_seed(seed),
    });
    client.writer.fail_after = 0;

    try std.testing.expectError(error.IoError, client.ws.read_frame());
    try std.testing.expectEqual(@as(?WebSocketError, null), client.ws.read_failure);
    try std.testing.expectEqual(@as(?WebSocketError, error.IoError), client.ws.write_failure);
    try std.testing.expectEqual(@as(usize, 0), client.writer.written);

    client.ws.reset_tx();
    try std.testing.expectEqual(@as(?WebSocketError, null), client.ws.write_failure);

    const received = try client.ws.read_frame();
    try std.testing.expectEqual(connection.OpCode.text, received.opcode);
    try std.testing.expectEqualStrings("ok", received.payload);
}

test "WebSocket: successful 1002 latches InvalidCloseCode" {
    const seed: [connection.mask_seed_len]u8 = @splat(0x45);
    var stream: EncodedStream(16) = .{};
    var payload = [_]u8{ 0x03, 0xe7, 'b', 'a', 'd' };
    try stream.append(Frame.close_raw(&payload));

    var reader = stream.reader();
    var client: ConnectionRig(16, 2, 32, 8, 0, 32) = .{};
    try client.init(&reader, .{
        .role = .client,
        .mask_keys = connection.MaskKeySource.from_seed(seed),
    });

    try std.testing.expectError(error.InvalidCloseCode, client.ws.read_frame());
    try std.testing.expectEqual(@as(?WebSocketError, error.InvalidCloseCode), client.ws.read_failure);
    try std.testing.expectEqual(@as(?WebSocketError, null), client.ws.write_failure);
    const seek_after_first = reader.seek;

    try std.testing.expectError(error.InvalidCloseCode, client.ws.read_frame());
    try std.testing.expectEqual(seek_after_first, reader.seek);
}

test "WebSocket: close code 1014 is accepted and echoed" {
    var stream: EncodedStream(32) = .{};
    var close_storage: [8]u8 = undefined;
    try append_masked(&stream, try Frame.close(1014, "gone", &close_storage), .{ 0x5a, 0x6b, 0x7c, 0x8d });

    var reader = stream.reader();
    var server: ConnectionRig(32, 2, 64, 8, 0, 32) = .{};
    try server.init(&reader, .{ .role = .server });

    const received = try server.ws.read_frame();
    try std.testing.expectEqual(connection.OpCode.close, received.opcode);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xf6, 'g', 'o', 'n', 'e' }, received.payload);
    try std.testing.expect(server.ws.is_closed());

    var index: usize = 0;
    const echo = try next_wire_frame(server.bytes(), &index);
    try std.testing.expectEqual(connection.OpCode.close, connection.OpCode.from_wire(echo.header.header.opcode).?);
    try std.testing.expect(!echo.header.header.mask);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xf6, 'g', 'o', 'n', 'e' }, echo.payload);
    try std.testing.expectEqual(server.writer.written, index);
}

test "WebSocket: empty close payload is echoed empty" {
    var stream: EncodedStream(16) = .{};
    var empty: [0]u8 = .{};
    try append_masked(&stream, Frame.close_raw(&empty), .{ 0x0a, 0x0b, 0x0c, 0x0d });

    var reader = stream.reader();
    var server: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
    try server.init(&reader, .{ .role = .server });

    const received = try server.ws.read_frame();
    try std.testing.expectEqual(connection.OpCode.close, received.opcode);
    try std.testing.expectEqual(@as(usize, 0), received.payload.len);
    try std.testing.expect(server.ws.is_closed());

    var index: usize = 0;
    const echo = try next_wire_frame(server.bytes(), &index);
    try std.testing.expectEqual(@as(usize, 0), echo.payload.len);
    try std.testing.expectEqual(server.writer.written, index);
}

test "WebSocket: invalid UTF-8 close reason returns InvalidUTF8 with no reply" {
    var stream: EncodedStream(16) = .{};
    var payload = [_]u8{ 0x03, 0xe8, 0xff };
    try append_masked(&stream, Frame.close_raw(&payload), .{ 0x1a, 0x2b, 0x3c, 0x4d });

    var reader = stream.reader();
    var server: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
    try server.init(&reader, .{ .role = .server });

    try std.testing.expectError(error.InvalidUTF8, server.ws.read_frame());
    try std.testing.expectEqual(@as(usize, 0), server.writer.written);
    try std.testing.expect(!server.ws.is_closed());
    try std.testing.expect(server.ws.is_at_wire_boundary());
    const seek_after_failure = reader.seek;

    try std.testing.expectError(error.InvalidUTF8, server.ws.read_frame());
    try std.testing.expectEqual(seek_after_failure, reader.seek);
}

test "WebSocket: invalid close code with valid reason sends 1002 with the reason" {
    var stream: EncodedStream(16) = .{};
    var payload = [_]u8{ 0x03, 0xe7, 'b', 'a', 'd' };
    try append_masked(&stream, Frame.close_raw(&payload), .{ 0xaa, 0xbb, 0xcc, 0xdd });

    var reader = stream.reader();
    var server: ConnectionRig(16, 2, 64, 8, 0, 32) = .{};
    try server.init(&reader, .{ .role = .server });

    try std.testing.expectError(error.InvalidCloseCode, server.ws.read_frame());
    try std.testing.expect(server.ws.is_closed());

    var index: usize = 0;
    const reply = try next_wire_frame(server.bytes(), &index);
    try std.testing.expectEqual(connection.OpCode.close, connection.OpCode.from_wire(reply.header.header.opcode).?);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xea, 'b', 'a', 'd' }, reply.payload);
    try std.testing.expectEqual(server.writer.written, index);
}

test "WebSocket: invalid close code and invalid UTF-8 reason returns InvalidUTF8" {
    var stream: EncodedStream(16) = .{};
    var payload = [_]u8{ 0x03, 0xe7, 0xff };
    try append_masked(&stream, Frame.close_raw(&payload), .{ 0x12, 0x34, 0x56, 0x78 });

    var reader = stream.reader();
    var server: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
    try server.init(&reader, .{ .role = .server });

    try std.testing.expectError(error.InvalidUTF8, server.ws.read_frame());
    try std.testing.expectEqual(@as(usize, 0), server.writer.written);
    try std.testing.expect(!server.ws.is_closed());
}

test "WebSocket: invalid close code with empty reason sends an exact 1002 payload" {
    var stream: EncodedStream(16) = .{};
    var payload = [_]u8{ 0x03, 0xee };
    try append_masked(&stream, Frame.close_raw(&payload), .{ 0x21, 0x43, 0x65, 0x87 });

    var reader = stream.reader();
    var server: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
    try server.init(&reader, .{ .role = .server });

    try std.testing.expectError(error.InvalidCloseCode, server.ws.read_frame());
    try std.testing.expect(server.ws.is_closed());

    var index: usize = 0;
    const reply = try next_wire_frame(server.bytes(), &index);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xea }, reply.payload);
    try std.testing.expectEqual(server.writer.written, index);
}

test "WebSocket: close buffer too small drops the 1002 reason" {
    var stream: EncodedStream(16) = .{};
    var payload = [_]u8{ 0x03, 0xe7, 'b', 'a', 'd' };
    try append_masked(&stream, Frame.close_raw(&payload), .{ 0x98, 0x76, 0x54, 0x32 });

    var reader = stream.reader();
    var server: ConnectionRig(16, 2, 64, 2, 0, 16) = .{};
    try server.init(&reader, .{ .role = .server });

    try std.testing.expectError(error.InvalidCloseCode, server.ws.read_frame());
    try std.testing.expect(server.ws.is_closed());

    var index: usize = 0;
    const reply = try next_wire_frame(server.bytes(), &index);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xea }, reply.payload);
    try std.testing.expectEqual(server.writer.written, index);
}

test "WebSocket: auto_close off delivers close bytes without validation or echo" {
    var stream: EncodedStream(16) = .{};
    var payload = [_]u8{ 0x03, 0xe7, 0xff };
    try append_masked(&stream, Frame.close_raw(&payload), .{ 0xef, 0xcd, 0xab, 0x89 });

    var reader = stream.reader();
    var server: ConnectionRig(16, 1, 64, 8, 0, 8) = .{};
    try server.init(&reader, .{ .role = .server, .options = .{ .auto_close = false } });

    const received = try server.ws.read_frame();
    try std.testing.expectEqual(connection.OpCode.close, received.opcode);
    try std.testing.expectEqual(@as(?connection.MaskingKey, null), received.masking_key);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xe7, 0xff }, received.payload);
    try std.testing.expectEqual(@as(usize, 0), server.writer.written);
    try std.testing.expect(!server.ws.is_closed());
}

test "WebSocket: one-byte close is rejected as ProtocolError before policy" {
    for ([_]bool{ true, false }) |auto_close| {
        var stream: EncodedStream(16) = .{};
        var payload = [_]u8{0x00};
        try append_masked(&stream, Frame.close_raw(&payload), .{ 0xde, 0xad, 0xbe, 0xef });

        var reader = stream.reader();
        var server: ConnectionRig(16, 1, 64, 8, 0, 8) = .{};
        try server.init(&reader, .{ .role = .server, .options = .{ .auto_close = auto_close } });

        try std.testing.expectError(error.ProtocolError, server.ws.read_frame());
        try std.testing.expectEqual(@as(usize, 0), server.writer.written);
        try std.testing.expect(!server.ws.is_closed());
    }
}

test "WebSocket: invalid outbound close payload is rejected by zslay" {
    var empty = std.Io.Reader.fixed("");
    var server: ConnectionRig(16, 2, 64, 8, 0, 32) = .{};
    try server.init(&empty, .{ .role = .server });

    var one_byte = [_]u8{0x03};
    try std.testing.expectError(error.ProtocolError, server.ws.write_frame(Frame.close_raw(&one_byte)));
    try std.testing.expectEqual(@as(usize, 0), server.writer.written);
    try std.testing.expect(!server.ws.is_closed());
    try std.testing.expectEqual(@as(usize, 0), server.ws.tx_pending());

    var bad_code = [_]u8{ 0x03, 0xe7 };
    try std.testing.expectError(error.ProtocolError, server.ws.write_frame(Frame.close_raw(&bad_code)));
    try std.testing.expectEqual(@as(usize, 0), server.writer.written);
    try std.testing.expect(!server.ws.is_closed());

    var close_storage: [2]u8 = undefined;
    try server.ws.write_frame(try Frame.close(1000, "", &close_storage));
    try std.testing.expect(server.ws.is_closed());
    try std.testing.expectEqual(@as(usize, 0), server.ws.tx_pending());
}

test "WebSocket: outbound close is terminal for data writes but repeated closes serialize" {
    var empty = std.Io.Reader.fixed("");
    var server: ConnectionRig(16, 2, 64, 8, 0, 64) = .{};
    try server.init(&empty, .{ .role = .server });

    var first_close_storage: [8]u8 = undefined;
    try server.ws.write_frame(try Frame.close(1000, "a", &first_close_storage));
    const after_first_close = server.writer.written;

    var text = [_]u8{'x'};
    try std.testing.expectError(error.ConnectionClosed, server.ws.write_frame(Frame.text(&text)));
    try std.testing.expectEqual(after_first_close, server.writer.written);
    try std.testing.expect(server.ws.is_closed());

    var second_close_storage: [8]u8 = undefined;
    try server.ws.write_frame(try Frame.close(1000, "b", &second_close_storage));
    try std.testing.expect(server.ws.is_closed());
    try std.testing.expectEqual(@as(usize, 0), server.ws.tx_pending());

    var index: usize = 0;
    const first = try next_wire_frame(server.bytes(), &index);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xe8, 'a' }, first.payload);
    const second = try next_wire_frame(server.bytes(), &index);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xe8, 'b' }, second.payload);
    try std.testing.expectEqual(server.writer.written, index);
}

test "WebSocket: non-close reads after a close write gate until a peer close" {
    var stream: EncodedStream(32) = .{};
    var text_payload = [_]u8{'x'};
    var close_storage: [8]u8 = undefined;
    try append_masked(&stream, Frame.text(&text_payload), .{ 0x01, 0x23, 0x45, 0x67 });
    try append_masked(&stream, try Frame.close(1000, "bye", &close_storage), .{ 0x89, 0xab, 0xcd, 0xef });

    var reader = stream.reader();
    var server: ConnectionRig(32, 2, 64, 8, 0, 32) = .{};
    try server.init(&reader, .{ .role = .server });

    var local_close_storage: [2]u8 = undefined;
    try server.ws.write_frame(try Frame.close(1000, "", &local_close_storage));
    const output_after_local_close = server.writer.written;

    try std.testing.expectError(error.ConnectionClosed, server.ws.read_frame());
    try std.testing.expectEqual(output_after_local_close, server.writer.written);

    const peer_close = try server.ws.read_frame();
    try std.testing.expectEqual(connection.OpCode.close, peer_close.opcode);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xe8, 'b', 'y', 'e' }, peer_close.payload);
    try std.testing.expectEqual(output_after_local_close, server.writer.written);
    try std.testing.expect(server.ws.is_closed());
}

test "WebSocket: invalid close after a close write returns InvalidCloseCode without a reply" {
    var stream: EncodedStream(16) = .{};
    var payload = [_]u8{ 0x03, 0xe7, 'b', 'a', 'd' };
    try append_masked(&stream, Frame.close_raw(&payload), .{ 0x02, 0x46, 0x8a, 0xce });

    var reader = stream.reader();
    var server: ConnectionRig(16, 2, 64, 8, 0, 32) = .{};
    try server.init(&reader, .{ .role = .server });

    var local_close_storage: [2]u8 = undefined;
    try server.ws.write_frame(try Frame.close(1000, "", &local_close_storage));
    const output_after_local_close = server.writer.written;

    try std.testing.expectError(error.InvalidCloseCode, server.ws.read_frame());
    try std.testing.expectEqual(output_after_local_close, server.writer.written);
    try std.testing.expect(server.ws.is_closed());
}

test "WebSocket: reset does not clear the closed flag" {
    var stream: EncodedStream(32) = .{};
    var close_storage: [2]u8 = undefined;
    var text_payload = [_]u8{'x'};
    try append_masked(&stream, try Frame.close(1000, "", &close_storage), .{ 0x13, 0x57, 0x9b, 0xdf });
    try append_masked(&stream, Frame.text(&text_payload), .{ 0x24, 0x68, 0xac, 0xe0 });

    var reader = stream.reader();
    var server: ConnectionRig(32, 2, 64, 8, 0, 32) = .{};
    try server.init(&reader, .{ .role = .server });

    _ = try server.ws.read_frame();
    try std.testing.expect(server.ws.is_closed());
    const output_after_close = server.writer.written;

    server.ws.reset();

    try std.testing.expect(server.ws.is_closed());
    try std.testing.expectError(error.ConnectionClosed, server.ws.read_frame());
    try std.testing.expectEqual(output_after_close, server.writer.written);
}

test "WebSocket: max_message_size is exclusive across short and extended lengths" {
    const seed: [connection.mask_seed_len]u8 = @splat(0x77);
    var payload: [65536]u8 = @splat(0x41);

    {
        var stream: EncodedStream(512) = .{};
        for ([_]usize{ 0, 1, 125, 126, 127 }) |len| {
            try stream.append(Frame.binary(payload[0..len]));
        }

        var reader = stream.reader();
        var client: ConnectionRig(127, 1, 64, 2, 0, 8) = .{};
        try client.init(&reader, .{
            .role = .client,
            .options = .{ .max_message_size = 128 },
            .mask_keys = connection.MaskKeySource.from_seed(seed),
        });

        for ([_]usize{ 0, 1, 125, 126, 127 }) |len| {
            const received = try client.ws.read_frame();
            try std.testing.expectEqual(len, received.payload.len);
            try std.testing.expectEqualSlices(u8, payload[0..len], received.payload);
        }
        try std.testing.expect(client.ws.is_at_wire_boundary());
    }

    {
        var stream: EncodedStream(256) = .{};
        try stream.append(Frame.binary(payload[0..128]));

        var reader = stream.reader();
        var client: ConnectionRig(128, 1, 64, 2, 0, 8) = .{};
        try client.init(&reader, .{
            .role = .client,
            .options = .{ .max_message_size = 128 },
            .mask_keys = connection.MaskKeySource.from_seed(seed),
        });

        try std.testing.expectError(error.FrameTooLarge, client.ws.read_frame());
    }

    {
        var stream: EncodedStream(65545) = .{};
        try stream.append(Frame.binary(payload[0..65535]));

        var reader = stream.reader();
        var client: ConnectionRig(65535, 1, 64, 2, 0, 8) = .{};
        try client.init(&reader, .{
            .role = .client,
            .options = .{ .max_message_size = 65536 },
            .mask_keys = connection.MaskKeySource.from_seed(seed),
        });

        const received = try client.ws.read_frame();
        try std.testing.expectEqual(@as(usize, 65535), received.payload.len);
        try std.testing.expectEqual(@as(u8, 0x41), received.payload[0]);
        try std.testing.expectEqual(@as(u8, 0x41), received.payload[65534]);
    }

    {
        var stream: EncodedStream(65546) = .{};
        try stream.append(Frame.binary(&payload));

        var reader = stream.reader();
        var client: ConnectionRig(16, 1, 64, 2, 0, 8) = .{};
        try client.init(&reader, .{
            .role = .client,
            .options = .{ .max_message_size = 65536 },
            .mask_keys = connection.MaskKeySource.from_seed(seed),
        });

        try std.testing.expectError(error.FrameTooLarge, client.ws.read_frame());
    }
}

test "WebSocket: zero max_message_size rejects before reading and does not latch" {
    var stream: EncodedStream(16) = .{};
    var payload = [_]u8{ 'o', 'k' };
    try stream.append(Frame.text(&payload));

    var reader = stream.reader();
    var client: ConnectionRig(16, 1, 64, 2, 0, 8) = .{};
    try client.init(&reader, .{
        .role = .client,
        .options = .{ .max_message_size = 0 },
        .mask_keys = connection.MaskKeySource.from_seed(@splat(0x31)),
    });

    try std.testing.expectError(error.FrameTooLarge, client.ws.read_frame());
    try std.testing.expectEqual(@as(usize, 0), reader.seek);
    try std.testing.expectEqual(@as(usize, 0), client.ws.max_message_size());

    try std.testing.expectError(error.FrameTooLarge, client.ws.read_frame());
    try std.testing.expectEqual(@as(usize, 0), reader.seek);

    client.ws.set_max_message_size(8);
    try std.testing.expectEqual(@as(usize, 8), client.ws.max_message_size());

    const received = try client.ws.read_frame();
    try std.testing.expectEqualStrings("ok", received.payload);
}

test "WebSocket: one-byte limit accepts an empty frame and rejects one byte" {
    {
        var stream: EncodedStream(16) = .{};
        var empty: [0]u8 = .{};
        try stream.append(Frame.text(&empty));

        var reader = stream.reader();
        var client: ConnectionRig(16, 1, 64, 2, 0, 8) = .{};
        try client.init(&reader, .{
            .role = .client,
            .options = .{ .max_message_size = 1 },
            .mask_keys = connection.MaskKeySource.from_seed(@splat(0x71)),
        });

        const received = try client.ws.read_frame();
        try std.testing.expectEqual(connection.OpCode.text, received.opcode);
        try std.testing.expectEqual(@as(usize, 0), received.payload.len);
    }

    {
        var stream: EncodedStream(16) = .{};
        var payload = [_]u8{'x'};
        try stream.append(Frame.text(&payload));

        var reader = stream.reader();
        var client: ConnectionRig(16, 1, 64, 2, 0, 8) = .{};
        try client.init(&reader, .{
            .role = .client,
            .options = .{ .max_message_size = 1 },
            .mask_keys = connection.MaskKeySource.from_seed(@splat(0x72)),
        });

        try std.testing.expectError(error.FrameTooLarge, client.ws.read_frame());
    }
}

test "WebSocket: frame larger than frame_buffer returns BufferTooShort and latches" {
    var stream: EncodedStream(32) = .{};
    var payload = [_]u8{ 'a', 'b', 'c', 'd', 'e' };
    try append_masked(&stream, Frame.binary(&payload), .{ 0x0f, 0x1e, 0x2d, 0x3c });

    var reader = stream.reader();
    var server: ConnectionRig(4, 1, 64, 8, 0, 8) = .{};
    try server.init(&reader, .{ .role = .server });

    try std.testing.expectError(error.BufferTooShort, server.ws.read_frame());
    try std.testing.expectEqual(@as(usize, 6), reader.seek);
    try std.testing.expect(!server.ws.is_at_wire_boundary());

    try std.testing.expectError(error.BufferTooShort, server.ws.read_frame());
    try std.testing.expectEqual(@as(usize, 6), reader.seek);
}

test "WebSocket: cumulative fragmented message over max_message_len returns FrameTooLarge" {
    var stream: EncodedStream(32) = .{};
    var first_payload = [_]u8{ 'a', 'b', 'c', 'd', 'e' };
    var second_payload = [_]u8{ 'f', 'g', 'h', 'i', 'j' };
    try append_masked(&stream, Frame.init(false, .binary, null, &first_payload), .{ 0x11, 0x32, 0x53, 0x74 });
    try append_masked(&stream, Frame.init(true, .continuation, null, &second_payload), .{ 0x85, 0xa6, 0xc7, 0xe8 });

    var reader = stream.reader();
    var server: ConnectionRig(16, 1, 64, 8, 0, 8) = .{};
    try server.init(&reader, .{ .role = .server, .options = .{ .max_message_size = 9 } });

    const first = try server.ws.read_frame();
    try std.testing.expectEqual(connection.OpCode.binary, first.opcode);
    try std.testing.expect(!first.fin);
    try std.testing.expectEqualStrings("abcde", first.payload);

    try std.testing.expectError(error.FrameTooLarge, server.ws.read_frame());
}

test "WebSocket: set_max_message_size updates the read gate and zslay limits" {
    var stream: EncodedStream(32) = .{};
    var first_payload = [_]u8{ 'a', 'b', 'c' };
    var second_payload = [_]u8{ 'd', 'e', 'f', 'g' };
    try stream.append(Frame.text(&first_payload));
    try stream.append(Frame.text(&second_payload));

    var reader = stream.reader();
    var client: ConnectionRig(16, 1, 64, 2, 0, 8) = .{};
    try client.init(&reader, .{
        .role = .client,
        .options = .{ .max_message_size = 4 },
        .mask_keys = connection.MaskKeySource.from_seed(@splat(0x44)),
    });

    const first = try client.ws.read_frame();
    try std.testing.expectEqualStrings("abc", first.payload);

    client.ws.set_max_message_size(0);
    try std.testing.expectEqual(@as(usize, 0), client.ws.max_message_size());
    const seek_before_zero = reader.seek;
    try std.testing.expectError(error.FrameTooLarge, client.ws.read_frame());
    try std.testing.expectEqual(seek_before_zero, reader.seek);

    client.ws.set_max_message_size(8);
    try std.testing.expectEqual(@as(usize, 8), client.ws.max_message_size());
    const second = try client.ws.read_frame();
    try std.testing.expectEqualStrings("defg", second.payload);

    {
        var boundary_stream: EncodedStream(16) = .{};
        var boundary_payload = [_]u8{ 'd', 'e', 'f', 'g' };
        try boundary_stream.append(Frame.text(&boundary_payload));

        var boundary_reader = boundary_stream.reader();
        var boundary: ConnectionRig(16, 1, 64, 2, 0, 8) = .{};
        try boundary.init(&boundary_reader, .{
            .role = .client,
            .options = .{ .max_message_size = 4 },
            .mask_keys = connection.MaskKeySource.from_seed(@splat(0x45)),
        });

        try std.testing.expectError(error.FrameTooLarge, boundary.ws.read_frame());
    }
}

test "WebSocket: lowering max_message_size mid-fragment clamps the cumulative limit" {
    {
        var stream: EncodedStream(32) = .{};
        var first_payload = [_]u8{ 'a', 'b', 'c', 'd', 'e' };
        var second_payload = [_]u8{'f'};
        try append_masked(&stream, Frame.init(false, .text, null, &first_payload), .{ 0x11, 0x22, 0x33, 0x44 });
        try append_masked(
            &stream,
            Frame.init(true, .continuation, null, &second_payload),
            .{ 0x55, 0x66, 0x77, 0x88 },
        );

        var reader = stream.reader();
        var server: ConnectionRig(16, 1, 64, 8, 0, 8) = .{};
        try server.init(&reader, .{ .role = .server, .options = .{ .max_message_size = 64 } });

        const first = try server.ws.read_frame();
        try std.testing.expect(!first.fin);
        try std.testing.expectEqualStrings("abcde", first.payload);

        server.ws.set_max_message_size(4);
        // The exclusive 4-byte limit derives an inclusive 3, but the accepted
        // five-byte fragment must stay valid until its message completes.
        try std.testing.expectEqual(@as(u64, 5), server.ws.conn.max_message_len);
        try std.testing.expectError(error.FrameTooLarge, server.ws.read_frame());
    }

    {
        var empty = std.Io.Reader.fixed("");
        var server: ConnectionRig(16, 1, 64, 8, 0, 16) = .{};
        try server.init(&empty, .{ .role = .server, .options = .{ .max_message_size = 64 } });

        var first_payload = [_]u8{ 'a', 'b', 'c', 'd', 'e' };
        var second_payload = [_]u8{'f'};
        try server.ws.write_frame(Frame.init(false, .text, null, &first_payload));
        try std.testing.expectEqual(connection.OpCode.text, server.ws.conn.tx_fragment.opcode.?);
        try std.testing.expectEqual(@as(u64, 5), server.ws.conn.tx_fragment.message_len);

        server.ws.set_max_message_size(4);
        try std.testing.expectEqual(@as(u64, 5), server.ws.conn.max_message_len);
        try std.testing.expectError(
            error.FrameTooLarge,
            server.ws.write_frame(Frame.init(true, .continuation, null, &second_payload)),
        );
        try std.testing.expectEqual(@as(usize, 0), server.ws.tx_pending());
        try std.testing.expect(!server.ws.is_closed());
    }
}

test "WebSocket: init requires a write buffer longer than the maximum header" {
    var empty = std.Io.Reader.fixed("");
    var out: [8]u8 = undefined;
    var writer = RecordingVecWriter.init(&out);
    var frame_buffer: [8]u8 = undefined;
    var tx_nodes: [1]zslay.FrameNode = undefined;
    var close_buffer: [2]u8 = undefined;

    var too_small: [zslay.MaxFrameHeaderLen]u8 = undefined;
    try std.testing.expectError(error.InvalidLength, connection.WebSocket.init(
        &empty,
        &writer.writer,
        .{
            .frame_buffer = &frame_buffer,
            .tx_nodes = &tx_nodes,
            .write_buffer = &too_small,
            .close_buffer = &close_buffer,
        },
        .{ .role = .server },
    ));

    var minimum: [zslay.MaxFrameHeaderLen + 1]u8 = undefined;
    const ws = try connection.WebSocket.init(
        &empty,
        &writer.writer,
        .{
            .frame_buffer = &frame_buffer,
            .tx_nodes = &tx_nodes,
            .write_buffer = &minimum,
            .close_buffer = &close_buffer,
        },
        .{ .role = .server },
    );
    try std.testing.expectEqual(connection.Role.server, ws.role());
}

test "WebSocket: init rejects a close buffer smaller than two bytes" {
    var empty = std.Io.Reader.fixed("");
    var out: [8]u8 = undefined;
    var writer = RecordingVecWriter.init(&out);
    var frame_buffer: [8]u8 = undefined;
    var tx_nodes: [1]zslay.FrameNode = undefined;
    var write_buffer: [zslay.MaxFrameHeaderLen + 1]u8 = undefined;

    var too_small: [1]u8 = undefined;
    try std.testing.expectError(error.InvalidLength, connection.WebSocket.init(
        &empty,
        &writer.writer,
        .{
            .frame_buffer = &frame_buffer,
            .tx_nodes = &tx_nodes,
            .write_buffer = &write_buffer,
            .close_buffer = &too_small,
        },
        .{ .role = .server },
    ));

    var minimum: [2]u8 = undefined;
    const ws = try connection.WebSocket.init(
        &empty,
        &writer.writer,
        .{
            .frame_buffer = &frame_buffer,
            .tx_nodes = &tx_nodes,
            .write_buffer = &write_buffer,
            .close_buffer = &minimum,
        },
        .{ .role = .server },
    );
    try std.testing.expectEqual(connection.Role.server, ws.role());
}

test "WebSocket: init rejects overlapping caller buffers" {
    var empty = std.Io.Reader.fixed("");
    var out: [8]u8 = undefined;
    var writer = RecordingVecWriter.init(&out);
    var frame_buffer: [8]u8 = undefined;
    var tx_nodes: [2]zslay.FrameNode = undefined;
    var write_buffer: [zslay.MaxFrameHeaderLen + 1]u8 = undefined;
    var close_buffer: [2]u8 = undefined;

    // The frame buffer aliases the transmit-node storage.
    try std.testing.expectError(error.InvalidLength, connection.WebSocket.init(
        &empty,
        &writer.writer,
        .{
            .frame_buffer = std.mem.sliceAsBytes(&tx_nodes),
            .tx_nodes = &tx_nodes,
            .write_buffer = &write_buffer,
            .close_buffer = &close_buffer,
        },
        .{ .role = .server },
    ));

    // Mask scratch aliases the copied-write composition buffer.
    try std.testing.expectError(error.InvalidLength, connection.WebSocket.init(
        &empty,
        &writer.writer,
        .{
            .frame_buffer = &frame_buffer,
            .tx_nodes = &tx_nodes,
            .write_buffer = &write_buffer,
            .close_buffer = &close_buffer,
            .mask_scratch = write_buffer[0..4],
        },
        .{ .role = .server },
    ));
}

test "WebSocket: tx nodes are required for automatic replies" {
    var empty = std.Io.Reader.fixed("");
    var out: [16]u8 = undefined;
    var writer = RecordingVecWriter.init(&out);
    var frame_buffer: [8]u8 = undefined;
    var no_nodes: [0]zslay.FrameNode = .{};
    var write_buffer: [zslay.MaxFrameHeaderLen + 1]u8 = undefined;
    var close_buffer: [2]u8 = undefined;
    const storage: connection.Storage = .{
        .frame_buffer = &frame_buffer,
        .tx_nodes = &no_nodes,
        .write_buffer = &write_buffer,
        .close_buffer = &close_buffer,
    };

    try std.testing.expectError(error.InvalidLength, connection.WebSocket.init(
        &empty,
        &writer.writer,
        storage,
        .{ .role = .server },
    ));

    var ws = try connection.WebSocket.init(
        &empty,
        &writer.writer,
        storage,
        .{ .role = .server, .options = .{ .auto_pong = false, .auto_close = false } },
    );

    var payload = [_]u8{'x'};
    try std.testing.expectError(error.QueueFull, ws.write_frame(Frame.text(&payload)));
    try std.testing.expectEqual(@as(usize, 0), writer.written);
    try std.testing.expect(!ws.is_closed());
    try std.testing.expectEqual(@as(usize, 0), ws.tx_pending());
}

test "WebSocket: zero max_message_size also bounds outbound control payloads" {
    var empty = std.Io.Reader.fixed("");
    var server: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
    try server.init(&empty, .{ .role = .server, .options = .{ .max_message_size = 0 } });

    var close_storage: [2]u8 = undefined;
    try std.testing.expectError(
        error.FrameTooLarge,
        server.ws.write_frame(try Frame.close(1000, "", &close_storage)),
    );
    try std.testing.expectEqual(@as(usize, 0), server.writer.written);
    try std.testing.expect(!server.ws.is_closed());

    var empty_payload: [0]u8 = .{};
    try server.ws.write_frame(Frame.close_raw(&empty_payload));
    try std.testing.expect(server.ws.is_closed());

    var index: usize = 0;
    const close = try next_wire_frame(server.bytes(), &index);
    try std.testing.expectEqual(@as(usize, 0), close.payload.len);
    try std.testing.expectEqual(server.writer.written, index);
}

test "WebSocket: write rejects storage overlaps but allows frame_buffer payloads" {
    var empty = std.Io.Reader.fixed("");
    var server: ConnectionRig(16, 2, 64, 8, 8, 32) = .{};
    try server.init(&empty, .{ .role = .server });

    try std.testing.expectError(error.InvalidLength, server.ws.write_frame(Frame.binary(server.write_buffer[0..4])));
    try std.testing.expectError(error.InvalidLength, server.ws.write_frame(Frame.binary(server.close_buffer[0..2])));
    try std.testing.expectError(error.InvalidLength, server.ws.write_frame(Frame.binary(server.mask_scratch[0..4])));

    const tx_bytes = std.mem.sliceAsBytes(&server.tx_nodes);
    try std.testing.expectError(error.InvalidLength, server.ws.write_frame(Frame.binary(tx_bytes[0..4])));

    try std.testing.expectEqual(@as(usize, 0), server.writer.written);
    try std.testing.expect(!server.ws.is_closed());
    try std.testing.expectEqual(@as(usize, 0), server.ws.tx_pending());

    // A delivered frame may be echoed from frame_buffer; that region is not
    // connection-owned scratch.
    @memcpy(server.frame_buffer[0..2], "hi");
    try server.ws.write_frame(Frame.text(server.frame_buffer[0..2]));
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 0x02, 'h', 'i' }, server.bytes());
    try std.testing.expectEqual(@as(usize, 0), server.ws.tx_pending());
}

test "WebSocket: max_message_size above zslay MaxPayloadLen is clamped" {
    var empty = std.Io.Reader.fixed("");
    var server: ConnectionRig(16, 1, 64, 8, 0, 8) = .{};
    try server.init(&empty, .{
        .role = .server,
        .options = .{ .max_message_size = std.math.maxInt(usize) },
    });

    const clamped_payload_len = std.math.cast(usize, zslay.MaxPayloadLen) orelse std.math.maxInt(usize);
    const expected = @min(std.math.maxInt(usize), clamped_payload_len);
    try std.testing.expectEqual(expected, server.ws.max_message_size());
}

test "WebSocket: set_max_message_size clamps above zslay MaxPayloadLen" {
    const seed: [connection.mask_seed_len]u8 = @splat(0x46);
    var stream: EncodedStream(16) = .{};
    var payload = [_]u8{ 'o', 'k' };
    try stream.append(Frame.text(&payload));

    var reader = stream.reader();
    var client: ConnectionRig(16, 1, 64, 2, 0, 8) = .{};
    try client.init(&reader, .{
        .role = .client,
        .options = .{ .max_message_size = 8 },
        .mask_keys = connection.MaskKeySource.from_seed(seed),
    });

    client.ws.set_max_message_size(std.math.maxInt(usize));

    const clamped = @min(std.math.maxInt(usize), @as(usize, zslay.MaxPayloadLen));
    try std.testing.expectEqual(clamped, client.ws.max_message_size());

    const received = try client.ws.read_frame();
    try std.testing.expectEqual(connection.OpCode.text, received.opcode);
    try std.testing.expectEqualStrings("ok", received.payload);
}

test "WebSocket: non-FIN text fragments are delivered raw across a split code point" {
    var stream: EncodedStream(64) = .{};
    var first = [_]u8{ 0x41, 0xc2 };
    var second = [_]u8{0xa2};
    var third = [_]u8{0xff};
    var fourth = [_]u8{0xff};
    try append_masked(&stream, Frame.init(false, .text, null, &first), .{ 0x01, 0x11, 0x21, 0x31 });
    try append_masked(&stream, Frame.init(true, .continuation, null, &second), .{ 0x02, 0x12, 0x22, 0x32 });
    try append_masked(&stream, Frame.init(false, .text, null, &third), .{ 0x03, 0x13, 0x23, 0x33 });
    try append_masked(&stream, Frame.init(true, .continuation, null, &fourth), .{ 0x04, 0x14, 0x24, 0x34 });

    var reader = stream.reader();
    var server: ConnectionRig(16, 1, 64, 8, 0, 8) = .{};
    try server.init(&reader, .{ .role = .server });

    const start = try server.ws.read_frame();
    try std.testing.expectEqual(connection.OpCode.text, start.opcode);
    try std.testing.expect(!start.fin);
    try std.testing.expectEqualSlices(u8, &.{ 0x41, 0xc2 }, start.payload);

    const split_tail = try server.ws.read_frame();
    try std.testing.expectEqual(connection.OpCode.continuation, split_tail.opcode);
    try std.testing.expect(split_tail.fin);
    try std.testing.expectEqualSlices(u8, &.{0xa2}, split_tail.payload);

    const invalid_start = try server.ws.read_frame();
    try std.testing.expectEqual(connection.OpCode.text, invalid_start.opcode);
    try std.testing.expect(!invalid_start.fin);
    try std.testing.expectEqualSlices(u8, &.{0xff}, invalid_start.payload);

    const invalid_tail = try server.ws.read_frame();
    try std.testing.expectEqual(connection.OpCode.continuation, invalid_tail.opcode);
    try std.testing.expect(invalid_tail.fin);
    try std.testing.expectEqualSlices(u8, &.{0xff}, invalid_tail.payload);

    try std.testing.expectEqual(@as(usize, 0), server.writer.written);
    try std.testing.expect(server.ws.is_at_wire_boundary());
}

test "WebSocket: invalid FIN text latches InvalidUTF8 until reset at a frame boundary" {
    var stream: EncodedStream(32) = .{};
    var invalid = [_]u8{0xff};
    var valid = [_]u8{ 'o', 'k' };
    try append_masked(&stream, Frame.text(&invalid), .{ 0x05, 0x15, 0x25, 0x35 });
    try append_masked(&stream, Frame.text(&valid), .{ 0x06, 0x16, 0x26, 0x36 });

    var reader = stream.reader();
    var server: ConnectionRig(16, 1, 64, 8, 0, 8) = .{};
    try server.init(&reader, .{ .role = .server });

    try std.testing.expectError(error.InvalidUTF8, server.ws.read_frame());
    try std.testing.expect(server.ws.is_at_wire_boundary());
    const seek_after_failure = reader.seek;

    try std.testing.expectError(error.InvalidUTF8, server.ws.read_frame());
    try std.testing.expectEqual(seek_after_failure, reader.seek);

    server.ws.reset();
    const received = try server.ws.read_frame();
    try std.testing.expectEqualStrings("ok", received.payload);
    try std.testing.expect(server.ws.is_at_wire_boundary());
}

test "WebSocket: truncated header returns UnexpectedEOF and latches" {
    var wire = [_]u8{0x81};
    var reader = std.Io.Reader.fixed(&wire);
    var server: ConnectionRig(16, 1, 64, 8, 0, 8) = .{};
    try server.init(&reader, .{ .role = .server });

    try std.testing.expectError(error.UnexpectedEOF, server.ws.read_frame());
    try std.testing.expectEqual(@as(usize, 1), reader.seek);

    try std.testing.expectError(error.UnexpectedEOF, server.ws.read_frame());
    try std.testing.expectEqual(@as(usize, 1), reader.seek);
}

test "WebSocket: a partial header is not a wire boundary" {
    {
        var wire = [_]u8{0x81};
        var reader = std.Io.Reader.fixed(&wire);
        var server: ConnectionRig(16, 1, 64, 8, 0, 8) = .{};
        try server.init(&reader, .{ .role = .server });

        try std.testing.expectError(error.UnexpectedEOF, server.ws.read_frame());
        try std.testing.expectEqual(@as(usize, 1), reader.seek);
        try std.testing.expect(!server.ws.is_at_wire_boundary());

        try std.testing.expectError(error.UnexpectedEOF, server.ws.read_frame());
        try std.testing.expectEqual(@as(usize, 1), reader.seek);
        try std.testing.expect(!server.ws.is_at_wire_boundary());
    }

    {
        var reader = std.Io.Reader.fixed("");
        var server: ConnectionRig(16, 1, 64, 8, 0, 8) = .{};
        try server.init(&reader, .{ .role = .server });

        try std.testing.expectError(error.UnexpectedEOF, server.ws.read_frame());
        try std.testing.expectEqual(@as(usize, 0), reader.seek);
        try std.testing.expect(server.ws.is_at_wire_boundary());

        try std.testing.expectError(error.UnexpectedEOF, server.ws.read_frame());
        try std.testing.expectEqual(@as(usize, 0), reader.seek);
        try std.testing.expect(server.ws.is_at_wire_boundary());
    }
}

test "WebSocket: truncated payload returns UnexpectedEOF and latches" {
    var wire = [_]u8{ 0x81, 0x05, 'a', 'b', 'c' };
    var reader = std.Io.Reader.fixed(&wire);
    var client: ConnectionRig(16, 1, 64, 2, 0, 8) = .{};
    try client.init(&reader, .{
        .role = .client,
        .mask_keys = connection.MaskKeySource.from_seed(@splat(0x66)),
    });

    try std.testing.expectError(error.UnexpectedEOF, client.ws.read_frame());
    try std.testing.expectEqual(@as(usize, 5), reader.seek);
    try std.testing.expect(!client.ws.is_at_wire_boundary());

    try std.testing.expectError(error.UnexpectedEOF, client.ws.read_frame());
    try std.testing.expectEqual(@as(usize, 5), reader.seek);
    try std.testing.expect(!client.ws.is_at_wire_boundary());
}

test "WebSocket: a failed reader returns IoError and latches" {
    var reader = std.Io.Reader{
        .vtable = &.{ .stream = read_failed_stream },
        .buffer = &.{},
        .seek = 0,
        .end = 0,
    };
    var server: ConnectionRig(16, 1, 64, 8, 0, 8) = .{};
    try server.init(&reader, .{ .role = .server });

    try std.testing.expectError(error.IoError, server.ws.read_frame());
    try std.testing.expectError(error.IoError, server.ws.read_frame());

    server.ws.reset();
    try std.testing.expectError(error.IoError, server.ws.read_frame());
}

test "WebSocket: vectored writes above the threshold use two iovecs" {
    var empty = std.Io.Reader.fixed("");
    var server: ConnectionRig(16, 2, 64, 8, 0, 1100) = .{};
    try server.init(&empty, .{ .role = .server, .options = .{ .writev_threshold = 1024 } });

    var payload: [1025]u8 = @splat(0x5a);
    try server.ws.write_frame(Frame.binary(&payload));

    try std.testing.expectEqual(@as(usize, 1), server.writer.drain_calls);
    try std.testing.expectEqual(@as(usize, 2), server.writer.max_iovecs);

    var index: usize = 0;
    const wire_frame = try next_wire_frame(server.bytes(), &index);
    try std.testing.expectEqual(@as(usize, 1025), wire_frame.payload.len);
    try std.testing.expectEqualSlices(u8, &payload, wire_frame.payload);
    try std.testing.expectEqual(server.writer.written, index);
}

test "WebSocket: payload equal to the threshold uses the copied path" {
    var empty = std.Io.Reader.fixed("");
    var server: ConnectionRig(16, 2, 1100, 8, 0, 1100) = .{};
    try server.init(&empty, .{ .role = .server, .options = .{ .writev_threshold = 1024 } });

    var payload: [1024]u8 = @splat(0x6b);
    try server.ws.write_frame(Frame.binary(&payload));

    try std.testing.expectEqual(@as(usize, 1), server.writer.drain_calls);
    try std.testing.expectEqual(@as(usize, 1), server.writer.max_iovecs);

    var index: usize = 0;
    const wire_frame = try next_wire_frame(server.bytes(), &index);
    try std.testing.expectEqual(@as(usize, 1024), wire_frame.payload.len);
    try std.testing.expectEqualSlices(u8, &payload, wire_frame.payload);
    try std.testing.expectEqual(server.writer.written, index);
}

test "WebSocket: set_writev false composes header and payload through the write buffer" {
    var empty = std.Io.Reader.fixed("");
    var server: ConnectionRig(16, 2, 64, 8, 0, 2010) = .{};
    try server.init(&empty, .{ .role = .server });
    server.ws.set_writev(false);

    var payload: [2000]u8 = @splat(0x7c);
    var expected: [2010]u8 = undefined;
    const expected_bytes = try Frame.binary(&payload).write(&expected);

    try server.ws.write_frame(Frame.binary(&payload));

    try std.testing.expect(server.writer.drain_calls > 1);
    try std.testing.expectEqual(@as(usize, 1), server.writer.max_iovecs);
    try std.testing.expectEqualSlices(u8, expected_bytes, server.bytes());
    try std.testing.expectEqual(@as(usize, 0), server.ws.tx_pending());
}

test "WebSocket: masked vectored writes chunk through scratch and preserve offsets" {
    const seed: [connection.mask_seed_len]u8 = @splat(0x19);
    var empty = std.Io.Reader.fixed("");
    var client: ConnectionRig(16, 2, 64, 8, 4, 64) = .{};
    try client.init(&empty, .{
        .role = .client,
        .mask_keys = connection.MaskKeySource.from_seed(seed),
    });
    client.ws.set_writev_threshold(0);

    var payload = [_]u8{ 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j' };
    try client.ws.write_frame(Frame.text(&payload));

    try std.testing.expectEqual(@as(usize, 3), client.writer.drain_calls);
    try std.testing.expectEqual(@as(usize, 2), client.writer.max_iovecs);
    try std.testing.expectEqual(@as(usize, 16), client.writer.written);

    var index: usize = 0;
    const wire_frame = try next_wire_frame(client.bytes(), &index);
    try std.testing.expect(wire_frame.header.header.mask);
    const key = wire_frame.header.masking_key.?;
    try std.testing.expectEqual(@as(usize, 10), wire_frame.payload.len);

    var plaintext: [10]u8 = undefined;
    @memcpy(&plaintext, wire_frame.payload);
    zslay.mask(&plaintext, key, 0);
    try std.testing.expectEqualStrings("abcdefghij", &plaintext);
}

test "WebSocket: empty mask scratch falls back to the copied path" {
    const seed: [connection.mask_seed_len]u8 = @splat(0x2b);
    var empty = std.Io.Reader.fixed("");
    var client: ConnectionRig(16, 2, 64, 8, 0, 64) = .{};
    try client.init(&empty, .{
        .role = .client,
        .mask_keys = connection.MaskKeySource.from_seed(seed),
    });
    client.ws.set_writev_threshold(0);

    var payload = [_]u8{ 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j' };
    try client.ws.write_frame(Frame.text(&payload));

    try std.testing.expectEqual(@as(usize, 1), client.writer.drain_calls);
    try std.testing.expectEqual(@as(usize, 1), client.writer.max_iovecs);

    var index: usize = 0;
    const wire_frame = try next_wire_frame(client.bytes(), &index);
    const key = wire_frame.header.masking_key.?;
    var plaintext: [10]u8 = undefined;
    @memcpy(&plaintext, wire_frame.payload);
    zslay.mask(&plaintext, key, 0);
    try std.testing.expectEqualStrings("abcdefghij", &plaintext);
}

test "WebSocket: empty payload writes a header-only frame" {
    var empty = std.Io.Reader.fixed("");
    var server: ConnectionRig(16, 1, 64, 8, 0, 16) = .{};
    try server.init(&empty, .{ .role = .server });

    var payload: [0]u8 = .{};
    try server.ws.write_frame(Frame.text(&payload));

    try std.testing.expectEqual(@as(usize, 2), server.writer.written);
    try std.testing.expectEqual(@as(usize, 1), server.writer.drain_calls);
    try std.testing.expectEqual(@as(usize, 1), server.writer.max_iovecs);
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 0x00 }, server.bytes());
    try std.testing.expectEqual(@as(usize, 0), server.ws.tx_pending());
}

test "WebSocket: a latched write failure blocks reads" {
    const seed: [connection.mask_seed_len]u8 = @splat(0x5d);
    var stream: EncodedStream(16) = .{};
    var input = [_]u8{ 'o', 'k' };
    try stream.append(Frame.text(&input));

    var reader = stream.reader();
    var client: ConnectionRig(16, 2, 64, 2, 0, 16) = .{};
    try client.init(&reader, .{
        .role = .client,
        .mask_keys = connection.MaskKeySource.from_seed(seed),
    });
    client.writer.fail_after = 0;

    var payload = [_]u8{ 'h', 'i' };
    try std.testing.expectError(error.IoError, client.ws.write_frame(Frame.text(&payload)));
    try std.testing.expectEqual(@as(usize, 0), client.writer.written);
    try std.testing.expectEqual(@as(usize, 1), client.ws.tx_pending());

    const drain_calls_after_failure = client.writer.drain_calls;
    try std.testing.expectError(error.IoError, client.ws.write_frame(Frame.text(&payload)));
    try std.testing.expectEqual(drain_calls_after_failure, client.writer.drain_calls);

    try std.testing.expectError(error.IoError, client.ws.read_frame());
    try std.testing.expectEqual(@as(usize, 0), reader.seek);
}

test "WebSocket: flush reports a buffered writer failure and latches" {
    var empty = std.Io.Reader.fixed("");
    var frame_buffer: [16]u8 = undefined;
    var tx_nodes: [1]zslay.FrameNode = undefined;
    var write_buffer: [64]u8 = undefined;
    var close_buffer: [8]u8 = undefined;
    var out: [64]u8 = undefined;
    var flush_buffer: [64]u8 = undefined;
    var writer = FlushFailWriter.init(&out, &flush_buffer);

    var ws = try connection.WebSocket.init(&empty, &writer.writer, .{
        .frame_buffer = &frame_buffer,
        .tx_nodes = &tx_nodes,
        .write_buffer = &write_buffer,
        .close_buffer = &close_buffer,
    }, .{ .role = .server });

    var payload = [_]u8{ 'h', 'i' };
    try ws.write_frame(Frame.text(&payload));
    try std.testing.expectEqual(@as(usize, 0), writer.written);
    try std.testing.expectEqual(@as(usize, 4), writer.writer.end);

    try std.testing.expectError(error.IoError, ws.flush());
    try std.testing.expectEqual(@as(usize, 1), writer.flush_calls);

    try std.testing.expectError(error.IoError, ws.flush());
    try std.testing.expectEqual(@as(usize, 1), writer.flush_calls);

    var next_payload = [_]u8{'x'};
    try std.testing.expectError(error.IoError, ws.write_frame(Frame.text(&next_payload)));
}

test "WebSocket: automatic pong is flushed before read_frame returns" {
    var stream: EncodedStream(32) = .{};
    var ping_payload = [_]u8{'p'};
    var text_payload = [_]u8{ 'o', 'k' };
    try append_masked(&stream, Frame.ping(&ping_payload), .{ 0x01, 0x23, 0x45, 0x67 });
    try append_masked(&stream, Frame.text(&text_payload), .{ 0x89, 0xab, 0xcd, 0xef });

    var reader = stream.reader();
    var frame_buffer: [16]u8 = undefined;
    var tx_nodes: [1]zslay.FrameNode = undefined;
    var write_buffer: [64]u8 = undefined;
    var close_buffer: [8]u8 = undefined;
    var out: [16]u8 = undefined;
    var flush_buffer: [16]u8 = undefined;
    var writer = FlushFailWriter.init(&out, &flush_buffer);
    writer.fail_flush = false;

    var ws = try connection.WebSocket.init(&reader, &writer.writer, .{
        .frame_buffer = &frame_buffer,
        .tx_nodes = &tx_nodes,
        .write_buffer = &write_buffer,
        .close_buffer = &close_buffer,
    }, .{ .role = .server });

    const received = try ws.read_frame();
    try std.testing.expectEqual(connection.OpCode.text, received.opcode);
    try std.testing.expectEqualStrings("ok", received.payload);

    // The obligation flush moved the buffered pong to the recording sink
    // before read_frame returned.
    try std.testing.expectEqual(@as(usize, 1), writer.flush_calls);
    try std.testing.expectEqual(@as(usize, 0), writer.writer.end);
    try std.testing.expectEqual(@as(usize, 3), writer.written);

    var index: usize = 0;
    const pong = try next_wire_frame(out[0..writer.written], &index);
    try std.testing.expectEqual(connection.OpCode.pong, connection.OpCode.from_wire(pong.header.header.opcode).?);
    try std.testing.expectEqualStrings("p", pong.payload);
    try std.testing.expectEqual(writer.written, index);
}

test "WebSocket: failed automatic reply flush latches write failure" {
    var stream: EncodedStream(16) = .{};
    var ping_payload = [_]u8{'p'};
    var text_payload = [_]u8{ 'o', 'k' };
    try append_masked(&stream, Frame.ping(&ping_payload), .{ 0x01, 0x23, 0x45, 0x67 });
    try append_masked(&stream, Frame.text(&text_payload), .{ 0x89, 0xab, 0xcd, 0xef });

    var reader = stream.reader();
    var frame_buffer: [16]u8 = undefined;
    var tx_nodes: [1]zslay.FrameNode = undefined;
    var write_buffer: [64]u8 = undefined;
    var close_buffer: [8]u8 = undefined;
    var out: [16]u8 = undefined;
    var flush_buffer: [16]u8 = undefined;
    var writer = FlushFailWriter.init(&out, &flush_buffer);

    var ws = try connection.WebSocket.init(&reader, &writer.writer, .{
        .frame_buffer = &frame_buffer,
        .tx_nodes = &tx_nodes,
        .write_buffer = &write_buffer,
        .close_buffer = &close_buffer,
    }, .{ .role = .server });

    try std.testing.expectError(error.IoError, ws.read_frame());
    // The automatic pong reached the buffered writer, so the flush failure is
    // a transmit failure rather than a read failure.
    try std.testing.expectEqual(@as(?WebSocketError, error.IoError), ws.write_failure);
    try std.testing.expectEqual(@as(?WebSocketError, null), ws.read_failure);
    try std.testing.expectEqual(@as(usize, 1), writer.flush_calls);
    try std.testing.expectEqual(@as(usize, 0), writer.written);

    const seek_after_failure = reader.seek;
    try std.testing.expectError(error.IoError, ws.read_frame());
    try std.testing.expectEqual(seek_after_failure, reader.seek);
    try std.testing.expectEqual(@as(usize, 1), writer.flush_calls);

    ws.reset_tx();
    try std.testing.expectEqual(@as(?WebSocketError, null), ws.write_failure);
    try std.testing.expectEqual(@as(?WebSocketError, null), ws.read_failure);

    const received = try ws.read_frame();
    try std.testing.expectEqual(connection.OpCode.text, received.opcode);
    try std.testing.expectEqualStrings("ok", received.payload);
}

test "WebSocket: a successful buffered flush releases queued bytes" {
    var empty = std.Io.Reader.fixed("");
    var frame_buffer: [16]u8 = undefined;
    var tx_nodes: [1]zslay.FrameNode = undefined;
    var write_buffer: [64]u8 = undefined;
    var close_buffer: [8]u8 = undefined;
    var out: [16]u8 = undefined;
    var flush_buffer: [16]u8 = undefined;
    var writer = FlushFailWriter.init(&out, &flush_buffer);
    writer.fail_flush = false;

    var ws = try connection.WebSocket.init(&empty, &writer.writer, .{
        .frame_buffer = &frame_buffer,
        .tx_nodes = &tx_nodes,
        .write_buffer = &write_buffer,
        .close_buffer = &close_buffer,
    }, .{ .role = .server });

    var payload = [_]u8{ 'h', 'i' };
    try ws.write_frame(Frame.text(&payload));
    try std.testing.expectEqual(@as(usize, 0), writer.written);
    try std.testing.expectEqual(@as(usize, 4), writer.writer.end);

    try ws.flush();

    try std.testing.expectEqual(@as(usize, 4), writer.written);
    try std.testing.expectEqual(@as(usize, 0), writer.writer.end);
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 0x02, 'h', 'i' }, out[0..writer.written]);
}

test "WebSocket: reset_tx clears a terminal write failure and closed" {
    var empty = std.Io.Reader.fixed("");
    var server: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
    try server.init(&empty, .{ .role = .server });
    server.writer.fail_after = 0;

    var close_storage: [2]u8 = undefined;
    try std.testing.expectError(
        error.IoError,
        server.ws.write_frame(try Frame.close(1000, "", &close_storage)),
    );
    try std.testing.expect(server.ws.is_closed());
    try std.testing.expectEqual(@as(usize, 1), server.ws.tx_pending());
    try std.testing.expectEqual(@as(usize, 0), server.writer.written);

    server.writer.fail_after = null;
    server.ws.reset_tx();

    try std.testing.expect(!server.ws.is_closed());
    try std.testing.expectEqual(@as(usize, 0), server.ws.tx_pending());

    var next_close_storage: [2]u8 = undefined;
    try server.ws.write_frame(try Frame.close(1000, "", &next_close_storage));
    try std.testing.expect(server.ws.is_closed());
    try std.testing.expectEqual(@as(usize, 0), server.ws.tx_pending());

    var index: usize = 0;
    const close = try next_wire_frame(server.bytes(), &index);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xe8 }, close.payload);
    try std.testing.expectEqual(server.writer.written, index);
}

test "WebSocket: a mid-frame writer failure is not retried" {
    var empty = std.Io.Reader.fixed("");
    var server: ConnectionRig(16, 2, 64, 8, 0, 16) = .{};
    try server.init(&empty, .{ .role = .server });
    server.writer.fail_after = 2;

    var payload = [_]u8{ 'h', 'e', 'l', 'l', 'o' };
    try std.testing.expectError(error.IoError, server.ws.write_frame(Frame.text(&payload)));
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 0x05 }, server.bytes());
    try std.testing.expectEqual(@as(usize, 1), server.writer.drain_calls);
    try std.testing.expectEqual(@as(usize, 1), server.ws.tx_pending());

    var retry = [_]u8{'x'};
    try std.testing.expectError(error.IoError, server.ws.write_frame(Frame.text(&retry)));
    try std.testing.expectEqual(@as(usize, 1), server.writer.drain_calls);
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 0x05 }, server.bytes());
}

/// Caller-owned split storage plus a recording writer.
///
/// Read and write halves use disjoint regions: a read reply borrows read
/// storage while the write half drains it, so sharing would alias queued
/// payload bytes during composition.
fn SplitRig(
    comptime frame_capacity: usize,
    comptime node_count: usize,
    comptime compose_capacity: usize,
    comptime close_capacity: usize,
    comptime scratch_capacity: usize,
    comptime out_capacity: usize,
) type {
    return struct {
        frame_buffer: [frame_capacity]u8 = undefined,
        message_buffer: [frame_capacity]u8 = undefined,
        tx_nodes: [node_count]zslay.FrameNode = undefined,
        read_compose_buffer: [compose_capacity]u8 = undefined,
        write_buffer: [compose_capacity]u8 = undefined,
        read_close_buffer: [close_capacity]u8 = undefined,
        write_close_buffer: [close_capacity]u8 = undefined,
        mask_scratch: [scratch_capacity]u8 = undefined,
        out: [out_capacity]u8 = undefined,
        writer: RecordingVecWriter = undefined,
        split: split.Split = undefined,

        const Self = @This();

        fn init(self: *Self, reader: *std.Io.Reader, config: split.Config) !void {
            self.writer = RecordingVecWriter.init(&self.out);
            self.split = try split.after_handshake_split(reader, &self.writer.writer, .{
                .read = .{
                    .frame_buffer = &self.frame_buffer,
                    .close_buffer = &self.read_close_buffer,
                    .compose_buffer = &self.read_compose_buffer,
                },
                .write = .{
                    .tx_nodes = &self.tx_nodes,
                    .write_buffer = &self.write_buffer,
                    .close_buffer = &self.write_close_buffer,
                    .mask_scratch = &self.mask_scratch,
                },
            }, config);
        }

        fn bytes(self: *const Self) []const u8 {
            return self.out[0..self.writer.written];
        }
    };
}

test "Split: server pair reads a masked client frame and writes an unmasked reply" {
    var stream: EncodedStream(32) = .{};
    var inbound = [_]u8{ 'h', 'i' };
    try append_masked(&stream, Frame.text(&inbound), .{ 0x01, 0x02, 0x03, 0x04 });

    var reader = stream.reader();
    var parts: SplitRig(64, 2, 32, 8, 0, 64) = .{};
    try parts.init(&reader, .{ .role = .server });

    const received = try parts.split.read_frame();
    try std.testing.expectEqual(split.OpCode.text, received.opcode);
    try std.testing.expect(received.fin);
    try std.testing.expectEqual(@as(?split.MaskingKey, null), received.masking_key);
    try std.testing.expectEqualStrings("hi", received.payload);
    try std.testing.expectEqual(@as(usize, 0), parts.writer.written);

    var outbound = [_]u8{ 'o', 'k' };
    try parts.split.write_frame(Frame.text(&outbound));
    try parts.split.flush();

    var index: usize = 0;
    const wire = try next_wire_frame(parts.bytes(), &index);
    try std.testing.expectEqual(split.OpCode.text, split.OpCode.from_wire(wire.header.header.opcode).?);
    try std.testing.expect(!wire.header.header.mask);
    try std.testing.expectEqual(@as(?split.MaskingKey, null), wire.header.masking_key);
    try std.testing.expectEqualStrings("ok", wire.payload);
    try std.testing.expectEqual(parts.writer.written, index);
}

test "Split: client pair masks writes on the key schedule and reads clear inbound frames" {
    const seed: [connection.mask_seed_len]u8 = @splat(0x2a);
    var empty = std.Io.Reader.fixed("");
    var parts: SplitRig(32, 2, 64, 8, 16, 64) = .{};
    try parts.init(&empty, .{
        .role = .client,
        .mask_keys = connection.MaskKeySource.from_seed(seed),
    });

    var expected_keys = connection.MaskKeySource.from_seed(seed);
    const first_key = expected_keys.next();

    var first_payload = [_]u8{ 'h', 'i' };
    try parts.split.write_frame(Frame.text(&first_payload));

    var index: usize = 0;
    const first = try next_wire_frame(parts.bytes(), &index);
    try std.testing.expect(first.header.header.mask);
    try std.testing.expectEqualSlices(u8, &first_key, &first.header.masking_key.?);
    try std.testing.expectEqual(@as(u8, 'h' ^ first_key[0]), first.payload[0]);
    try std.testing.expectEqual(@as(u8, 'i' ^ first_key[1]), first.payload[1]);

    var plaintext: [2]u8 = undefined;
    @memcpy(&plaintext, first.payload);
    zslay.mask(&plaintext, first_key, 0);
    try std.testing.expectEqualStrings("hi", &plaintext);

    const written_after_first = parts.writer.written;
    var inbound: EncodedStream(16) = .{};
    var inbound_payload = [_]u8{ 'o', 'k' };
    try inbound.append(Frame.text(&inbound_payload));
    empty = inbound.reader();

    const received = try parts.split.read_frame();
    try std.testing.expectEqual(split.OpCode.text, received.opcode);
    try std.testing.expectEqual(@as(?split.MaskingKey, null), received.masking_key);
    try std.testing.expectEqualStrings("ok", received.payload);
    try std.testing.expectEqual(written_after_first, parts.writer.written);

    var second_payload = [_]u8{ 'g', 'o' };
    try parts.split.write_frame(Frame.text(&second_payload));

    const second_key = expected_keys.next();
    const second = try next_wire_frame(parts.bytes(), &index);
    try std.testing.expect(second.header.header.mask);
    try std.testing.expectEqualSlices(u8, &second_key, &second.header.masking_key.?);
    try std.testing.expectEqual(parts.writer.written, index);
}

test "Split: read_frame forwards an exact pong through the write half and suppresses the ping" {
    var stream: EncodedStream(32) = .{};
    var ping_payload = [_]u8{ 'h', 'i' };
    var text_payload = [_]u8{ 'o', 'k' };
    try append_masked(&stream, Frame.ping(&ping_payload), .{ 0x01, 0x02, 0x03, 0x04 });
    try append_masked(&stream, Frame.text(&text_payload), .{ 0x05, 0x06, 0x07, 0x08 });

    var reader = stream.reader();
    var parts: SplitRig(32, 2, 32, 8, 0, 32) = .{};
    try parts.init(&reader, .{ .role = .server });

    const received = try parts.split.read_frame();
    try std.testing.expectEqual(split.OpCode.text, received.opcode);
    try std.testing.expectEqualStrings("ok", received.payload);

    var index: usize = 0;
    const pong = try next_wire_frame(parts.bytes(), &index);
    try std.testing.expectEqual(split.OpCode.pong, split.OpCode.from_wire(pong.header.header.opcode).?);
    try std.testing.expect(!pong.header.header.mask);
    try std.testing.expectEqual(@as(?split.MaskingKey, null), pong.header.masking_key);
    try std.testing.expectEqualStrings("hi", pong.payload);
    try std.testing.expectEqual(parts.writer.written, index);
    try std.testing.expectEqual(@as(usize, 0), parts.split.write.tx_pending());
}

test "Split: auto_pong off delivers the ping and writes nothing" {
    var stream: EncodedStream(16) = .{};
    var ping_payload = [_]u8{ 'h', 'i' };
    try append_masked(&stream, Frame.ping(&ping_payload), .{ 0x09, 0x0a, 0x0b, 0x0c });

    var reader = stream.reader();
    var parts: SplitRig(16, 1, 32, 8, 0, 16) = .{};
    try parts.init(&reader, .{ .role = .server, .options = .{ .auto_pong = false } });

    const received = try parts.split.read_frame();
    try std.testing.expectEqual(split.OpCode.ping, received.opcode);
    try std.testing.expect(received.fin);
    try std.testing.expectEqual(@as(?split.MaskingKey, null), received.masking_key);
    try std.testing.expectEqualStrings("hi", received.payload);
    try std.testing.expectEqual(@as(usize, 0), parts.writer.written);
    try std.testing.expect(!parts.split.is_closed());
    try std.testing.expect(parts.split.is_at_wire_boundary());
}

test "Split: auto_close echoes a valid close through the write half and gates later reads" {
    var stream: EncodedStream(32) = .{};
    var close_storage: [8]u8 = undefined;
    var text_payload = [_]u8{'x'};
    try append_masked(&stream, try Frame.close(1000, "bye", &close_storage), .{ 0xa1, 0xb2, 0xc3, 0xd4 });
    try append_masked(&stream, Frame.text(&text_payload), .{ 0x11, 0x22, 0x33, 0x44 });

    var reader = stream.reader();
    var parts: SplitRig(32, 2, 32, 8, 0, 32) = .{};
    try parts.init(&reader, .{ .role = .server });

    const received = try parts.split.read_frame();
    try std.testing.expectEqual(split.OpCode.close, received.opcode);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xe8, 'b', 'y', 'e' }, received.payload);
    try std.testing.expect(parts.split.write.is_closed());
    try std.testing.expect(parts.split.is_closed());

    var index: usize = 0;
    const echo = try next_wire_frame(parts.bytes(), &index);
    try std.testing.expectEqual(split.OpCode.close, split.OpCode.from_wire(echo.header.header.opcode).?);
    try std.testing.expect(!echo.header.header.mask);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xe8, 'b', 'y', 'e' }, echo.payload);
    try std.testing.expectEqual(parts.writer.written, index);

    const written_after_close = parts.writer.written;
    try std.testing.expectError(error.ConnectionClosed, parts.split.read_frame());
    try std.testing.expectEqual(written_after_close, parts.writer.written);
}

test "Split: invalid close code sends a masked 1002 with the reason and closes the write half" {
    const seed: [connection.mask_seed_len]u8 = @splat(0x48);
    var stream: EncodedStream(16) = .{};
    var payload = [_]u8{ 0x03, 0xe7, 'b', 'a', 'd' };
    try stream.append(Frame.close_raw(&payload));

    var reader = stream.reader();
    var parts: SplitRig(16, 2, 32, 8, 0, 32) = .{};
    try parts.init(&reader, .{
        .role = .client,
        .mask_keys = connection.MaskKeySource.from_seed(seed),
    });

    try std.testing.expectError(error.InvalidCloseCode, parts.split.read_frame());
    try std.testing.expect(parts.split.write.is_closed());

    var index: usize = 0;
    const reply = try next_wire_frame(parts.bytes(), &index);
    try std.testing.expect(reply.header.header.mask);
    const key = reply.header.masking_key.?;
    try std.testing.expectEqual(@as(usize, 5), reply.payload.len);

    var plaintext: [5]u8 = undefined;
    @memcpy(&plaintext, reply.payload);
    zslay.mask(&plaintext, key, 0);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xea, 'b', 'a', 'd' }, &plaintext);
    try std.testing.expectEqual(parts.writer.written, index);
}

test "Split: successful 1002 through an external sink is terminal and latched" {
    const CountingSink = struct {
        sent: usize = 0,

        pub fn send_obligation(self: *@This(), outgoing: Frame) WebSocketError!void {
            _ = outgoing;
            self.sent += 1;
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

    var stream: EncodedStream(32) = .{};
    var close_payload = [_]u8{ 0x03, 0xe7, 'b', 'a', 'd' };
    var trailing = [_]u8{'x'};
    try append_masked(&stream, Frame.close_raw(&close_payload), .{ 0x81, 0x82, 0x83, 0x84 });
    try append_masked(&stream, Frame.text(&trailing), .{ 0x85, 0x86, 0x87, 0x88 });

    var reader = stream.reader();
    var parts: SplitRig(32, 2, 32, 8, 0, 32) = .{};
    try parts.init(&reader, .{ .role = .server });

    var sink: CountingSink = .{};
    try std.testing.expectError(error.InvalidCloseCode, parts.split.read_frame_with(&sink));
    try std.testing.expectEqual(@as(usize, 1), sink.sent);
    try std.testing.expectEqual(@as(?WebSocketError, error.InvalidCloseCode), parts.split.read.inner.read_failure);
    try std.testing.expect(parts.split.read.inner.is_closed());
    try std.testing.expect(parts.split.is_closed());
    const seek_after_first = reader.seek;

    var text = [_]u8{'y'};
    try std.testing.expectError(error.ConnectionClosed, parts.split.write_frame(Frame.text(&text)));

    try std.testing.expectError(error.InvalidCloseCode, parts.split.read_frame_with(&sink));
    try std.testing.expectEqual(seek_after_first, reader.seek);
    try std.testing.expectEqual(@as(usize, 1), sink.sent);
}

test "Split: successful 1002 through the internal write half latches InvalidCloseCode" {
    const seed: [connection.mask_seed_len]u8 = @splat(0x47);
    const wire_key: MaskingKey = .{ 0x21, 0x22, 0x23, 0x24 };
    var stream: EncodedStream(16) = .{};
    var payload = [_]u8{ 0x03, 0xe7, 'b', 'a', 'd' };
    var trailing = [_]u8{ 'o', 'k' };
    try stream.append(Frame.close_raw(&payload));
    try append_masked(&stream, Frame.text(&trailing), wire_key);

    var reader = stream.reader();
    var parts: SplitRig(16, 2, 32, 8, 0, 32) = .{};
    try parts.init(&reader, .{
        .role = .client,
        .mask_keys = connection.MaskKeySource.from_seed(seed),
    });

    try std.testing.expectError(error.InvalidCloseCode, parts.split.read_frame());
    try std.testing.expectEqual(@as(?WebSocketError, error.InvalidCloseCode), parts.split.read.inner.read_failure);
    try std.testing.expectEqual(@as(?WebSocketError, null), parts.split.write.failure());
    try std.testing.expect(parts.split.write.is_closed());
    const seek_after_first = reader.seek;

    try std.testing.expectError(error.InvalidCloseCode, parts.split.read_frame());
    try std.testing.expectEqual(seek_after_first, reader.seek);
}

test "Split: invalid UTF-8 close reason returns InvalidUTF8 with no output" {
    var stream: EncodedStream(16) = .{};
    var payload = [_]u8{ 0x03, 0xe8, 0xff };
    try append_masked(&stream, Frame.close_raw(&payload), .{ 0x1a, 0x2b, 0x3c, 0x4d });

    var reader = stream.reader();
    var parts: SplitRig(16, 2, 32, 8, 0, 16) = .{};
    try parts.init(&reader, .{ .role = .server });

    try std.testing.expectError(error.InvalidUTF8, parts.split.read_frame());
    try std.testing.expectEqual(@as(usize, 0), parts.writer.written);
    try std.testing.expect(!parts.split.write.is_closed());
    try std.testing.expect(parts.split.is_at_wire_boundary());
    const seek_after_failure = reader.seek;

    try std.testing.expectError(error.InvalidUTF8, parts.split.read_frame());
    try std.testing.expectEqual(seek_after_failure, reader.seek);
    try std.testing.expectEqual(@as(usize, 0), parts.writer.written);
}

test "Split: client auto_apply_mask off delivers control frames without replies" {
    const seed: [connection.mask_seed_len]u8 = @splat(0x3c);
    var stream: EncodedStream(32) = .{};
    var ping_payload = [_]u8{ 'h', 'i' };
    var close_storage: [8]u8 = undefined;
    var text_payload = [_]u8{'x'};
    try stream.append(Frame.ping(&ping_payload));
    try stream.append(try Frame.close(1000, "bye", &close_storage));
    try stream.append(Frame.text(&text_payload));

    var reader = stream.reader();
    var parts: SplitRig(32, 2, 32, 8, 0, 32) = .{};
    try parts.init(&reader, .{
        .role = .client,
        .options = .{ .auto_apply_mask = false },
        .mask_keys = connection.MaskKeySource.from_seed(seed),
    });

    const ping = try parts.split.read_frame();
    try std.testing.expectEqual(split.OpCode.ping, ping.opcode);
    try std.testing.expectEqualStrings("hi", ping.payload);
    try std.testing.expectEqual(@as(usize, 0), parts.writer.written);
    try std.testing.expect(!parts.split.is_closed());

    const close = try parts.split.read_frame();
    try std.testing.expectEqual(split.OpCode.close, close.opcode);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xe8, 'b', 'y', 'e' }, close.payload);
    try std.testing.expectEqual(@as(usize, 0), parts.writer.written);
    try std.testing.expect(parts.split.is_closed());
    try std.testing.expect(!parts.split.write.is_closed());

    try std.testing.expectError(error.ConnectionClosed, parts.split.read_frame());
    try std.testing.expectEqual(@as(usize, 0), parts.writer.written);
}

test "Split: auto_apply_mask off delivers masked frames and skips control policy" {
    const key: MaskingKey = .{ 0x11, 0x22, 0x33, 0x44 };
    var stream: EncodedStream(64) = .{};
    var text_payload = [_]u8{ 'h', 'i' };
    var ping_payload = [_]u8{'p'};
    var close_storage: [8]u8 = undefined;
    try append_masked(&stream, Frame.text(&text_payload), key);
    try append_masked(&stream, Frame.ping(&ping_payload), key);
    try append_masked(&stream, try Frame.close(1000, "bye", &close_storage), key);

    var reader = stream.reader();
    var parts: SplitRig(32, 2, 32, 8, 0, 8) = .{};
    try parts.init(&reader, .{ .role = .server, .options = .{ .auto_apply_mask = false } });

    var plaintext: [8]u8 = undefined;

    const text = try parts.split.read_frame();
    try std.testing.expectEqual(split.OpCode.text, text.opcode);
    try std.testing.expectEqual(@as(?split.MaskingKey, key), text.masking_key);
    @memcpy(plaintext[0..text.payload.len], text.payload);
    zslay.mask(plaintext[0..text.payload.len], key, 0);
    try std.testing.expectEqualStrings("hi", plaintext[0..text.payload.len]);

    const ping = try parts.split.read_frame();
    try std.testing.expectEqual(split.OpCode.ping, ping.opcode);
    try std.testing.expectEqual(@as(?split.MaskingKey, key), ping.masking_key);
    @memcpy(plaintext[0..ping.payload.len], ping.payload);
    zslay.mask(plaintext[0..ping.payload.len], key, 0);
    try std.testing.expectEqualStrings("p", plaintext[0..ping.payload.len]);
    try std.testing.expectEqual(@as(usize, 0), parts.writer.written);

    const close = try parts.split.read_frame();
    try std.testing.expectEqual(split.OpCode.close, close.opcode);
    try std.testing.expectEqual(@as(?split.MaskingKey, key), close.masking_key);
    @memcpy(plaintext[0..close.payload.len], close.payload);
    zslay.mask(plaintext[0..close.payload.len], key, 0);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xe8, 'b', 'y', 'e' }, plaintext[0..close.payload.len]);
    try std.testing.expectEqual(@as(usize, 0), parts.writer.written);
    try std.testing.expect(!parts.split.is_closed());
}

test "Split: automatic pong prepare failure latches the read half" {
    const seed: [connection.mask_seed_len]u8 = @splat(0x4e);
    var stream: EncodedStream(16) = .{};
    var ping_payload = [_]u8{ 'p', 'i', 'n', 'g' };
    try stream.append(Frame.ping(&ping_payload));

    var reader = stream.reader();
    var parts: SplitRig(16, 2, 32, 8, 0, 16) = .{};
    try parts.init(&reader, .{
        .role = .client,
        .mask_keys = connection.MaskKeySource.from_seed(seed),
    });
    parts.split.write.set_auto_apply_mask(false);

    try std.testing.expectError(error.PayloadNotMasked, parts.split.read_frame());
    try std.testing.expectEqual(@as(?WebSocketError, error.PayloadNotMasked), parts.split.read.inner.read_failure);
    try std.testing.expectEqual(@as(?WebSocketError, null), parts.split.write.failure());
    try std.testing.expectEqual(@as(usize, 0), parts.writer.written);

    try std.testing.expectError(error.PayloadNotMasked, parts.split.read_frame());
    try std.testing.expectEqual(@as(?WebSocketError, error.PayloadNotMasked), parts.split.read.inner.read_failure);
    try std.testing.expectEqual(@as(usize, 0), parts.writer.written);
}

test "Split: failed 1002 send leaves the read latch clear until reset_tx" {
    const seed: [connection.mask_seed_len]u8 = @splat(0x5e);
    var stream: EncodedStream(32) = .{};
    var close_payload = [_]u8{ 0x03, 0xe7, 'b', 'a', 'd' };
    var text_payload = [_]u8{ 'o', 'k' };
    try stream.append(Frame.close_raw(&close_payload));
    try stream.append(Frame.text(&text_payload));

    var reader = stream.reader();
    var parts: SplitRig(16, 2, 32, 8, 0, 16) = .{};
    try parts.init(&reader, .{
        .role = .client,
        .mask_keys = connection.MaskKeySource.from_seed(seed),
    });
    parts.writer.fail_after = 0;

    try std.testing.expectError(error.IoError, parts.split.read_frame());
    try std.testing.expectEqual(@as(?WebSocketError, null), parts.split.read.inner.read_failure);
    try std.testing.expectEqual(@as(?WebSocketError, error.IoError), parts.split.write.failure());
    try std.testing.expectEqual(@as(usize, 0), parts.writer.written);

    parts.split.reset_tx();
    try std.testing.expectEqual(@as(?WebSocketError, null), parts.split.write.failure());

    const received = try parts.split.read_frame();
    try std.testing.expectEqual(split.OpCode.text, received.opcode);
    try std.testing.expectEqualStrings("ok", received.payload);
}

test "Split: FragmentCollectorRead does not latch a sink transport failure" {
    var stream: EncodedStream(32) = .{};
    var ping_payload = [_]u8{'p'};
    var text_payload = [_]u8{ 'o', 'k' };
    try append_masked(&stream, Frame.ping(&ping_payload), .{ 0x91, 0x92, 0x93, 0x94 });
    try append_masked(&stream, Frame.text(&text_payload), .{ 0x95, 0x96, 0x97, 0x98 });

    var reader = stream.reader();
    var parts: SplitRig(32, 2, 32, 8, 0, 32) = .{};
    try parts.init(&reader, .{ .role = .server });
    parts.writer.fail_after = 0;

    var collector = try split.FragmentCollectorRead.init(parts.split.read, &parts.message_buffer);

    try std.testing.expectError(error.IoError, collector.read_frame(&parts.split.write));
    try std.testing.expectEqual(@as(?WebSocketError, null), collector.failure);
    try std.testing.expectEqual(@as(?WebSocketError, null), collector.read.inner.read_failure);
    try std.testing.expectEqual(@as(?WebSocketError, null), parts.split.read.inner.read_failure);
    try std.testing.expectEqual(@as(?WebSocketError, error.IoError), parts.split.write.failure());
    try std.testing.expectEqual(@as(usize, 0), parts.writer.written);

    parts.split.reset_tx();

    const received = try collector.read_frame(&parts.split.write);
    try std.testing.expectEqual(split.OpCode.text, received.opcode);
    try std.testing.expectEqualStrings("ok", received.payload);
}

test "Split: read_frame_with an external sink records the close in the read half" {
    const CountingSink = struct {
        sent: usize = 0,

        pub fn send_obligation(self: *@This(), outgoing: Frame) WebSocketError!void {
            _ = outgoing;
            self.sent += 1;
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

    var stream: EncodedStream(32) = .{};
    var close_storage: [8]u8 = undefined;
    var trailing = [_]u8{'x'};
    try append_masked(&stream, try Frame.close(1000, "bye", &close_storage), .{ 0x61, 0x62, 0x63, 0x64 });
    try append_masked(&stream, Frame.text(&trailing), .{ 0x65, 0x66, 0x67, 0x68 });

    var reader = stream.reader();
    var parts: SplitRig(32, 2, 32, 8, 0, 32) = .{};
    try parts.init(&reader, .{ .role = .server });

    var sink: CountingSink = .{};
    const received = try parts.split.read_frame_with(&sink);
    try std.testing.expectEqual(split.OpCode.close, received.opcode);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xe8, 'b', 'y', 'e' }, received.payload);
    try std.testing.expectEqual(@as(usize, 1), sink.sent);
    try std.testing.expect(parts.split.is_closed());
    try std.testing.expectEqual(@as(usize, 0), parts.writer.written);

    var text = [_]u8{'x'};
    try std.testing.expectError(error.ConnectionClosed, parts.split.write_frame(Frame.text(&text)));
    try std.testing.expectError(error.ConnectionClosed, parts.split.read_frame());
}

test "Split: client pong masking uses the write-half key schedule" {
    const seed: [connection.mask_seed_len]u8 = @splat(0x6e);
    var stream: EncodedStream(32) = .{};
    var ping_payload = [_]u8{ 'p', 'i', 'n', 'g' };
    var text_payload = [_]u8{ 'o', 'k' };
    try stream.append(Frame.ping(&ping_payload));
    try stream.append(Frame.text(&text_payload));

    var reader = stream.reader();
    var parts: SplitRig(32, 2, 32, 8, 16, 32) = .{};
    try parts.init(&reader, .{
        .role = .client,
        .mask_keys = connection.MaskKeySource.from_seed(seed),
    });

    var expected_keys = connection.MaskKeySource.from_seed(seed);
    const expected_key = expected_keys.next();

    const received = try parts.split.read_frame();
    try std.testing.expectEqual(split.OpCode.text, received.opcode);
    try std.testing.expectEqualStrings("ok", received.payload);

    var index: usize = 0;
    const pong = try next_wire_frame(parts.bytes(), &index);
    try std.testing.expectEqual(split.OpCode.pong, split.OpCode.from_wire(pong.header.header.opcode).?);
    try std.testing.expect(pong.header.header.mask);
    try std.testing.expectEqualSlices(u8, &expected_key, &pong.header.masking_key.?);

    var plaintext: [4]u8 = undefined;
    @memcpy(&plaintext, pong.payload);
    zslay.mask(&plaintext, expected_key, 0);
    try std.testing.expectEqualStrings("ping", &plaintext);
    try std.testing.expectEqual(parts.writer.written, index);
}

test "Split: truncated header and payload latch UnexpectedEOF until reset" {
    {
        var wire = [_]u8{0x81};
        var reader = std.Io.Reader.fixed(&wire);
        var parts: SplitRig(16, 1, 32, 8, 0, 8) = .{};
        try parts.init(&reader, .{ .role = .server });

        try std.testing.expectError(error.UnexpectedEOF, parts.split.read_frame());
        try std.testing.expectEqual(@as(usize, 1), reader.seek);
        try std.testing.expect(!parts.split.is_at_wire_boundary());
        try std.testing.expectError(error.UnexpectedEOF, parts.split.read_frame());
        try std.testing.expectEqual(@as(usize, 1), reader.seek);

        parts.split.reset();
        try std.testing.expect(parts.split.is_at_wire_boundary());

        // The truncated transport is discarded; the caller positions the
        // reader at a fresh frame boundary after reset.
        var fresh: EncodedStream(16) = .{};
        var payload = [_]u8{ 'o', 'k' };
        try append_masked(&fresh, Frame.text(&payload), .{ 0x0a, 0x0b, 0x0c, 0x0d });
        reader = fresh.reader();

        const received = try parts.split.read_frame();
        try std.testing.expectEqualStrings("ok", received.payload);
    }

    {
        // Masked header with a three-byte payload, but only two bytes follow.
        var wire = [_]u8{ 0x81, 0x83, 0x01, 0x02, 0x03, 0x04, 'a', 'b' };
        var reader = std.Io.Reader.fixed(&wire);
        var parts: SplitRig(16, 1, 32, 8, 0, 8) = .{};
        try parts.init(&reader, .{ .role = .server });

        try std.testing.expectError(error.UnexpectedEOF, parts.split.read_frame());
        try std.testing.expectEqual(@as(usize, 8), reader.seek);
        try std.testing.expect(!parts.split.is_at_wire_boundary());
        try std.testing.expectError(error.UnexpectedEOF, parts.split.read_frame());
        try std.testing.expectEqual(@as(usize, 8), reader.seek);

        parts.split.reset();
        try std.testing.expect(parts.split.is_at_wire_boundary());

        var fresh: EncodedStream(16) = .{};
        var payload = [_]u8{ 'o', 'k' };
        try append_masked(&fresh, Frame.text(&payload), .{ 0x1a, 0x2b, 0x3c, 0x4d });
        reader = fresh.reader();

        const received = try parts.split.read_frame();
        try std.testing.expectEqualStrings("ok", received.payload);
    }
}

test "Split: zero max_message_size rejects before consuming and does not latch" {
    var stream: EncodedStream(16) = .{};
    var payload = [_]u8{ 'o', 'k' };
    try append_masked(&stream, Frame.text(&payload), .{ 0x31, 0x32, 0x33, 0x34 });

    var reader = stream.reader();
    var parts: SplitRig(16, 1, 32, 8, 0, 8) = .{};
    try parts.init(&reader, .{ .role = .server, .options = .{ .max_message_size = 0 } });

    try std.testing.expectError(error.FrameTooLarge, parts.split.read_frame());
    try std.testing.expectEqual(@as(usize, 0), reader.seek);
    try std.testing.expectError(error.FrameTooLarge, parts.split.read_frame());
    try std.testing.expectEqual(@as(usize, 0), reader.seek);

    parts.split.set_max_message_size(8);
    try std.testing.expectEqual(@as(usize, 8), parts.split.read.max_message_size());
    try std.testing.expectEqual(@as(usize, 8), parts.split.write.max_message_size());

    const received = try parts.split.read_frame();
    try std.testing.expectEqualStrings("ok", received.payload);
}

test "Split: a write failure latches, blocks reads, and reset_tx clears it" {
    const seed: [connection.mask_seed_len]u8 = @splat(0x5d);
    var stream: EncodedStream(16) = .{};
    var inbound = [_]u8{ 'o', 'k' };
    try stream.append(Frame.text(&inbound));

    var reader = stream.reader();
    var parts: SplitRig(16, 2, 32, 8, 0, 16) = .{};
    try parts.init(&reader, .{
        .role = .client,
        .mask_keys = connection.MaskKeySource.from_seed(seed),
    });
    parts.writer.fail_after = 0;

    var payload = [_]u8{ 'h', 'i' };
    try std.testing.expectError(error.IoError, parts.split.write_frame(Frame.text(&payload)));
    try std.testing.expectEqual(@as(?WebSocketError, error.IoError), parts.split.write.failure());
    try std.testing.expectEqual(@as(usize, 1), parts.split.write.tx_pending());
    try std.testing.expectEqual(@as(usize, 0), parts.writer.written);

    try std.testing.expectError(error.IoError, parts.split.read_frame());
    try std.testing.expectEqual(@as(usize, 0), reader.seek);

    parts.split.reset_tx();
    try std.testing.expectEqual(@as(?WebSocketError, null), parts.split.write.failure());
    try std.testing.expectEqual(@as(usize, 0), parts.split.write.tx_pending());
    try std.testing.expect(!parts.split.is_closed());

    const received = try parts.split.read_frame();
    try std.testing.expectEqualStrings("ok", received.payload);
}

test "Split: write_frame after close rejects data but serializes repeated closes" {
    var empty = std.Io.Reader.fixed("");
    var parts: SplitRig(16, 2, 32, 8, 0, 64) = .{};
    try parts.init(&empty, .{ .role = .server });

    var first_close_storage: [8]u8 = undefined;
    try parts.split.write_frame(try Frame.close(1000, "a", &first_close_storage));
    const after_first_close = parts.writer.written;
    try std.testing.expect(parts.split.write.is_closed());

    var text = [_]u8{'x'};
    try std.testing.expectError(error.ConnectionClosed, parts.split.write_frame(Frame.text(&text)));
    try std.testing.expectEqual(after_first_close, parts.writer.written);

    var second_close_storage: [8]u8 = undefined;
    try parts.split.write_frame(try Frame.close(1000, "b", &second_close_storage));
    try std.testing.expect(parts.split.write.is_closed());
    try std.testing.expectEqual(@as(usize, 0), parts.split.write.tx_pending());

    var index: usize = 0;
    const first = try next_wire_frame(parts.bytes(), &index);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xe8, 'a' }, first.payload);
    const second = try next_wire_frame(parts.bytes(), &index);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xe8, 'b' }, second.payload);
    try std.testing.expectEqual(parts.writer.written, index);
}

test "Split: FragmentCollectorRead assembles a split code point with an interleaved ping" {
    var stream: EncodedStream(64) = .{};
    var first = [_]u8{ 'A', 0xe2 };
    var ping_payload = [_]u8{'p'};
    var last = [_]u8{ 0x82, 0xac };
    try append_masked(&stream, Frame.init(false, .text, null, &first), .{ 0x01, 0x02, 0x03, 0x04 });
    try append_masked(&stream, Frame.ping(&ping_payload), .{ 0x05, 0x06, 0x07, 0x08 });
    try append_masked(&stream, Frame.init(true, .continuation, null, &last), .{ 0x09, 0x0a, 0x0b, 0x0c });

    var reader = stream.reader();
    var parts: SplitRig(32, 2, 32, 8, 0, 32) = .{};
    try parts.init(&reader, .{ .role = .server });

    var collector = try split.FragmentCollectorRead.init(parts.split.read, &parts.message_buffer);
    const message = try collector.read_frame(&parts.split.write);
    try std.testing.expectEqual(split.OpCode.text, message.opcode);
    try std.testing.expect(message.fin);
    try std.testing.expectEqualSlices(u8, &.{ 'A', 0xe2, 0x82, 0xac }, message.payload);
    try std.testing.expectEqual(@as(usize, 0), collector.message_len());
    try std.testing.expect(collector.is_at_frame_boundary());

    var index: usize = 0;
    const pong = try next_wire_frame(parts.bytes(), &index);
    try std.testing.expectEqual(split.OpCode.pong, split.OpCode.from_wire(pong.header.header.opcode).?);
    try std.testing.expectEqualStrings("p", pong.payload);
    try std.testing.expectEqual(parts.writer.written, index);
}

test "Split: FragmentCollectorRead delivers a ping between fragments without disturbing accumulation" {
    var stream: EncodedStream(64) = .{};
    var first = [_]u8{ 'A', 0xe2 };
    var ping_payload = [_]u8{'p'};
    var last = [_]u8{ 0x82, 0xac };
    try append_masked(&stream, Frame.init(false, .text, null, &first), .{ 0x11, 0x12, 0x13, 0x14 });
    try append_masked(&stream, Frame.ping(&ping_payload), .{ 0x15, 0x16, 0x17, 0x18 });
    try append_masked(&stream, Frame.init(true, .continuation, null, &last), .{ 0x19, 0x1a, 0x1b, 0x1c });

    var reader = stream.reader();
    var parts: SplitRig(32, 2, 32, 8, 0, 32) = .{};
    try parts.init(&reader, .{ .role = .server, .options = .{ .auto_pong = false } });

    var collector = try split.FragmentCollectorRead.init(parts.split.read, &parts.message_buffer);
    const ping = try collector.read_frame(&parts.split.write);
    try std.testing.expectEqual(split.OpCode.ping, ping.opcode);
    try std.testing.expectEqualStrings("p", ping.payload);
    try std.testing.expectEqual(@as(usize, 2), collector.message_len());
    try std.testing.expect(!collector.is_at_frame_boundary());

    const message = try collector.read_frame(&parts.split.write);
    try std.testing.expectEqualSlices(u8, &.{ 'A', 0xe2, 0x82, 0xac }, message.payload);
    try std.testing.expectEqual(@as(usize, 0), collector.message_len());
    try std.testing.expect(collector.is_at_frame_boundary());
    try std.testing.expectEqual(@as(usize, 0), parts.writer.written);
}

test "Split: FragmentCollectorRead rejects a message buffer overlapping the read frame buffer" {
    var empty = std.Io.Reader.fixed("");
    var parts: SplitRig(16, 1, 32, 8, 0, 8) = .{};
    try parts.init(&empty, .{ .role = .server });

    try std.testing.expectError(
        error.InvalidLength,
        split.FragmentCollectorRead.init(parts.split.read, parts.frame_buffer[0..8]),
    );
}

test "Split: FragmentCollectorRead reset clears an in-progress message and boundary tracking" {
    var stream: EncodedStream(64) = .{};
    var first = [_]u8{ 'h', 'e' };
    var ping_payload = [_]u8{'p'};
    var text_payload = [_]u8{ 'o', 'k' };
    try append_masked(&stream, Frame.init(false, .text, null, &first), .{ 0x21, 0x22, 0x23, 0x24 });
    try append_masked(&stream, Frame.ping(&ping_payload), .{ 0x25, 0x26, 0x27, 0x28 });
    try append_masked(&stream, Frame.text(&text_payload), .{ 0x29, 0x2a, 0x2b, 0x2c });

    var reader = stream.reader();
    var parts: SplitRig(32, 2, 32, 8, 0, 32) = .{};
    try parts.init(&reader, .{ .role = .server, .options = .{ .auto_pong = false } });

    var collector = try split.FragmentCollectorRead.init(parts.split.read, &parts.message_buffer);
    const ping = try collector.read_frame(&parts.split.write);
    try std.testing.expectEqual(split.OpCode.ping, ping.opcode);
    try std.testing.expectEqual(@as(usize, 2), collector.message_len());
    try std.testing.expect(!collector.is_at_frame_boundary());

    collector.reset();
    try std.testing.expectEqual(@as(usize, 0), collector.message_len());
    try std.testing.expect(collector.is_at_frame_boundary());

    const message = try collector.read_frame(&parts.split.write);
    try std.testing.expectEqual(split.OpCode.text, message.opcode);
    try std.testing.expectEqualStrings("ok", message.payload);
    try std.testing.expectEqual(@as(usize, 0), parts.writer.written);
}

test "Split: FragmentCollectorRead latches an accumulation failure until reset" {
    var stream: EncodedStream(16) = .{};
    var payload = [_]u8{ 'a', 'b', 'c', 'd', 'e' };
    try append_masked(&stream, Frame.init(false, .text, null, &payload), .{ 0x31, 0x32, 0x33, 0x34 });

    var reader = stream.reader();
    var parts: SplitRig(16, 1, 32, 8, 0, 8) = .{};
    try parts.init(&reader, .{ .role = .server });

    var collector = try split.FragmentCollectorRead.init(parts.split.read, parts.message_buffer[0..4]);

    try std.testing.expectError(error.BufferTooShort, collector.read_frame(&parts.split.write));
    try std.testing.expectEqual(@as(?WebSocketError, error.BufferTooShort), collector.failure);
    const seek_after_failure = reader.seek;

    try std.testing.expectError(error.BufferTooShort, collector.read_frame(&parts.split.write));
    try std.testing.expectEqual(seek_after_failure, reader.seek);
    try std.testing.expectEqual(@as(?WebSocketError, error.BufferTooShort), collector.failure);

    collector.reset();
    try std.testing.expectEqual(@as(?WebSocketError, null), collector.failure);
    try std.testing.expect(collector.is_at_frame_boundary());
}

test "Split: FragmentCollectorRead does not latch ConnectionClosed before a peer close" {
    var stream: EncodedStream(64) = .{};
    var local_close_storage: [8]u8 = undefined;
    var text_payload = [_]u8{ 'o', 'k' };
    var peer_close_storage: [8]u8 = undefined;
    try append_masked(&stream, Frame.text(&text_payload), .{ 0x71, 0x72, 0x73, 0x74 });
    try append_masked(&stream, try Frame.close(1000, "peer", &peer_close_storage), .{ 0x75, 0x76, 0x77, 0x78 });

    var reader = stream.reader();
    var parts: SplitRig(32, 2, 32, 8, 0, 32) = .{};
    try parts.init(&reader, .{ .role = .server });

    try parts.split.write_frame(try Frame.close(1000, "local", &local_close_storage));

    var collector = try split.FragmentCollectorRead.init(parts.split.read, &parts.message_buffer);

    try std.testing.expectError(error.ConnectionClosed, collector.read_frame(&parts.split.write));
    try std.testing.expectEqual(@as(?WebSocketError, null), collector.failure);

    const received = try collector.read_frame(&parts.split.write);
    try std.testing.expectEqual(split.OpCode.close, received.opcode);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xe8, 'p', 'e', 'e', 'r' }, received.payload);
    try std.testing.expectEqual(@as(?WebSocketError, null), collector.failure);
}

test "Split: FragmentCollectorRead does not latch a zero-max FrameTooLarge" {
    var stream: EncodedStream(16) = .{};
    var text_payload = [_]u8{ 'o', 'k' };
    try append_masked(&stream, Frame.text(&text_payload), .{ 0x79, 0x7a, 0x7b, 0x7c });

    var reader = stream.reader();
    var parts: SplitRig(16, 1, 32, 8, 0, 8) = .{};
    try parts.init(&reader, .{ .role = .server, .options = .{ .max_message_size = 0 } });

    var collector = try split.FragmentCollectorRead.init(parts.split.read, &parts.message_buffer);

    try std.testing.expectError(error.FrameTooLarge, collector.read_frame(&parts.split.write));
    try std.testing.expectEqual(@as(?WebSocketError, null), collector.failure);
    try std.testing.expectEqual(@as(usize, 0), reader.seek);

    collector.read.set_max_message_size(8);
    const received = try collector.read_frame(&parts.split.write);
    try std.testing.expectEqual(split.OpCode.text, received.opcode);
    try std.testing.expectEqualStrings("ok", received.payload);
    try std.testing.expectEqual(@as(?WebSocketError, null), collector.failure);
}

test "Split: public module re-exports the split surface" {
    const root = @import("root.zig");

    try std.testing.expect(root.Split == split.Split);
    try std.testing.expect(root.WebSocketRead == split.WebSocketRead);
    try std.testing.expect(root.WebSocketWrite == split.WebSocketWrite);
    try std.testing.expect(root.FragmentCollectorRead == split.FragmentCollectorRead);
    try std.testing.expect(root.SplitStorage == split.Storage);
    try std.testing.expect(root.SplitReadStorage == split.ReadStorage);
    try std.testing.expect(root.SplitWriteStorage == split.WriteStorage);
    try std.testing.expect(root.SplitOptions == split.Options);
    try std.testing.expect(root.SplitConfig == split.Config);
    try std.testing.expect(root.after_handshake_split == split.after_handshake_split);
}

test "Split: setters apply to both halves and remain reachable on each half" {
    var empty = std.Io.Reader.fixed("");
    var parts: SplitRig(16, 2, 32, 8, 0, 64) = .{};
    try parts.init(&empty, .{ .role = .server });

    // The split-level setters reach the half that owns each option. Inbound
    // close and pong policy belong to the read half; vectored writes belong to
    // the write half; masking and the writev threshold are shared.
    try std.testing.expect(parts.split.read.inner.options.auto_close);
    try std.testing.expect(parts.split.write.inner.options.auto_close);

    parts.split.set_auto_close(false);
    try std.testing.expect(!parts.split.read.inner.options.auto_close);
    try std.testing.expect(parts.split.write.inner.options.auto_close);

    parts.split.set_auto_pong(false);
    try std.testing.expect(!parts.split.read.inner.options.auto_pong);
    try std.testing.expect(parts.split.write.inner.options.auto_pong);

    parts.split.set_auto_apply_mask(false);
    try std.testing.expect(!parts.split.read.inner.options.auto_apply_mask);
    try std.testing.expect(!parts.split.write.inner.options.auto_apply_mask);

    parts.split.set_writev(false);
    try std.testing.expect(parts.split.read.inner.options.writev);
    try std.testing.expect(!parts.split.write.inner.options.writev);

    parts.split.set_writev_threshold(7);
    try std.testing.expectEqual(@as(usize, 7), parts.split.read.inner.options.writev_threshold);
    try std.testing.expectEqual(@as(usize, 7), parts.split.write.inner.options.writev_threshold);

    parts.split.set_max_message_size(123);
    try std.testing.expectEqual(@as(usize, 123), parts.split.read.max_message_size());
    try std.testing.expectEqual(@as(usize, 123), parts.split.write.max_message_size());

    parts.split.read.set_max_message_size(45);
    try std.testing.expectEqual(@as(usize, 45), parts.split.read.max_message_size());
    try std.testing.expectEqual(@as(usize, 123), parts.split.write.max_message_size());

    parts.split.write.set_max_message_size(67);
    try std.testing.expectEqual(@as(usize, 45), parts.split.read.max_message_size());
    try std.testing.expectEqual(@as(usize, 67), parts.split.write.max_message_size());

    parts.split.set_max_message_size(128);
    try std.testing.expectEqual(@as(usize, 128), parts.split.read.max_message_size());
    try std.testing.expectEqual(@as(usize, 128), parts.split.write.max_message_size());

    parts.split.read.set_writev_threshold(0);
    parts.split.read.set_auto_apply_mask(true);
    parts.split.read.set_auto_close(true);
    parts.split.read.set_auto_pong(true);
    parts.split.write.set_writev(false);
    parts.split.write.set_writev_threshold(0);
    parts.split.write.set_auto_apply_mask(true);
    parts.split.set_writev(false);
    parts.split.set_writev_threshold(0);
    parts.split.set_auto_apply_mask(true);

    var payload = [_]u8{ 'a', 'b', 'c', 'd' };
    try parts.split.write_frame(Frame.text(&payload));
    try std.testing.expectEqual(@as(usize, 1), parts.writer.max_iovecs);
    try std.testing.expectEqual(@as(usize, 1), parts.writer.drain_calls);
}

test "Split: server read honors the exclusive maximum at short and extended lengths" {
    var stream: EncodedStream(512) = .{};
    const lengths = [_]usize{ 0, 1, 125, 126 };
    const keys = [_]MaskingKey{
        .{ 0x01, 0x02, 0x03, 0x04 },
        .{ 0x05, 0x06, 0x07, 0x08 },
        .{ 0x09, 0x0a, 0x0b, 0x0c },
        .{ 0x0d, 0x0e, 0x0f, 0x10 },
    };
    for (lengths, keys) |len, key| {
        var payload: [126]u8 = @splat(0x41);
        try append_masked(&stream, Frame.binary(payload[0..len]), key);
    }

    var max_payload: [127]u8 = @splat(0x41);
    try append_masked(&stream, Frame.binary(&max_payload), .{ 0x11, 0x12, 0x13, 0x14 });

    var reader = stream.reader();
    var parts: SplitRig(126, 2, 32, 8, 0, 8) = .{};
    try parts.init(&reader, .{ .role = .server, .options = .{ .max_message_size = 127 } });

    const expected: [126]u8 = @splat(0x41);
    for (lengths) |len| {
        const received = try parts.split.read_frame();
        try std.testing.expectEqual(split.OpCode.binary, received.opcode);
        try std.testing.expectEqual(len, received.payload.len);
        try std.testing.expectEqualSlices(u8, expected[0..len], received.payload);
    }

    try std.testing.expectError(error.FrameTooLarge, parts.split.read_frame());
}
