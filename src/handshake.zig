//! RFC 6455 HTTP client handshake and server upgrade primitives.
//!
//! The module owns the handshake boundary from fastwebsockets 0.10.0:
//! key generation, request construction, response verification, request
//! validation, accept-token generation, and the `101 Switching Protocols`
//! reply. The HTTP request line and status line use `std.http` parsers, header
//! fields use a local bounded scanner, and all transport I/O goes through
//! caller-provided `std.Io.Reader` and
//! `std.Io.Writer` values. Nothing here allocates, opens a socket, or retains
//! state after a call. zslay remains the RFC 6455 frame codec; HTTP upgrade
//! parsing and key handling are outside its wire boundary and live here.
//!
//! The RFC 6455 accept GUID is a protocol constant, not a configurable value.
//! It is defined once as `accept_guid` and hashed incrementally with the client
//! key, so no caller buffer must be sized for the concatenation and no error
//! path can silently return an empty token.
//!
//! Returned request and response values borrow the caller's header buffer until
//! the next read on that buffer. Extra bytes after the header stay buffered in
//! the `std.Io.Reader`, so a server that coalesces the 101 response with the
//! first WebSocket frame does not lose frame bytes.
//!
//! RFC 7692 permessage-deflate and RFC 8441 extended CONNECT are deliberately
//! deferred. Compression cannot be enabled until zslay supports negotiated
//! RSV1, and extended CONNECT is an HTTP/2 path that tachyon does not yet own.

const std = @import("std");
const errors = @import("error.zig");

/// Handshake failures use the shared fastwebsockets error taxonomy.
pub const Error = errors.WebSocketError;

/// RFC 6455 Section 1.3 GUID used to derive `Sec-WebSocket-Accept`.
///
/// The value is fixed by the protocol. Keeping it in one named constant with a
/// streaming hash replaces the previous local `websocket_magic` concatenation
/// buffer; it is never negotiated, overridden, or formatted by callers.
pub const accept_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// Decoded client key length required by RFC 6455 Section 4.1.
pub const key_len = 16;

/// Canonical base64 length of a 16-byte client key.
pub const encoded_key_len = 24;

/// Base64 length of a SHA-1 accept token.
pub const accept_token_len = 28;

/// Maximum header fields accepted in one handshake head.
pub const max_header_count = 128;

/// Raw client key bytes.
pub const KeyBytes = [key_len]u8;

/// Caller-owned storage for the base64-encoded client key.
pub const KeyBuffer = [encoded_key_len]u8;

/// Caller-owned storage for the base64-encoded accept token.
pub const AcceptTokenBuffer = [accept_token_len]u8;

comptime {
    std.debug.assert(std.base64.standard.Encoder.calcSize(key_len) == encoded_key_len);
    std.debug.assert(std.base64.standard.Encoder.calcSize(std.crypto.hash.Sha1.digest_length) == accept_token_len);
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
};

/// Validated upgrade request. Both slices borrow the caller's header buffer.
pub const Request = struct {
    /// Canonical base64 `Sec-WebSocket-Key` value.
    key: []const u8,
    /// Complete request head including the final blank line.
    head: []const u8,
};

/// Validated handshake response. Both slices borrow the caller's header buffer.
pub const Response = struct {
    /// HTTP status, always 101 on success.
    status: u16,
    /// Validated `Sec-WebSocket-Accept` value.
    accept: []const u8,
    /// Complete response head including the final blank line.
    head: []const u8,
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
/// HTTP optional whitespace around the field value is ignored. The caller must
/// pass the same trimmed slice to `compute_accept_token` if it hashes a key
/// outside `validate_request` or `write_response`.
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
/// The SHA-1 input is `client_key` followed by the RFC 6455 GUID. Hashing the
/// two pieces incrementally avoids a fixed concatenation buffer and makes the
/// output length independent of the caller's key length.
pub fn compute_accept_token(client_key: []const u8, out_buffer: *AcceptTokenBuffer) []const u8 {
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(trim_ows(client_key));
    hasher.update(accept_guid);

    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    hasher.final(&digest);
    return std.base64.standard.Encoder.encode(out_buffer, &digest);
}

/// Reads one HTTP head from `reader` into caller-owned storage.
///
/// The returned slice includes the final empty line. Reading stops exactly
/// after that line, so bytes that follow the header remain buffered in
/// `reader` for the WebSocket frame path. The scan is chunked, so a header is
/// bounded by `storage`, not by the transport reader's internal buffer.
/// `storage` must not overlap the reader's internal buffer.
pub fn read_head(reader: *std.Io.Reader, storage: []u8) Error![]const u8 {
    if (storage.len < 4) return error.BufferTooShort;
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
/// `Upgrade` and `Upgrade` for `websocket`, including comma-separated lists.
/// It intentionally does not validate the key, version, method, or target;
/// call `validate_request` before upgrading.
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

    if (fields.version_count == 0) return error.InvalidSecWebsocketVersion;
    if (fields.version_count != 1) return error.InvalidSecWebsocketVersion;
    if (!std.mem.eql(u8, fields.version.?, "13")) return error.InvalidSecWebsocketVersion;

    if (fields.key_count == 0) return error.MissingSecWebSocketKey;
    if (fields.key_count != 1) return error.InvalidHttpRequest;
    if (!valid_client_key(fields.key.?)) return error.InvalidHttpRequest;

    return .{ .key = fields.key.?, .head = head };
}

/// Reads and validates one server-side upgrade request.
pub fn read_request(reader: *std.Io.Reader, storage: []u8) Error!Request {
    const head = try read_head(reader, storage);
    return validate_request(head);
}

/// Validates an HTTP response against the expected accept token.
///
/// `status_out` always receives the parsed status, including a rejection, the
/// same convention as `errors.invalid_status_code`. The accept check is
/// deliberate hardening beyond fastwebsockets 0.10.0, which does not verify it.
pub fn validate_response(
    head: []const u8,
    expected_accept: []const u8,
    status_out: *u16,
) Error!Response {
    if (!valid_head_bytes(head)) return error.InvalidHttpRequest;
    const parsed = std.http.Client.Response.Head.parse(head) catch return error.InvalidHttpRequest;
    status_out.* = @as(u16, @backingInt(parsed.status));

    if (parsed.version != .@"HTTP/1.1") return error.InvalidHttpRequest;
    if (parsed.status != .switching_protocols) {
        return errors.invalid_status_code(status_out.*, status_out);
    }
    if (expected_accept.len != accept_token_len) return error.InvalidSecWebSocketAccept;

    const fields = scan_response_headers(head) orelse return error.InvalidHttpRequest;
    if (fields.has_body_header) return error.InvalidHttpRequest;
    if (fields.extension_count != 0) return error.InvalidHttpRequest;
    if (fields.protocol_count != 0) return error.InvalidHttpRequest;
    if (fields.connection_close) return error.InvalidConnectionHeader;
    if (!fields.upgrade_websocket) return error.InvalidUpgradeHeader;
    if (!fields.connection_upgrade) return error.InvalidConnectionHeader;
    if (fields.accept_count != 1) return error.InvalidSecWebSocketAccept;
    if (!std.mem.eql(u8, fields.accept.?, expected_accept)) return error.InvalidSecWebSocketAccept;

    return .{ .status = status_out.*, .accept = fields.accept.?, .head = head };
}

/// Reads and validates one client-side handshake response.
pub fn read_response(
    reader: *std.Io.Reader,
    storage: []u8,
    expected_accept: []const u8,
    status_out: *u16,
) Error!Response {
    const head = try read_head(reader, storage);
    return validate_response(head, expected_accept, status_out);
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

    writer.print("GET {s} HTTP/1.1\r\n", .{options.target}) catch |err| return errors.from_writer(err);
    writer.print("Host: {s}\r\n", .{options.host}) catch |err| return errors.from_writer(err);
    writer.writeAll("Upgrade: websocket\r\n") catch |err| return errors.from_writer(err);
    writer.writeAll("Connection: Upgrade\r\n") catch |err| return errors.from_writer(err);
    writer.print("Sec-WebSocket-Key: {s}\r\n", .{key}) catch |err| return errors.from_writer(err);
    writer.writeAll("Sec-WebSocket-Version: 13\r\n") catch |err| return errors.from_writer(err);

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
/// upgraded transport. The accept token is computed here so a server cannot
/// pair a validated key with an unrelated token.
pub fn write_response(writer: *std.Io.Writer, client_key: []const u8) Error!void {
    if (!valid_client_key(client_key)) return error.InvalidHttpRequest;

    var accept_buffer: AcceptTokenBuffer = undefined;
    const accept = compute_accept_token(client_key, &accept_buffer);

    writer.writeAll("HTTP/1.1 101 Switching Protocols\r\n") catch |err| return errors.from_writer(err);
    writer.writeAll("Upgrade: websocket\r\n") catch |err| return errors.from_writer(err);
    writer.writeAll("Connection: Upgrade\r\n") catch |err| return errors.from_writer(err);
    writer.print("Sec-WebSocket-Accept: {s}\r\n", .{accept}) catch |err| return errors.from_writer(err);
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
    return read_response(reader, head_storage, expected_accept, status_out);
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
};

const ResponseFields = struct {
    connection_upgrade: bool = false,
    connection_close: bool = false,
    upgrade_websocket: bool = false,
    has_body_header: bool = false,
    accept: ?[]const u8 = null,
    accept_count: usize = 0,
    extension_count: usize = 0,
    protocol_count: usize = 0,
};

fn scan_request_headers(head: []const u8) ?RequestFields {
    var fields = RequestFields{};
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next() orelse return null;

    var header_count: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) return fields;
        if (line[0] == ' ' or line[0] == '\t') return null;
        header_count += 1;
        if (header_count > max_header_count) return null;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
        const name = line[0..colon];
        if (!valid_header_name(name)) return null;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");

        if (std.ascii.eqlIgnoreCase(name, "connection")) {
            fields.connection_upgrade = fields.connection_upgrade or has_token(value, "upgrade");
            fields.connection_close = fields.connection_close or has_token(value, "close");
        } else if (std.ascii.eqlIgnoreCase(name, "upgrade")) {
            fields.upgrade_websocket = fields.upgrade_websocket or has_token(value, "websocket");
        } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-version")) {
            fields.version_count += 1;
            if (fields.version_count == 1) fields.version = value;
        } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-key")) {
            fields.key_count += 1;
            if (fields.key_count == 1) fields.key = value;
        } else if (std.ascii.eqlIgnoreCase(name, "host")) {
            fields.host_count += 1;
            if (fields.host_count == 1) fields.host = value;
        } else if (std.ascii.eqlIgnoreCase(name, "content-length") or
            std.ascii.eqlIgnoreCase(name, "transfer-encoding") or
            std.ascii.eqlIgnoreCase(name, "expect"))
        {
            fields.has_body_header = true;
        }
    }
    return null;
}

fn scan_response_headers(head: []const u8) ?ResponseFields {
    var fields = ResponseFields{};
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next() orelse return null;

    var header_count: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) return fields;
        if (line[0] == ' ' or line[0] == '\t') return null;
        header_count += 1;
        if (header_count > max_header_count) return null;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
        const name = line[0..colon];
        if (!valid_header_name(name)) return null;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");

        if (std.ascii.eqlIgnoreCase(name, "connection")) {
            fields.connection_upgrade = fields.connection_upgrade or has_token(value, "upgrade");
            fields.connection_close = fields.connection_close or has_token(value, "close");
        } else if (std.ascii.eqlIgnoreCase(name, "upgrade")) {
            fields.upgrade_websocket = fields.upgrade_websocket or has_token(value, "websocket");
        } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-accept")) {
            fields.accept_count += 1;
            if (fields.accept_count == 1) fields.accept = value;
        } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-protocol")) {
            fields.protocol_count += 1;
        } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-extensions")) {
            fields.extension_count += 1;
        } else if (std.ascii.eqlIgnoreCase(name, "content-length") or
            std.ascii.eqlIgnoreCase(name, "transfer-encoding"))
        {
            fields.has_body_header = true;
        }
    }
    return null;
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
