const zslay = @import("zslay");
const tachyon = @import("tachyon");

const Frame = tachyon.Frame;
const OpCode = tachyon.OpCode;
const header_len = tachyon.header_len;
const CloseCode = tachyon.CloseCode;
const close_code_from_u16 = tachyon.close_code_from_u16;
const is_control = tachyon.is_control;
const is_valid_utf8 = tachyon.is_valid_utf8;
const Utf8State = tachyon.Utf8State;
const validate_utf8_reader = tachyon.validate_utf8_reader;
const Fragments = tachyon.Fragments;
const FragmentCollector = tachyon.FragmentCollector;
const Role = tachyon.Role;

test "Dependency: zslay encodes an unmasked text frame header" {
    const std = @import("std");

    var header_buffer: zslay.FrameHeaderBuffer = undefined;
    const header: zslay.FrameHeader = .{
        .opcode = @backingInt(zslay.Opcode.text),
        .rsv3 = false,
        .rsv2 = false,
        .rsv1 = false,
        .fin = true,
        .payload_len = 5,
        .mask = false,
    };

    const encoded_len = try zslay.encode_header(&header_buffer, header, 5, null);

    try std.testing.expectEqual(@as(usize, 2), encoded_len);
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 0x05 }, header_buffer[0..encoded_len]);
}

test "Frame: public module re-exports the facade" {
    const std = @import("std");

    var payload = [_]u8{ 'o', 'k' };
    const f = Frame.text(&payload);

    try std.testing.expectEqual(OpCode.text, f.opcode);
    try std.testing.expectEqual(@as(usize, 2), try header_len(payload.len, false));
    try std.testing.expectEqual(CloseCode.normal_closure, close_code_from_u16(1000));
    try std.testing.expect(is_control(.ping));
    try std.testing.expect(f.is_utf8());
}

test "UTF-8: public module re-exports the validator" {
    const std = @import("std");

    try std.testing.expect(is_valid_utf8("ok"));

    var state: Utf8State = .{};
    state = try state.feed("o");
    state = try state.feed("k");
    try state.finish();

    var buffer: [4]u8 = undefined;
    var reader = std.Io.Reader.fixed("ok");
    try validate_utf8_reader(&reader, &buffer);
}

test "Fragment: public module re-exports the fragment layer" {
    const std = @import("std");

    var message: [5]u8 = undefined;
    var fragments = Fragments.init(&message);

    var head = [_]u8{ 'h', 'e' };
    try std.testing.expect((try fragments.accumulate(Frame.init(false, .text, null, &head))) == null);
    try std.testing.expectEqual(OpCode.text, fragments.message_opcode().?);
    try std.testing.expectEqual(@as(usize, 2), fragments.message_len());

    var tail = [_]u8{ 'l', 'l', 'o' };
    const completed = try fragments.accumulate(Frame.init(true, .continuation, null, &tail));

    try std.testing.expectEqualStrings("hello", completed.?.payload);
    try std.testing.expect(fragments.is_idle());

    var reader = std.Io.Reader.fixed("");
    var frame_buffer: [4]u8 = undefined;
    var message_buffer: [4]u8 = undefined;
    const collector = try FragmentCollector.init(&reader, &frame_buffer, &message_buffer, Role.server, 64);

    try std.testing.expect(collector.is_at_frame_boundary());
}
