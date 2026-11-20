const std = @import("std");
const zslay = @import("zslay");
const tachyon = @import("tachyon");

const WebSocketError = tachyon.WebSocketError;
const from_zslay = tachyon.from_zslay;
const from_zslay_close = tachyon.from_zslay_close;
const from_zslay_queue = tachyon.from_zslay_queue;
const invalid_status_code = tachyon.invalid_status_code;
const from_reader = tachyon.from_reader;
const from_writer = tachyon.from_writer;
const from_stream = tachyon.from_stream;
const to_zslay = tachyon.to_zslay;
const description = tachyon.description;
const to_string = tachyon.to_string;
const to_close_code = tachyon.to_close_code;
const is_protocol_error = tachyon.is_protocol_error;
const is_fatal = tachyon.is_fatal;
const is_utf8_error = tachyon.is_utf8_error;
const is_eof_error = tachyon.is_eof_error;

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
