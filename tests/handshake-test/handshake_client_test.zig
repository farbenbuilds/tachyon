const std = @import("std");
const tachyon = @import("tachyon");

const support = @import("../support.zig");

const handshake = tachyon.handshake;
const handshake_sample_key = support.handshake_sample_key;
const handshake_sample_accept = support.handshake_sample_accept;
const handshake_valid_request = support.handshake_valid_request;
const handshake_valid_response = support.handshake_valid_response;

test "Handshake: client_with_key writes, verifies, and preserves frame bytes" {
    const wire = handshake_valid_response ++ "\x81\x02hi";
    var reader = std.Io.Reader.fixed(wire);
    var out: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out);
    var head_storage: [256]u8 = undefined;
    var status: u16 = 0;

    const response = try handshake.client_with_key(&reader, &writer, .{
        .host = "server.example.com",
        .target = "/chat",
        .key = handshake_sample_key,
    }, &head_storage, &status);

    const expected_request =
        "GET /chat HTTP/1.1\r\n" ++
        "Host: server.example.com\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Sec-WebSocket-Version: 13\r\n" ++
        "\r\n";
    try std.testing.expectEqualStrings(expected_request, writer.buffered());
    try std.testing.expectEqual(@as(u16, 101), status);
    try std.testing.expectEqualStrings(handshake_valid_response, response.head);

    var wire_frame: [4]u8 = undefined;
    try reader.readSliceAll(&wire_frame);
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 0x02, 'h', 'i' }, &wire_frame);
}

test "Handshake: read_request and read_response wrap head parsing" {
    var request_reader = std.Io.Reader.fixed(handshake_valid_request);
    var request_storage: [256]u8 = undefined;
    const request = try handshake.read_request(&request_reader, &request_storage);
    try std.testing.expectEqualStrings(handshake_sample_key, request.key);

    var response_reader = std.Io.Reader.fixed(handshake_valid_response);
    var response_storage: [256]u8 = undefined;
    var status: u16 = 0;
    const response = try handshake.read_response(
        &response_reader,
        &response_storage,
        handshake_sample_accept,
        &status,
    );
    try std.testing.expectEqual(@as(u16, 101), response.status);
}

test "Handshake: client generates a key when options.key is null" {
    var reader = std.Io.Reader.fixed("HTTP/1.1 400 Bad Request\r\n\r\n");
    var out: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out);
    var head_storage: [256]u8 = undefined;
    var status: u16 = 0;

    try std.testing.expectError(error.InvalidStatusCode, handshake.client(
        std.testing.io,
        &reader,
        &writer,
        .{ .host = "example.com" },
        &head_storage,
        &status,
    ));
    try std.testing.expectEqual(@as(u16, 400), status);

    const request = writer.buffered();
    const prefix = "Sec-WebSocket-Key: ";
    const start = (std.mem.indexOf(u8, request, prefix) orelse return error.TestUnexpectedResult) + prefix.len;
    try std.testing.expect(start + 24 <= request.len);
    try std.testing.expect(handshake.valid_client_key(request[start..][0..24]));
}

test "Handshake: server primitives read a request, write 101, and preserve frame bytes" {
    const wire = handshake_valid_request ++ "\x81\x02hi";
    var reader = std.Io.Reader.fixed(wire);
    var out: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out);
    var head_storage: [256]u8 = undefined;

    const request = try handshake.read_request(&reader, &head_storage);
    try std.testing.expectEqualStrings(handshake_sample_key, request.key);
    try std.testing.expectEqualStrings(handshake_valid_request, request.head);

    try handshake.write_response(&writer, request.key);
    const expected_response =
        "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" ++
        "\r\n";
    try std.testing.expectEqualStrings(expected_response, writer.buffered());

    var wire_frame: [4]u8 = undefined;
    try reader.readSliceAll(&wire_frame);
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 0x02, 'h', 'i' }, &wire_frame);
}

test "Handshake: is_request is token-only and validate_request is strict" {
    try std.testing.expect(handshake.is_request(handshake_valid_request));

    const unknown_method =
        "BREW /chat HTTP/1.1\r\n" ++
        "Host: server.example.com\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n\r\n";
    try std.testing.expect(handshake.is_request(unknown_method));
    try std.testing.expectError(error.InvalidHttpRequest, handshake.validate_request(unknown_method));

    const body_header =
        "GET /chat HTTP/1.1\r\n" ++
        "Host: server.example.com\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Content-Length: 5\r\n\r\n";
    try std.testing.expect(handshake.is_request(body_header));
    try std.testing.expectError(error.InvalidHttpRequest, handshake.validate_request(body_header));
}

test "Handshake: public module re-exports the handshake surface" {
    const root = @import("tachyon");

    try std.testing.expect(root.handshake == handshake);
    try std.testing.expect(root.client_handshake == handshake.client);
    try std.testing.expect(root.client_handshake_with_key == handshake.client_with_key);
    try std.testing.expect(root.verify_handshake_response == handshake.verify);
    try std.testing.expect(root.is_upgrade_request == handshake.is_request);
    try std.testing.expect(root.validate_upgrade_request == handshake.validate_request);
    try std.testing.expect(root.read_upgrade_request == handshake.read_request);
    try std.testing.expect(root.write_upgrade_response == handshake.write_response);
    try std.testing.expect(root.HandshakeClientOptions == handshake.ClientOptions);
    try std.testing.expect(root.HandshakeRequest == handshake.Request);
    try std.testing.expect(root.HandshakeResponse == handshake.Response);
    try std.testing.expectEqualStrings(handshake.accept_guid, root.accept_guid);
}
