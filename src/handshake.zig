//! RFC 6455 HTTP client handshake and shared server upgrade primitives.
//!
//! The module owns the handshake boundary from fastwebsockets 0.10.0:
//! key generation, request construction, response verification, request
//! validation, and the `101 Switching Protocols` reply. The HTTP request line
//! and status line use `std.http` parsers, header fields use a local bounded
//! scanner, and all transport I/O goes through caller-provided
//! `std.Io.Reader` and `std.Io.Writer` values. Nothing here allocates, opens a
//! socket, or retains state after a call. zslay remains the RFC 6455 frame
//! codec; HTTP upgrade parsing and key handling are outside its wire boundary
//! and live here.
//!
//! The RFC 6455 accept GUID and the accept-token derivation are owned by
//! `src/upgrade.zig`. This module re-exports `accept_guid`, `accept_token_len`,
//! `AcceptTokenBuffer`, and `compute_accept_token` so the client path and
//! existing callers share that single definition without duplicating the magic
//! value or the streaming SHA-1 construction.
//!
//! Returned request and response values borrow the caller's header buffer until
//! the next read on that buffer. Extra bytes after the header stay buffered in
//! the `std.Io.Reader`, so a server that coalesces the 101 response with the
//! first WebSocket frame does not lose frame bytes.
//!
//! RFC 7692 permessage-deflate negotiation is supported for the documented
//! parameter subset: window bits 8..15, both no-context-takeover flags, and
//! exact response verification. The default no-extension request, response,
//! and verify paths remain strict. RFC 8441 extended CONNECT remains deferred
//! because it is an HTTP/2 path that tachyon does not yet own.

const std = @import("std");
const errors = @import("error.zig");
const upgrade = @import("upgrade.zig");

/// Handshake failures use the shared fastwebsockets error taxonomy.
pub const Error = errors.WebSocketError;

/// RFC 6455 Section 1.3 accept GUID, owned by `src/upgrade.zig`.
pub const accept_guid = upgrade.accept_guid;

/// Decoded client key length required by RFC 6455 Section 4.1.
pub const key_len = 16;

/// Canonical base64 length of a 16-byte client key.
pub const encoded_key_len = 24;

/// Base64 length of a SHA-1 accept token, owned by `src/upgrade.zig`.
pub const accept_token_len = upgrade.accept_token_len;

/// Maximum header fields accepted in one handshake head.
pub const max_header_count = 128;

/// Raw client key bytes.
pub const KeyBytes = [key_len]u8;

/// Caller-owned storage for the base64-encoded client key.
pub const KeyBuffer = [encoded_key_len]u8;

/// Caller-owned storage for the base64-encoded accept token.
pub const AcceptTokenBuffer = upgrade.AcceptTokenBuffer;

/// RFC 7692 permessage-deflate parameters.
///
/// `server_max_window_bits` is the server-to-client compressor window and
/// `client_max_window_bits` is the client-to-server compressor window. A zero
/// window field means the parameter is absent; nonzero values are 8..15.
/// `server_no_context_takeover` disables the server compressor history and
/// `client_no_context_takeover` disables the client compressor history.
pub const PerMessageDeflate = struct {
    server_no_context_takeover: bool = false,
    client_no_context_takeover: bool = false,
    server_max_window_bits: u4 = 0,
    client_max_window_bits: u4 = 0,

    pub fn effective_server_window_bits(self: PerMessageDeflate) u4 {
        return if (self.server_max_window_bits == 0) 15 else self.server_max_window_bits;
    }

    pub fn effective_client_window_bits(self: PerMessageDeflate) u4 {
        return if (self.client_max_window_bits == 0) 15 else self.client_max_window_bits;
    }
};

/// Bounded list of permessage-deflate offers from one request.
pub const max_permessage_deflate_offers = 4;

pub const ExtensionOffers = struct {
    offers: [max_permessage_deflate_offers]PerMessageDeflate = @splat(.{}),
    count: usize = 0,

    pub fn slice(self: *const ExtensionOffers) []const PerMessageDeflate {
        return self.offers[0..self.count];
    }

    pub fn first(self: *const ExtensionOffers) ?PerMessageDeflate {
        if (self.count == 0) return null;
        return self.offers[0];
    }
};

/// Negotiated or offered WebSocket extensions.
pub const Extensions = struct {
    permessage_deflate: ?PerMessageDeflate = null,
};

/// Server-side upper bounds used when selecting a permessage-deflate response.
pub const ExtensionLimits = struct {
    server_no_context_takeover: bool = true,
    client_no_context_takeover: bool = true,
    server_max_window_bits: u4 = 15,
    client_max_window_bits: u4 = 15,
};

comptime {
    std.debug.assert(std.base64.standard.Encoder.calcSize(key_len) == encoded_key_len);
}

/// Client request fields. `key` is null until `client` generates one, or may be
/// set directly with `client_with_key` and `write_request` for a deterministic
/// key source.
pub const ClientOptions = struct {
    /// Value written to the `Host` header, including an optional port.
    host: []const u8,
    /// Origin-form request target. Must start with `/`.
    target: []const u8 = "/",
    /// Canonical base64 client key, or null to generate one in `client`.
    key: ?[]const u8 = null,
    /// Optional `Origin` header value.
    origin: ?[]const u8 = null,
    /// Extension offer; empty means no `Sec-WebSocket-Extensions` header.
    extensions: Extensions = .{},
};

/// Validated upgrade request. Both slices borrow the caller's header buffer.
pub const Request = struct {
    /// Canonical base64 `Sec-WebSocket-Key` value.
    key: []const u8,
    /// Complete request head including the final blank line.
    head: []const u8,
    /// All bounded permessage-deflate offers in request order.
    offers: ExtensionOffers = .{},
    /// First parsed offer, retained for source compatibility.
    extensions: Extensions = .{},
};

/// Validated handshake response. Both slices borrow the caller's header buffer.
pub const Response = struct {
    /// HTTP status, always 101 on success.
    status: u16,
    /// Validated `Sec-WebSocket-Accept` value.
    accept: []const u8,
    /// Complete response head including the final blank line.
    head: []const u8,
    /// Parsed extension response, if any.
    extensions: Extensions = .{},
};

/// Reports whether a comma-delimited field contains `expected`.
///
/// HTTP token matching is case-insensitive and ignores optional whitespace
/// around each token. A substring does not match.
pub fn has_token(value: []const u8, expected: []const u8) bool {
    if (expected.len == 0) return false;

    var tokens = std.mem.splitScalar(u8, value, ',');
    while (tokens.next()) |token| {
        const trimmed = std.mem.trim(u8, token, " \t");
        if (std.ascii.eqlIgnoreCase(trimmed, expected)) return true;
    }
    return false;
}

/// Parses a `Sec-WebSocket-Extensions` offer value without allocating.
///
/// Only `permessage-deflate` and its four parameters are represented. Multiple
/// permessage-deflate offers are allowed for compatibility; use
/// `parse_extension_offers` to retain all of them. Unknown extension offers are
/// ignored so callers can decline them; malformed or out-of-range
/// permessage-deflate parameters fail closed.
pub fn parse_extensions(value: []const u8) Error!Extensions {
    const offers = try parse_extension_offers(value);
    const first = offers.first() orelse return .{};
    return .{ .permessage_deflate = first };
}

/// Parses every permessage-deflate offer in one header value.
pub fn parse_extension_offers(value: []const u8) Error!ExtensionOffers {
    if (trim_ows(value).len == 0) return .{};

    var result = ExtensionOffers{};
    var segments = std.mem.splitScalar(u8, value, ',');
    while (segments.next()) |raw_segment| {
        const segment = trim_ows(raw_segment);
        if (segment.len == 0) return error.InvalidHttpRequest;

        const semi = std.mem.indexOfScalar(u8, segment, ';');
        const name = trim_ows(segment[0 .. semi orelse segment.len]);
        if (name.len == 0) return error.InvalidHttpRequest;
        if (!std.ascii.eqlIgnoreCase(name, "permessage-deflate")) continue;

        if (result.count == max_permessage_deflate_offers) return error.InvalidHttpRequest;
        result.offers[result.count] = try parsePerMessageDeflate(segment, .offer);
        result.count += 1;
    }
    return result;
}

/// Parses a single server permessage-deflate response value.
///
/// Unknown extensions, duplicate extensions, and valueless
/// `client_max_window_bits` are rejected.
pub fn parse_response_extensions(value: []const u8) Error!Extensions {
    if (trim_ows(value).len == 0) return error.InvalidHttpRequest;

    var result: ?PerMessageDeflate = null;
    var segments = std.mem.splitScalar(u8, value, ',');
    while (segments.next()) |raw_segment| {
        const segment = trim_ows(raw_segment);
        if (segment.len == 0) return error.InvalidHttpRequest;

        const semi = std.mem.indexOfScalar(u8, segment, ';');
        const name = trim_ows(segment[0 .. semi orelse segment.len]);
        if (name.len == 0 or !std.ascii.eqlIgnoreCase(name, "permessage-deflate")) {
            return error.InvalidHttpRequest;
        }
        if (result != null) return error.InvalidHttpRequest;
        result = try parsePerMessageDeflate(segment, .response);
    }
    return .{ .permessage_deflate = result };
}

/// Writes one canonical `Sec-WebSocket-Extensions` line, including CRLF.
///
/// Writes nothing when `extensions` is empty. A window parameter is written only
/// when its field is nonzero; zero means the parameter is absent. The writer is
/// not flushed.
pub fn write_extensions(writer: *std.Io.Writer, extensions: Extensions) Error!void {
    const pmd = extensions.permessage_deflate orelse return;
    try validatePerMessageDeflate(pmd);

    writer.writeAll("Sec-WebSocket-Extensions: permessage-deflate") catch |err| return errors.from_writer(err);
    if (pmd.server_no_context_takeover) {
        writer.writeAll("; server_no_context_takeover") catch |err| return errors.from_writer(err);
    }
    if (pmd.client_no_context_takeover) {
        writer.writeAll("; client_no_context_takeover") catch |err| return errors.from_writer(err);
    }
    if (pmd.server_max_window_bits != 0) {
        writer.print("; server_max_window_bits={d}", .{pmd.server_max_window_bits}) catch |err|
            return errors.from_writer(err);
    }
    if (pmd.client_max_window_bits != 0) {
        writer.print("; client_max_window_bits={d}", .{pmd.client_max_window_bits}) catch |err|
            return errors.from_writer(err);
    }
    writer.writeAll("\r\n") catch |err| return errors.from_writer(err);
}

/// Selects a permessage-deflate response from one offer.
///
/// Only parameters present in the offer are returned. If an offered window
/// exceeds the server limit, the extension is declined instead of silently
/// lowering an unsolicited value. The no-context flags may be declined.
pub fn select_permessage_deflate(offer: Extensions, limits: ExtensionLimits) Error!Extensions {
    const offered = offer.permessage_deflate orelse return .{};
    try validatePerMessageDeflate(offered);
    try validateExtensionLimits(limits);

    if (offered.effective_server_window_bits() > limits.server_max_window_bits) return .{};
    if (offered.effective_client_window_bits() > limits.client_max_window_bits) return .{};

    return .{ .permessage_deflate = .{
        .server_no_context_takeover = offered.server_no_context_takeover and limits.server_no_context_takeover,
        .client_no_context_takeover = offered.client_no_context_takeover and limits.client_no_context_takeover,
        .server_max_window_bits = offered.server_max_window_bits,
        .client_max_window_bits = offered.client_max_window_bits,
    } };
}

/// Selects the first offered permessage-deflate configuration supported by
/// `limits`. Returns an empty selection when no offer is supported.
pub fn select_permessage_deflate_offers(
    offers: ExtensionOffers,
    limits: ExtensionLimits,
) Error!Extensions {
    for (offers.slice()) |pmd| {
        const selected = try select_permessage_deflate(.{ .permessage_deflate = pmd }, limits);
        if (selected.permessage_deflate != null) return selected;
    }
    return .{};
}

const ParseMode = enum { offer, response };

fn parsePerMessageDeflate(segment: []const u8, mode: ParseMode) Error!PerMessageDeflate {
    var params = std.mem.splitScalar(u8, segment, ';');
    const name = trim_ows(params.next() orelse return error.InvalidHttpRequest);
    if (!std.ascii.eqlIgnoreCase(name, "permessage-deflate")) return error.InvalidHttpRequest;

    var pmd = PerMessageDeflate{};
    var seen_server_no_context = false;
    var seen_client_no_context = false;
    var seen_server_window = false;
    var seen_client_window = false;

    while (params.next()) |raw_param| {
        const param = trim_ows(raw_param);
        if (param.len == 0) return error.InvalidHttpRequest;

        const equals = std.mem.indexOfScalar(u8, param, '=');
        const param_name = trim_ows(param[0 .. equals orelse param.len]);
        const param_value: ?[]const u8 = if (equals) |index| trim_ows(param[index + 1 ..]) else null;
        if (param_name.len == 0) return error.InvalidHttpRequest;
        if (param_value != null and param_value.?.len == 0) return error.InvalidHttpRequest;

        if (std.ascii.eqlIgnoreCase(param_name, "server_no_context_takeover")) {
            if (seen_server_no_context or param_value != null) return error.InvalidHttpRequest;
            seen_server_no_context = true;
            pmd.server_no_context_takeover = true;
        } else if (std.ascii.eqlIgnoreCase(param_name, "client_no_context_takeover")) {
            if (seen_client_no_context or param_value != null) return error.InvalidHttpRequest;
            seen_client_no_context = true;
            pmd.client_no_context_takeover = true;
        } else if (std.ascii.eqlIgnoreCase(param_name, "server_max_window_bits")) {
            if (seen_server_window) return error.InvalidHttpRequest;
            seen_server_window = true;
            pmd.server_max_window_bits = try parseWindowBits(param_value orelse return error.InvalidHttpRequest);
        } else if (std.ascii.eqlIgnoreCase(param_name, "client_max_window_bits")) {
            if (seen_client_window) return error.InvalidHttpRequest;
            seen_client_window = true;
            if (param_value) |raw_value| {
                pmd.client_max_window_bits = try parseWindowBits(raw_value);
            } else {
                // A valueless offer permits the server to choose; 15 is the
                // maximal concrete window and keeps presence distinct from 0.
                if (mode == .response) return error.InvalidHttpRequest;
                pmd.client_max_window_bits = 15;
            }
        } else {
            return error.InvalidHttpRequest;
        }
    }
    return pmd;
}

fn parseWindowBits(raw_value: []const u8) Error!u4 {
    const value = trim_ows(raw_value);
    const unquoted = if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"')
        value[1 .. value.len - 1]
    else
        value;
    if (unquoted.len == 0) return error.InvalidHttpRequest;

    const bits = std.fmt.parseInt(u4, unquoted, 10) catch return error.InvalidHttpRequest;
    if (bits < 8 or bits > 15) return error.InvalidHttpRequest;
    return bits;
}

fn validatePerMessageDeflate(pmd: PerMessageDeflate) Error!void {
    if (pmd.server_max_window_bits != 0 and
        (pmd.server_max_window_bits < 8 or pmd.server_max_window_bits > 15)) return error.InvalidHttpRequest;
    if (pmd.client_max_window_bits != 0 and
        (pmd.client_max_window_bits < 8 or pmd.client_max_window_bits > 15)) return error.InvalidHttpRequest;
}

fn validateExtensionLimits(limits: ExtensionLimits) Error!void {
    if (limits.server_max_window_bits < 8 or limits.server_max_window_bits > 15) return error.InvalidHttpRequest;
    if (limits.client_max_window_bits < 8 or limits.client_max_window_bits > 15) return error.InvalidHttpRequest;
}

fn extensionResponseAllowed(offer: Extensions, response: Extensions) bool {
    const offered = offer.permessage_deflate orelse return response.permessage_deflate == null;
    const selected = response.permessage_deflate orelse return true;

    if (selected.server_no_context_takeover and !offered.server_no_context_takeover) return false;
    if (selected.client_no_context_takeover and !offered.client_no_context_takeover) return false;

    if (selected.server_max_window_bits != 0) {
        if (offered.server_max_window_bits == 0) return false;
        if (selected.server_max_window_bits > offered.server_max_window_bits) return false;
    }
    if (selected.client_max_window_bits != 0) {
        if (offered.client_max_window_bits == 0) return false;
        if (selected.client_max_window_bits > offered.client_max_window_bits) return false;
    }
    return true;
}

fn mergeExtensions(target: *Extensions, more: Extensions) Error!void {
    if (more.permessage_deflate) |pmd| {
        if (target.permessage_deflate != null) return error.InvalidHttpRequest;
        target.permessage_deflate = pmd;
    }
}

fn appendExtensionOffers(target: *ExtensionOffers, more: ExtensionOffers) Error!void {
    if (target.count + more.count > max_permessage_deflate_offers) return error.InvalidHttpRequest;
    for (more.slice()) |offer| {
        target.offers[target.count] = offer;
        target.count += 1;
    }
}

/// Generates a fresh 16-byte key and returns its canonical base64 encoding.
///
/// Entropy comes from the caller's `std.Io` implementation. The secure source
/// makes a syscall (or equivalent) instead of relying on process RNG state, so
/// a handshake key is never derived from a deterministic test seed unless the
/// caller explicitly uses `client_with_key`.
pub fn generate_key(io: std.Io, out_buffer: *KeyBuffer) Error![]const u8 {
    var key: KeyBytes = undefined;
    std.Io.randomSecure(io, &key) catch return error.IoError;
    return encode_key(key, out_buffer);
}

/// Encodes raw key bytes into caller-owned base64 storage.
pub fn encode_key(key: KeyBytes, out_buffer: *KeyBuffer) []const u8 {
    return std.base64.standard.Encoder.encode(out_buffer, &key);
}

/// Reports whether a key is the canonical base64 encoding of 16 bytes.
///
/// HTTP optional whitespace around the field value is ignored.
/// `compute_accept_token` applies the same trimming, so a validated value and
/// its accept token cannot disagree about surrounding whitespace.
pub fn valid_client_key(client_key: []const u8) bool {
    const key_value = trim_ows(client_key);
    if (key_value.len != encoded_key_len) return false;

    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(key_value) catch return false;
    if (decoded_len != key_len) return false;

    var decoded: KeyBytes = undefined;
    std.base64.standard.Decoder.decode(&decoded, key_value) catch return false;

    var canonical: KeyBuffer = undefined;
    _ = encode_key(decoded, &canonical);
    return std.mem.eql(u8, key_value, &canonical);
}

/// Writes the `Sec-WebSocket-Accept` token and returns a slice into `out_buffer`.
///
/// Delegates to `src/upgrade.zig`, which owns the RFC 6455 GUID and the
/// streaming SHA-1 plus base64 construction. The delegation keeps the value
/// and derivation in one place while preserving the handshake-side name.
pub const compute_accept_token = upgrade.compute_accept_token;

/// Reads one HTTP head from `reader` into caller-owned storage.
///
/// The returned slice includes the final empty line. Reading stops exactly
/// after that line, so bytes that follow the header remain buffered in
/// `reader` for the WebSocket frame path. The scan is chunked, so a header is
/// bounded by `storage`, not by the transport reader's internal buffer.
/// `storage` must not overlap the reader's internal buffer, and a reader with
/// no internal buffer returns `IoError`.
pub fn read_head(reader: *std.Io.Reader, storage: []u8) Error![]const u8 {
    if (storage.len < 4) return error.BufferTooShort;
    if (reader.buffer.len == 0) return error.IoError;
    if (overlaps(reader.buffer, storage)) return error.BufferTooShort;

    var len: usize = 0;
    var scan_from: usize = 0;
    while (true) {
        const buffered = reader.buffered();
        if (buffered.len == 0) {
            reader.fillMore() catch |err| return switch (err) {
                error.EndOfStream => error.UnexpectedEOF,
                error.ReadFailed => error.IoError,
            };
            continue;
        }

        const old_len = len;
        const available = storage.len - len;
        if (available == 0) return error.BufferTooShort;
        const take = @min(buffered.len, available);

        @memcpy(storage[len..][0..take], buffered[0..take]);
        len += take;

        if (std.mem.indexOfPosLinear(u8, storage[0..len], scan_from, "\r\n\r\n")) |end| {
            const head_len = end + 4;
            if (!valid_head_bytes(storage[0..head_len])) return error.InvalidHttpRequest;
            reader.toss(head_len - old_len);
            return storage[0..head_len];
        }

        const previous = if (old_len == 0) null else storage[old_len - 1];
        if (contains_bare_lf(storage[old_len..len], previous)) return error.InvalidHttpRequest;

        reader.toss(take);
        if (len == storage.len) return error.BufferTooShort;
        scan_from = if (len >= 3) len - 3 else 0;
    }
}

/// Reports whether a request head carries both RFC 6455 upgrade tokens.
///
/// This is the `is_upgrade_request` probe: it checks `Connection` for
/// `Upgrade` and `Upgrade` for `websocket`, including comma-separated lists,
/// and rejects `Connection: close`. It intentionally does not validate the key,
/// version, method, or target; call `validate_request` before upgrading.
pub fn is_request(head: []const u8) bool {
    if (!valid_head_bytes(head)) return false;
    const fields = scan_request_headers(head) orelse return false;
    return fields.connection_upgrade and fields.upgrade_websocket and !fields.connection_close;
}

/// Validates a server-side upgrade request and returns its borrowed key.
///
/// This is the strict server gate: `GET` over HTTP/1.1, unique
/// `Sec-WebSocket-Version: 13`, unique canonical `Sec-WebSocket-Key`, and both
/// upgrade tokens. It combines the fastwebsockets `upgrade` key/version checks
/// with `is_upgrade_request` so a caller cannot accidentally skip the token
/// checks before writing a 101 response.
pub fn validate_request(head: []const u8) Error!Request {
    if (!valid_head_bytes(head)) return error.InvalidHttpRequest;
    const parsed = std.http.Server.Request.Head.parse(head) catch return error.InvalidHttpRequest;
    if (parsed.method != .GET) return error.InvalidHttpRequest;
    if (parsed.version != .@"HTTP/1.1") return error.InvalidHttpRequest;
    if (!valid_target(parsed.target)) return error.InvalidHttpRequest;

    const fields = scan_request_headers(head) orelse return error.InvalidHttpRequest;
    if (fields.has_body_header) return error.InvalidHttpRequest;
    if (fields.host_count != 1 or !valid_host(fields.host.?)) return error.InvalidHttpRequest;
    if (fields.connection_close) return error.InvalidConnectionHeader;
    if (!fields.connection_upgrade) return error.InvalidConnectionHeader;
    if (!fields.upgrade_websocket) return error.InvalidUpgradeHeader;

    if (fields.key_count == 0) return error.MissingSecWebSocketKey;
    if (fields.key_count != 1) return error.InvalidHttpRequest;
    if (!valid_client_key(fields.key.?)) return error.InvalidHttpRequest;

    if (fields.version_count == 0) return error.InvalidSecWebsocketVersion;
    if (fields.version_count != 1) return error.InvalidSecWebsocketVersion;
    if (!std.mem.eql(u8, fields.version.?, "13")) return error.InvalidSecWebsocketVersion;

    const extensions: Extensions = if (fields.offers.first()) |pmd|
        .{ .permessage_deflate = pmd }
    else
        .{};
    return .{ .key = fields.key.?, .head = head, .offers = fields.offers, .extensions = extensions };
}

/// Reads and validates one server-side upgrade request.
pub fn read_request(reader: *std.Io.Reader, storage: []u8) Error!Request {
    const head = try read_head(reader, storage);
    return validate_request(head);
}

/// Verifies an HTTP response, matching the fastwebsockets `handshake::verify`
/// role with the additional `Sec-WebSocket-Accept` hardening.
///
/// For a well-formed status line, `status_out` receives the parsed status,
/// including a non-101 rejection, following `errors.invalid_status_code`.
/// A malformed status line returns `InvalidHttpRequest` without writing it.
pub fn verify(
    head: []const u8,
    expected_accept: []const u8,
    status_out: *u16,
) Error!Response {
    return verify_with_extensions(head, expected_accept, .{}, status_out);
}

/// Verifies a response against the client's extension offer.
///
/// An empty `expected_extensions` rejects every response extension, preserving
/// the strict no-extension default. A non-empty offer accepts no response
/// extension (the server declined) or a permessage-deflate response that is a
/// permitted subset: response no-context flags must be implied by the offer and
/// response window bits must be present in the offer and no larger.
pub fn verify_with_extensions(
    head: []const u8,
    expected_accept: []const u8,
    expected_extensions: Extensions,
    status_out: *u16,
) Error!Response {
    if (expected_extensions.permessage_deflate) |pmd| try validatePerMessageDeflate(pmd);
    if (!valid_head_bytes(head)) return error.InvalidHttpRequest;
    if (!valid_response_status_line(head)) return error.InvalidHttpRequest;

    const parsed = std.http.Client.Response.Head.parse(head) catch return error.InvalidHttpRequest;
    status_out.* = @as(u16, @backingInt(parsed.status));

    if (parsed.version != .@"HTTP/1.1") return error.InvalidHttpRequest;
    if (parsed.status != .switching_protocols) {
        return errors.invalid_status_code(status_out.*, status_out);
    }
    if (expected_accept.len != accept_token_len) return error.InvalidSecWebSocketAccept;

    const fields = scan_response_headers(head) orelse return error.InvalidHttpRequest;
    if (fields.has_body_header) return error.InvalidHttpRequest;
    if (expected_extensions.permessage_deflate == null) {
        if (fields.extension_count != 0) return error.InvalidHttpRequest;
    } else {
        if (fields.extension_count != 0 and
            !extensionResponseAllowed(expected_extensions, fields.extensions)) return error.InvalidHttpRequest;
    }
    if (fields.protocol_count != 0) return error.InvalidHttpRequest;
    if (fields.connection_close) return error.InvalidConnectionHeader;
    if (!fields.upgrade_websocket) return error.InvalidUpgradeHeader;
    if (!fields.connection_upgrade) return error.InvalidConnectionHeader;
    if (fields.accept_count != 1) return error.InvalidSecWebSocketAccept;
    if (!std.mem.eql(u8, fields.accept.?, expected_accept)) return error.InvalidSecWebSocketAccept;

    return .{
        .status = status_out.*,
        .accept = fields.accept.?,
        .head = head,
        .extensions = fields.extensions,
    };
}

/// Reads and verifies one client-side handshake response with extensions.
pub fn read_response_with_extensions(
    reader: *std.Io.Reader,
    storage: []u8,
    expected_accept: []const u8,
    expected_extensions: Extensions,
    status_out: *u16,
) Error!Response {
    const head = try read_head(reader, storage);
    return verify_with_extensions(head, expected_accept, expected_extensions, status_out);
}

/// Reads and verifies one client-side handshake response.
pub fn read_response(
    reader: *std.Io.Reader,
    storage: []u8,
    expected_accept: []const u8,
    status_out: *u16,
) Error!Response {
    return read_response_with_extensions(reader, storage, expected_accept, .{}, status_out);
}

/// Writes a canonical RFC 6455 client upgrade request.
///
/// The writer is not flushed; the caller controls the transport boundary, as
/// with `WebSocket.write_frame`. The key must already be canonical base64.
pub fn write_request(writer: *std.Io.Writer, options: ClientOptions) Error!void {
    const key = trim_ows(options.key orelse return error.InvalidHttpRequest);
    if (!valid_host(options.host)) return error.InvalidHttpRequest;
    if (!valid_target(options.target)) return error.InvalidHttpRequest;
    if (!valid_client_key(key)) return error.InvalidHttpRequest;
    if (!valid_optional_header(options.origin)) return error.InvalidHttpRequest;
    if (options.extensions.permessage_deflate) |pmd| try validatePerMessageDeflate(pmd);

    writer.print("GET {s} HTTP/1.1\r\n", .{options.target}) catch |err| return errors.from_writer(err);
    writer.print("Host: {s}\r\n", .{options.host}) catch |err| return errors.from_writer(err);
    writer.writeAll("Upgrade: websocket\r\n") catch |err| return errors.from_writer(err);
    writer.writeAll("Connection: Upgrade\r\n") catch |err| return errors.from_writer(err);
    writer.print("Sec-WebSocket-Key: {s}\r\n", .{key}) catch |err| return errors.from_writer(err);
    writer.writeAll("Sec-WebSocket-Version: 13\r\n") catch |err| return errors.from_writer(err);
    try write_extensions(writer, options.extensions);

    if (options.origin) |origin| {
        if (origin.len != 0) {
            writer.print("Origin: {s}\r\n", .{origin}) catch |err| return errors.from_writer(err);
        }
    }
    writer.writeAll("\r\n") catch |err| return errors.from_writer(err);
}

/// Writes the `101 Switching Protocols` reply for a validated client key.
///
/// The writer is not flushed; the caller sends the response before reading the
/// upgraded transport. The accept token is derived through the shared
/// `src/upgrade.zig` computation so a server cannot pair a validated key with
/// an unrelated token.
pub fn write_response(writer: *std.Io.Writer, client_key: []const u8) Error!void {
    return write_response_with_extensions(writer, client_key, .{});
}

/// Writes the `101 Switching Protocols` reply with an optional extension line.
///
/// The writer is not flushed. `extensions` must be a selected response, not an
/// offer; an empty value keeps the strict no-extension reply.
pub fn write_response_with_extensions(
    writer: *std.Io.Writer,
    client_key: []const u8,
    extensions: Extensions,
) Error!void {
    if (!valid_client_key(client_key)) return error.InvalidHttpRequest;
    if (extensions.permessage_deflate) |pmd| try validatePerMessageDeflate(pmd);

    var accept_buffer: AcceptTokenBuffer = undefined;
    const accept = compute_accept_token(client_key, &accept_buffer);

    writer.writeAll("HTTP/1.1 101 Switching Protocols\r\n") catch |err| return errors.from_writer(err);
    writer.writeAll("Upgrade: websocket\r\n") catch |err| return errors.from_writer(err);
    writer.writeAll("Connection: Upgrade\r\n") catch |err| return errors.from_writer(err);
    writer.print("Sec-WebSocket-Accept: {s}\r\n", .{accept}) catch |err| return errors.from_writer(err);
    try write_extensions(writer, extensions);
    writer.writeAll("\r\n") catch |err| return errors.from_writer(err);
}

/// Performs the client handshake with a caller-supplied key.
///
/// This is the deterministic counterpart to `client`: it writes the request,
/// flushes the writer, reads the response, verifies the accept token, and
/// returns the response view. It never allocates and never opens a stream.
pub fn client_with_key(
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    options: ClientOptions,
    head_storage: []u8,
    status_out: *u16,
) Error!Response {
    const key = options.key orelse return error.InvalidHttpRequest;
    try write_request(writer, options);
    writer.flush() catch |err| return errors.from_writer(err);

    var accept_buffer: AcceptTokenBuffer = undefined;
    const expected_accept = compute_accept_token(key, &accept_buffer);
    return read_response_with_extensions(reader, head_storage, expected_accept, options.extensions, status_out);
}

/// Performs the full client handshake, generating a fresh key when needed.
///
/// Set `options.key` to use a deterministic key; otherwise the caller's
/// `std.Io` secure random source supplies 16 bytes. Extra bytes after the
/// response head remain buffered in `reader` for `after_handshake_split`.
pub fn client(
    io: std.Io,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    options: ClientOptions,
    head_storage: []u8,
    status_out: *u16,
) Error!Response {
    if (options.key) |_| return client_with_key(reader, writer, options, head_storage, status_out);

    var key_buffer: KeyBuffer = undefined;
    const key = try generate_key(io, &key_buffer);

    var generated = options;
    generated.key = key;
    return client_with_key(reader, writer, generated, head_storage, status_out);
}

const RequestFields = struct {
    connection_upgrade: bool = false,
    connection_close: bool = false,
    upgrade_websocket: bool = false,
    has_body_header: bool = false,
    version: ?[]const u8 = null,
    version_count: usize = 0,
    key: ?[]const u8 = null,
    key_count: usize = 0,
    host: ?[]const u8 = null,
    host_count: usize = 0,
    offers: ExtensionOffers = .{},
    extension_count: usize = 0,
};

const ResponseFields = struct {
    connection_upgrade: bool = false,
    connection_close: bool = false,
    upgrade_websocket: bool = false,
    has_body_header: bool = false,
    accept: ?[]const u8 = null,
    accept_count: usize = 0,
    extension_count: usize = 0,
    extensions: Extensions = .{},
    protocol_count: usize = 0,
};

const HeaderLine = struct {
    name: []const u8,
    value: []const u8,
};

const HeaderScanner = struct {
    lines: std.mem.SplitIterator(u8, .sequence),
    count: usize = 0,
    failed: bool = false,

    fn init(head: []const u8) HeaderScanner {
        var lines = std.mem.splitSequence(u8, head, "\r\n");
        _ = lines.next();
        return .{ .lines = lines };
    }

    fn next(self: *HeaderScanner) ?HeaderLine {
        const line = self.lines.next() orelse {
            self.failed = true;
            return null;
        };
        if (line.len == 0) return null;
        if (line[0] == ' ' or line[0] == '\t') {
            self.failed = true;
            return null;
        }

        self.count += 1;
        if (self.count > max_header_count) {
            self.failed = true;
            return null;
        }

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse {
            self.failed = true;
            return null;
        };
        const name = line[0..colon];
        if (!valid_header_name(name)) {
            self.failed = true;
            return null;
        }

        return .{ .name = name, .value = std.mem.trim(u8, line[colon + 1 ..], " \t") };
    }
};

fn scan_request_headers(head: []const u8) ?RequestFields {
    var fields = RequestFields{};
    var headers = HeaderScanner.init(head);

    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "connection")) {
            fields.connection_upgrade = fields.connection_upgrade or has_token(header.value, "upgrade");
            fields.connection_close = fields.connection_close or has_token(header.value, "close");
        } else if (std.ascii.eqlIgnoreCase(header.name, "upgrade")) {
            fields.upgrade_websocket = fields.upgrade_websocket or has_token(header.value, "websocket");
        } else if (std.ascii.eqlIgnoreCase(header.name, "sec-websocket-version")) {
            fields.version_count += 1;
            if (fields.version_count == 1) fields.version = header.value;
        } else if (std.ascii.eqlIgnoreCase(header.name, "sec-websocket-key")) {
            fields.key_count += 1;
            if (fields.key_count == 1) fields.key = header.value;
        } else if (std.ascii.eqlIgnoreCase(header.name, "host")) {
            fields.host_count += 1;
            if (fields.host_count == 1) fields.host = header.value;
        } else if (std.ascii.eqlIgnoreCase(header.name, "sec-websocket-extensions")) {
            fields.extension_count += 1;
            const parsed = parse_extension_offers(header.value) catch {
                headers.failed = true;
                break;
            };
            appendExtensionOffers(&fields.offers, parsed) catch {
                headers.failed = true;
                break;
            };
        } else if (std.ascii.eqlIgnoreCase(header.name, "content-length") or
            std.ascii.eqlIgnoreCase(header.name, "transfer-encoding") or
            std.ascii.eqlIgnoreCase(header.name, "expect"))
        {
            fields.has_body_header = true;
        }
    }
    return if (headers.failed) null else fields;
}

fn scan_response_headers(head: []const u8) ?ResponseFields {
    var fields = ResponseFields{};
    var headers = HeaderScanner.init(head);

    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "connection")) {
            fields.connection_upgrade = fields.connection_upgrade or has_token(header.value, "upgrade");
            fields.connection_close = fields.connection_close or has_token(header.value, "close");
        } else if (std.ascii.eqlIgnoreCase(header.name, "upgrade")) {
            fields.upgrade_websocket = fields.upgrade_websocket or has_token(header.value, "websocket");
        } else if (std.ascii.eqlIgnoreCase(header.name, "sec-websocket-accept")) {
            fields.accept_count += 1;
            if (fields.accept_count == 1) fields.accept = header.value;
        } else if (std.ascii.eqlIgnoreCase(header.name, "sec-websocket-protocol")) {
            fields.protocol_count += 1;
        } else if (std.ascii.eqlIgnoreCase(header.name, "sec-websocket-extensions")) {
            fields.extension_count += 1;
            const parsed = parse_response_extensions(header.value) catch {
                headers.failed = true;
                break;
            };
            mergeExtensions(&fields.extensions, parsed) catch {
                headers.failed = true;
                break;
            };
        } else if (std.ascii.eqlIgnoreCase(header.name, "content-length") or
            std.ascii.eqlIgnoreCase(header.name, "transfer-encoding"))
        {
            fields.has_body_header = true;
        }
    }
    return if (headers.failed) null else fields;
}

fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_start = @intFromPtr(left.ptr);
    const left_end = left_start + left.len;
    const right_start = @intFromPtr(right.ptr);
    const right_end = right_start + right.len;
    return left_start < right_end and right_start < left_end;
}

fn trim_ows(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t");
}

fn contains_bare_lf(bytes: []const u8, previous: ?u8) bool {
    for (bytes, 0..) |byte, index| {
        if (byte != '\n') continue;
        const prev = if (index == 0) previous else bytes[index - 1];
        if (prev != '\r') return true;
    }
    return false;
}

fn valid_response_status_line(head: []const u8) bool {
    const line_end = std.mem.indexOf(u8, head, "\r\n") orelse return false;
    const status_line = head[0..line_end];
    if (status_line.len < 12) return false;
    if (!std.mem.eql(u8, status_line[0..9], "HTTP/1.1 ")) return false;
    if (!std.ascii.isDigit(status_line[9])) return false;
    if (!std.ascii.isDigit(status_line[10])) return false;
    if (!std.ascii.isDigit(status_line[11])) return false;
    if (status_line.len > 12 and status_line[12] != ' ') return false;
    return true;
}

fn valid_head_bytes(head: []const u8) bool {
    var index: usize = 0;
    while (index < head.len) : (index += 1) {
        const byte = head[index];
        if (byte == '\r') {
            if (index + 1 >= head.len or head[index + 1] != '\n') return false;
            index += 1;
            continue;
        }
        if (byte == '\n') return false;
        if (byte < ' ' and byte != '\t') return false;
        if (byte == 0x7f) return false;
    }
    return true;
}

fn valid_header_name(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        switch (byte) {
            '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => {},
            else => return false,
        }
    }
    return true;
}

fn valid_host(host: []const u8) bool {
    if (host.len == 0) return false;
    for (host) |byte| {
        if (byte <= ' ' or byte == 0x7f or byte == '/' or byte == '\\') return false;
    }
    return true;
}

fn valid_target(target: []const u8) bool {
    if (target.len == 0 or target[0] != '/') return false;
    for (target) |byte| {
        if (byte <= ' ' or byte == 0x7f or byte == '#') return false;
    }
    return true;
}

fn valid_optional_header(value: ?[]const u8) bool {
    const bytes = value orelse return true;
    for (bytes) |byte| {
        if (byte == '\r' or byte == '\n' or byte == 0) return false;
        if (byte < ' ' and byte != '\t') return false;
        if (byte == 0x7f) return false;
    }
    return true;
}
