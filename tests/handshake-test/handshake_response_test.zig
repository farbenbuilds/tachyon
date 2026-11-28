const std = @import("std");
const tachyon = @import("tachyon");

const support = @import("../support.zig");

const handshake = tachyon.handshake;
const handshake_sample_key = support.handshake_sample_key;
const handshake_sample_accept = support.handshake_sample_accept;
const handshake_valid_response = support.handshake_valid_response;
const build_response_head = support.build_response_head;

test "Handshake: verify accepts token lists and the expected accept" {
    var storage: [256]u8 = undefined;
    var status: u16 = 0;
    const head = try build_response_head(
        &storage,
        "HTTP/1.1 101 Switching Protocols",
        "h2c, websocket",
        "keep-alive, Upgrade",
        handshake_sample_accept,
    );

    const response = try handshake.verify(head, handshake_sample_accept, &status);
    try std.testing.expectEqual(@as(u16, 101), response.status);
    try std.testing.expectEqualStrings(handshake_sample_accept, response.accept);
    try std.testing.expectEqualStrings(head, response.head);
    try std.testing.expectEqual(@as(u16, 101), status);
}

test "Handshake: verify rejects status, header, and accept failures" {
    var storage: [256]u8 = undefined;
    var status: u16 = 0;

    const rejected = try build_response_head(&storage, "HTTP/1.1 400 Bad Request", null, null, null);
    try std.testing.expectError(
        error.InvalidStatusCode,
        handshake.verify(rejected, handshake_sample_accept, &status),
    );
    try std.testing.expectEqual(@as(u16, 400), status);

    const missing_accept = try build_response_head(
        &storage,
        "HTTP/1.1 101 Switching Protocols",
        "websocket",
        "Upgrade",
        null,
    );
    try std.testing.expectError(
        error.InvalidSecWebSocketAccept,
        handshake.verify(missing_accept, handshake_sample_accept, &status),
    );

    const wrong_accept = try build_response_head(
        &storage,
        "HTTP/1.1 101 Switching Protocols",
        "websocket",
        "Upgrade",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    );
    try std.testing.expectError(
        error.InvalidSecWebSocketAccept,
        handshake.verify(wrong_accept, handshake_sample_accept, &status),
    );

    const wrong_upgrade = try build_response_head(
        &storage,
        "HTTP/1.1 101 Switching Protocols",
        "h2c",
        "Upgrade",
        handshake_sample_accept,
    );
    try std.testing.expectError(
        error.InvalidUpgradeHeader,
        handshake.verify(wrong_upgrade, handshake_sample_accept, &status),
    );

    const wrong_connection = try build_response_head(
        &storage,
        "HTTP/1.1 101 Switching Protocols",
        "websocket",
        "keep-alive",
        handshake_sample_accept,
    );
    try std.testing.expectError(
        error.InvalidConnectionHeader,
        handshake.verify(wrong_connection, handshake_sample_accept, &status),
    );

    try std.testing.expectError(
        error.InvalidSecWebSocketAccept,
        handshake.verify(handshake_valid_response, "", &status),
    );
}

test "Handshake: verify rejects duplicate accepts and malformed heads" {
    var status: u16 = 0;
    const duplicate_accept =
        "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" ++
        "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" ++
        "\r\n";
    try std.testing.expectError(
        error.InvalidSecWebSocketAccept,
        handshake.verify(duplicate_accept, handshake_sample_accept, &status),
    );

    const folded =
        "HTTP/1.1 101 Switching Protocols\r\n" ++
        " Upgrade: websocket\r\n\r\n";
    try std.testing.expectError(
        error.InvalidHttpRequest,
        handshake.verify(folded, handshake_sample_accept, &status),
    );

    try std.testing.expectError(
        error.InvalidHttpRequest,
        handshake.verify("not a response", handshake_sample_accept, &status),
    );

    const body_header =
        "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" ++
        "Content-Length: 2\r\n\r\n";
    try std.testing.expectError(
        error.InvalidHttpRequest,
        handshake.verify(body_header, handshake_sample_accept, &status),
    );

    const extension_header =
        "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" ++
        "Sec-WebSocket-Extensions: permessage-deflate\r\n\r\n";
    try std.testing.expectError(
        error.InvalidHttpRequest,
        handshake.verify(extension_header, handshake_sample_accept, &status),
    );

    const protocol_header =
        "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" ++
        "Sec-WebSocket-Protocol: chat\r\n\r\n";
    try std.testing.expectError(
        error.InvalidHttpRequest,
        handshake.verify(protocol_header, handshake_sample_accept, &status),
    );

    const spaced_content_length =
        "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" ++
        "Content-Length : 2\r\n\r\n";
    try std.testing.expectError(
        error.InvalidHttpRequest,
        handshake.verify(spaced_content_length, handshake_sample_accept, &status),
    );

    const close_connection =
        "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade, close\r\n" ++
        "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n";
    try std.testing.expectError(
        error.InvalidConnectionHeader,
        handshake.verify(close_connection, handshake_sample_accept, &status),
    );

    status = 7;
    try std.testing.expectError(
        error.InvalidHttpRequest,
        handshake.verify(
            "HTTP/1.1 09; Switching Protocols\r\n\r\n",
            handshake_sample_accept,
            &status,
        ),
    );
    try std.testing.expectEqual(@as(u16, 7), status);
    try std.testing.expectError(
        error.InvalidHttpRequest,
        handshake.verify("HTTP/1.1 abc Nope\r\n\r\n", handshake_sample_accept, &status),
    );
    try std.testing.expectEqual(@as(u16, 7), status);
}

test "Handshake: write_response emits the computed 101 accept token" {
    var out: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out);

    try handshake.write_response(&writer, handshake_sample_key);
    try std.testing.expectError(error.InvalidHttpRequest, handshake.write_response(&writer, "not a key"));

    const expected =
        "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" ++
        "\r\n";
    try std.testing.expectEqualStrings(expected, writer.buffered());
}
