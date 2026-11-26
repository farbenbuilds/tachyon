//! RFC 7692 permessage-deflate message payload codec over caller-owned storage.
//!
//! This module transforms complete message payloads with the raw DEFLATE
//! container. It knows nothing about opcodes, frames, RSV1, fragmentation,
//! control frames, or handshake negotiation; the caller supplies whole payloads
//! and decides when compression applies. Wire activation remains blocked on
//! negotiated RSV1 support in zslay: zslay rejects reserved bits and the
//! connection, fragment, split, handshake, and upgrade layers do not invoke
//! this codec.
//!
//! The sender flushes the compressed block stream to a byte boundary and
//! appends one `0x00` octet. The receiver serves the peer payload followed by
//! `00 00 ff ff` from a private reader adapter, completing an empty non-final
//! stored block. An empty message is the canonical one-byte `0x00` payload.
//! Sync-flush senders are supported as long as the message reaches a clean
//! block boundary with no unconsumed input. RFC 7692 prohibits a BFINAL block
//! because the end-of-message signal travels out of band, so rejecting one is
//! conformance rather than a tolerated deviation. When the overflowing block is
//! BFINAL, the codec reports `InvalidCompressedData` ahead of
//! `MessageTooLarge`; both errors are terminal.
//!
//! Both directions are zero-allocation and use only `std.compress.flate`.
//! `DeflaterStorage` is roughly 295 KiB and `InflaterStorage` roughly 69 KiB.
//! Storage must be initialized at its final address, must not be copied after
//! init, and must outlive the handle, because the compressor and decoder keep
//! pointers into storage fields. Input and output slices are caller-owned and
//! must not overlap each other or any byte of the handle or its storage; an
//! aliasing call fails with `AliasedBuffer` before any state changes unless a
//! fatal failure is already latched, which takes precedence.
//!
//! DEFLATE has no integrity or checksum. Malformed input that leaves a non-clean
//! boundary fails closed; some truncated or corrupted streams can still decode
//! to a shorter or wrong message, and appending the RFC 7692 tail can complete a
//! truncated compressed stream into a structurally valid one. Callers must
//! treat decompressed output as untrusted. `OutputTooShort` returns before the
//! compressor is touched; among failures that consume codec state, no other
//! failure is safely retryable in a context-dependent session. A writer
//! failure, a receiver message that does not fit, or a malformed receiver
//! stream latches until `reset`, but after consumed input (`MessageTooLarge`,
//! `InvalidCompressedData`, or `CompressionFailed`) the caller must close the
//! connection or renegotiate `no_context_takeover`. `reset` discards history
//! and is not recovery for a context-dependent session.
//!
//! Context takeover is the default. `no_context_takeover` reinitializes the
//! sender before each nonempty message and the decoder before each message;
//! `reset` discards context explicitly.

const std = @import("std");

const flate = std.compress.flate;

/// Bytes the receiver appends to a permessage-deflate payload to terminate the
/// sync flush as an empty non-final stored block.
pub const sync_tail = [4]u8{ 0x00, 0x00, 0xff, 0xff };

// Size of the private reader staging buffer. The decoder only reads fixed-size
// integers (at most four bytes) at a time, so sixteen bytes is ample.
const input_staging_len = 16;

// Size of the initialization writer buffer. `Compress.init` asserts a capacity
// greater than eight bytes, and an empty raw header writes nothing.
const output_scratch_len = 16;

const max_window_len = flate.max_window_len;

comptime {
    // The decoder peeks a u32 at a time; `Compress.init` requires a writer
    // capacity greater than eight bytes.
    std.debug.assert(input_staging_len >= @sizeOf(u32));
    std.debug.assert(output_scratch_len > 8);
}

/// Shared codec configuration.
pub const Config = struct {
    /// Drop history after each message in this direction.
    no_context_takeover: bool = false,
    /// RFC 7692 window size. A deflater requires 15 because Zig's compressor
    /// always uses the full window; keep outbound at 15. An inflater accepts
    /// 8..15 but does not enforce the negotiated LZ77 distance limit.
    /// `std.compress.flate.max_window_len` is a 64 KiB std history-buffer
    /// requirement, not the 32 KiB DEFLATE wire window. Future negotiation must
    /// reject values below 15 for sending or enforce the limit before
    /// advertising a smaller receive window.
    window_bits: u4 = 15,
};

/// Codec error set.
pub const Error = error{
    UnsupportedWindowBits,
    OutputTooShort,
    MessageTooLarge,
    InvalidCompressedData,
    CompressionFailed,
    SizeOverflow,
    AliasedBuffer,
};

// Returns whether two byte ranges share memory. Empty slices never overlap, and
// each pointer difference is taken in the positive direction so it cannot
// overflow.
fn slicesOverlap(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const a_start = @intFromPtr(a.ptr);
    const b_start = @intFromPtr(b.ptr);
    if (a_start <= b_start) return b_start - a_start < a.len;
    return a_start - b_start < b.len;
}

// Private reader that serves a caller slice followed by `sync_tail` as one
// continuous stream. It copies only through its small staging buffer.
const InputAdapter = struct {
    reader: std.Io.Reader,
    data: []const u8 = &.{},
    tail_pos: usize = sync_tail.len,

    fn init(staging: *[input_staging_len]u8) InputAdapter {
        return .{
            .reader = .{
                .vtable = &.{ .stream = stream },
                .buffer = staging,
                .seek = 0,
                .end = 0,
            },
        };
    }

    fn begin(self: *InputAdapter, data: []const u8) void {
        self.data = data;
        self.tail_pos = 0;
        self.reader.seek = 0;
        self.reader.end = 0;
    }

    fn pending(self: *const InputAdapter) []const u8 {
        if (self.data.len != 0) return self.data;
        return sync_tail[self.tail_pos..];
    }

    fn advance(self: *InputAdapter, n: usize) void {
        if (self.data.len != 0) {
            self.data = self.data[n..];
        } else {
            self.tail_pos += n;
        }
    }

    fn stream(
        r: *std.Io.Reader,
        w: *std.Io.Writer,
        limit: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        const self: *InputAdapter = @fieldParentPtr("reader", r);
        const src = self.pending();
        if (src.len == 0) return error.EndOfStream;
        const chunk = limit.sliceConst(src);
        if (chunk.len == 0) return 0;
        const n = try w.write(chunk);
        self.advance(n);
        return n;
    }
};

/// Caller-owned sender storage, roughly 295 KiB.
///
/// Initialize it at its final address and keep it alive for the handle's
/// lifetime. Do not copy it after `Deflater.init`: the compressor keeps
/// pointers into `output` and `history`. Input and output passed to
/// `Deflater.compress` must not overlap each other or any byte of this storage
/// or the handle; a call with overlapping buffers fails with `AliasedBuffer`
/// unless a failure is already latched.
pub const DeflaterStorage = struct {
    compressor: flate.Compress,
    history: [max_window_len]u8,
    output: std.Io.Writer,
    output_scratch: [output_scratch_len]u8,
};

/// Sender-side permessage-deflate handle borrowing a `DeflaterStorage`.
///
/// `compress` accepts one complete message and writes one complete wire
/// payload. Calls must not overlap, and the storage must outlive the handle.
pub const Deflater = struct {
    storage: *DeflaterStorage,
    config: Config,
    failure: ?Error = null,

    /// Initializes the compressor in `storage`. The storage address must stay
    /// stable for the lifetime of the handle.
    pub fn init(storage: *DeflaterStorage, config: Config) Error!Deflater {
        if (config.window_bits != 15) return error.UnsupportedWindowBits;
        var deflater: Deflater = .{ .storage = storage, .config = config };
        try deflater.reinitialize();
        return deflater;
    }

    /// Compresses one complete message into `output`.
    ///
    /// The buffer must hold at least `max_compressed_len(input.len)` bytes. A
    /// short buffer returns `OutputTooShort` before the compressor is touched,
    /// so its context remains valid. `input` and `output` must not overlap each
    /// other or any byte of this handle or its storage; an aliasing call returns
    /// `AliasedBuffer` before any state changes unless a failure is already
    /// latched. A latched failure takes precedence. A writer failure latches
    /// `CompressionFailed` until `reset`, but a context-dependent session is
    /// unrecoverable after consumed input and must close or renegotiate
    /// `no_context_takeover`.
    pub fn compress(self: *Deflater, input: []const u8, output: []u8) Error![]const u8 {
        if (self.failure) |failure| return failure;

        const storage_bytes: []const u8 = std.mem.asBytes(self.storage);
        const handle_bytes: []const u8 = std.mem.asBytes(self);
        if (slicesOverlap(input, output) or
            slicesOverlap(input, storage_bytes) or
            slicesOverlap(input, handle_bytes) or
            slicesOverlap(output, storage_bytes) or
            slicesOverlap(output, handle_bytes))
        {
            return error.AliasedBuffer;
        }

        const bound = try max_compressed_len(input.len);
        if (output.len < bound) return error.OutputTooShort;

        // An empty message has no input for the compressor to consume. The
        // canonical wire form is the single octet that terminates an empty
        // stored block once the receiver appends the sync tail.
        if (input.len == 0) {
            output[0] = 0x00;
            return output[0..1];
        }

        // With context takeover off the compressor must not see the previous
        // message's history. An empty message is skipped above, but the next
        // nonempty message still starts from a fresh compressor.
        if (self.config.no_context_takeover) try self.reinitialize();

        // Rebinding this field is safe: the compressor stores a pointer to the
        // field itself, not to the previous buffer. The nonempty preflight also
        // guarantees the caller buffer exceeds the eight-byte writer minimum.
        self.storage.output = .fixed(output);
        self.storage.compressor.writer.writeAll(input) catch {
            return self.latch(error.CompressionFailed);
        };
        self.storage.compressor.writer.flush() catch {
            return self.latch(error.CompressionFailed);
        };

        // The bound leaves ample room for the appended octet. Checking anyway
        // keeps a bad bound from becoming an out-of-bounds write.
        const end = self.storage.output.end;
        if (end >= output.len) return self.latch(error.CompressionFailed);
        output[end] = 0x00;
        return output[0 .. end + 1];
    }

    /// Discards the compressor context and clears the failure latch.
    ///
    /// This is not session recovery after consumed input under context
    /// takeover: the peer still holds the discarded history. Close the
    /// connection or renegotiate `no_context_takeover`.
    pub fn reset(self: *Deflater) Error!void {
        try self.reinitialize();
    }

    fn reinitialize(self: *Deflater) Error!void {
        self.storage.output = .fixed(&self.storage.output_scratch);
        self.storage.compressor = flate.Compress.init(
            &self.storage.output,
            &self.storage.history,
            .raw,
            .default,
        ) catch {
            self.failure = error.CompressionFailed;
            return error.CompressionFailed;
        };
        self.failure = null;
    }

    fn latch(self: *Deflater, err: Error) Error {
        self.failure = err;
        return err;
    }
};

/// Caller-owned receiver storage, roughly 69 KiB.
///
/// Initialize it at its final address and keep it alive for the handle's
/// lifetime. Do not copy it after `Inflater.init`: the decoder keeps pointers
/// to the adapter reader and the window. Input and output passed to
/// `Inflater.decompress` must not overlap each other or any byte of this
/// storage or the handle; a call with overlapping buffers fails with
/// `AliasedBuffer` unless a failure is already latched.
pub const InflaterStorage = struct {
    decompressor: flate.Decompress,
    window: [max_window_len]u8,
    staging: [input_staging_len]u8,
    adapter: InputAdapter,
};

/// Receiver-side permessage-deflate handle borrowing an `InflaterStorage`.
///
/// `decompress` accepts one complete wire payload and writes one complete
/// message. Calls must not overlap, and the storage must outlive the handle.
pub const Inflater = struct {
    storage: *InflaterStorage,
    config: Config,
    failure: ?Error = null,

    /// Initializes the decoder in `storage`. The storage address must stay
    /// stable for the lifetime of the handle.
    pub fn init(storage: *InflaterStorage, config: Config) Error!Inflater {
        switch (config.window_bits) {
            8...15 => {},
            else => return error.UnsupportedWindowBits,
        }
        var inflater: Inflater = .{ .storage = storage, .config = config };
        inflater.reinitialize();
        return inflater;
    }

    /// Decompresses one complete message into `output`.
    ///
    /// Exactly-full output succeeds only when the message ends at that byte;
    /// otherwise the failure is `MessageTooLarge`, or `InvalidCompressedData`
    /// when the overflowing block is BFINAL. A malformed stream, a boundary
    /// with unconsumed input or non-clean block state, or a BFINAL stream
    /// returns `InvalidCompressedData`; `InvalidCompressedData` and
    /// `MessageTooLarge` are both terminal. `input` and `output` must not
    /// overlap each other or any byte of this handle or its storage; an aliasing
    /// call returns `AliasedBuffer` before any state changes unless a failure is
    /// already latched. A latched failure takes precedence. DEFLATE has no
    /// integrity check, so some truncated or corrupted input can still decode to
    /// a shorter or wrong message, and appending the RFC 7692 tail can complete
    /// a truncated compressed stream into a structurally valid one; treat
    /// decompressed output as untrusted. A failure that has consumed decoder
    /// input latches until `reset`, but after consumed input (`MessageTooLarge`
    /// or `InvalidCompressedData`) the caller must close the connection or
    /// renegotiate `no_context_takeover`; `reset` discards history and is not
    /// recovery for a context-dependent session.
    pub fn decompress(self: *Inflater, input: []const u8, output: []u8) Error![]const u8 {
        if (self.failure) |failure| return failure;

        const storage_bytes: []const u8 = std.mem.asBytes(self.storage);
        const handle_bytes: []const u8 = std.mem.asBytes(self);
        if (slicesOverlap(input, output) or
            slicesOverlap(input, storage_bytes) or
            slicesOverlap(input, handle_bytes) or
            slicesOverlap(output, storage_bytes) or
            slicesOverlap(output, handle_bytes))
        {
            return error.AliasedBuffer;
        }

        // A zero-length payload is an empty message. The canonical sender form
        // is the one-byte 0x00 payload below, but accepting the empty slice
        // avoids rejecting a peer that omits the stored-block byte; an empty
        // message cannot produce output or advance the deflate history.
        if (input.len == 0) {
            if (self.config.no_context_takeover) self.reinitialize();
            return output[0..0];
        }

        if (self.config.no_context_takeover) self.reinitialize();
        self.storage.adapter.begin(input);
        self.storage.decompressor.err = null;

        var written_len: usize = 0;
        // Every iteration drains buffered output, consumes input, or returns,
        // and the caller's compressed slice is finite, so the loop terminates.
        while (true) {
            const chunk = self.storage.decompressor.reader.buffered();
            if (chunk.len != 0) {
                if (chunk.len > output.len - written_len) return self.overflowFailure();
                @memcpy(output[written_len..][0..chunk.len], chunk);
                written_len += chunk.len;
                self.storage.decompressor.reader.toss(chunk.len);
                continue;
            }

            self.storage.decompressor.reader.fillMore() catch |err| switch (err) {
                // A decoder that reaches `.end` saw BFINAL=1, which RFC 7692
                // prohibits on the wire.
                error.EndOfStream => return self.latch(error.InvalidCompressedData),
                error.ReadFailed => return self.finishAtBoundary(output, written_len),
            };
        }
    }

    /// Discards the decoder context and clears the failure latch.
    ///
    /// This is not session recovery after consumed input under context
    /// takeover: the peer's next message may reference the discarded history.
    /// Close the connection or renegotiate `no_context_takeover`.
    pub fn reset(self: *Inflater) Error!void {
        self.reinitialize();
    }

    // An overflowing BFINAL block is already an RFC 7692 violation, so report
    // it ahead of a message that merely exceeds the caller buffer.
    fn overflowFailure(self: *Inflater) Error {
        if (self.storage.decompressor.final_block) return self.latch(error.InvalidCompressedData);
        return self.latch(error.MessageTooLarge);
    }

    fn finishAtBoundary(self: *Inflater, output: []u8, written_len: usize) Error![]const u8 {
        const decompressor = &self.storage.decompressor;

        // `ReadFailed` carries the boundary signal in `err`, and only an input
        // EOF at a clean block boundary is a complete message.
        const boundary = decompressor.err orelse return self.latch(error.InvalidCompressedData);
        if (boundary != error.EndOfStream) return self.latch(error.InvalidCompressedData);
        if (decompressor.state != .block_header) return self.latch(error.InvalidCompressedData);
        if (decompressor.consumed_bits != 0) return self.latch(error.InvalidCompressedData);

        // The message must also end at an input boundary: bytes left in the
        // reader were not consumed by the decoder, so the payload did not end
        // where the block stream did. This is a structural check, not an
        // integrity check; DEFLATE has no checksum.
        if (decompressor.input.bufferedLen() != 0) return self.latch(error.InvalidCompressedData);

        // The failed fill may have decoded output before it hit the boundary;
        // that output belongs to the message.
        var total_len = written_len;
        const chunk = decompressor.reader.buffered();
        if (chunk.len > output.len - total_len) return self.overflowFailure();
        @memcpy(output[total_len..][0..chunk.len], chunk);
        total_len += chunk.len;
        decompressor.reader.toss(chunk.len);

        // Leave the decoder ready for the next takeover message.
        decompressor.err = null;
        return output[0..total_len];
    }

    fn reinitialize(self: *Inflater) void {
        self.storage.adapter = InputAdapter.init(&self.storage.staging);
        self.storage.decompressor = flate.Decompress.init(
            &self.storage.adapter.reader,
            .raw,
            &self.storage.window,
        );
        self.failure = null;
    }

    fn latch(self: *Inflater, err: Error) Error {
        self.failure = err;
        return err;
    }
};

/// Safe upper bound for one compressed message, including the appended octet.
///
/// The bound is deliberately loose because Zig's compressor may emit stored
/// blocks and sync-flush overhead in addition to the compressed payload.
pub fn max_compressed_len(input_len: usize) Error!usize {
    if (input_len == 0) return 1;
    const quarter = input_len / 4;
    const with_quarter = std.math.add(usize, input_len, quarter) catch return error.SizeOverflow;
    return std.math.add(usize, with_quarter, 1024) catch return error.SizeOverflow;
}
