const std = @import("std");
const zslay = @import("zslay");
const tachyon = @import("tachyon");

const support = @import("../support.zig");

const handshake = tachyon.handshake;
const split = tachyon.split;
const upgrade = tachyon.upgrade;
const Frame = tachyon.Frame;
const WebSocketError = tachyon.WebSocketError;
const EncodedStream = support.EncodedStream;
const RecordingVecWriter = support.RecordingVecWriter;
const FlushFailWriter = support.FlushFailWriter;
const next_wire_frame = support.next_wire_frame;
const append_masked = support.append_masked;
const handshake_sample_key = support.handshake_sample_key;
const handshake_sample_accept = support.handshake_sample_accept;
const handshake_valid_request = support.handshake_valid_request;
const handshake_valid_response = support.handshake_valid_response;
const build_request_head = support.build_request_head;

test "Upgrade: public module re-exports the upgrade surface" {
    const root = @import("tachyon");

    try std.testing.expect(root.upgrade == upgrade);
    try std.testing.expect(root.Upgrade == upgrade.Upgrade);
    try std.testing.expect(root.UpgradeFut == upgrade.UpgradeFut);
    try std.testing.expect(root.IncomingUpgrade == upgrade.IncomingUpgrade);
    try std.testing.expect(root.upgrade_websocket == upgrade.upgrade);
    try std.testing.expect(root.upgrade_websocket_async == upgrade.upgrade_async);
    try std.testing.expect(root.read_incoming_upgrade == upgrade.incoming);
    try std.testing.expectEqualStrings(root.accept_guid, upgrade.accept_guid);
    try std.testing.expectEqual(root.accept_token_len, upgrade.accept_token_len);
    try std.testing.expect(root.AcceptTokenBuffer == upgrade.AcceptTokenBuffer);
    try std.testing.expect(root.compute_accept_token == upgrade.compute_accept_token);
    try std.testing.expect(root.is_upgrade_request == upgrade.is_upgrade_request);
}

/// Caller-owned header, frame, and split buffers for server upgrade tests.
const UpgradeRig = struct {
    head_storage: [256]u8 = undefined,
    frame_buffer: [64]u8 = undefined,
    read_compose_buffer: [32]u8 = undefined,
    write_buffer: [32]u8 = undefined,
    read_close_buffer: [8]u8 = undefined,
    write_close_buffer: [8]u8 = undefined,
    mask_scratch: [16]u8 = undefined,
    tx_nodes: [2]zslay.FrameNode = undefined,

    fn storage(self: *UpgradeRig) split.Storage {
        return .{
            .read = .{
                .frame_buffer = &self.frame_buffer,
                .close_buffer = &self.read_close_buffer,
                .compose_buffer = &self.read_compose_buffer,
            },
            .write = .{
                .tx_nodes = &self.tx_nodes,
                .write_buffer = &self.write_buffer,
                .close_buffer = &self.write_close_buffer,
                .mask_scratch = &self.mask_scratch,
            },
        };
    }
};

/// Copies the valid request head plus encoded frame bytes into `wire`.
fn build_upgrade_wire(wire: []u8, frame_bytes: []const u8) []u8 {
    std.debug.assert(wire.len >= handshake_valid_request.len + frame_bytes.len);
    @memcpy(wire[0..handshake_valid_request.len], handshake_valid_request);
    @memcpy(wire[handshake_valid_request.len..][0..frame_bytes.len], frame_bytes);
    return wire[0 .. handshake_valid_request.len + frame_bytes.len];
}

test "Upgrade: accept GUID and token match the RFC sample through both modules" {
    try std.testing.expectEqual(@as(usize, 28), upgrade.accept_token_len);

    var upgrade_buffer: upgrade.AcceptTokenBuffer = undefined;
    const upgrade_accept = upgrade.compute_accept_token(handshake_sample_key, &upgrade_buffer);
    try std.testing.expectEqualStrings(handshake_sample_accept, upgrade_accept);

    try std.testing.expectEqualStrings(upgrade.accept_guid, handshake.accept_guid);
    try std.testing.expectEqual(upgrade.accept_token_len, handshake.accept_token_len);
    try std.testing.expect(handshake.AcceptTokenBuffer == upgrade.AcceptTokenBuffer);

    var handshake_buffer: handshake.AcceptTokenBuffer = undefined;
    const handshake_accept = handshake.compute_accept_token(handshake_sample_key, &handshake_buffer);
    try std.testing.expectEqualStrings(handshake_sample_accept, handshake_accept);
}

test "Upgrade: incoming validates and leaves coalesced bytes buffered" {
    var stream: EncodedStream(16) = .{};
    var client_payload = [_]u8{ 'h', 'i' };
    try append_masked(&stream, Frame.text(&client_payload), .{ 0x01, 0x02, 0x03, 0x04 });

    var wire: [512]u8 = undefined;
    const wire_bytes = build_upgrade_wire(&wire, stream.bytes[0..stream.len]);
    var reader = std.Io.Reader.fixed(wire_bytes);
    var rig: UpgradeRig = .{};

    const incoming_upgrade = try upgrade.incoming(&reader, &rig.head_storage);

    try std.testing.expectEqualStrings(handshake_sample_key, incoming_upgrade.request.key);
    try std.testing.expectEqualStrings(handshake_valid_request, incoming_upgrade.request.head);
    const key_addr = @intFromPtr(incoming_upgrade.request.key.ptr);
    const head_addr = @intFromPtr(incoming_upgrade.request.head.ptr);
    try std.testing.expect(key_addr >= head_addr);
    try std.testing.expect(key_addr < head_addr + incoming_upgrade.request.head.len);

    var coalesced: [16]u8 = undefined;
    try reader.readSliceAll(coalesced[0..stream.len]);
    try std.testing.expectEqualSlices(u8, stream.bytes[0..stream.len], coalesced[0..stream.len]);
}

test "Upgrade: one-shot upgrade writes the 101, flushes, and splits for frames" {
    var stream: EncodedStream(16) = .{};
    var client_payload = [_]u8{ 'h', 'i' };
    try append_masked(&stream, Frame.text(&client_payload), .{ 0x01, 0x02, 0x03, 0x04 });

    var wire: [512]u8 = undefined;
    const wire_bytes = build_upgrade_wire(&wire, stream.bytes[0..stream.len]);
    var reader = std.Io.Reader.fixed(wire_bytes);
    var rig: UpgradeRig = .{};
    var out: [256]u8 = undefined;
    var flush_buffer: [256]u8 = undefined;
    var writer = FlushFailWriter.init(&out, &flush_buffer);
    writer.fail_flush = false;

    var result = try upgrade.upgrade(
        &reader,
        &writer.writer,
        &rig.head_storage,
        rig.storage(),
        .{ .role = .server },
    );

    try std.testing.expectEqual(@as(usize, 1), writer.flush_calls);
    try std.testing.expectEqual(handshake_valid_response.len, writer.written);
    try std.testing.expectEqualStrings(handshake_valid_response, out[0..writer.written]);
    try std.testing.expectEqualStrings(handshake_sample_key, result.request.key);
    try std.testing.expectEqualStrings(handshake_valid_request, result.request.head);
    try std.testing.expectEqual(split.Role.server, result.websocket.read.role());
    try std.testing.expectEqual(split.Role.server, result.websocket.write.role());

    const received = try result.websocket.read_frame();
    try std.testing.expectEqual(split.OpCode.text, received.opcode);
    try std.testing.expect(received.fin);
    try std.testing.expectEqual(@as(?split.MaskingKey, null), received.masking_key);
    try std.testing.expectEqualStrings("hi", received.payload);
}

test "Upgrade: incoming upgrade writes the same 101, flushes, and splits" {
    var stream: EncodedStream(16) = .{};
    var client_payload = [_]u8{ 'h', 'i' };
    try append_masked(&stream, Frame.text(&client_payload), .{ 0x05, 0x06, 0x07, 0x08 });

    var wire: [512]u8 = undefined;
    const wire_bytes = build_upgrade_wire(&wire, stream.bytes[0..stream.len]);
    var reader = std.Io.Reader.fixed(wire_bytes);
    var rig: UpgradeRig = .{};
    var out: [256]u8 = undefined;
    var flush_buffer: [256]u8 = undefined;
    var writer = FlushFailWriter.init(&out, &flush_buffer);
    writer.fail_flush = false;

    const incoming_upgrade = try upgrade.incoming(&reader, &rig.head_storage);
    try std.testing.expectEqual(@as(usize, 0), writer.written);
    try std.testing.expectEqual(@as(usize, 0), writer.flush_calls);

    var result = try incoming_upgrade.upgrade(&reader, &writer.writer, rig.storage(), .{ .role = .server });

    try std.testing.expectEqual(@as(usize, 1), writer.flush_calls);
    try std.testing.expectEqual(handshake_valid_response.len, writer.written);
    try std.testing.expectEqualStrings(handshake_valid_response, out[0..writer.written]);
    try std.testing.expectEqual(split.Role.server, result.websocket.read.role());

    const received = try result.websocket.read_frame();
    try std.testing.expectEqual(split.OpCode.text, received.opcode);
    try std.testing.expectEqualStrings("hi", received.payload);
}

test "Upgrade: invalid requests fail before any response byte" {
    const Case = struct {
        connection_value: ?[]const u8 = "Upgrade",
        upgrade_value: ?[]const u8 = "websocket",
        key: ?[]const u8 = handshake_sample_key,
        version: ?[]const u8 = "13",
        expected: WebSocketError,
    };
    const cases = [_]Case{
        .{ .key = "not a key", .expected = error.InvalidHttpRequest },
        .{ .version = "12", .expected = error.InvalidSecWebsocketVersion },
        .{ .connection_value = null, .expected = error.InvalidConnectionHeader },
        .{ .connection_value = "keep-alive", .expected = error.InvalidConnectionHeader },
        .{ .upgrade_value = null, .expected = error.InvalidUpgradeHeader },
        .{ .upgrade_value = "h2c", .expected = error.InvalidUpgradeHeader },
    };

    var buffer: [256]u8 = undefined;
    var rig: UpgradeRig = .{};
    var out: [256]u8 = undefined;
    var empty_buffer: [0]u8 = .{};
    // A zero-capacity buffer forces any write through drain, so both a write
    // attempt and a flush attempt become observable on a rejected request.
    var writer = FlushFailWriter.init(&out, &empty_buffer);

    for (cases) |case| {
        const head = try build_request_head(
            &buffer,
            "GET",
            case.connection_value,
            case.upgrade_value,
            case.key,
            case.version,
        );
        var case_reader = std.Io.Reader.fixed(head);
        try std.testing.expectError(case.expected, upgrade.upgrade(
            &case_reader,
            &writer.writer,
            &rig.head_storage,
            rig.storage(),
            .{ .role = .server },
        ));
    }

    try std.testing.expectEqual(@as(usize, 0), writer.written);
    try std.testing.expectEqual(@as(usize, 0), writer.flush_calls);
}

test "Upgrade: a failed 101 flush returns IoError before the split" {
    var reader = std.Io.Reader.fixed(handshake_valid_request);
    var rig: UpgradeRig = .{};
    var out: [256]u8 = undefined;
    var empty_buffer: [0]u8 = .{};
    var writer = FlushFailWriter.init(&out, &empty_buffer);

    try std.testing.expectError(error.IoError, upgrade.upgrade(
        &reader,
        &writer.writer,
        &rig.head_storage,
        rig.storage(),
        .{ .role = .server },
    ));

    // The 101 was written before the flush failed; no split was returned.
    try std.testing.expectEqual(@as(usize, 1), writer.flush_calls);
    try std.testing.expectEqual(handshake_valid_response.len, writer.written);
    try std.testing.expectEqualStrings(handshake_valid_response, out[0..writer.written]);
}

test "Upgrade: a client-role config is forced to server for the split" {
    var reader = std.Io.Reader.fixed(handshake_valid_request);
    var rig: UpgradeRig = .{};
    var out: [256]u8 = undefined;
    var writer = RecordingVecWriter.init(&out);

    var result = try upgrade.upgrade(
        &reader,
        &writer.writer,
        &rig.head_storage,
        rig.storage(),
        .{ .role = .client },
    );

    try std.testing.expectEqual(split.Role.server, result.websocket.read.role());
    try std.testing.expectEqual(split.Role.server, result.websocket.write.role());
    try std.testing.expectEqual(handshake_valid_response.len, writer.written);
    try std.testing.expectEqualStrings(handshake_valid_response, out[0..writer.written]);

    var payload = [_]u8{ 'o', 'k' };
    try result.websocket.write_frame(Frame.text(&payload));
    try result.websocket.flush();

    var index: usize = handshake_valid_response.len;
    const outgoing = try next_wire_frame(out[0..writer.written], &index);
    try std.testing.expectEqual(split.OpCode.text, split.OpCode.from_wire(outgoing.header.header.opcode).?);
    try std.testing.expect(!outgoing.header.header.mask);
    try std.testing.expectEqual(@as(?split.MaskingKey, null), outgoing.header.masking_key);
    try std.testing.expectEqualStrings("ok", outgoing.payload);
    try std.testing.expectEqual(writer.written, index);
}

test "Upgrade: upgrade_async awaits after the 101 flush and preserves frame bytes" {
    var stream: EncodedStream(16) = .{};
    var client_payload = [_]u8{ 'h', 'i' };
    try append_masked(&stream, Frame.text(&client_payload), .{ 0x09, 0x0a, 0x0b, 0x0c });

    var wire: [512]u8 = undefined;
    const wire_bytes = build_upgrade_wire(&wire, stream.bytes[0..stream.len]);
    var reader = std.Io.Reader.fixed(wire_bytes);
    var rig: UpgradeRig = .{};
    var out: [256]u8 = undefined;
    var flush_buffer: [256]u8 = undefined;
    var writer = FlushFailWriter.init(&out, &flush_buffer);
    writer.fail_flush = false;

    // Every pointer and buffer passed to the future stays on this stack frame
    // until the awaited result has been consumed below.
    var future = upgrade.upgrade_async(
        std.testing.io,
        &reader,
        &writer.writer,
        &rig.head_storage,
        rig.storage(),
        .{ .role = .server },
    );
    var result = try future.await(std.testing.io);

    try std.testing.expectEqual(@as(usize, 1), writer.flush_calls);
    try std.testing.expectEqual(handshake_valid_response.len, writer.written);
    try std.testing.expectEqualStrings(handshake_valid_response, out[0..writer.written]);
    try std.testing.expectEqualStrings(handshake_sample_key, result.request.key);

    const received = try result.websocket.read_frame();
    try std.testing.expectEqual(split.OpCode.text, received.opcode);
    try std.testing.expectEqual(@as(?split.MaskingKey, null), received.masking_key);
    try std.testing.expectEqualStrings("hi", received.payload);
}

test "Upgrade: is_upgrade_request agrees with the handshake token probe" {
    try std.testing.expect(upgrade.is_upgrade_request(handshake_valid_request));
    try std.testing.expect(handshake.is_request(handshake_valid_request));

    var buffer: [256]u8 = undefined;
    const no_upgrade = try build_request_head(&buffer, "GET", "Upgrade", null, handshake_sample_key, "13");
    try std.testing.expect(!upgrade.is_upgrade_request(no_upgrade));
    try std.testing.expect(!handshake.is_request(no_upgrade));

    const no_connection = try build_request_head(&buffer, "GET", null, "websocket", handshake_sample_key, "13");
    try std.testing.expect(!upgrade.is_upgrade_request(no_connection));
    try std.testing.expect(!handshake.is_request(no_connection));
}

test "Upgrade: writes negotiated extension response after split construction" {
    var stream: EncodedStream(16) = .{};
    var client_payload = [_]u8{0xff};
    try append_masked(&stream, Frame.init_rsv1(true, .text, true, null, &client_payload), .{ 0x21, 0x22, 0x23, 0x24 });

    const extended_request =
        "GET /chat HTTP/1.1\r\n" ++
        "Host: server.example.com\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Sec-WebSocket-Version: 13\r\n" ++
        "Sec-WebSocket-Extensions: permessage-deflate; server_max_window_bits=10\r\n\r\n";
    var wire: [512]u8 = undefined;
    @memcpy(wire[0..extended_request.len], extended_request);
    @memcpy(wire[extended_request.len..][0..stream.len], stream.bytes[0..stream.len]);

    var reader = std.Io.Reader.fixed(wire[0 .. extended_request.len + stream.len]);
    var rig: UpgradeRig = .{};
    var out: [256]u8 = undefined;
    var flush_buffer: [256]u8 = undefined;
    var writer = FlushFailWriter.init(&out, &flush_buffer);
    writer.fail_flush = false;

    const selected = handshake.Extensions{ .permessage_deflate = .{ .server_max_window_bits = 10 } };
    var result = try upgrade.upgrade_with_extensions(
        &reader,
        &writer.writer,
        &rig.head_storage,
        rig.storage(),
        .{ .role = .server },
        selected,
    );

    try std.testing.expectEqual(@as(usize, 1), writer.flush_calls);
    try std.testing.expect(
        std.mem.indexOf(u8, out[0..writer.written], "Sec-WebSocket-Extensions: permessage-deflate") != null,
    );
    try std.testing.expect(result.websocket.read.inner.options.allow_rsv1);

    const received = try result.websocket.read_frame();
    try std.testing.expect(received.rsv1);
    try std.testing.expectEqualSlices(u8, &.{0xff}, received.payload);
}

test "Upgrade: extension storage validation precedes the 101" {
    var stream: EncodedStream(16) = .{};
    var client_payload = [_]u8{'x'};
    try append_masked(&stream, Frame.text(&client_payload), .{ 0x31, 0x32, 0x33, 0x34 });
    var wire: [512]u8 = undefined;
    const wire_bytes = build_upgrade_wire(&wire, stream.bytes[0..stream.len]);

    var reader = std.Io.Reader.fixed(wire_bytes);
    var rig: UpgradeRig = .{};
    var short_write_buffer: [1]u8 = undefined;
    var short_storage = rig.storage();
    short_storage.write.write_buffer = &short_write_buffer;
    var out: [256]u8 = undefined;
    var flush_buffer: [256]u8 = undefined;
    var writer = FlushFailWriter.init(&out, &flush_buffer);
    writer.fail_flush = false;

    try std.testing.expectError(error.InvalidLength, upgrade.upgrade_with_extensions(
        &reader,
        &writer.writer,
        &rig.head_storage,
        short_storage,
        .{ .role = .server },
        .{ .permessage_deflate = .{} },
    ));
    try std.testing.expectEqual(@as(usize, 0), writer.written);
    try std.testing.expectEqual(@as(usize, 0), writer.flush_calls);
}

test "Upgrade: invalid split storage fails before the 101" {
    var rig: UpgradeRig = .{};
    var out: [256]u8 = undefined;
    var empty_buffer: [0]u8 = .{};
    var writer = FlushFailWriter.init(&out, &empty_buffer);
    var short_write_buffer: [8]u8 = undefined;

    var short_storage = rig.storage();
    short_storage.write.write_buffer = &short_write_buffer;
    var short_reader = std.Io.Reader.fixed(handshake_valid_request);
    try std.testing.expectError(error.InvalidLength, upgrade.upgrade(
        &short_reader,
        &writer.writer,
        &rig.head_storage,
        short_storage,
        .{ .role = .server },
    ));
    try std.testing.expectEqual(@as(usize, 0), writer.written);
    try std.testing.expectEqual(@as(usize, 0), writer.flush_calls);

    var empty_tx_storage = rig.storage();
    empty_tx_storage.write.tx_nodes = &.{};
    var empty_tx_reader = std.Io.Reader.fixed(handshake_valid_request);
    try std.testing.expectError(error.InvalidLength, upgrade.upgrade(
        &empty_tx_reader,
        &writer.writer,
        &rig.head_storage,
        empty_tx_storage,
        .{ .role = .server },
    ));
    try std.testing.expectEqual(@as(usize, 0), writer.written);
    try std.testing.expectEqual(@as(usize, 0), writer.flush_calls);

    var async_reader = std.Io.Reader.fixed(handshake_valid_request);
    var async_storage = rig.storage();
    async_storage.write.write_buffer = &short_write_buffer;
    var future = upgrade.upgrade_async(
        std.testing.io,
        &async_reader,
        &writer.writer,
        &rig.head_storage,
        async_storage,
        .{ .role = .server },
    );
    try std.testing.expectError(error.InvalidLength, future.await(std.testing.io));
    try std.testing.expectEqual(@as(usize, 0), writer.written);
    try std.testing.expectEqual(@as(usize, 0), writer.flush_calls);
}

test "Upgrade: async invalid request fails before any response byte" {
    var buffer: [256]u8 = undefined;
    const head = try build_request_head(&buffer, "GET", "Upgrade", "websocket", "not a key", "13");
    var reader = std.Io.Reader.fixed(head);
    var rig: UpgradeRig = .{};
    var out: [256]u8 = undefined;
    var empty_buffer: [0]u8 = .{};
    var writer = FlushFailWriter.init(&out, &empty_buffer);

    var future = upgrade.upgrade_async(
        std.testing.io,
        &reader,
        &writer.writer,
        &rig.head_storage,
        rig.storage(),
        .{ .role = .server },
    );
    try std.testing.expectError(error.InvalidHttpRequest, future.await(std.testing.io));

    try std.testing.expectEqual(@as(usize, 0), writer.written);
    try std.testing.expectEqual(@as(usize, 0), writer.flush_calls);
}
