# Codebase Map

tachyon is a Zig 0.17.1 WebSocket implementation that recreates the behavior of
denoland/fastwebsockets 0.10.0 while delegating the RFC 6455 framing engine to
[farbenbuilds/zslay](https://github.com/farbenbuilds/zslay). This document maps
the current tree, the zslay ownership boundary, the connection architecture, and
the fastwebsockets surface each target module owns.

The boundary is verified against the pinned zslay sources (`src/root.zig`,
`src/types.zig`, `src/frame.zig`, and `src/event.zig`) and the fastwebsockets
0.10.0 behavioral target (`src/close.rs`, `src/frame.rs`, `src/lib.rs`,
`src/fragment.rs`, `src/handshake.rs`, and `src/upgrade.rs`). zslay is a framing
engine with a bounded connection state machine, not only a header codec.

The 0.10.0 surface is the parity baseline, not the ceiling. Backpressure,
streaming messages, native `std.Io` transport, permessage-deflate, and pub/sub
are planned extension modules at the edge. Incremental UTF-8 validation is
implemented in `src/utf8.zig`: the raw connection read path validates clear FIN
text frames and the fragment collector validates assembled messages across
fragments. None of them may change the zero-allocation frame core or duplicate
zslay wire logic.

## Current State

The repository now contains the Zig package plus the environment and
documentation foundation:

- `build.zig` and `build.zig.zon` define the public `tachyon` module, the
  `libtachyon.a` static library, Debug and ReleaseSafe test steps over
  `tests/main.zig`, the `check` step, and the pinned zslay dependency.
- `src/root.zig` is the module entry point; it re-exports zslay, the frame
  facade, the UTF-8 validator, the WebSocket error model, the fragment
  accumulator and collector, the connection layer, the split read and write
  halves, and the HTTP handshake primitives.
- `src/frame.zig` implements the frame facade: `Frame`, `Payload`, the `OpCode`
  and `CloseCode` aliases with conversions, `unmask`/`unmask_at` delegations,
  the header-length bridge, `std.Io.Writer` vectored writes, and caller-buffer
  writes.
- `src/error.zig` implements the fastwebsockets 0.10.0 error taxonomy, zslay
  boundary normalization, `std.Io` reader/writer/stream mappings, the status
  out-parameter helper, and the close-code policy.
- `src/utf8.zig` implements incremental zero-allocation text validation. Complete
  ranges use `std.unicode`; the `State` value carries only a split code point's
  remaining bytes, and `validate_reader` adapts arbitrary `std.Io.Reader` chunk
  sizes without allocating. `Frame.is_utf8` delegates to the same validator.
- `src/fragment.zig` implements the read-side fragment layer. `Fragments`
  accumulates text and binary continuations into a caller-owned message buffer
  and validates text incrementally across fragments, including code points split
  between frames. `FragmentCollector` drives `zslay.Conn` over a caller-provided
  `std.Io.Reader` with a caller-owned frame buffer, unmasks inbound frames in
  place, and returns control frames to the caller without disturbing the
  in-progress message. It sends no automatic pong or close replies.
- `src/connection.zig` implements the role-aware `WebSocket` policy over one
  `zslay.Conn`. The caller supplies a `std.Io.Reader`, a `std.Io.Writer`, and
  caller-owned storage: `frame_buffer` for one inbound payload, `tx_nodes` for
  the bounded transmit queue, `write_buffer` for copied writes, `close_buffer`
  for synthesized 1002 replies, and optional `mask_scratch` for masked vectored
  writes. `Options` defaults `auto_apply_mask`, `auto_close`, `auto_pong`, and
  `writev` to true, the writev threshold to 1024 bytes, and the exclusive
  maximum message size to 64 MiB. `MaskKeySource` is a seeded ChaCha8 source
  supplied by the caller. The raw read path suppresses pings and writes an exact
  pong, validates a close reason as UTF-8 before the close code, echoes a valid
  close payload exactly when no close was already observed, and answers an
  invalid code with 1002 and the validated reason when it fits `close_buffer`,
  otherwise an empty reason. Automatic pong and close replies are flushed before
  `read_frame` returns. `read_event` is the shared read step: `read_frame` loops
  over it and sends the reply. A client with `auto_apply_mask` off does not attempt
  automatic replies: pings are delivered, and closes are validated but not
  echoed or answered with 1002.
  `closed` gates non-close reads and writes, read failures latch until `reset`
  and write failures until `reset_tx`, writes use the vectored path above the
  threshold and the copied path at or below it, and a zero maximum rejects
  before any byte is consumed. `FragmentCollector` remains the assembled-message
  API.
- `src/split.zig` implements the split read and write surface. `WebSocketRead`
  and `WebSocketWrite` each own an independent `connection.WebSocket` and
  `zslay.Conn`, because zslay couples receive and transmit state in one value.
  The read half drives RX through `WebSocket.read_event` and never writes; the
  write half drives TX through `write_frame` and `flush` and never reads. Both
  halves may share the external `std.Io.Reader` and `std.Io.Writer` pointers
  because each uses one direction. `Split` couples them, `after_handshake_split`
  (also exported as `init`) builds the pair, and all `ReadStorage`,
  `WriteStorage`, and `Storage` regions are caller-owned and zero allocation.
  Automatic pong and close obligations are returned by `read_event` and
  forwarded through a sink with `send_obligation(Frame)`, `is_closed()`, and
  `failure()`; `WebSocketWrite.send_obligation` writes and flushes each reply.
  An invalid close code still fills its 1002 reply before returning
  `InvalidCloseCode`, and non-close frames are refused once either half is
  closed. `FragmentCollectorRead` wraps a `WebSocketRead` by value with a
  caller-owned `message_buffer`, assembles continuations and split UTF-8 code
  points, and rejects a `message_buffer` overlapping the read `frame_buffer`
  with `InvalidLength`.
- `src/handshake.zig` implements the RFC 6455 handshake boundary. The caller
  supplies a `std.Io.Reader`, a `std.Io.Writer`, and a header buffer. The module
  generates 16 key bytes through `std.Io.randomSecure`, encodes them as
  canonical base64, re-exports the accept GUID and streaming accept-token
  derivation from `src/upgrade.zig`, writes a GET upgrade request, reads and
  validates the 101 response, and validates server requests before writing the
  101 reply. `write_response` uses the re-exported `compute_accept_token` to
  derive `Sec-WebSocket-Accept`. It accepts `Connection` and `Upgrade` token
  lists, rejects duplicate key, version, accept, and Host headers, rejects
  body-bearing upgrade and 101 heads, requires an origin-form target and RFC
  token header names, verifies the accept token as deliberate hardening, and
  leaves bytes after the header buffered in the reader for the frame path. The
  head scan is chunked and bounded by caller storage, not by the transport
  reader's internal buffer. `is_request` is the token-only probe;
  `validate_request` is the strict server gate. RFC 7692 offer parsing and RFC
  8441 extended CONNECT are deliberately deferred with the compression and
  HTTP/2 extension work. The accept GUID literal and accept-token derivation
  are owned by `src/upgrade.zig`; this module re-exports those names for client
  callers.
- `src/upgrade.zig` implements the RFC 6455 server upgrade call order. It owns
  `accept_guid`, `accept_token_len`, `AcceptTokenBuffer`, and the streaming
  SHA-1/base64 `compute_accept_token`; `src/handshake.zig` re-exports those four
  names so client handshake callers keep working. `incoming` reads and strictly
  validates a request through `handshake.read_request` without writing.
  `IncomingUpgrade.upgrade` and the one-shot `upgrade` force `config.role =
  .server` on a copy, construct the split from caller storage with
  `split.after_handshake_split`, and only then write the 101 through
  `handshake.write_response` and flush; writer failures map to `IoError`, and a
  failed write or flush discards the constructed zero-allocation split. Split
  construction validates caller storage and configuration without I/O, so those
  failures precede every response byte. `upgrade_async` returns
  `UpgradeFut = std.Io.Future(Error!Upgrade)`; the future and the resolved
  `Upgrade` borrow the reader, writer, head storage, split storage, and request
  view, so callers must await or cancel before releasing them. No response byte
  precedes both successful request validation and successful split-storage
  validation, bytes after the request head stay buffered in the reader, and all
  storage is caller-owned and zero allocation; the module opens no socket or
  task outside the caller-provided `std.Io`.
- `build.zig.zon.nix`, `build.zig.zon.json`, and `build.zig.zon.txt` are
  generated by zon2nix; the flake consumes the Nix expression for offline test
  and package builds.
- `flake.nix` and `flake.lock` provide the Zig 0.17.1 environment and zon2nix.
- `.envrc`, `.gitignore`, `.gitattributes`, and `.pre-commit-config.yaml`
  configure the shell, repository hygiene, and generated-file handling.
- `scripts/update_zon_files.sh` regenerates the dependency views.
- The root guides, shared skill pack, graphify integration, agent definitions,
  `.github` metadata, and project banner document and support the project.

The client handshake and shared server upgrade primitives are implemented in
`src/handshake.zig`, and `src/upgrade.zig` implements the server call order over
them. The split halves are implemented in `src/split.zig`. The test suite covers
the dependency boundary, the error model, the frame facade, the incremental
UTF-8 validator, the fragment accumulator and collector, the connection policy,
raw frame path, and write paths, split reads and writes, the HTTP handshake, and
the server upgrade call order, including key canonicality, token lists,
duplicate headers, status and accept failures, bounded head reads, coalesced
frame bytes, validated-only `incoming`, split construction before the 101 write
and flush, the forced server role, and the async future and its borrows. The
suite lives under `tests/` and is aggregated by `tests/main.zig`; category
folders mirror the protocol layers, `tests/support.zig` holds shared fixtures,
and `tests/module-test/module_test.zig` adds fragment, connection, split, and
handshake re-export tests. Library sources contain no test blocks.

## Target Runtime Flow

### Frame encoding

`Frame` is the fastwebsockets-facing facade; it is not a second codec. Header
serialization delegates to `zslay.encode_header`, which derives and validates
the RFC 6455 length marker, control-frame limits, reserved bits, and
masking-key consistency. Callers either set `FrameHeader.payload_len` with
`zslay.frame.length_marker` or use `zslay.Conn.prepare_frame`, which validates
the payload rules and serializes the header. `queue_frame` is the call that
enforces fragment order and queue capacity; preparing a frame alone does not.

`Frame.writev` serializes the header into a stack buffer and drains header and
payload with one `std.Io.Writer.writeVecAll`, which retries partial writes so
neither byte range is dropped. `Frame.write` copies the header and payload into
a caller-owned buffer and returns the written slice, rejecting a short buffer
with `BufferTooShort`. Neither path allocates.

### Frame masking

`tachyon.unmask` is a one-line delegation to `zslay.mask` at key position zero;
`tachyon.unmask_at` forwards the running offset for chunked payloads. zslay XORs
in wide-word chunks while preserving the four-byte key schedule. Payload memory
stays caller-owned. There is no tachyon masking loop and no separate masking
module.

`zslay.Conn` validates mask direction and exposes masking keys and payload
offsets, but it never XORs payload bytes. `prepare_frame` validates payload
properties, including close payloads, and serializes the header; it does not
mask. The connection layer calls `zslay.mask` for inbound and outbound
payloads. `FrameNode.payload` is `[]const u8`, so keep queued payloads
unmasked and mask chunks into caller-owned scratch at write time using
`get_tx_payload_offset` and `unmask_at`. Masking a close payload before
`prepare_frame` or `queue_frame` would corrupt the code and reason that zslay
validates.

### Async transport

tachyon uses Zig 0.17.1 `std.Io` asynchronous I/O for sockets, streams, and
examples. It does not depend on libxev or another event-loop library. uWebZockets
owns its own libxev-based engine; tachyon is a separate library with a standard
library transport boundary.

The protocol core remains synchronous and I/O-agnostic. The connection layer
accepts caller-provided readers and writers, so an application can drive it from
`std.Io`, a test harness, or an in-memory buffer without changing frame or
connection behavior.

### Connection reads

`src/connection.zig` implements the role-aware `WebSocket` policy over one
`zslay.Conn`. `WebSocket.init` consumes a caller-provided `std.Io.Reader` and
`std.Io.Writer` plus caller-owned `Storage`: `frame_buffer` bounds one inbound
payload, `tx_nodes` is the bounded zslay transmit queue, `write_buffer`
composes copied writes, `close_buffer` holds a synthesized 1002 payload, and
optional `mask_scratch` accelerates masked vectored writes. The byte buffers
and transmit nodes must not overlap; `write_buffer` must be longer than
`zslay.MaxFrameHeaderLen`, and `close_buffer` must be at least two bytes. A
client must supply a `MaskKeySource`, and automatic replies need at least one
`tx_nodes` entry when enabled. `init` clamps `max_message_size` to
`zslay.MaxPayloadLen` and derives zslay's inclusive limits as
`max_message_size - 1` when nonzero.

`read_frame` returns one raw wire frame whose payload borrows `frame_buffer`
until the next read. `zslay.Conn` owns header staging, wire decode,
masking-direction checks, fragment ordering, and frame and cumulative message
limits. tachyon then applies fastwebsockets policy:

- with `auto_apply_mask` on, a server unmasks inbound client payloads in place
  and clears the key; with it off, a masked frame is delivered with its masking
  key set, and control replies that need clear bytes are skipped. A client with
  `auto_apply_mask` off does not attempt automatic replies: pings are delivered,
  and closes are validated but not echoed or answered with 1002,
- with `auto_pong` on, a ping is suppressed and answered with an exact pong that
  is flushed before `read_frame` returns. A masked ping with `auto_apply_mask`
  off, or any ping for a client with `auto_apply_mask` off, is delivered
  without a reply. With `auto_pong` off, the ping is delivered,
- with `auto_close` on, the reason is validated as UTF-8 before zslay's close
  predicate. Invalid UTF-8 returns `InvalidUTF8` with no reply; an invalid code
  returns `InvalidCloseCode` and sends 1002 with the validated reason when it
  fits `close_buffer`, otherwise with an empty reason; a valid close is returned
  and, unless a close was already observed, echoed with the exact payload. The
  reply is flushed before `read_frame` returns, unless the client has
  `auto_apply_mask` off: then the close is validated but no echo or 1002 is
  sent. With `auto_close` off, the payload is delivered without code or UTF-8
  validation and without an echo. zslay's header-level checks still apply, so a
  one-byte close is rejected as `ProtocolError` before policy runs,
- clear FIN text frames are validated before delivery; non-FIN fragments and
  continuations are delivered raw, because a code point may span fragments,
- after a close write, non-close reads return `ConnectionClosed` until the peer
  close arrives. `ConnectionClosed` is not latched, so the peer close remains
  deliverable,
- a zero maximum returns `FrameTooLarge` before any byte is consumed and does
  not latch. A read failure without an automatic reply latches inside
  `read_event` until `reset`, except `ConnectionClosed`; an error that also fills
  `reply_out` is not latched there, and `read_frame` latches it only after a
  successful send. A latched write failure also blocks reads because automatic
  replies could not be honored.
  `reset` is safe only when `is_at_wire_boundary()` is true or the transport is
  discarded.

`read_event(was_closed, reply_out)` is the shared read step. It clears
`reply_out`, applies policy to one wire frame, and returns the frame or `null`
after consuming a suppressed ping; a pong, close echo, or 1002 reply is placed
in `reply_out` without writing. `read_frame` loops over it, sends each reply, and
latches the originating read error only after a successful send. A transport
failure during that send leaves the read latch clear and is owned by
`write_failure`, so `reset_tx` alone recovers; a prepare or queue failure before
any bytes are emitted is latched as a read failure. Split reads call it directly
and forward the reply through a sink. An invalid close code still fills its 1002
reply before returning `InvalidCloseCode`, and non-close frames are refused once
either half is closed. The unsplit behavior is unchanged.

The connection derives both zslay limits from its exclusive option and never
duplicates the accounting. zslay 0.5.0 has no limit setter, so
`set_max_message_size` writes `Conn.max_frame_len` and `Conn.max_message_len`
directly and reads the public in-flight `rx_fragment.message_len` and
`tx_fragment.message_len` to clamp the cumulative limit so zslay's fragment
invariant holds. The new per-frame limit applies to the next header
immediately, while the cumulative limit applies at the next frame boundary.
Replace this direct-field coupling with a zslay setter when one lands.

### Connection writes

`write_frame` queues and synchronously drains one outbound frame. The payload
must be clear; a pre-masked frame is rejected with `PayloadMasked` so zslay
validates close bytes on the clear payload. An outbound payload must not overlap
`tx_nodes`, `write_buffer`, `close_buffer`, or `mask_scratch`; a payload borrowed
from `frame_buffer` is allowed for echoes. The connection uses
`zslay.Conn.prepare_frame` for payload validation and header serialization and
`queue_frame` for fragment ordering and queue capacity, then drains the queue
into the caller's `std.Io.Writer`. Application writes do not flush the writer;
`flush` drains the queue and calls `writer.flush`. Automatic pong and close
replies are the exception: `read_frame` flushes them before returning.

A client masks outbound frames with the next key from its `MaskKeySource` when
`auto_apply_mask` is on; a client with it off fails zslay's masking-direction
check with `PayloadNotMasked`. A server writes unmasked frames. `prepare_frame`
never XORs payload bytes, so the connection masks chunks at write time with
`zslay.mask` and the running offset. When `writev` is on and the payload is
longer than `writev_threshold`, the header and one payload chunk go out with
`writeVecAll`; masked chunks use `mask_scratch` when it exists, and an empty
scratch falls back to the copied path. At or below the threshold, the header and
a payload chunk are composed in `write_buffer`, and a payload larger than that
buffer is chunked rather than grown. No path allocates.

A successful close write sets `closed`; data writes after it return
`ConnectionClosed`, while repeated close writes are still serialized.
`prepare_frame` and `queue_frame` add close-payload validation, ping/pong
preemption, and `QueueFull`, which is deliberate hardening beyond
fastwebsockets 0.10.0. The derived limits also bound outbound frames: a payload
that reaches the exclusive maximum fails `FrameTooLarge`, so while the maximum
is zero only empty frames pass. A write failure is latched and returned by later
writes and reads; a partial write is never retried on the same transport.
`reset_tx` clears the queue, the latch, and `closed`, and is safe only when the
transport is discarded. Outbound text is not UTF-8 validated, matching
fastwebsockets and zslay. Send close frames through `write_frame`, not the raw
`Frame.write` or `Frame.writev` paths, so zslay validates the close payload.

### Handshake and upgrade

`src/handshake.zig` implements the client handshake and the shared server
upgrade primitives over `std.Io.Reader` and `std.Io.Writer`. The client path
generates 16 bytes through `std.Io.randomSecure`, encodes them as canonical
base64, writes a GET request with `Host`, `Upgrade`, `Connection`,
`Sec-WebSocket-Key`, and `Sec-WebSocket-Version: 13`, flushes the writer, reads
the response head into caller-owned storage, and exposes the
fastwebsockets-named `verify` gate for `101 Switching Protocols`,
`Upgrade: websocket`, `Connection: Upgrade`, and, as deliberate hardening beyond
fastwebsockets 0.10.0, `Sec-WebSocket-Accept`. `client_with_key` is the
deterministic counterpart for tests or a caller-supplied key source.

The server path exposes `is_request` for the `Connection` and `Upgrade` token
probe and `validate_request` as the strict gate: GET over HTTP/1.1, both token
lists, exactly one `Sec-WebSocket-Version: 13`, and exactly one canonical
`Sec-WebSocket-Key`. `write_response` derives the accept token through the
re-exported `compute_accept_token` and emits the 101 response. The RFC 6455 GUID
is defined once as `accept_guid` in `src/upgrade.zig` and hashed incrementally
with the key there, so `src/handshake.zig` adds no literal, fixed concatenation
buffer, or empty-token fallback.

`read_head` stops exactly after the blank line and leaves following bytes
buffered in the `std.Io.Reader`, so a server may coalesce the 101 response with
the first WebSocket frame. Header storage is caller-owned and bounded; a short
buffer fails with `BufferTooShort`, and a transport failure maps to `IoError`.

`src/upgrade.zig` implements the server call order over those primitives.
`incoming` reads and strictly validates the request into `IncomingUpgrade`
without writing. `IncomingUpgrade.upgrade` and the one-shot `upgrade` force the
server role on a copy of the split config, construct the split from caller
storage with `split.after_handshake_split`, and only then write the 101 through
`handshake.write_response` and flush. Split construction validates caller
storage and configuration without I/O, including `write_buffer`, `close_buffer`,
`tx_nodes`, and region overlap, so those failures precede every response byte; a
failed 101 write or flush discards the already-constructed zero-allocation
split. `upgrade_async` runs the same call order through `std.Io.async` and
returns `UpgradeFut = std.Io.Future(Error!Upgrade)`; the future and the resolved
`Upgrade` borrow the reader, writer, head storage, split storage, and request
view, so callers must await or cancel before releasing them. No response byte
precedes both successful request validation and successful split-storage
validation, coalesced bytes stay buffered in the reader, and
`is_upgrade_request` remains the token-only routing probe. The accept GUID and
streaming accept-token derivation live in this module; `src/handshake.zig`
re-exports them for the client path.

The one-shot `upgrade` does not inspect `Origin`, matching fastwebsockets; it is
not an authentication boundary. Callers with cookie or ambient authentication
should use `incoming`, inspect `request.head`, and apply origin policy before
`.upgrade`. `IncomingUpgrade` fields are public, so callers that need the
validation guarantee must obtain the value from `incoming`.

### Fragmentation

`src/fragment.zig` implements the read side. `Fragments` accumulates text and
binary continuations into a caller-owned message buffer and validates text as
one UTF-8 stream, carrying a split code point in `utf8.State`; a FIN text
continuation that ends inside a code point returns `InvalidUTF8`. `Fragments`
returns an unfragmented data frame with its borrowed payload, returns control
frames immediately without touching the in-progress message, and fails closed
with `InvalidUTF8`, `InvalidFragment`, `InvalidContinuationFrame`,
`FrameTooLarge`, or `BufferTooShort`. Masked payloads are rejected with
`PayloadMasked` before validation or state change, because the accumulator
operates on clear bytes and never validates ciphertext as UTF-8. The standalone
accumulator has no built-in message cap, so direct users bound input
themselves, and incoming payload bytes must not alias its message buffer
because the copies use `@memcpy`.

`FragmentCollector` takes a caller-provided `std.Io.Reader`, a `frame_buffer`
that bounds one frame payload, and a `message_buffer` that bounds one collected
message. `frame_buffer` must hold the largest frame the configured limit can
accept, matching the `decoded.payload_len` check; a frame that fits zslay's
limit but not `frame_buffer` fails closed with
`BufferTooShort` after the header is consumed. `message_buffer` should hold at
least `max_message_size - 1` bytes for full limit parity. The collector drives
`zslay.Conn` with `advance_rx`, relies on zslay for continuation ordering,
control-frame validation, mask direction, and cumulative frame/message limits,
and unmasks inbound payloads in place with `zslay.mask`. Returned payloads
borrow `frame_buffer` or `message_buffer` until the next `read_frame`.
`max_message_size` is exclusive: `init` rejects values above
`zslay.MaxPayloadLen` with `InvalidLength`, configures zslay's inclusive limits
as `max_message_size - 1`, and a zero limit returns `FrameTooLarge` before any
byte is consumed. `read_frame` reports `UnexpectedEOF` for a short or zero read
and `IoError` for a reader failure.

Every protocol, frame, and I/O `read_frame` failure is latched and returned by
later calls until `reset`. A zero `max_message_size` is a configuration
rejection that returns `FrameTooLarge` before any byte is consumed and does not
latch. That latch keeps zslay's fragment accounting and the tachyon accumulator
from drifting apart after a rejected decoded frame, where zslay has already
advanced but the accumulator has not. `reset` is safe only when `is_at_wire_boundary()`
is true, or when the transport is discarded; a header or payload read that
failed mid-frame leaves the reader advanced, and resetting protocol state does
not rewind it. `is_at_frame_boundary()` means "wire boundary and no message in
progress", while `is_at_wire_boundary()` alone is the reset-safety predicate
because it only requires the next wire byte to start a frame.

Close frames are returned after zslay's header-level length checks only. The
caller or the connection layer must call `zslay.validate_close_payload` before
acting on the close code or reason, or echoing the close; the collector does
not validate close codes or UTF-8 reasons. The collector is deliberately
read-only: control frames go to the caller, and automatic pong/close replies
belong to the connection layer.

### Split halves

`src/split.zig` implements the split read and write surface. `zslay.Conn`
couples receive and transmit state in one value, so a split pair owns one
independent `connection.WebSocket` and `zslay.Conn` per half. The read half,
`WebSocketRead`, drives RX through `WebSocket.read_event` and never writes; the
write half, `WebSocketWrite`, drives TX through `write_frame` and `flush` and
never reads. Both halves may share the same external `std.Io.Reader` and
`std.Io.Writer` pointers because each uses one direction. `Split` couples the
two halves, and `after_handshake_split` (also exported as `init`) builds the
write half first, then the read half, from caller-owned `Storage`.

Automatic pong and close obligations are returned by `read_event` and forwarded
through a sink. `WebSocketRead.read_frame(sink)` requires
`sink.send_obligation(Frame)`, `sink.is_closed()`, and `sink.failure()`.
`WebSocketWrite` implements all three; `send_obligation` writes the reply and
flushes it before returning. A successful close reply, including a 1002, marks
the read half closed even when the sink is external. An invalid close code still
fills its 1002 reply before returning `InvalidCloseCode`; a successful send also
latches `InvalidCloseCode` on the read half. A transport failure while sending
that reply leaves the read latch clear, so `reset_tx` recovers, while a prepare
or queue failure still latches the send error. A close returned under
`auto_close` is terminal even when its echo goes to an external sink.
`Split.write_frame` allows repeated closes but refuses non-close frames once
either half is closed. `Split.read_frame` uses its write half as the sink;
`read_frame_with` accepts another sink.

Storage is caller-owned and nothing allocates. `ReadStorage` holds
`frame_buffer` for one inbound payload, `close_buffer` for a synthesized 1002
reply, and a constructor-required `compose_buffer` that the read path never
writes and that must be longer than `zslay.MaxFrameHeaderLen`. `WriteStorage`
holds `tx_nodes` for the bounded transmit queue, `write_buffer`, `close_buffer`,
and optional `mask_scratch`. The halves should keep their storage regions
disjoint because a read reply borrows read storage while the write half queues
and drains it.

`FragmentCollectorRead` wraps a `WebSocketRead` by value plus a caller-owned
`message_buffer` and owns a `Fragments` accumulator. It forwards obligations
through the sink, assembles continuations and split UTF-8 code points, rejects a
`message_buffer` that overlaps the read `frame_buffer` with `InvalidLength`, and
latches read and accumulation failures until `reset` except `ConnectionClosed`,
which is returned without latching so a later peer close stays deliverable, the
zero-maximum `FrameTooLarge` configuration rejection, and a sink-owned transport
failure: when `sink.failure()` is set, the collector leaves its own latch clear,
so the write latch owns recovery and `reset_tx` allows the next read. `reset`
clears the collector latch, the read latch, and any in-progress message; it is
safe when the read half is at `is_at_wire_boundary()` or the transport is
discarded, because reset deliberately discards the in-progress message. The
unsplit `FragmentCollector` remains deliberately read-only: control frames go to
its caller, and automatic pong and close replies belong to the connection or
split path. Wire state, masking direction, fragment ordering, limits, close
policy, and the transmit queue still belong to zslay.

## Target Source Layout

| File | Purpose |
| --- | --- |
| `src/root.zig` | Public module entry point and re-exports. |
| `src/frame.zig` | `Frame` facade, `Payload`, `OpCode`/`CloseCode` aliases and conversions, masking delegates, header-length bridge, and write paths. |
| `src/utf8.zig` | Implemented extension: incremental zero-allocation UTF-8 validation with `std.unicode` complete ranges, a split code-point `State`, and an optional `std.Io.Reader` adapter. |
| `src/error.zig` | `WebSocketError` set, zslay and `std.Io` mappings, descriptions, close-code policy, and classification helpers. |
| `src/backpressure.zig` | Planned extension: byte/frame watermarks and admission policy over zslay's bounded queue. |
| `src/connection.zig` | Implemented: role-aware `WebSocket` policy over `zslay.Conn`, caller-owned storage, automatic pong and close replies, seeded mask source, exclusive limits, closed gating, failure latches, and vectored or copied writes. |
| `src/fragment.zig` | Implemented: `Fragments` accumulator and read-side `FragmentCollector` over `zslay.Conn`, caller-owned frame/message buffers, streaming UTF-8, and completed-message delivery. |
| `src/stream.zig` | Planned extension: chunked message reader/writer for large messages without whole-message buffering. |
| `src/split.zig` | Implemented: `WebSocketRead`, `WebSocketWrite`, and `Split` over independent `connection.WebSocket`/`zslay.Conn` values, caller-owned `ReadStorage`/`WriteStorage`, sink-forwarded obligations, and `FragmentCollectorRead`. |
| `src/native_stream.zig` | Planned extension: `std.Io.Reader`/`std.Io.Writer` adapter for `std.Io.net.Stream`. |
| `src/deflate.zig` | Planned extension: RFC 7692 permessage-deflate state, deflater, inflater, and context takeover. |
| `src/pubsub.zig` | Planned extension: bounded topic hub and fanout over the frame/stream API. |
| `src/handshake.zig` | Implemented: RFC 6455 client handshake and shared server upgrade primitives over `std.Io.Reader`/`Writer`, key generation, accept-token re-exports from `src/upgrade.zig`, bounded head parsing, request validation, and response construction. |
| `src/upgrade.zig` | Implemented: RFC 6455 server upgrade call order over the validated `handshake` request and response primitives, including the accept GUID and accept-token derivation, `incoming` validation without writing, split construction from caller storage before the 101 write and flush, the forced server role, and `upgrade_async` over `std.Io.Future`. |
| `tests/main.zig` | Aggregates every category test file for the Debug and ReleaseSafe test steps. |
| `tests/support.zig` | Shared fixtures and test-only protocol readers and writers. |
| `tests/<category>-test/` | Unit coverage grouped by area: module, error, frame, UTF-8, fragment, connection, split, handshake, and upgrade. |
| `tests/<integration>-test/` | Planned Autobahn, fuzz, and loopback integration suites; no adapter exists yet. |
| `src/bench.zig` | Frame, connection, streaming, and extension microbenchmarks. |

The layout follows the fastwebsockets module split, with Zig-specific names and
no hidden allocator or runtime dependency. The handshake/upgrade pair
deliberately forms a small re-export cycle: `src/upgrade.zig` uses the handshake
request and response primitives, and `src/handshake.zig` re-exports the
accept-token names from `src/upgrade.zig`. Treat the pair as one dependency
unit rather than a strict ordering.

The unit suite under `tests/` is current, and `tests/main.zig` is its only
aggregator. Future Autobahn, fuzz, and loopback suites belong under `tests/` as
new integration category folders; none is implemented yet. Library sources
contain no test blocks.

The target layout deliberately contains no `src/close.zig` or `src/mask.zig`.
The close predicate, payload validator, masking routine, and outgoing close
validation live in zslay; inbound close policy and the echo stay in tachyon. If
an API-parity helper needs a home, put aliases and one-line delegations in
`src/frame.zig`; do not create a second policy module.

Rows marked planned extension are roadmap items; their files do not exist yet.
The current agent definitions own only current files. Extend the planned owner
in `AGENT_DIRECTORY.md` and the matching agent definitions before starting one
of these modules.

## fastwebsockets to tachyon Mapping

| fastwebsockets | tachyon | Status |
| --- | --- | --- |
| `Frame` | `Frame` facade over zslay headers | Implemented |
| `OpCode` | `OpCode` alias of `zslay.Opcode` | Implemented (alias) |
| `Payload` | `Payload` (caller-owned slice) | Implemented |
| `CloseCode` | `CloseCode` alias of `zslay.StatusCode` plus one-line conversions | Implemented (alias) |
| `WebSocketError` | `WebSocketError`, mapped from `zslay.Error` | Implemented |
| `unmask` | `unmask` wrapper over `zslay.mask` | Implemented (delegation) |
| `Role` | `Role` alias of `zslay.EndpointRole` from `src/fragment.zig` | Implemented (alias); the connection layer reuses it |
| `WebSocket` | `WebSocket` wrapping `zslay.Conn` with caller-owned storage | Implemented |
| `FragmentCollector` | `FragmentCollector` over `zslay.Conn` with caller-owned buffers | Implemented |
| `handshake::client` | `handshake.client` / `handshake.client_with_key` | Implemented over `std.Io.Reader`/`Writer` with accept verification |
| `handshake::generate_key` | `handshake.generate_key` | Implemented with `std.Io.randomSecure` |
| `upgrade::upgrade` | `upgrade.upgrade`, `upgrade.incoming`, and `upgrade.upgrade_async` | Implemented; validates and builds the server split pair from caller storage before writing and flushing the 101 |
| `upgrade::is_upgrade_request` | `upgrade.is_upgrade_request`, an alias of `handshake.is_request` | Implemented (alias) |
| `WebSocketRead` / `WebSocketWrite` | `WebSocketRead` and `WebSocketWrite` over independent `connection.WebSocket`/`zslay.Conn` values | Implemented |
| `FragmentCollectorRead` | assembled-message collector over a `WebSocketRead` with a caller-owned `message_buffer` | Implemented |
| `set_writev` / `set_writev_threshold` | same setters | Implemented |
| `set_auto_close` / `set_auto_pong` | same setters | Implemented |
| `set_auto_apply_mask` | same setter | Implemented |
| `set_max_message_size` | same setter | Implemented |
| permessage-deflate | not in 0.10.0 | Planned extension beyond parity; RFC 7692 |

## zslay Ownership Boundary

zslay is the only frame codec and the only owner of RFC 6455 wire state. The
pinned sources expose the following surface; tachyon must reuse it rather than
restate it.

| Capability | zslay API | tachyon action |
| --- | --- | --- |
| Wire types | `Opcode`, `EndpointRole`, `FrameHeader`, `MaskingKey`, `MaxFrameHeaderLen`, `MaxPayloadLen`, `DecodedHeader` | Alias or re-export. Never redeclare the packed layout. |
| Header coding | `encode_header`, `decode_header`, `header_bytes_needed`, `get_serialized_size` | Call from `src/frame.zig`; never pack bits, decode extended lengths, or choose length markers by hand. |
| Masking | `mask(buf, key, pos)` | Delegate with the running offset; `unmask` and `unmask_at` are wrappers, not implementations. `Conn` never XORs payload bytes; `prepare_frame` validates payload rules and writes the header, but never masks. |
| Close codes | `StatusCode`, `is_valid_close_code`, `validate_close_payload` | `CloseCode` aliases `StatusCode`; conversions and allowed checks delegate to zslay. tachyon applies inbound validation and synthesizes close echoes. Do not add a range table. |
| Connection state | `Conn`, `ConnConfig`, `FrameNode`, `RxAction`, `TxAction` | Wrap `Conn` in `src/connection.zig`; do not duplicate RX/TX state or fragment bookkeeping. |
| Limits | `max_frame_len`, `max_message_len` | Set from fastwebsockets options; zslay 0.5.0 has no limit setter, so the connection writes these fields directly as noted under Compatibility Notes. Use zslay for wire checks and add only the API-boundary `>=` gate documented there. |
| TX queue | `Queue(Element)`, `FrameNode` | Use the bounded queue and prepared nodes; do not write a second ring buffer. |
| Errors | `Error` | Map to `WebSocketError` once at the tachyon boundary. |

zslay deliberately does not provide:

- sockets, `std.Io` adapters, or vectored writes,
- automatic pong or close replies,
- text-message UTF-8 validation,
- payload buffering or fragment collection,
- HTTP handshakes, upgrades, accept-token generation, or key generation,
- fastwebsockets option names/defaults or error names,
- random mask-key generation.

Those are tachyon responsibilities. The following are prohibited duplications:

- a second `CloseCode` enum, allowed-range table, or close-payload validator,
- a second masking loop or `src/mask.zig`,
- bit-level header parsing, extended-length decoding, or control-frame limit
  checks outside zslay,
- masking-direction, continuation-order, or cumulative-size state in tachyon,
- a replacement bounded transmit queue when `zslay.Queue` fits.

If zslay lacks a required primitive, change zslay first, publish a release,
update `build.zig.zon`, regenerate the zon2nix views, and land the dependency
bump with the tachyon change that needs it.

## Compatibility Notes

These differences are deliberate and must stay visible in tests and reviews:

| Topic | fastwebsockets 0.10.0 | tachyon with zslay |
| --- | --- | --- |
| Close taxonomy and names | `CloseCode` uses PascalCase and preserves `Bad`, `Reserved`, `Iana`, and `Library` variants | `CloseCode` aliases `zslay.StatusCode` (snake_case, non-exhaustive); unknown values round-trip through `u16`. Add named constants if parity requires them; do not add a second range table. |
| Close code 1014 | `CloseCode::from(1014)` produces `Bad(1014)`, so `is_allowed` rejects it | `is_valid_close_code` accepts 1014; tachyon follows the IANA registry and accepts it |
| Inbound close validation and echo | With `auto_close` on, an invalid code returns `InvalidCloseCode` and obligates `close(1002, reason)`; a valid close returns the frame and obligates an exact-payload echo. With `auto_close` off, code and UTF-8 are unchecked and a 1-byte close is delivered. | `decode_header` always rejects one-byte and extended/oversized control payloads. tachyon checks reason UTF-8 first, then uses zslay's code predicate and validator. When automatic replies are permitted, it sends the applicable 1002 reply or exact echo and flushes it before `read_frame` returns. Never echo unvalidated reason bytes. |
| Close error precedence | Invalid UTF-8 is checked before code allowance | `zslay.validate_close_payload` checks code before UTF-8. tachyon performs the UTF-8 check first at the policy boundary, then applies zslay's code predicate, so the error and reply order match fastwebsockets. |
| Control-frame length | Ping above 125 bytes is rejected explicitly; close and pong lengths are not checked there | Any control frame with an extended-length marker or payload above 125 bytes is rejected |
| Non-minimal extended lengths | Accepts a 16-bit length below 126 and a 64-bit length below 65536 | `decode_header` rejects both with `ProtocolError`; tachyon is stricter |
| Maximum message size | Per frame with `payload_len >= max_message_size`, so equality is rejected; fragment totals are not summed; a configured zero maximum rejects empty frames | Per-frame equality is preserved by setting `max_frame_len` and `max_message_len` to `max_message_size - 1` when nonzero, and every frame is rejected when the maximum is zero. `WebSocket.init` clamps its own option to `zslay.MaxPayloadLen`; `FragmentCollector.init` instead rejects values above that bound with `InvalidLength`. `Conn` still owns the accounting; `max_message_len` adds cumulative hardening. |
| Maximum size clamp | Values above the platform maximum are not clamped | `WebSocket.init` and `set_max_message_size` clamp silently to `zslay.MaxPayloadLen`; `FragmentCollector.init` rejects above that bound with `InvalidLength` |
| Message-limit updates | `set_max_message_size` updates the connection option | zslay 0.5.0 has no limit setter, so `WebSocket.set_max_message_size` writes `Conn.max_frame_len` and `Conn.max_message_len` directly and reads the public in-flight fragment lengths to clamp the cumulative limit. Replace this direct-field coupling with a zslay setter when one lands |
| Outbound limit side effect | The maximum applies to reads only | `WebSocket` derives zslay's outgoing limits from the same exclusive option, so oversized outbound data and nonempty control frames fail `FrameTooLarge`; automatic replies stay bounded by the inbound frame that passed the same limit |
| Masking direction | Not enforced on read or write; `auto_apply_mask` controls application, so a client with it disabled writes an unmasked frame | `Conn` always requires client-to-server masked and server-to-client unmasked frames; client writes with auto-mask disabled fail with `PayloadNotMasked` |
| Mask application | Client masks writes and server unmasks reads when `auto_apply_mask` is on | `Conn` validates direction and exposes key/offset but never XORs; the connection calls `zslay.mask` with the running offset and unmasks inbound frames in place when `auto_apply_mask` is on |
| Pre-masked outbound payload | `Frame::new` accepts a key and assumes the payload already matches it | `WebSocket.write_frame` rejects `masking_key != null` with `PayloadMasked` so close validation sees clear bytes; raw `Frame.write` and `Frame.writev` remain available for pre-masked frames |
| `auto_apply_mask` off control policy | Control replies operate on clear payloads | A masked inbound frame with `auto_apply_mask` off is delivered with its key set, and control replies that need clear bytes are skipped. A client with `auto_apply_mask` off does not attempt automatic replies: pings are delivered, and closes are validated but not echoed or answered with 1002 |
| Frame construction | `Frame::new` accepts a mask and assumes the payload already matches it | `Frame.init` uses the same contract; `Frame.mask(key)` is the safe path for plaintext payloads and asserts the frame is unmasked |
| Frame mask key generation | `Frame::mask()` draws a random key when the frame has none | `Frame.mask(key)` requires a caller-supplied key; randomness belongs to the connection or handshake boundary |
| Connection mask key source | `Frame::mask()` draws `rand::random()` | `WebSocket` uses a seeded ChaCha8 `MaskKeySource` supplied at init. A deterministic seed is the test seam; production seeds must be uniform and secret, and the connection never reads ambient randomness |
| Unmask state | `Frame::unmask` leaves the mask key set, so a second call masks the payload again | `Frame.unmask` applies the stored key once and clears it, so it is idempotent |
| Header formatting failure | `Frame::fmt_head` panics when the head buffer is too short | `Frame.fmt_head` returns `zslay.Error`, including `BufferTooShort` |
| Frame write target | `Frame::write` grows a `Vec`; `Frame::writev` takes an `AsyncWriteExt` stream | `Frame.write` needs a caller buffer and returns `BufferTooShort`; `Frame.writev` takes `*std.Io.Writer` |
| Facade close writes | `write_frame` sends the close payload without code or UTF-8 validation | `Frame.write` and `Frame.writev` encode any close payload; send close frames through `WebSocket.write_frame`, which uses `prepare_frame` and `queue_frame` |
| 1002 reply reason and close buffer | Allocates the reply from the validated reason | `WebSocket` reuses the validated reason only when it fits `close_buffer`, otherwise it sends an empty reason; the reason is never truncated mid-code-point |
| One-byte close | With `auto_close` on, returns `InvalidCloseFrame`; with it off, delivers the byte | zslay rejects a one-byte close at decode with `ProtocolError` before close policy runs; tachyon adds no second length guard |
| Ping delivery | `auto_pong` on suppresses the ping from the application and queues a pong; off delivers it | `WebSocket` suppresses and writes an exact pong when no close was already observed, then flushes it before `read_frame` returns; a masked ping with `auto_apply_mask` off, or any ping for a client with `auto_apply_mask` off, is delivered without a reply. With `auto_pong` off, the ping is delivered unless a close was already observed |
| Transmit validation and queue | No close/code/UTF-8 validation, fragment-order or size checks, or control-FIN rejection; repeated close writes are sent again | `prepare_frame` and `queue_frame` add validation, ping/pong preemption, and `QueueFull`; repeated close writes are still serialized |
| Read after close and `ConnectionClosed` latch | After a close write, non-close reads return `ConnectionClosed`; the peer close frame remains deliverable | `Conn` has no closed flag; `WebSocket` tracks it and gates non-close reads and writes. `ConnectionClosed` is not latched, so a later peer close remains deliverable |
| Terminal write failure | Propagates `IoError` or `SendError`; a partial write is not resumable | `WebSocket` latches `write_failure`; later writes and reads return it, and no partial write is retried. `reset_tx` clears the queue, the latch, and `closed`, and is safe only when the transport is discarded |
| Text UTF-8 | The raw path checks only FIN text frames; the collector streams validation | `WebSocket.read_frame` validates clear FIN text frames and delivers non-FIN fragments raw; `FragmentCollector` validates the assembled message across fragments. Neither validates a non-FIN fragment in isolation |
| Raw versus collector API | Raw `read_frame` and `FragmentCollector` are separate paths | `WebSocket.read_frame` returns wire frames with payloads borrowed from `frame_buffer`; `FragmentCollector` remains the assembled-message API with a caller-owned `message_buffer` |
| Split halves | Read and write halves share one connection | `zslay.Conn` couples RX and TX, so each half owns an independent `connection.WebSocket` and `zslay.Conn`. `read_event` returns automatic obligations instead of writing; the read half forwards them to a sink, and `WebSocketWrite.send_obligation` writes then flushes. Under `auto_close`, a successful close reply or 1002 closes the read half even through an external sink; a successful invalid-close 1002 also latches `InvalidCloseCode`. A transport failure while sending the 1002 leaves the read latch clear for `reset_tx`, while a prepare or queue failure latches the read half. `Split.write_frame` allows repeated closes but refuses non-close frames once either half is closed |
| Raw fragment sequencing | Raw `read_frame` delivers orphan continuations and new data frames mid-fragment; only `FragmentCollector` enforces order | `Conn` rejects both; tachyon's raw API is stricter |
| Payload and close construction | `Payload` has borrowed, owned, and `BytesMut` variants; `Frame::close` allocates | `Payload` is a caller-owned slice; `Frame.close` needs caller-provided storage |
| Raw close encoding | `Frame::close` does not validate and `write_frame` sends the payload | Raw `encode_header` accepts a 1-byte close; validate and send close frames through `WebSocket.write_frame`, which uses `prepare_frame` and `queue_frame` |
| Error granularity | `InvalidStatusCode(u16)` and IO/HTTP/send wrappers | Zig errors cannot carry the status or wrapped detail; `invalid_status_code` writes the rejected status to a caller out-parameter, `description` approximates transparent IO/HTTP text, and zslay's `ProtocolError` collapses categories |
| Fragment collector | Allocates and has no cumulative message cap | Caller-owned `message_buffer` and `frame_buffer` plus zslay's cumulative `max_message_len`. The collector is read-only, so control replies belong to the connection layer; a local buffer shortfall fails with `BufferTooShort`. |
| Client handshake | Checks status 101, `Upgrade`, and `Connection`; does not verify `Sec-WebSocket-Accept` | tachyon verifies `Sec-WebSocket-Accept` as deliberate hardening |
| Client response token matching | `Upgrade` and `Connection` must equal one token as a whole string | tachyon uses the RFC 6455 token-list check, so `h2c, websocket` and `keep-alive, Upgrade` are accepted |
| Server upgrade | `upgrade()` checks key and version only; `is_upgrade_request()` checks the `Connection` and `Upgrade` token lists | `handshake.is_request` keeps the token-only probe; `handshake.validate_request` is the strict combined server gate so a caller cannot write 101 after checking only key and version |
| Server key validation | Any `Sec-WebSocket-Key` value is hashed; base64 and decoded length are not checked | tachyon requires exactly one canonical base64 value decoding to 16 bytes before hashing |
| Server upgrade call order | Returns a response and an upgrade future; the caller sends the response before awaiting the future | `src/upgrade.zig` owns the read, validate-only, split construction, 101 write, and flush order. `incoming` writes nothing; `IncomingUpgrade.upgrade` forces the server role, constructs the split first so storage failures precede response bytes, then re-validates the key, writes and flushes the 101, and discards the zero-allocation split if that write or flush fails. `upgrade_async` keeps borrowing caller storage, and the resolved `Upgrade` does too, until awaited or cancelled. The one-shot `upgrade` does not inspect `Origin` |
| Handshake HTTP parsing | hyper parses the request and response heads | tachyon reads a chunked, bounded head from caller-provided `std.Io.Reader` storage, rejects bare LF, folded or non-token header names, missing or duplicate Host, non-origin targets, `Connection: close`, and body-bearing upgrade or 101 heads, and leaves coalesced frame bytes buffered |
| Subprotocol negotiation | Caller builds the request and inspects the returned response | `ClientOptions` does not offer subprotocols in this PR, so a response `Sec-WebSocket-Protocol` is rejected instead of being silently accepted |
| Handshake buffer limits | hyper allocates header storage | caller-owned header storage bounds the whole head independently of the reader buffer; a short buffer returns `BufferTooShort`, malformed line endings return `InvalidHttpRequest`, EOF returns `UnexpectedEOF`, and transport failures map to `IoError` |

The close-reason pre-check is policy ordering, not a second wire validator:
zslay still owns the predicate, payload length limits, and authoritative
validation.

Where the table says tachyon is stricter, do not weaken the check to imitate an
upstream gap. Record an intentional relaxation in this document and test it.

## Extension Roadmap

These modules extend the 0.10.0 parity baseline. They are ordered by dependency
and remain optional: a build that does not use them behaves like the core
library. The frame layer stays pure and zslay remains the only wire codec.

Implementation order: finish the parity core first, then backpressure and
native stream, then streaming messages, then deflate, then pub/sub. UTF-8 landed
ahead of its call sites; the fragment collector and the raw connection read path
now use it. Deflate without the zslay RSV1 change is a non-goal.

| Module | Capability | Depends on | Exit criteria |
| --- | --- | --- | --- |
| `src/utf8.zig` | Incremental text validation across frame boundaries | `std.unicode` for contiguous slices | Implemented: rejects overlong, surrogate, truncated, and above-U+10FFFF sequences; zero allocation; no replacement characters |
| `src/backpressure.zig` | Byte/frame high and low watermarks over `zslay.Queue`, plus read-buffer limits | `zslay.Queue`, connection state | Bounded queues, explicit `WouldBlock`, no drops, no spin, slow consumers pause |
| `src/native_stream.zig` | `std.Io.Reader`/`std.Io.Writer` adapter for `std.Io.net.Stream` | Zig 0.17.1 `std.Io` | Caller owns socket and buffers; readiness comes from `std.Io`; no libxev |
| `src/stream.zig` | Chunked message reader/writer for large messages | connection, `utf8`, `backpressure` | Control frames interleave; no whole-message buffering; UTF-8 and deflate hooks |
| `src/deflate.zig` | RFC 7692 permessage-deflate | zslay negotiated RSV1, `std.compress.flate`, stream/fragment | Negotiated only after zslay RSV1 support; decompressed output capped; control frames never compressed |
| `src/pubsub.zig` | Bounded topic hub and fanout | `stream`, `backpressure` | Application layer only; no wire-format change; per-subscriber backpressure or disconnect policy |

### Backpressure

zslay already owns the bounded transmit ring, `QueueFull`, `tx_pending`, and the
header/payload progress cursors. `src/backpressure.zig` is a policy layer, not a
second queue:

- track queued bytes and frames with high and low watermarks,
- return `error.WouldBlock` or a typed `backpressured` result instead of
  dropping frames or growing a buffer,
- stop reading when the receive buffer is above its high watermark and resume
  below the low watermark,
- let `src/native_stream.zig` await writability through `std.Io` rather than
  spinning,
- keep every queue and buffer caller-owned and bounded.

### Incremental UTF-8

zslay validates the close reason; it does not validate text messages.
`src/utf8.zig` owns an incremental validator that can pause inside a code point:

- the raw connection read path validates clear FIN text frames,
- `FragmentCollector` validates the assembled message, and the planned
  `src/stream.zig` validates streamed chunks, including code points split
  across frames,
- deflate validates the decompressed text, not the compressed bytes,
- contiguous buffers use `std.unicode` rather than a second scanner,
- invalid input fails closed; never substitute U+FFFD or skip bytes.

The validator is a small value type, so chunked reads cannot leave hidden
mutation behind:

- `State.feed` is a pure transition. It returns the next state and leaves the
  input state untouched on failure; `State.finish` rejects a truncated final
  code point.
- `std.unicode.utf8ValidateSlice` validates every complete range. The state
  carries only the final 0-3 bytes of a code point that crosses a chunk
  boundary, so overlong, surrogate, and above-U+10FFFF sequences are decided by
  the standard library rather than a second scanner.
- `validate_reader` drives the same state from a caller-buffered
  `std.Io.Reader`. Read sizes are arbitrary, which is the `std.Io` streaming
  contract; the adapter allocates nothing and consumes payload bytes only. It
  reads to end-of-stream and does not know frame boundaries, so wrap a bounded
  payload in `std.Io.Reader.limited` when the message length is known. Frame
  decoding still belongs to zslay and the connection layer.
- The validator returns `zslay.Error.InvalidUtf8`; the reader adapter also
  returns `BufferTooShort` for a zero-length buffer and propagates
  `std.Io.Reader` read failures. `errors.from_zslay` maps the validation error
  to `WebSocketError.InvalidUTF8` once at the connection boundary.
- `Frame.is_utf8` delegates to the same validator for contiguous payloads.
- State is per text message. Reset it when a new text message starts, keep it
  across interleaved control frames, and discard it when a close aborts the
  message. Binary payloads never feed it.

### Streaming messages

`src/stream.zig` is the large-message path. It exposes caller-buffered chunks
instead of collecting a complete message as `FragmentCollector` does:

- `MessageReader` yields payload chunks and end-of-message boundaries,
- `MessageWriter` accepts chunks and preserves fragmentation order,
- control frames may interleave and keep their automatic reply obligations,
- backpressure and UTF-8/deflate hooks apply per chunk,
- no allocation and no hidden copy of the full message.

`FragmentCollector` remains the convenience API for applications that want one
contiguous message and can afford the buffer.

### Native stream

`src/native_stream.zig` is the only module that binds tachyon to Zig's native
stream types. It wraps the `std.Io.net.Stream` methods `stream.reader(io, buffer)`
and `stream.writer(io, buffer)` as `std.Io.Reader` and `std.Io.Writer`, then
drives the connection layer. The socket, buffers, and lifetimes stay with the
caller. It adds no event loop, no task spawning, and no socket ownership to the
protocol core.

### permessage-deflate

`src/deflate.zig` implements RFC 7692 as an optional extension:

- zslay must first learn negotiated RSV1: the current `encode_header` and
  `decode_header` reject all reserved bits, so changing tachyon alone would
  bypass the only codec.
- RSV1 is set on the first frame of a compressed message only; control frames
  and non-first fragments must never set it.
- Use `std.compress.flate` with the raw container. Its history buffer is
  `std.compress.flate.max_window_len` (64 KiB) per direction; RFC 7692's maximum
  LZ77 window is 32 KiB, so the extra buffer is a Zig std requirement, not a
  larger wire window.
- Support `server_no_context_takeover` and `client_no_context_takeover`; retain
  the history buffer when context takeover is negotiated.
- Reject negotiated `max_window_bits` below 15 until a constrained compressor
  exists, because Zig's compressor always uses the full window.
- Compress with raw deflate. If the result does not already end in an empty
  stored block with `BTYPE=00`, append one, then remove the final four octets
  `00 00 ff ff`. On receive, append those four octets before inflating. Fragment
  only after compression. `std.compress.flate` does not promise the trailing
  empty block, so never strip four bytes unconditionally.
- Bound decompressed output by `max_message_size` before delivery and fail
  closed on overflow. Compression must never become a decompression bomb or an
  unbounded buffer.
- Negotiation and response formatting will belong to `src/handshake.zig` and
  `src/upgrade.zig`; compression state belongs in `src/deflate.zig`. Nothing
  enables compression until zslay supports negotiated RSV1.

### Pub/Sub

`src/pubsub.zig` is an application layer, not a WebSocket wire extension:

- publish, subscribe, and unsubscribe over caller-defined message envelopes,
- bounded topic and subscriber tables with caller-owned storage,
- fanout through `src/stream.zig` and `src/backpressure.zig`,
- a slow subscriber is backpressured or disconnected by policy; it must not
  grow an unbounded per-subscriber queue,
- authorization and envelope formats stay outside the protocol core,
- no change to zslay or the RFC 6455 framing path.

## Dependency Rules

`build.zig.zon` declares [farbenbuilds/zslay](https://github.com/farbenbuilds/zslay),
and the `zon2nix` pre-commit hook generates `build.zig.zon.nix`,
`build.zig.zon.json`, and `build.zig.zon.txt`. The flake consumes the generated
Nix expression, so dependency versions and hashes live in one place instead of
being repeated in `flake.nix`.

Do not copy zslay internals into tachyon. Do not edit `zig-pkg/` or the Nix
store. The zslay boundary is public API only.

When bumping zslay, re-read `src/root.zig`, `src/types.zig`, `src/frame.zig`,
and `src/event.zig`, then update the inventory and compatibility table before
changing tachyon. Do not infer the boundary from this summary alone.

## Environment Files

| File | Purpose |
| --- | --- |
| `flake.nix` | Zig 0.17.1 shell, zon2nix, Nix formatting check, and musl shell. |
| `flake.lock` | Pinned Nix inputs. |
| `.envrc` | direnv entry point with musl host detection. |
| `.pre-commit-config.yaml` | Formatting, hygiene, and zon2nix hooks. |
| `scripts/update_zon_files.sh` | Generates `build.zig.zon.nix`, `.json`, and `.txt` from `build.zig.zon`. |
| `.gitattributes` | Linguist rules for agent tooling, generated graph output, docs, and `.zon` files. |
| `.gitignore` | Nix, Zig, build, graph, and editor output. |

Build files:

| File | Purpose |
| --- | --- |
| `build.zig` | Public `tachyon` module, static library, Debug and ReleaseSafe tests over `tests/main.zig`, and `check` step. |
| `build.zig.zon` | Package metadata, minimum Zig version, zslay dependency, and published paths including `tests/` and the packaging and documentation files. |
| `build.zig.zon.nix` | Generated by zon2nix so the flake can prefetch every package dependency for offline Nix builds. |
| `build.zig.zon.json`, `build.zig.zon.txt` | Generated dependency metadata and URL lists for audits and tooling. |

## Project Support Files

- `README.md` introduces the library and its current status.
- `AGENTS.md` and `CLAUDE.md` define agent rules; `AGENT_DIRECTORY.md` owns the
  roster and workflow.
- `CODING_CONVENTION.md` defines the Zig style and safety contract.
- `CONTRIBUTE.md` covers setup, checks, commits, and releases.
- `CI_CD_PIPELINE.md` records the pipeline contract, including the implemented
  `.github/workflows/lint.yml` and the planned test and publish workflows.
- `tests/README.md` documents the test tree, aggregator, category naming, and
  run commands.
- `SECURITY.md` covers reporting and supported versions.
- `CHANGELOG.md` records landed changes.
- `THIRD_PARTY_NOTICES.md` records fastwebsockets, zslay, and uWebZockets
  attribution.
- `SKILL.md` summarizes the vendored skill pack and graphify setup.
- `.agents/skills/` and `skills-lock.json` hold the shared skill pack.
- `.agents/agents/`, `.opencode/agents/`, `.codex/agents/`, and `.claude/agents/`
  hold the matching agent definitions.
- `.codex/TEAM_WORKFLOW.md` defines the Codex team procedure.
- `.opencode/`, `.codex/`, and `.claude/` hold the graphify skill copies,
  plugin, hooks, and client configuration. `.agents/rules/` and
  `.agents/workflows/` hold the Google Antigravity integration.
- `scripts/install_graphify_integrations.sh` refreshes the four integrations;
  `scripts/check_graphify_integrations.sh` is the pre-commit consistency gate.
- `misc/tachyon-banner.png` is the README banner asset.
- `.github/` holds the pull request template, commit convention, code of
  conduct, issue forms, and funding metadata.
- `.github/workflows/lint.yml` runs `zig fmt --check .` for pull requests into
  `main` that change a `.zig` file, a `.zon` file, or `build.zig`.
