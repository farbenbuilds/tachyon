//! `std.Io.net.Stream` transport adapter for the connection and split layers.
//!
//! `Transport` binds the two `std.Io.net.Stream` directions to the
//! `std.Io.Reader` and `std.Io.Writer` interfaces that `connection.WebSocket`
//! and `split.Split` consume. `WebSocket` and `Split` are thin native wrappers
//! over those layers; they add no protocol state, masking, close policy, or
//! queueing of their own. The shape mirrors fastwebsockets' transport-generic
//! `WebSocket<S>`: the caller owns the transport, the wrappers start at the
//! post-handshake frame boundary, and read obligations stay in the existing
//! connection and split paths.
//!
//! The caller owns the socket, both `std.Io` buffers, and every connection or
//! split storage slice. Readiness and suspension come from the caller's
//! `std.Io` through the stream's `net_read` and `net_write` operations; this
//! module never allocates, opens a socket, or spawns a task. It never closes
//! the handle implicitly: `close` and `shutdown` are explicit because the
//! stream may outlive the adapter.
//!
//! Run the HTTP handshake or server upgrade over `transport.reader()` and
//! `transport.writer()` before binding a `WebSocket` or `Split`. The native
//! wrappers start at the post-handshake frame boundary, matching
//! fastwebsockets' `after_handshake` surface.
//!
//! `Transport` must keep a stable address once a wrapper binds it: the
//! wrapper stores pointers to its embedded reader and writer interfaces.
//! Moving a bound transport invalidates those pointers.

const std = @import("std");
const zslay = @import("zslay");
const connection = @import("connection.zig");
const split = @import("split.zig");

/// Shared fastwebsockets error taxonomy.
pub const Error = connection.Error;

/// Local endpoint role, re-exported from the connection layer.
pub const Role = connection.Role;

/// RFC 6455 opcode alias from the connection layer.
pub const OpCode = connection.OpCode;

/// Close status alias from the connection layer.
pub const CloseCode = connection.CloseCode;

/// Frame record with caller-owned payload bytes.
pub const Frame = connection.Frame;

/// fastwebsockets-compatible policy options.
pub const Options = connection.Options;

/// Construction-time role, options, and client mask source.
pub const Config = connection.Config;

/// Caller-owned connection storage, matching `connection.Storage`.
pub const ConnectionStorage = connection.Storage;

/// Caller-owned split storage, matching `split.Storage`.
pub const SplitStorage = split.Storage;

/// Caller-owned buffers for one stream pair.
pub const TransportStorage = struct {
    /// Buffers the `std.Io.Reader` that feeds frame headers and payloads. It
    /// must be non-empty and must not overlap `write_buffer` or any
    /// connection or split storage slice.
    read_buffer: []u8,
    /// Buffers the `std.Io.Writer` that drains completed frames and automatic
    /// replies. It must be non-empty and disjoint from `read_buffer` and all
    /// connection or split storage.
    write_buffer: []u8,
};

/// Borrowed `std.Io.net.Stream` plus its reader and writer interfaces.
///
/// The struct is movable before a wrapper binds it and must not move
/// afterwards. `close` and `shutdown` are explicit; constructing or dropping a
/// `Transport` never closes the socket. Reads and writes suspend through the
/// caller-provided `std.Io`, so no event loop or worker task is created here.
///
/// A transport accepts one wrapper. `bound` is set after a `WebSocket` or
/// `Split` binds the reader and writer interfaces, because two wrappers over
/// the same direction would compete for bytes. The flag is one-way: dropping a
/// wrapper does not rewind or release the stream.
pub const Transport = struct {
    io: std.Io,
    stream: std.Io.net.Stream,
    reader_state: std.Io.net.Stream.Reader,
    writer_state: std.Io.net.Stream.Writer,
    bound: bool = false,

    /// Builds the two stream directions over caller-owned buffers.
    ///
    /// Empty buffers are rejected because both `std.Io` interfaces require
    /// storage to make progress. Overlapping directions are rejected because
    /// reads and writes can be in flight at the same time.
    pub fn init(io: std.Io, stream: std.Io.net.Stream, storage: TransportStorage) Error!Transport {
        try validate_pair(storage.read_buffer, storage.write_buffer);

        return .{
            .io = io,
            .stream = stream,
            .reader_state = stream.reader(io, storage.read_buffer),
            .writer_state = stream.writer(io, storage.write_buffer),
        };
    }

    /// Reader interface consumed by the connection and split read half.
    pub fn reader(self: *Transport) *std.Io.Reader {
        return &self.reader_state.interface;
    }

    /// Writer interface consumed by the connection and split write half.
    pub fn writer(self: *Transport) *std.Io.Writer {
        return &self.writer_state.interface;
    }

    /// Closes the borrowed stream handle exactly once.
    ///
    /// The caller remains responsible for not closing the same handle through
    /// another copy. No wrapper calls this automatically.
    pub fn close(self: *Transport) void {
        self.stream.close(self.io);
    }

    /// Half-closes or fully shuts down the borrowed stream handle.
    pub fn shutdown(self: *Transport, how: std.Io.net.ShutdownHow) std.Io.net.ShutdownError!void {
        return self.stream.shutdown(self.io, how);
    }

    /// Detailed reader failure behind a mapped `error.IoError`.
    ///
    /// `connection.WebSocket` maps `std.Io.Reader.Error.ReadFailed` to
    /// `IoError`; the stream keeps the original cause here for diagnostics.
    /// Ordinary end-of-stream does not set this field.
    pub fn stream_read_error(self: *const Transport) ?std.Io.net.Stream.Reader.Error {
        return self.reader_state.err;
    }

    /// Detailed writer failure behind a mapped `error.IoError`.
    pub fn stream_write_error(self: *const Transport) ?std.Io.net.Stream.Writer.Error {
        return self.writer_state.err;
    }

    /// True after a native `WebSocket` or `Split` bound this transport.
    pub fn is_bound(self: *const Transport) bool {
        return self.bound;
    }
};

/// Native unsplit WebSocket over one `std.Io.net.Stream`.
///
/// Protocol behavior, automatic replies, masking, limits, and failure latches
/// are exactly `connection.WebSocket`. The transport pointer must outlive this
/// value and keep its address stable.
pub const WebSocket = struct {
    transport: *Transport,
    inner: connection.WebSocket,

    /// Binds a native transport to the connection policy layer.
    ///
    /// Transport buffers are checked against the connection storage before the
    /// connection is constructed. The same checks and error precedence as
    /// `connection.WebSocket.init` then apply.
    pub fn init(transport: *Transport, storage: ConnectionStorage, config: Config) Error!WebSocket {
        if (transport.is_bound()) return error.InvalidLength;
        try validate_connection_storage(transport, storage);

        const inner = try connection.WebSocket.init(transport.reader(), transport.writer(), storage, config);
        transport.bound = true;
        return .{ .transport = transport, .inner = inner };
    }

    /// Reads one raw wire frame, applying automatic pong and close policy.
    ///
    /// The returned payload borrows the connection's `frame_buffer` until the
    /// next read. Automatic replies are written and flushed before this returns.
    pub fn read_frame(self: *WebSocket) Error!Frame {
        return self.inner.read_frame();
    }

    /// Queues and drains one outbound frame without flushing.
    pub fn write_frame(self: *WebSocket, outgoing: Frame) Error!void {
        return self.inner.write_frame(outgoing);
    }

    /// Drains queued nodes and flushes the native writer.
    pub fn flush(self: *WebSocket) Error!void {
        return self.inner.flush();
    }

    pub fn is_closed(self: *const WebSocket) bool {
        return self.inner.is_closed();
    }

    pub fn role(self: *const WebSocket) Role {
        return self.inner.role();
    }

    pub fn max_message_size(self: *const WebSocket) usize {
        return self.inner.max_message_size();
    }

    pub fn tx_pending(self: *const WebSocket) usize {
        return self.inner.tx_pending();
    }

    pub fn is_at_wire_boundary(self: *const WebSocket) bool {
        return self.inner.is_at_wire_boundary();
    }

    /// Latched read failure, cleared only by `reset`.
    pub fn read_failure(self: *const WebSocket) ?Error {
        return self.inner.read_failure;
    }

    /// Latched write failure, cleared only by `reset_tx`.
    pub fn write_failure(self: *const WebSocket) ?Error {
        return self.inner.write_failure;
    }

    pub fn set_writev(self: *WebSocket, enabled: bool) void {
        self.inner.set_writev(enabled);
    }

    pub fn set_writev_threshold(self: *WebSocket, threshold: usize) void {
        self.inner.set_writev_threshold(threshold);
    }

    pub fn set_auto_close(self: *WebSocket, enabled: bool) void {
        self.inner.set_auto_close(enabled);
    }

    pub fn set_auto_pong(self: *WebSocket, enabled: bool) void {
        self.inner.set_auto_pong(enabled);
    }

    pub fn set_auto_apply_mask(self: *WebSocket, enabled: bool) void {
        self.inner.set_auto_apply_mask(enabled);
    }

    pub fn set_max_message_size(self: *WebSocket, max_size: usize) void {
        self.inner.set_max_message_size(max_size);
    }

    pub fn set_mask_keys(self: *WebSocket, mask_keys: connection.MaskKeySource) void {
        self.inner.set_mask_keys(mask_keys);
    }

    pub fn reset(self: *WebSocket) void {
        self.inner.reset();
    }

    pub fn reset_tx(self: *WebSocket) void {
        self.inner.reset_tx();
    }
};

/// Native split pair over one `std.Io.net.Stream`.
///
/// Both halves borrow the transport's reader and writer and keep independent
/// connection and zslay state, matching `split.Split`. Automatic obligations
/// are forwarded through the write half and flushed before a read returns.
pub const Split = struct {
    transport: *Transport,
    inner: split.Split,

    /// Binds a native transport to the split read and write halves.
    pub fn init(transport: *Transport, storage: SplitStorage, config: Config) Error!Split {
        if (transport.is_bound()) return error.InvalidLength;
        try validate_split_storage(transport, storage);

        const inner = try split.after_handshake_split(transport.reader(), transport.writer(), storage, config);
        transport.bound = true;
        return .{ .transport = transport, .inner = inner };
    }

    /// Reads one raw frame, routing automatic replies through the write half.
    pub fn read_frame(self: *Split) Error!Frame {
        return self.inner.read_frame();
    }

    /// Reads one raw frame, routing replies through a caller-supplied sink.
    pub fn read_frame_with(self: *Split, sink: anytype) Error!Frame {
        return self.inner.read_frame_with(sink);
    }

    /// Queues and drains one outbound frame without flushing.
    pub fn write_frame(self: *Split, outgoing: Frame) Error!void {
        return self.inner.write_frame(outgoing);
    }

    /// Drains queued nodes and flushes the native writer.
    pub fn flush(self: *Split) Error!void {
        return self.inner.flush();
    }

    pub fn is_closed(self: *const Split) bool {
        return self.inner.is_closed();
    }

    pub fn is_at_wire_boundary(self: *const Split) bool {
        return self.inner.is_at_wire_boundary();
    }

    /// Latched read-side failure, cleared only by `reset`.
    pub fn read_failure(self: *const Split) ?Error {
        return self.inner.read.inner.read_failure;
    }

    /// Latched write-side failure, cleared only by `reset_tx`.
    pub fn write_failure(self: *const Split) ?Error {
        return self.inner.write.failure();
    }

    pub fn set_writev(self: *Split, enabled: bool) void {
        self.inner.set_writev(enabled);
    }

    pub fn set_writev_threshold(self: *Split, threshold: usize) void {
        self.inner.set_writev_threshold(threshold);
    }

    pub fn set_auto_close(self: *Split, enabled: bool) void {
        self.inner.set_auto_close(enabled);
    }

    pub fn set_auto_pong(self: *Split, enabled: bool) void {
        self.inner.set_auto_pong(enabled);
    }

    pub fn set_auto_apply_mask(self: *Split, enabled: bool) void {
        self.inner.set_auto_apply_mask(enabled);
    }

    pub fn set_max_message_size(self: *Split, max_size: usize) void {
        self.inner.set_max_message_size(max_size);
    }

    pub fn reset(self: *Split) void {
        self.inner.reset();
    }

    pub fn reset_tx(self: *Split) void {
        self.inner.reset_tx();
    }
};

/// Validates the two direction buffers.
fn validate_pair(read_buffer: []u8, write_buffer: []u8) Error!void {
    if (read_buffer.len == 0 or write_buffer.len == 0) return error.InvalidLength;
    if (zslay.event.ranges_overlap(
        @intFromPtr(read_buffer.ptr),
        read_buffer.len,
        @intFromPtr(write_buffer.ptr),
        write_buffer.len,
    )) return error.InvalidLength;
}

/// Rejects transport buffers that alias unsplit connection storage.
fn validate_connection_storage(transport: *const Transport, storage: ConnectionStorage) Error!void {
    const tx_bytes: []const u8 = std.mem.sliceAsBytes(storage.tx_nodes);
    try validate_others(transport, &.{
        storage.frame_buffer,
        tx_bytes,
        storage.write_buffer,
        storage.close_buffer,
        storage.mask_scratch,
    });
}

/// Rejects transport buffers that alias either split half's storage.
fn validate_split_storage(transport: *const Transport, storage: SplitStorage) Error!void {
    const tx_bytes: []const u8 = std.mem.sliceAsBytes(storage.write.tx_nodes);
    try validate_others(transport, &.{
        storage.read.frame_buffer,
        storage.read.close_buffer,
        storage.read.compose_buffer,
        tx_bytes,
        storage.write.write_buffer,
        storage.write.close_buffer,
        storage.write.mask_scratch,
    });
}

/// Rejects overlap between either transport buffer and a storage region.
fn validate_others(transport: *const Transport, regions: []const []const u8) Error!void {
    const read_buffer = transport.reader_state.interface.buffer;
    const write_buffer = transport.writer_state.interface.buffer;

    for (regions) |region| {
        if (zslay.event.ranges_overlap(
            @intFromPtr(read_buffer.ptr),
            read_buffer.len,
            @intFromPtr(region.ptr),
            region.len,
        )) return error.InvalidLength;
        if (zslay.event.ranges_overlap(
            @intFromPtr(write_buffer.ptr),
            write_buffer.len,
            @intFromPtr(region.ptr),
            region.len,
        )) return error.InvalidLength;
    }
}
