//! WebSocket errors and error mapping for tachyon.
//!
//! Recreates the failure model and categories of fastwebsockets 0.10.0 in pure Zig 0.17.1,
//! integrating wire-level errors from zslay 0.5.0, `std.Io` transport errors, and roadmap
//! extensions (backpressure, native std.Io streams, RFC 7692 permessage-deflate).
//!
//! ## fastwebsockets parity
//!
//! `WebSocketError` carries all 20 fastwebsockets 0.10.0 variants, including `IoError`,
//! `HTTPError`, and `SendError`. Zig error values cannot carry payloads, so
//! `InvalidStatusCode` keeps its rejected status in a caller-owned out-parameter through
//! `invalid_status_code`; IO, HTTP, and send detail stays at the transport, handshake, and
//! connection boundaries.
//!
//! ## zslay boundary normalizations
//!
//! zslay 0.5.0 spells UTF-8 violations `InvalidUtf8` and reports oversized payloads as
//! `PayloadTooLarge`. The fastwebsockets boundary uses `InvalidUTF8` and `FrameTooLarge`, so
//! `from_zslay` and `from_zslay_close` normalize `InvalidUtf8` to `InvalidUTF8`, and
//! `from_zslay` normalizes `PayloadTooLarge` to `FrameTooLarge`. zslay-only tags remain
//! available for direct propagation, and `to_zslay` maps the normalized tags back to their
//! zslay spellings.
//!
//! ## std.Io transport mappings
//!
//! `from_reader`, `from_writer`, and `from_stream` map `std.Io.Reader`, `std.Io.Writer`, and
//! `std.Io.Reader.StreamError` non-EOF failures to `IoError`; EOF maps to `UnexpectedEOF`
//! because a WebSocket cannot end cleanly mid-frame, and connection policy decides whether EOF
//! is expected.
//!
//! ## Close-code policy
//!
//! `to_close_code` returns an RFC 6455 code only for peer-caused wire failures. Handshake,
//! transport, already-closed, and retryable local conditions return null because a close frame
//! is impossible, already sent, or should not be sent.
//!
//! ## zslay ProtocolError Collapsing
//!
//! In fastwebsockets 0.10.0, wire violations produce distinct typed variants (for example
//! `ControlFrameFragmented`, `PingFrameTooLarge`, `ReservedBitsNotZero`, `InvalidCloseFrame`,
//! and `InvalidCloseCode`). zslay's wire parser (`decode_header`, `validate_close_payload`,
//! and `Conn` state transitions) collapses these conditions into `error.ProtocolError`:
//!
//! 1. Non-zero RSV bits (RSV1, RSV2, RSV3) without negotiated extensions.
//! 2. Control frames with FIN bit unset (fragmented control frame).
//! 3. Control frames with payload length exceeding 125 bytes.
//! 4. Non-minimal 16-bit or 64-bit extended length encoding.
//! 5. 1-byte close frame payload.
//! 6. Close status codes outside permitted RFC 6455 / IANA ranges.
//! 7. Orphan continuation frames or unexpected new data frames mid-fragment.
//! 8. Supplying a masking key for an unmasked outgoing frame.
//!
//! tachyon maintains fastwebsockets-compatible error tags in `WebSocketError` so higher-level
//! policy checks can return specific categories, while `from_zslay` maps zslay's wire errors
//! into `WebSocketError`.

const std = @import("std");
const zslay = @import("zslay");

/// WebSocket error set mirroring fastwebsockets 0.10.0 failure categories,
/// zslay 0.5.0 wire/queue errors, and planned roadmap extensions.
pub const WebSocketError = error{
    // --- fastwebsockets 0.10.0 parity errors ---
    /// Unfragmented data frame arrived while a fragmented message was in progress.
    InvalidFragment,
    /// Invalid UTF-8 sequence encountered in text payload or close reason (zslay naming).
    InvalidUtf8,
    /// Fastwebsockets exact variant spelling alias for UTF-8 violation.
    InvalidUTF8,
    /// Continuation frame received without an active fragmented message.
    InvalidContinuationFrame,
    /// HTTP status code in client handshake response was not 101 Switching Protocols.
    /// Status code value is preserved via handshake out-parameter.
    InvalidStatusCode,
    /// Missing or invalid Upgrade header in HTTP handshake response.
    InvalidUpgradeHeader,
    /// Missing or invalid Connection header in HTTP handshake response.
    InvalidConnectionHeader,
    /// Connection is closed; data frame read or write attempted after close.
    ConnectionClosed,
    /// Malformed close frame (e.g. 1-byte payload or control rule violation).
    InvalidCloseFrame,
    /// Close status code is outside the permitted RFC 6455 / IANA range.
    InvalidCloseCode,
    /// Premature end-of-file or stream termination before frame completion (fastwebsockets spelling).
    UnexpectedEOF,
    /// Idiomatic Zig spelling alias for EOF.
    UnexpectedEof,
    /// RSV1, RSV2, or RSV3 bits set without a negotiated extension.
    ReservedBitsNotZero,
    /// Control frame has FIN bit cleared (control frames cannot be fragmented).
    ControlFrameFragmented,
    /// Ping frame payload exceeds 125 bytes.
    PingFrameTooLarge,
    /// Frame or message payload exceeds configured maximum limit.
    FrameTooLarge,
    /// Handshake request Sec-WebSocket-Version is not "13".
    InvalidSecWebsocketVersion,
    /// Header or option value is invalid.
    InvalidValue,
    /// Missing Sec-WebSocket-Key header in handshake upgrade request.
    MissingSecWebSocketKey,
    /// Underlying transport I/O failure (fastwebsockets IoError); detail stays at the
    /// transport boundary.
    IoError,
    /// HTTP handshake failure; detail stays at the handshake boundary.
    HTTPError,
    /// Failed to enqueue or transmit frame over split channel/stream; detail stays at the
    /// send boundary.
    SendError,

    // --- zslay 0.5.0 wire & queue errors ---
    /// Opcode on the wire is reserved or undefined.
    InvalidOpcode,
    /// Payload length exceeds MaxPayloadLen (2^63 - 1), bit 63 is set, a configured
    /// frame or message limit exceeds MaxPayloadLen, or a local progress invariant
    /// fails. The 1002 close classification applies only when the error came from
    /// peer wire data.
    InvalidLength,
    /// Caller-provided buffer is insufficient for header or frame.
    BufferTooShort,
    /// Wire-level protocol violation caught by zslay parser.
    ProtocolError,
    /// Frame payload is masked when unmasked was required (e.g. server-to-client).
    PayloadMasked,
    /// Frame payload is unmasked when masking was required (e.g. client-to-server).
    PayloadNotMasked,
    /// Masking key missing when mask bit is set or required.
    MaskingKeyRequired,
    /// Direct alias from zslay.Error.PayloadTooLarge.
    PayloadTooLarge,
    /// Bounded transmit queue capacity exceeded.
    QueueFull,

    // --- Planned roadmap extensions (CODEBASE.md) ---
    /// Backpressure watermark exceeded; operation would block.
    WouldBlock,
    /// Stream reached clean end-of-stream.
    EndOfStream,
    /// RFC 7692 permessage-deflate decompression failed.
    DecompressionFailed,
    /// Decompressed payload exceeds configured message limit.
    DecompressedPayloadTooLarge,
    /// Sec-WebSocket-Accept does not match expected SHA-1 digest (deliberate hardening).
    InvalidSecWebSocketAccept,
    /// HTTP request/response line or header block is malformed.
    InvalidHttpRequest,
};

/// Combined error set for zslay wire errors and queue capacity exhaustion.
pub const ZslayQueueError = zslay.Error || error{QueueFull};

/// Returns the payloadless `InvalidStatusCode` tag and records the rejected HTTP
/// status in `status_out`, preserving fastwebsockets' `InvalidStatusCode(u16)`.
/// `description` intentionally omits upstream's dynamic `": {status}"` suffix;
/// callers format the recorded status through their own diagnostics.
pub fn invalid_status_code(status: u16, status_out: *u16) WebSocketError {
    status_out.* = status;
    return error.InvalidStatusCode;
}

/// Maps zslay wire/parser errors to canonical WebSocketError.
/// Normalizes zslay's InvalidUtf8 to fastwebsockets' InvalidUTF8 and zslay's
/// PayloadTooLarge to fastwebsockets' FrameTooLarge.
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

/// Maps zslay close-payload validation errors to fastwebsockets close categories.
///
/// Only valid after `decode_header` has accepted the close payload length. In that
/// path, ProtocolError specifically represents an invalid close status code. A direct
/// `validate_close_payload` call on an untrusted 1-byte or oversized payload must be
/// mapped through `from_zslay` instead, which preserves ProtocolError rather than
/// reporting InvalidCloseCode. The UTF-8 spelling is normalized to fastwebsockets'
/// InvalidUTF8.
pub fn from_zslay_close(err: zslay.Error) WebSocketError {
    return switch (err) {
        error.ProtocolError => error.InvalidCloseCode,
        error.InvalidUtf8 => error.InvalidUTF8,
        else => |e| from_zslay(e),
    };
}

/// Maps zslay wire/parser errors or QueueFull to canonical WebSocketError.
pub fn from_zslay_queue(err: ZslayQueueError) WebSocketError {
    return switch (err) {
        error.QueueFull => error.QueueFull,
        else => |e| from_zslay(e),
    };
}

/// Maps a `std.Io.Reader` failure to the WebSocket failure model.
/// End-of-stream becomes UnexpectedEOF: a WebSocket cannot end cleanly mid-frame,
/// and connection policy decides whether EOF is expected.
pub fn from_reader(err: std.Io.Reader.Error) WebSocketError {
    return switch (err) {
        error.EndOfStream => error.UnexpectedEOF,
        error.ReadFailed => error.IoError,
    };
}

/// Maps a `std.Io.Writer` failure to the WebSocket failure model.
pub fn from_writer(err: std.Io.Writer.Error) WebSocketError {
    return switch (err) {
        error.WriteFailed => error.IoError,
    };
}

/// Maps a `std.Io.Reader.StreamError` failure to the WebSocket failure model.
/// End-of-stream becomes UnexpectedEOF for the same reason as `from_reader`.
pub fn from_stream(err: std.Io.Reader.StreamError) WebSocketError {
    return switch (err) {
        error.ReadFailed => error.IoError,
        error.WriteFailed => error.IoError,
        error.EndOfStream => error.UnexpectedEOF,
    };
}

/// Reverse-maps WebSocketError to zslay.Error when the error originated in or
/// has a direct counterpart in zslay.
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

/// Returns a static, payloadless description for a WebSocket error.
///
/// The strings approximate fastwebsockets Display text at the Zig error boundary.
/// `IoError` and `HTTPError` cannot carry upstream's transparent IO/HTTP detail, and
/// `InvalidStatusCode` omits the dynamic `": {status}"` suffix; callers format the
/// recorded status through `invalid_status_code` and their own diagnostics.
pub fn description(err: WebSocketError) []const u8 {
    return switch (err) {
        // fastwebsockets error.rs messages
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

        // zslay wire errors
        error.InvalidOpcode => "Invalid opcode",
        error.InvalidLength => "Invalid length",
        error.BufferTooShort => "Buffer too short",
        error.ProtocolError => "Protocol error",
        error.PayloadMasked => "Payload is masked",
        error.PayloadNotMasked => "Payload is not masked",
        error.PayloadTooLarge => "Payload too large",
        error.MaskingKeyRequired => "Masking key is required",
        error.QueueFull => "Queue is full",

        // Roadmap extensions
        error.WouldBlock => "Operation would block",
        error.EndOfStream => "End of stream",
        error.DecompressionFailed => "Decompression failed",
        error.DecompressedPayloadTooLarge => "Decompressed payload too large",
        error.InvalidSecWebSocketAccept => "Invalid Sec-WebSocket-Accept header",
        error.InvalidHttpRequest => "Invalid HTTP request",
    };
}

/// Alias for description.
pub const to_string = description;

/// Returns the RFC 6455 close status code for a peer-caused wire failure.
///
/// A close code is returned only when sending a close frame is meaningful and the
/// failure was caused by peer wire data. Handshake, transport, already-closed, and
/// retryable local conditions return null because a close frame is impossible,
/// already sent, or should not be sent. No mapping returns 1000, 1010, or 1011.
pub fn to_close_code(err: WebSocketError) ?zslay.StatusCode {
    return switch (err) {
        // 1002 Protocol Error
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

        // 1007 Invalid Payload Data (UTF-8 encoding violation)
        error.InvalidUtf8,
        error.InvalidUTF8,
        => .invalid_payload,

        // 1009 Message Too Big
        error.FrameTooLarge,
        error.PayloadTooLarge,
        error.DecompressedPayloadTooLarge,
        => .message_too_big,

        // Handshake, transport, already-closed, backpressure, and local-buffer
        // failures: no WebSocket close frame is sent.
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

/// Returns true if the error represents an RFC 6455 wire protocol violation
/// requiring connection teardown with close code 1002 or 1007. Size failures map
/// to 1009 and are not protocol errors. The switch is exhaustive so every new
/// variant forces a classification decision.
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

/// Returns true if the error is terminal for the WebSocket connection.
/// Backpressure and caller-owned buffer failures are retryable. The switch is
/// exhaustive so every new variant forces a classification decision.
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

/// Returns true if the error represents a UTF-8 validation failure.
pub fn is_utf8_error(err: anyerror) bool {
    return err == error.InvalidUtf8 or err == error.InvalidUTF8;
}

/// Returns true if the error represents an unexpected end of stream or file.
pub fn is_eof_error(err: anyerror) bool {
    return err == error.UnexpectedEOF or err == error.UnexpectedEof or err == error.EndOfStream;
}
