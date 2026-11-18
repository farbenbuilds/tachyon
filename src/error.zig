//! WebSocket error model for tachyon.
//!
//! Mirrors fastwebsockets 0.10.0, maps zslay wire errors, and bridges `std.Io`
//! transport failures. Zig errors carry no payloads: `InvalidStatusCode` records
//! its status through `invalid_status_code`, and IO/HTTP/send detail stays at the
//! boundary. `from_zslay` normalizes zslay's `InvalidUtf8` and `PayloadTooLarge`
//! to `InvalidUTF8` and `FrameTooLarge`.
//!
//! zslay collapses RSV-bit, control-frame, non-minimal-length, close-frame,
//! close-code, fragment-order, and masking-key failures into `ProtocolError`.
//! `to_close_code` returns a code only for peer-caused wire failures.

const std = @import("std");
const zslay = @import("zslay");

/// fastwebsockets 0.10.0 parity, zslay boundary errors, and roadmap extensions.
pub const WebSocketError = error{
    // fastwebsockets 0.10.0
    InvalidFragment,
    InvalidUtf8, // zslay spelling; from_zslay returns InvalidUTF8
    InvalidUTF8,
    InvalidContinuationFrame,
    InvalidStatusCode, // status via invalid_status_code
    InvalidUpgradeHeader,
    InvalidConnectionHeader,
    ConnectionClosed,
    InvalidCloseFrame,
    InvalidCloseCode,
    UnexpectedEOF,
    UnexpectedEof, // idiomatic spelling alias
    ReservedBitsNotZero,
    ControlFrameFragmented,
    PingFrameTooLarge,
    FrameTooLarge,
    InvalidSecWebsocketVersion,
    InvalidValue,
    MissingSecWebSocketKey,
    IoError, // detail stays at the transport boundary
    HTTPError, // detail stays at the handshake boundary
    SendError, // detail stays at the send boundary

    // zslay 0.5.0
    InvalidOpcode,
    InvalidLength, // wire overflow or local invariant; close code only for peer data
    BufferTooShort,
    ProtocolError,
    PayloadMasked,
    PayloadNotMasked,
    MaskingKeyRequired,
    PayloadTooLarge, // zslay alias; from_zslay returns FrameTooLarge
    QueueFull,

    // roadmap extensions
    WouldBlock,
    EndOfStream,
    DecompressionFailed,
    DecompressedPayloadTooLarge,
    InvalidSecWebSocketAccept,
    InvalidHttpRequest,
};

/// zslay errors plus queue capacity exhaustion.
pub const ZslayQueueError = zslay.Error || error{QueueFull};

/// Returns `InvalidStatusCode` and records the rejected HTTP status in `status_out`.
pub fn invalid_status_code(status: u16, status_out: *u16) WebSocketError {
    status_out.* = status;
    return error.InvalidStatusCode;
}

/// Maps zslay errors, normalizing UTF-8 and oversized-payload spellings.
pub fn from_zslay(err: zslay.Error) WebSocketError {
    return switch (err) {
        error.InvalidOpcode => error.InvalidOpcode,
        error.InvalidLength => error.InvalidLength,
        error.BufferTooShort => error.BufferTooShort,
        error.ProtocolError => error.ProtocolError,
        error.PayloadMasked => error.PayloadMasked,
        error.PayloadNotMasked => error.PayloadNotMasked,
        error.PayloadTooLarge => error.FrameTooLarge,
        error.MaskingKeyRequired => error.MaskingKeyRequired,
        error.InvalidUtf8 => error.InvalidUTF8,
    };
}

/// Maps close-payload validation errors.
///
/// Call only after `decode_header` accepted the payload length; direct
/// `validate_close_payload` failures for malformed lengths belong in `from_zslay`.
pub fn from_zslay_close(err: zslay.Error) WebSocketError {
    return switch (err) {
        error.ProtocolError => error.InvalidCloseCode,
        error.InvalidUtf8 => error.InvalidUTF8,
        else => |e| from_zslay(e),
    };
}

pub fn from_zslay_queue(err: ZslayQueueError) WebSocketError {
    return switch (err) {
        error.QueueFull => error.QueueFull,
        else => |e| from_zslay(e),
    };
}

/// Maps reader EOF to `UnexpectedEOF` and read failures to `IoError`.
pub fn from_reader(err: std.Io.Reader.Error) WebSocketError {
    return switch (err) {
        error.EndOfStream => error.UnexpectedEOF,
        error.ReadFailed => error.IoError,
    };
}

/// Maps writer failures to `IoError`.
pub fn from_writer(err: std.Io.Writer.Error) WebSocketError {
    return switch (err) {
        error.WriteFailed => error.IoError,
    };
}

/// Maps stream failures; EOF becomes `UnexpectedEOF`.
pub fn from_stream(err: std.Io.Reader.StreamError) WebSocketError {
    return switch (err) {
        error.ReadFailed => error.IoError,
        error.WriteFailed => error.IoError,
        error.EndOfStream => error.UnexpectedEOF,
    };
}

/// Reverse-maps errors with a direct zslay counterpart.
pub fn to_zslay(err: WebSocketError) ?zslay.Error {
    return switch (err) {
        error.InvalidOpcode => error.InvalidOpcode,
        error.InvalidLength => error.InvalidLength,
        error.BufferTooShort => error.BufferTooShort,
        error.ProtocolError => error.ProtocolError,
        error.PayloadMasked => error.PayloadMasked,
        error.PayloadNotMasked => error.PayloadNotMasked,
        error.PayloadTooLarge, error.FrameTooLarge => error.PayloadTooLarge,
        error.MaskingKeyRequired => error.MaskingKeyRequired,
        error.InvalidUtf8, error.InvalidUTF8 => error.InvalidUtf8,
        else => null,
    };
}

/// Returns static display text. IO/HTTP detail and the `InvalidStatusCode`
/// status suffix stay with the caller.
pub fn description(err: WebSocketError) []const u8 {
    return switch (err) {
        error.InvalidFragment => "Invalid fragment",
        error.InvalidUtf8, error.InvalidUTF8 => "Invalid UTF-8",
        error.InvalidContinuationFrame => "Invalid continuation frame",
        error.InvalidStatusCode => "Invalid status code",
        error.InvalidUpgradeHeader => "Invalid upgrade header",
        error.InvalidConnectionHeader => "Invalid connection header",
        error.ConnectionClosed => "Connection is closed",
        error.InvalidCloseFrame => "Invalid close frame",
        error.InvalidCloseCode => "Invalid close code",
        error.UnexpectedEOF, error.UnexpectedEof => "Unexpected EOF",
        error.ReservedBitsNotZero => "Reserved bits are not zero",
        error.ControlFrameFragmented => "Control frame must not be fragmented",
        error.PingFrameTooLarge => "Ping frame too large",
        error.FrameTooLarge => "Frame too large",
        error.InvalidSecWebsocketVersion => "Sec-Websocket-Version must be 13",
        error.InvalidValue => "Invalid value",
        error.MissingSecWebSocketKey => "Sec-WebSocket-Key header is missing",
        error.IoError => "I/O error",
        error.HTTPError => "HTTP error",
        error.SendError => "Failed to send frame",

        error.InvalidOpcode => "Invalid opcode",
        error.InvalidLength => "Invalid length",
        error.BufferTooShort => "Buffer too short",
        error.ProtocolError => "Protocol error",
        error.PayloadMasked => "Payload is masked",
        error.PayloadNotMasked => "Payload is not masked",
        error.PayloadTooLarge => "Payload too large",
        error.MaskingKeyRequired => "Masking key is required",
        error.QueueFull => "Queue is full",

        error.WouldBlock => "Operation would block",
        error.EndOfStream => "End of stream",
        error.DecompressionFailed => "Decompression failed",
        error.DecompressedPayloadTooLarge => "Decompressed payload too large",
        error.InvalidSecWebSocketAccept => "Invalid Sec-WebSocket-Accept header",
        error.InvalidHttpRequest => "Invalid HTTP request",
    };
}

pub const to_string = description;

/// Returns the close code for a peer-caused wire failure, or null when sending a
/// close frame is impossible, already done, or inappropriate.
pub fn to_close_code(err: WebSocketError) ?zslay.StatusCode {
    return switch (err) {
        // 1002
        error.ProtocolError,
        error.InvalidFragment,
        error.InvalidContinuationFrame,
        error.ReservedBitsNotZero,
        error.ControlFrameFragmented,
        error.PingFrameTooLarge,
        error.InvalidCloseFrame,
        error.InvalidCloseCode,
        error.InvalidOpcode,
        error.InvalidLength,
        error.PayloadMasked,
        error.PayloadNotMasked,
        error.MaskingKeyRequired,
        error.InvalidValue,
        error.DecompressionFailed,
        => .protocol_error,

        // 1007
        error.InvalidUtf8,
        error.InvalidUTF8,
        => .invalid_payload,

        // 1009
        error.FrameTooLarge,
        error.PayloadTooLarge,
        error.DecompressedPayloadTooLarge,
        => .message_too_big,

        // No close frame.
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
        => null,
    };
}

/// True for RFC 6455 violations that close with 1002 or 1007.
pub fn is_protocol_error(err: WebSocketError) bool {
    return switch (err) {
        error.ProtocolError,
        error.InvalidFragment,
        error.InvalidContinuationFrame,
        error.ReservedBitsNotZero,
        error.ControlFrameFragmented,
        error.PingFrameTooLarge,
        error.InvalidCloseFrame,
        error.InvalidCloseCode,
        error.InvalidOpcode,
        error.InvalidLength,
        error.PayloadMasked,
        error.PayloadNotMasked,
        error.MaskingKeyRequired,
        error.InvalidValue,
        error.DecompressionFailed,
        error.InvalidUtf8,
        error.InvalidUTF8,
        => true,

        error.InvalidStatusCode,
        error.InvalidUpgradeHeader,
        error.InvalidConnectionHeader,
        error.ConnectionClosed,
        error.UnexpectedEOF,
        error.UnexpectedEof,
        error.FrameTooLarge,
        error.InvalidSecWebsocketVersion,
        error.MissingSecWebSocketKey,
        error.IoError,
        error.HTTPError,
        error.SendError,
        error.BufferTooShort,
        error.PayloadTooLarge,
        error.QueueFull,
        error.WouldBlock,
        error.EndOfStream,
        error.DecompressedPayloadTooLarge,
        error.InvalidSecWebSocketAccept,
        error.InvalidHttpRequest,
        => false,
    };
}

/// True when the connection cannot continue.
pub fn is_fatal(err: WebSocketError) bool {
    return switch (err) {
        error.WouldBlock,
        error.BufferTooShort,
        error.QueueFull,
        => false,

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
        error.ProtocolError,
        error.PayloadMasked,
        error.PayloadNotMasked,
        error.MaskingKeyRequired,
        error.PayloadTooLarge,
        error.EndOfStream,
        error.DecompressionFailed,
        error.DecompressedPayloadTooLarge,
        error.InvalidSecWebSocketAccept,
        error.InvalidHttpRequest,
        => true,
    };
}

/// True for either UTF-8 error spelling.
pub fn is_utf8_error(err: anyerror) bool {
    return err == error.InvalidUtf8 or err == error.InvalidUTF8;
}

/// True for unexpected EOF, the EOF alias, and clean end-of-stream.
pub fn is_eof_error(err: anyerror) bool {
    return err == error.UnexpectedEOF or err == error.UnexpectedEof or err == error.EndOfStream;
}
