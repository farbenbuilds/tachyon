const std = @import("std");
const tachyon = @import("tachyon");

const support = @import("../support.zig");

const handshake = tachyon.handshake;
const handshake_sample_key = support.handshake_sample_key;
const handshake_sample_accept = support.handshake_sample_accept;
const handshake_valid_request = support.handshake_valid_request;
const build_request_head = support.build_request_head;

test "Handshake: RFC 6455 sample key produces the published accept token" {
    var accept_buffer: handshake.AcceptTokenBuffer = undefined;
    const accept = handshake.compute_accept_token(handshake_sample_key, &accept_buffer);

    try std.testing.expectEqualStrings(handshake_sample_accept, accept);
    try std.testing.expect(handshake.valid_client_key(handshake_sample_key));
}

test "Handshake: generated keys are canonical base64 for 16 bytes" {
    var key_buffer: handshake.KeyBuffer = undefined;
    const key = try handshake.generate_key(std.testing.io, &key_buffer);

    try std.testing.expectEqual(@as(usize, 24), key.len);
    try std.testing.expect(handshake.valid_client_key(key));

    var decoded: handshake.KeyBytes = undefined;
    try std.base64.standard.Decoder.decode(&decoded, key);

    var canonical: handshake.KeyBuffer = undefined;
    try std.testing.expectEqualStrings(key, handshake.encode_key(decoded, &canonical));
}

test "Handshake: valid_client_key trims OWS and rejects invalid lengths and encodings" {
    try std.testing.expect(handshake.valid_client_key("AAAAAAAAAAAAAAAAAAAAAA=="));
    try std.testing.expect(handshake.valid_client_key(" dGhlIHNhbXBsZSBub25jZQ==\t"));

    var accept_buffer: handshake.AcceptTokenBuffer = undefined;
    const accept = handshake.compute_accept_token(" dGhlIHNhbXBsZSBub25jZQ== ", &accept_buffer);
    try std.testing.expectEqualStrings(handshake_sample_accept, accept);

    try std.testing.expect(!handshake.valid_client_key(""));
    try std.testing.expect(!handshake.valid_client_key("dGhlIHNhbXBsZSBub25jZQ="));
    try std.testing.expect(!handshake.valid_client_key("dGhlIHNhbXBsZSBub25jZR=="));
    try std.testing.expect(!handshake.valid_client_key("AAAAAAAAAAAAAAAA"));
    try std.testing.expect(!handshake.valid_client_key("!!!!!!!!!!!!!!!!!!!!!!!!"));
}

test "Handshake: has_token matches complete comma-separated tokens" {
    try std.testing.expect(handshake.has_token("keep-alive, Upgrade", "upgrade"));
    try std.testing.expect(handshake.has_token("  websocket \t", "WEBSOCKET"));
    try std.testing.expect(handshake.has_token("a, b, c", "b"));
    try std.testing.expect(!handshake.has_token("not-upgrade", "upgrade"));
    try std.testing.expect(!handshake.has_token("superupgrade", "upgrade"));
    try std.testing.expect(!handshake.has_token("", "upgrade"));
    try std.testing.expect(!handshake.has_token("a,,b", ""));
}

test "Handshake: is_request checks both upgrade token lists" {
    try std.testing.expect(handshake.is_request(handshake_valid_request));

    var buffer: [256]u8 = undefined;
    const token_lists = try build_request_head(
        &buffer,
        "GET",
        "keep-alive, Upgrade",
        "h2c, WebSocket",
        handshake_sample_key,
        "13",
    );
    try std.testing.expect(handshake.is_request(token_lists));

    const wrong_connection = try build_request_head(
        &buffer,
        "GET",
        "keep-alive",
        "websocket",
        handshake_sample_key,
        "13",
    );
    try std.testing.expect(!handshake.is_request(wrong_connection));

    const wrong_upgrade = try build_request_head(&buffer, "GET", "Upgrade", "h2c", handshake_sample_key, "13");
    try std.testing.expect(!handshake.is_request(wrong_upgrade));

    const closing = try build_request_head(
        &buffer,
        "GET",
        "Upgrade, close",
        "websocket",
        handshake_sample_key,
        "13",
    );
    try std.testing.expect(!handshake.is_request(closing));

    try std.testing.expect(!handshake.is_request("not an HTTP head"));
}

test "Handshake: validate_request returns the borrowed canonical key" {
    const request = try handshake.validate_request(handshake_valid_request);

    try std.testing.expectEqualStrings(handshake_sample_key, request.key);
    try std.testing.expectEqualStrings(handshake_valid_request, request.head);
    const key_addr = @intFromPtr(request.key.ptr);
    const head_addr = @intFromPtr(request.head.ptr);
    try std.testing.expect(key_addr >= head_addr);
    try std.testing.expect(key_addr < head_addr + request.head.len);
}

test "Handshake: validate_request rejects method, version, and token failures" {
    var buffer: [256]u8 = undefined;

    const post = try build_request_head(&buffer, "POST", "Upgrade", "websocket", handshake_sample_key, "13");
    try std.testing.expectError(error.InvalidHttpRequest, handshake.validate_request(post));

    const http_10 = "GET /chat HTTP/1.0\r\n" ++
        "Host: server.example.com\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Sec-WebSocket-Version: 13\r\n\r\n";
    try std.testing.expectError(error.InvalidHttpRequest, handshake.validate_request(http_10));

    const no_connection = try build_request_head(&buffer, "GET", null, "websocket", handshake_sample_key, "13");
    try std.testing.expectError(error.InvalidConnectionHeader, handshake.validate_request(no_connection));

    const wrong_connection = try build_request_head(
        &buffer,
        "GET",
        "keep-alive",
        "websocket",
        handshake_sample_key,
        "13",
    );
    try std.testing.expectError(error.InvalidConnectionHeader, handshake.validate_request(wrong_connection));

    const no_upgrade = try build_request_head(&buffer, "GET", "Upgrade", null, handshake_sample_key, "13");
    try std.testing.expectError(error.InvalidUpgradeHeader, handshake.validate_request(no_upgrade));

    const wrong_upgrade = try build_request_head(&buffer, "GET", "Upgrade", "h2c", handshake_sample_key, "13");
    try std.testing.expectError(error.InvalidUpgradeHeader, handshake.validate_request(wrong_upgrade));
}

test "Handshake: validate_request rejects missing, wrong, and duplicate key fields" {
    var buffer: [256]u8 = undefined;

    const no_key = try build_request_head(&buffer, "GET", "Upgrade", "websocket", null, "13");
    try std.testing.expectError(error.MissingSecWebSocketKey, handshake.validate_request(no_key));

    const no_key_or_version = try build_request_head(&buffer, "GET", "Upgrade", "websocket", null, null);
    try std.testing.expectError(error.MissingSecWebSocketKey, handshake.validate_request(no_key_or_version));

    const bad_key = try build_request_head(&buffer, "GET", "Upgrade", "websocket", "not a key", "13");
    try std.testing.expectError(error.InvalidHttpRequest, handshake.validate_request(bad_key));

    const no_version = try build_request_head(&buffer, "GET", "Upgrade", "websocket", handshake_sample_key, null);
    try std.testing.expectError(error.InvalidSecWebsocketVersion, handshake.validate_request(no_version));

    const wrong_version = try build_request_head(&buffer, "GET", "Upgrade", "websocket", handshake_sample_key, "12");
    try std.testing.expectError(error.InvalidSecWebsocketVersion, handshake.validate_request(wrong_version));

    const duplicate_key =
        "GET /chat HTTP/1.1\r\n" ++
        "Host: server.example.com\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Sec-WebSocket-Version: 13\r\n\r\n";
    try std.testing.expectError(error.InvalidHttpRequest, handshake.validate_request(duplicate_key));

    const duplicate_version =
        "GET /chat HTTP/1.1\r\n" ++
        "Host: server.example.com\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Sec-WebSocket-Version: 13\r\n" ++
        "Sec-WebSocket-Version: 13\r\n\r\n";
    try std.testing.expectError(error.InvalidSecWebsocketVersion, handshake.validate_request(duplicate_version));

    const no_host =
        "GET /chat HTTP/1.1\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Sec-WebSocket-Version: 13\r\n\r\n";
    try std.testing.expectError(error.InvalidHttpRequest, handshake.validate_request(no_host));

    const duplicate_host =
        "GET /chat HTTP/1.1\r\n" ++
        "Host: server.example.com\r\n" ++
        "Host: server.example.com\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Sec-WebSocket-Version: 13\r\n\r\n";
    try std.testing.expectError(error.InvalidHttpRequest, handshake.validate_request(duplicate_host));
}

test "Handshake: validate_request rejects excessive header counts" {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writer.writeAll(
        "GET /chat HTTP/1.1\r\n" ++
            "Host: server.example.com\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
            "Sec-WebSocket-Version: 13\r\n",
    );
    var index: usize = 0;
    while (index < handshake.max_header_count + 1) : (index += 1) {
        try writer.print("X-{d}: v\r\n", .{index});
    }
    try writer.writeAll("\r\n");
    try std.testing.expectError(error.InvalidHttpRequest, handshake.validate_request(writer.buffered()));

    var exact_buffer: [4096]u8 = undefined;
    var exact_writer = std.Io.Writer.fixed(&exact_buffer);
    try exact_writer.writeAll(
        "GET /chat HTTP/1.1\r\n" ++
            "Host: server.example.com\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
            "Sec-WebSocket-Version: 13\r\n",
    );
    index = 0;
    while (index < handshake.max_header_count - 5) : (index += 1) {
        try exact_writer.print("X-{d}: v\r\n", .{index});
    }
    try exact_writer.writeAll("\r\n");
    const request = try handshake.validate_request(exact_writer.buffered());
    try std.testing.expectEqualStrings(handshake_sample_key, request.key);
}

test "Handshake: validate_request rejects malformed and folded headers" {
    const folded =
        "GET /chat HTTP/1.1\r\n" ++
        "Host: server.example.com\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        " continued\r\n\r\n";
    try std.testing.expectError(error.InvalidHttpRequest, handshake.validate_request(folded));
    try std.testing.expectError(error.InvalidHttpRequest, handshake.validate_request("GET / HTTP/1.1\r\n\r\n"));
    try std.testing.expectError(error.InvalidHttpRequest, handshake.validate_request("GET\r\n\r\n"));

    const spaced_body_header =
        "GET /chat HTTP/1.1\r\n" ++
        "Host: server.example.com\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Sec-WebSocket-Version: 13\r\n" ++
        "Content-Length : 5\r\n\r\n";
    try std.testing.expectError(error.InvalidHttpRequest, handshake.validate_request(spaced_body_header));

    const spaced_host =
        "GET /chat HTTP/1.1\r\n" ++
        "Host : evil\r\n" ++
        "Host: server.example.com\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Sec-WebSocket-Version: 13\r\n\r\n";
    try std.testing.expectError(error.InvalidHttpRequest, handshake.validate_request(spaced_host));

    const absolute_target =
        "GET http://evil/ HTTP/1.1\r\n" ++
        "Host: server.example.com\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Sec-WebSocket-Version: 13\r\n\r\n";
    try std.testing.expectError(error.InvalidHttpRequest, handshake.validate_request(absolute_target));

    const empty_target =
        "GET  HTTP/1.1\r\n" ++
        "Host: server.example.com\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Sec-WebSocket-Version: 13\r\n\r\n";
    try std.testing.expectError(error.InvalidHttpRequest, handshake.validate_request(empty_target));

    const close_connection =
        "GET /chat HTTP/1.1\r\n" ++
        "Host: server.example.com\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade, close\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Sec-WebSocket-Version: 13\r\n\r\n";
    try std.testing.expectError(error.InvalidConnectionHeader, handshake.validate_request(close_connection));

    const bad_host_value =
        "GET /chat HTTP/1.1\r\n" ++
        "Host: server example\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Sec-WebSocket-Version: 13\r\n\r\n";
    try std.testing.expectError(error.InvalidHttpRequest, handshake.validate_request(bad_host_value));
}

test "Handshake: write_request emits the canonical client request" {
    var out: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out);

    try handshake.write_request(&writer, .{
        .host = "example.com",
        .target = "/chat",
        .key = handshake_sample_key,
        .origin = "https://example.com",
    });

    const expected =
        "GET /chat HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Sec-WebSocket-Version: 13\r\n" ++
        "Origin: https://example.com\r\n" ++
        "\r\n";
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "Handshake: write_request rejects injection and invalid fields" {
    var out: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out);

    try std.testing.expectError(error.InvalidHttpRequest, handshake.write_request(&writer, .{
        .host = "example.com\r\nInjected: yes",
        .key = handshake_sample_key,
    }));
    try std.testing.expectError(error.InvalidHttpRequest, handshake.write_request(&writer, .{
        .host = "example.com",
        .target = "chat",
        .key = handshake_sample_key,
    }));
    try std.testing.expectError(error.InvalidHttpRequest, handshake.write_request(&writer, .{
        .host = "example.com",
        .key = "not a key",
    }));
    try std.testing.expectError(error.InvalidHttpRequest, handshake.write_request(&writer, .{
        .host = "example.com",
        .origin = "https://example.com\r\nInjected: yes",
        .key = handshake_sample_key,
    }));
    try std.testing.expectError(error.InvalidHttpRequest, handshake.write_request(&writer, .{
        .host = "example.com",
    }));

    var small: [8]u8 = undefined;
    var small_writer = std.Io.Writer.fixed(&small);
    try std.testing.expectError(error.IoError, handshake.write_request(&small_writer, .{
        .host = "example.com",
        .key = handshake_sample_key,
    }));
}
