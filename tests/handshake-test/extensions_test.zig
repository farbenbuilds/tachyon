const std = @import("std");
const tachyon = @import("tachyon");

const support = @import("../support.zig");

const handshake = tachyon.handshake;

fn clientNegotiated(offer: handshake.Extensions, response_extensions: handshake.Extensions) !handshake.Extensions {
    var response_buffer: [512]u8 = undefined;
    var response_writer = std.Io.Writer.fixed(&response_buffer);
    try handshake.write_response_with_extensions(
        &response_writer,
        support.handshake_sample_key,
        response_extensions,
    );

    var request_buffer: [512]u8 = undefined;
    var request_writer = std.Io.Writer.fixed(&request_buffer);
    var reader = std.Io.Reader.fixed(response_writer.buffered());
    var head_storage: [512]u8 = undefined;
    var status: u16 = 0;
    const response = try handshake.client_with_key(
        &reader,
        &request_writer,
        .{
            .host = "server.example.com",
            .target = "/chat",
            .key = support.handshake_sample_key,
            .extensions = offer,
        },
        &head_storage,
        &status,
    );
    return response.extensions;
}

test "Handshake: parses permessage-deflate offers and selects supported parameters" {
    const offer = try handshake.parse_extensions(
        "permessage-deflate; server_no_context_takeover; client_no_context_takeover; " ++
            "server_max_window_bits=10; client_max_window_bits=11",
    );
    const pmd = offer.permessage_deflate.?;
    try std.testing.expect(pmd.server_no_context_takeover);
    try std.testing.expect(pmd.client_no_context_takeover);
    try std.testing.expectEqual(@as(u4, 10), pmd.server_max_window_bits);
    try std.testing.expectEqual(@as(u4, 11), pmd.client_max_window_bits);
    try std.testing.expectEqual(@as(u4, 10), pmd.effective_server_window_bits());
    try std.testing.expectEqual(@as(u4, 11), pmd.effective_client_window_bits());

    const valueless = try handshake.parse_extensions("permessage-deflate; client_max_window_bits");
    try std.testing.expectEqual(@as(u4, 15), valueless.permessage_deflate.?.client_max_window_bits);

    const selected = try handshake.select_permessage_deflate(offer, .{});
    try std.testing.expectEqual(@as(u4, 10), selected.permessage_deflate.?.server_max_window_bits);
    try std.testing.expectEqual(@as(u4, 11), selected.permessage_deflate.?.client_max_window_bits);

    const unknown = try handshake.parse_extensions("x-unknown; a=b, permessage-deflate; server_max_window_bits=9");
    try std.testing.expectEqual(@as(u4, 9), unknown.permessage_deflate.?.server_max_window_bits);
}

test "Handshake: selects only offered parameters and declines unsupported windows" {
    const bare = try handshake.parse_extensions("permessage-deflate");
    try std.testing.expectEqual(@as(u4, 0), bare.permessage_deflate.?.server_max_window_bits);
    try std.testing.expectEqual(@as(u4, 0), bare.permessage_deflate.?.client_max_window_bits);
    try std.testing.expectEqual(@as(u4, 15), bare.permessage_deflate.?.effective_server_window_bits());

    const selected_bare = try handshake.select_permessage_deflate(bare, .{});
    try std.testing.expectEqual(@as(u4, 0), selected_bare.permessage_deflate.?.server_max_window_bits);
    try std.testing.expectEqual(@as(u4, 0), selected_bare.permessage_deflate.?.client_max_window_bits);

    var header_buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&header_buffer);
    try handshake.write_extensions(&writer, selected_bare);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "client_max_window_bits") == null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "server_max_window_bits") == null);

    const declined_bare = try handshake.select_permessage_deflate(bare, .{
        .server_max_window_bits = 10,
        .client_max_window_bits = 10,
    });
    try std.testing.expectEqual(@as(?handshake.PerMessageDeflate, null), declined_bare.permessage_deflate);

    const too_large = try handshake.parse_extensions("permessage-deflate; server_max_window_bits=10");
    const declined = try handshake.select_permessage_deflate(too_large, .{
        .server_max_window_bits = 9,
    });
    try std.testing.expectEqual(@as(?handshake.PerMessageDeflate, null), declined.permessage_deflate);

    const within = try handshake.select_permessage_deflate(too_large, .{
        .server_max_window_bits = 10,
    });
    try std.testing.expectEqual(@as(u4, 10), within.permessage_deflate.?.server_max_window_bits);
}

test "Handshake: selects the first supported offer from a multi-offer request" {
    const offers = try handshake.parse_extension_offers(
        "permessage-deflate; server_max_window_bits=10, " ++
            "permessage-deflate; server_max_window_bits=9, " ++
            "permessage-deflate",
    );
    try std.testing.expectEqual(@as(usize, 3), offers.count);

    const selected = try handshake.select_permessage_deflate_offers(offers, .{
        .server_max_window_bits = 9,
    });
    try std.testing.expectEqual(@as(u4, 9), selected.permessage_deflate.?.server_max_window_bits);
    try std.testing.expectEqual(@as(u4, 0), selected.permessage_deflate.?.client_max_window_bits);

    const head =
        "GET /chat HTTP/1.1\r\n" ++
        "Host: server.example.com\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Sec-WebSocket-Version: 13\r\n" ++
        "Sec-WebSocket-Extensions: permessage-deflate; server_max_window_bits=10\r\n" ++
        "Sec-WebSocket-Extensions: permessage-deflate; server_max_window_bits=9\r\n\r\n";
    const request = try handshake.validate_request(head);
    try std.testing.expectEqual(@as(usize, 2), request.offers.count);
    try std.testing.expectEqual(@as(u4, 10), request.extensions.permessage_deflate.?.server_max_window_bits);
}

test "Handshake: rejects malformed offer and response parameters" {
    const malformed_offers = [_][]const u8{
        "permessage-deflate; server_max_window_bits",
        "permessage-deflate; server_max_window_bits=7",
        "permessage-deflate; server_max_window_bits=16",
        "permessage-deflate; client_max_window_bits=0",
        "permessage-deflate; server_no_context_takeover=1",
        "permessage-deflate; unknown_parameter",
        "permessage-deflate; server_max_window_bits=10; server_max_window_bits=11",
        "permessage-deflate; ; server_max_window_bits=10",
    };
    for (malformed_offers) |value| {
        try std.testing.expectError(error.InvalidHttpRequest, handshake.parse_extensions(value));
    }

    const malformed_responses = [_][]const u8{
        "permessage-deflate; client_max_window_bits",
        "permessage-deflate; server_max_window_bits=10, permessage-deflate",
        "x-unknown",
        "permessage-deflate; server_no_context_takeover=1",
    };
    for (malformed_responses) |value| {
        try std.testing.expectError(error.InvalidHttpRequest, handshake.parse_response_extensions(value));
    }
}

test "Handshake: strict verify rejects unsolicited extensions" {
    var response_buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&response_buffer);
    const selected = handshake.Extensions{ .permessage_deflate = .{} };
    try handshake.write_response_with_extensions(&writer, support.handshake_sample_key, selected);

    var status: u16 = 0;
    try std.testing.expectError(
        error.InvalidHttpRequest,
        handshake.verify(writer.buffered(), support.handshake_sample_accept, &status),
    );
    const verified = try handshake.verify_with_extensions(
        writer.buffered(),
        support.handshake_sample_accept,
        selected,
        &status,
    );
    try std.testing.expect(verified.extensions.permessage_deflate != null);
}

test "Handshake: client accepts declined and subset extension responses" {
    const offer = handshake.Extensions{ .permessage_deflate = .{
        .server_no_context_takeover = true,
        .client_no_context_takeover = true,
        .server_max_window_bits = 10,
        .client_max_window_bits = 11,
    } };

    const declined = try clientNegotiated(offer, .{});
    try std.testing.expectEqual(@as(?handshake.PerMessageDeflate, null), declined.permessage_deflate);

    const subset = try clientNegotiated(offer, .{ .permessage_deflate = .{
        .server_no_context_takeover = true,
        .server_max_window_bits = 9,
        .client_max_window_bits = 10,
    } });
    try std.testing.expectEqual(@as(u4, 9), subset.permessage_deflate.?.server_max_window_bits);
    try std.testing.expectEqual(@as(u4, 10), subset.permessage_deflate.?.client_max_window_bits);
    try std.testing.expect(!subset.permessage_deflate.?.client_no_context_takeover);

    try std.testing.expectError(
        error.InvalidHttpRequest,
        clientNegotiated(offer, .{ .permessage_deflate = .{
            .server_max_window_bits = 12,
        } }),
    );
    const no_flags_offer = handshake.Extensions{ .permessage_deflate = .{
        .server_max_window_bits = 10,
    } };
    try std.testing.expectError(
        error.InvalidHttpRequest,
        clientNegotiated(no_flags_offer, .{ .permessage_deflate = .{
            .client_no_context_takeover = true,
        } }),
    );
}
