//! Aggregates every tachyon test category for the Debug and ReleaseSafe steps.
//!
//! Each import pulls the category's test declarations into this root module, so
//! `zig build test` runs the whole suite twice without compiling tests into the
//! library. Keep this list in sync with tests/README.md.

test {
    _ = @import("module-test/module_test.zig");
    _ = @import("error-test/error_test.zig");
    _ = @import("backpressure-test/backpressure_test.zig");
    _ = @import("frame-test/frame_test.zig");
    _ = @import("utf8-test/utf8_test.zig");
    _ = @import("fragment-test/fragments_test.zig");
    _ = @import("fragment-test/collector_read_test.zig");
    _ = @import("fragment-test/collector_policy_test.zig");
    _ = @import("connection-test/connection_core_test.zig");
    _ = @import("connection-test/connection_control_test.zig");
    _ = @import("connection-test/connection_close_test.zig");
    _ = @import("connection-test/connection_limits_test.zig");
    _ = @import("connection-test/connection_read_test.zig");
    _ = @import("connection-test/connection_write_test.zig");
    _ = @import("connection-test/connection_backpressure_test.zig");
    _ = @import("stream-test/reader_chunks_test.zig");
    _ = @import("stream-test/reader_control_test.zig");
    _ = @import("stream-test/writer_test.zig");
    _ = @import("stream-test/state_test.zig");
    _ = @import("split-test/split_core_test.zig");
    _ = @import("split-test/split_read_test.zig");
    _ = @import("split-test/split_backpressure_test.zig");
    _ = @import("split-test/split_collector_test.zig");
    _ = @import("native-stream-test/native_stream_test.zig");
    _ = @import("handshake-test/handshake_request_test.zig");
    _ = @import("handshake-test/handshake_head_test.zig");
    _ = @import("handshake-test/handshake_response_test.zig");
    _ = @import("handshake-test/handshake_client_test.zig");
    _ = @import("upgrade-test/upgrade_test.zig");
}
