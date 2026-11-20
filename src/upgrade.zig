//! RFC 6455 server-side HTTP upgrade orchestration.
//!
//! This module owns the RFC 6455 accept GUID and the accept-token derivation.
//! `src/handshake.zig` re-exports that single definition for the client path, so
//! the magic value and its streaming SHA-1 plus base64 construction exist in
//! exactly one place.
//!
//! `incoming` reads and strictly validates a request without writing anything.
//! `IncomingUpgrade.upgrade` and the one-shot `upgrade` then construct the
//! server split pair with `split.after_handshake_split` on a copy of the config
//! with the server role forced; that construction validates caller storage and
//! configuration without performing I/O. Only then do they write the `101
//! Switching Protocols` response through `handshake.write_response` and flush
//! the writer. A response is never written before validation and split storage
//! construction succeed, and bytes after the request head stay buffered in the
//! reader for the frame path.
//!
//! `upgrade_async` runs the same call order through `std.Io.async`. The future
//! borrows every pointer and buffer it is given, and the resolved `Upgrade`
//! keeps borrowing them, so callers must await or cancel the future before
//! releasing the reader, writer, head storage, split storage, or request view.
//! On success, awaiting it resolves only after the 101 response has been
//! flushed. Nothing here allocates or opens a socket, and no task is opened
//! outside the caller-provided `std.Io`. The module never logs.

const std = @import("std");
const errors = @import("error.zig");
const handshake = @import("handshake.zig");
const split = @import("split.zig");

/// Server upgrade failures use the shared fastwebsockets error taxonomy.
pub const Error = errors.WebSocketError;

/// RFC 6455 Section 1.3 GUID used to derive `Sec-WebSocket-Accept`.
///
/// The value is required by RFC 6455 and cannot be removed. It is defined once
/// here, in the server upgrade module, and re-exported by `src/handshake.zig`;
/// it is never negotiated or overridden. Keeping it in one named constant with
/// a streaming hash avoids a local concatenation buffer.
pub const accept_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// Base64 length of a SHA-1 accept token.
pub const accept_token_len = 28;

/// Caller-owned storage for the base64-encoded accept token.
pub const AcceptTokenBuffer = [accept_token_len]u8;

comptime {
    std.debug.assert(std.base64.standard.Encoder.calcSize(std.crypto.hash.Sha1.digest_length) == accept_token_len);
}

/// Writes the `Sec-WebSocket-Accept` token and returns a slice into `out_buffer`.
///
/// The SHA-1 input is the optional-whitespace-trimmed `client_key` followed by
/// the RFC 6455 GUID. Hashing the two pieces incrementally avoids a fixed
/// concatenation buffer and makes the output length independent of the caller's
/// key length.
pub fn compute_accept_token(client_key: []const u8, out_buffer: *AcceptTokenBuffer) []const u8 {
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(std.mem.trim(u8, client_key, " \t"));
    hasher.update(accept_guid);

    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    hasher.final(&digest);
    return std.base64.standard.Encoder.encode(out_buffer, &digest);
}

/// fastwebsockets name for the token-only upgrade probe.
///
/// It checks the `Connection` and `Upgrade` token lists but does not validate
/// the key, version, method, or target; use `incoming` or
/// `handshake.validate_request` before writing a 101 response.
pub const is_upgrade_request = handshake.is_request;

/// Validated request plus the split WebSocket halves after the 101 is flushed.
pub const Upgrade = struct {
    /// Request view borrowed from the caller's header storage.
    request: handshake.Request,
    /// Server-role split pair over the same reader and writer.
    websocket: split.Split,
};

/// Asynchronous result of `upgrade_async`.
pub const UpgradeFut = std.Io.Future(Error!Upgrade);

/// Validated upgrade request whose 101 response has not yet been written.
///
/// `incoming` builds this value, so the caller can route on a validated request
/// before committing to the response. The borrowed request view stays valid
/// while the caller's header storage is unchanged.
pub const IncomingUpgrade = struct {
    /// Request view borrowed from the caller's header storage.
    request: handshake.Request,

    /// Builds the server split pair, then writes and flushes the 101 response.
    ///
    /// The request was validated by `incoming`, so a malformed or truncated
    /// head never reaches the writer. `config.role` is forced to `.server` on a
    /// copy, so a caller cannot accidentally build a client-role pair for a
    /// server response. The split is constructed first because
    /// `split.after_handshake_split` validates caller storage without I/O; an
    /// invalid `write_buffer`, `close_buffer`, `tx_nodes`, or overlapping
    /// region therefore fails before any response byte is written.
    /// `write_response` re-validates the key so a response cannot pair a
    /// non-canonical key with a token. A failed write or flush discards the
    /// already-constructed split, which owns no allocation.
    pub fn upgrade(
        self: IncomingUpgrade,
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
        storage: split.Storage,
        config: split.Config,
    ) Error!Upgrade {
        var server_config = config;
        server_config.role = .server;
        const websocket = try split.after_handshake_split(reader, writer, storage, server_config);

        try handshake.write_response(writer, self.request.key);
        writer.flush() catch |err| return errors.from_writer(err);

        return .{ .request = self.request, .websocket = websocket };
    }
};

/// Reads and strictly validates one server upgrade request without replying.
///
/// Validation requires GET over HTTP/1.1, both upgrade token lists, exactly one
/// `Sec-WebSocket-Version: 13`, and exactly one canonical base64
/// `Sec-WebSocket-Key`. Malformed or merely upgrade-looking requests fail with
/// a typed error and leave the writer untouched. Bytes after the head stay
/// buffered in `reader` for the frame path.
pub fn incoming(reader: *std.Io.Reader, head_storage: []u8) Error!IncomingUpgrade {
    const request = try handshake.read_request(reader, head_storage);
    return .{ .request = request };
}

/// Reads, validates, splits, answers, and returns one server upgrade.
///
/// The request is read and strictly validated, then the split pair is
/// constructed from the caller-owned storage, before any response byte is
/// written. The 101 response is written through `handshake.write_response` and
/// flushed, so the caller can immediately use the returned split pair for
/// frames. The request view borrows `head_storage`; all storage stays
/// caller-owned.
pub fn upgrade(
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    head_storage: []u8,
    storage: split.Storage,
    config: split.Config,
) Error!Upgrade {
    const incoming_upgrade = try incoming(reader, head_storage);
    return incoming_upgrade.upgrade(reader, writer, storage, config);
}

/// Runs `upgrade` through the caller's `std.Io` and returns its future.
///
/// Every pointer and buffer passed here is borrowed and must outlive the
/// returned future, including the resolved `Upgrade`, which keeps borrowing the
/// reader, writer, head storage, split storage, and request view. Callers must
/// await or cancel the future before releasing any of them. On success,
/// awaiting the future resolves only after the 101 response has been flushed;
/// validation and storage failures happen before any response byte is written.
/// The future is not started on a separate thread by tachyon; concurrency
/// belongs entirely to `io`.
pub fn upgrade_async(
    io: std.Io,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    head_storage: []u8,
    storage: split.Storage,
    config: split.Config,
) UpgradeFut {
    return std.Io.async(io, upgrade, .{ reader, writer, head_storage, storage, config });
}
