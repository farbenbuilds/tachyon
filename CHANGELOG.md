# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project follows semantic versioning.

## [Unreleased]

### Added

- Zig 0.17.1 package scaffold with a public `tachyon` module, static library,
  Debug and ReleaseSafe test steps, and a `check` step.
- `src/error.zig` with the fastwebsockets 0.10.0 error taxonomy, zslay boundary
  normalization, `std.Io.Reader`/`Writer`/`StreamError` mappings, the
  `InvalidStatusCode` out-parameter helper, close-code policy, and
  classification helpers, exported from `src/root.zig`.
- `src/frame.zig` with the `Frame` facade, `Payload`, `OpCode` and `CloseCode`
  aliases and conversions, `unmask`/`unmask_at` delegations, the header-length
  bridge, `std.Io.Writer` vectored writes, and caller-buffer writes, exported
  from `src/root.zig`.
- `src/utf8.zig` with an incremental zero-allocation UTF-8 validator: complete
  ranges use `std.unicode`, split code points stay in a pure `State` value,
  `validate_reader` adapts arbitrary `std.Io.Reader` chunk sizes, failures use
  `zslay.Error.InvalidUtf8`, and `Frame.is_utf8` delegates to the same
  validator. Exported from `src/root.zig` with focused Debug and ReleaseSafe
  tests.
- `src/fragment.zig` with the read-side fragment layer: the `Fragments`
  accumulator over a caller-owned message buffer and `FragmentCollector`, which
  drives `zslay.Conn`'s RX state machine over a caller-provided
  `std.Io.Reader`. It unmasks inbound frames in place, returns control frames to
  the caller without disturbing the in-progress message, and validates text
  incrementally across fragments, including code points split between frames.
  `max_message_size` is exclusive, `init` rejects values above
  `zslay.MaxPayloadLen`, and a message that exceeds local `message_buffer`
  capacity fails closed with `BufferTooShort`. Every protocol, frame, and I/O
  `read_frame` failure is latched and returned by later calls until `reset`; a
  zero `max_message_size` is a configuration rejection that returns
  `FrameTooLarge` without latching. The latch keeps zslay's fragment accounting
  from drifting from the accumulator; `reset` is safe only at
  `is_at_wire_boundary()` or when the transport is discarded, because a
  mid-frame read failure leaves the reader advanced. Close frames pass through
  after zslay's header-level checks only, so the caller or connection layer must
  call `zslay.validate_close_payload` before acting on or echoing them. The
  collector is deliberately read-only, so automatic pong and close replies
  belong to the connection layer. `Fragments`, `FragmentCollector`, and `Role`
  are exported from `src/root.zig`.
- `src/connection.zig` with the role-aware `WebSocket` policy over one
  `zslay.Conn`. The caller provides a `std.Io.Reader`, a `std.Io.Writer`, and
  caller-owned `frame_buffer`, `tx_nodes`, `write_buffer`, `close_buffer`, and
  optional `mask_scratch` storage; `init` validates the buffer layout and
  clamps the exclusive maximum message size to `zslay.MaxPayloadLen`. `Options`
  defaults auto-mask, auto-close, auto-pong, and writev to true, the writev
  threshold to 1024 bytes, and the maximum to 64 MiB. The raw read path
  suppresses pings and writes exact pongs, validates a close reason as UTF-8
  before the close code, echoes a valid close payload exactly, and answers an
  invalid code with 1002 and the validated reason when it fits `close_buffer`,
  otherwise an empty reason. Automatic pong and close replies are flushed before
  `read_frame` returns; a client with `auto_apply_mask` off does not attempt
  automatic replies: pings are delivered, and closes are validated but not
  echoed or answered with 1002. `closed` gates non-close reads and writes;
  `read_event` does not latch an error that also fills a reply, `read_frame`
  latches it after a successful send, a transport send failure stays with the
  write latch until `reset_tx`, and other read failures latch until `reset`
  except `ConnectionClosed`; a zero maximum rejects before consuming without
  latching. Writes mask chunks in caller-owned scratch or the write buffer, use
  the vectored path above the threshold and the copied path at or below it, and
  never allocate. `MaskKeySource` is a seeded ChaCha8 source, so tests are
  deterministic and production seeds come from the caller.
  `WebSocket` and the connection options, config, storage, and mask-source
  types are exported from `src/root.zig` with Debug and ReleaseSafe tests.
- `src/split.zig` with the split read/write surface: `Split`, `WebSocketRead`,
  `WebSocketWrite`, `FragmentCollectorRead`, `after_handshake_split`/`init`, and
  caller-owned `ReadStorage`, `WriteStorage`, and `Storage`. `zslay.Conn`
  couples RX and TX, so each half owns an independent `connection.WebSocket` and
  `zslay.Conn`; both halves may share the external reader and writer pointers
  because each uses one direction. The read half drives
  `WebSocket.read_event` and never writes, while the write half drives
  `write_frame` and `flush` and never reads. Automatic pong and close
  obligations are forwarded through a sink with `send_obligation(Frame)`,
  `is_closed()`, and `failure()`; `WebSocketWrite.send_obligation` writes and
  flushes each reply. A successful close reply, including a 1002, marks the read
  half closed even when the sink is external. An invalid close code still fills
  its 1002 reply before returning `InvalidCloseCode`; a successful send also
  latches `InvalidCloseCode` on the read half, while a transport failure while
  sending the 1002 leaves the read latch clear so `reset_tx` recovers. A prepare
  or queue failure still latches the send error. A close returned under
  `auto_close` is terminal even when its echo goes to an external sink, and
  `Split.write_frame` allows repeated closes but refuses non-close frames once
  either half is closed; a write failure gates reads. `FragmentCollectorRead`
  assembles continuations and split UTF-8 code points over a caller-owned
  `message_buffer`, rejects overlap with the read `frame_buffer` with
  `InvalidLength`, and latches read and accumulation failures until reset except
  `ConnectionClosed`, which is not latched so a later peer close stays
  deliverable, the zero-maximum `FrameTooLarge` configuration rejection, and a
  sink-owned transport failure: when `sink.failure()` is set, the collector
  leaves its own latch clear so `reset_tx` owns recovery and allows the next
  read. Reset clears the collector latch, the read latch, and the in-progress
  message; it is safe at `is_at_wire_boundary()` or when the transport is
  discarded. `WebSocket.read_event` is the shared read-step API,
  and `read_frame` now loops over it, sends the reply, and latches the
  originating read error only after a successful send without changing unsplit
  behavior. All storage is caller-owned and zero allocation; exported from
  `src/root.zig` with Debug and ReleaseSafe tests.
- `src/backpressure.zig` with an opt-in byte/frame watermark policy over
  zslay's bounded transmit ring. `ConnectionOptions.backpressure` configures
  high and low marks, `enqueue_frame` batches without draining, data admission
  returns `WouldBlock` in the paused phase or when a non-empty queue cannot fit
  the next frame, and automatic control replies use one reserved transmit node
  while application controls other than close stop at the data capacity. Deferred
  enqueue rejects payloads that alias read-lifetime buffers; the synchronous
  write path keeps the frame-buffer echo shortcut. The policy resumes at both low
  marks, accounts payload bytes and completed frames at the exact zslay
  queue/advance points, and does not latch `WouldBlock`. Outbound pressure never
  gates the read half, so peer close and ping frames stay deliverable. `flush`
  remains the `std.Io` wait point, so the policy adds no spin loop, allocation,
  or event loop. Exported from `src/root.zig` with focused policy, connection,
  split, and native-stream tests.
- `src/stream.zig` with the chunked large-message path over
  `connection.WebSocket`. `MessageReader` yields one borrowed `Chunk` per data
  frame, marks the message boundary with `Chunk.fin`, validates text
  incrementally across frames and chunks through `src/utf8.zig`, surfaces
  delivered pings and pongs as control events, and treats a peer close as
  terminal even when `auto_close` is off. `MessageWriter` queues one frame per
  chunk through `enqueue_frame`, preserves text/binary then continuation order,
  and exposes `finish` and `flush`; writer state advances only after a successful
  queue, so a `WouldBlock` or `QueueFull` chunk can be retried after `flush`.
  The pure `ReaderState`, `WriterState`, and `FrameSpec` values contain no I/O,
  allocator, or function pointer, and the module copies no whole message and
  never writes automatic replies. Exported from `src/root.zig` with Debug and
  ReleaseSafe reader, control, UTF-8, close, writer, backpressure, and pure-state
  tests.
- `src/deflate.zig` with the zero-allocation RFC 7692 permessage-deflate message
  payload codec over caller-owned storage, built on Zig 0.17.1
  `std.compress.flate` with the raw container and no allocator, C dependency,
  libdeflate, or zlib. The public surface is `sync_tail`, `Config`, `Error`,
  `DeflaterStorage`/`Deflater`, `InflaterStorage`/`Inflater`, and
  `max_compressed_len`; `Deflater` exposes `init`, `compress`, and `reset`, and
  `Inflater` exposes `init`, `decompress`, and `reset`. The sender accepts only
  `window_bits == 15`, preflights `max_compressed_len`, sync-flushes each
  message, and appends one `0x00` byte; empty input is the canonical one-byte
  `0x00` payload, and the codec never strips four trailing octets. The receiver
  accepts `window_bits` 8 through 15 but does not enforce the negotiated
  distance limit: `std.compress.flate.max_window_len` is a 64 KiB std
  history-buffer requirement, not the DEFLATE wire LZ77 window. Future
  negotiation must reject values below 15 for sending or enforce the limit
  before advertising a smaller receive window, and outbound stays at 15. The
  receiver serves the compressed payload followed by `00 00 ff ff`, drains the
  decoder's indirect output, and requires a clean block boundary with
  `state == .block_header`, zero consumed bits, and no unconsumed input; a
  zero-length received payload is accepted as empty. A BFINAL block is rejected
  with `InvalidCompressedData` as RFC 7692 requires; when the overflowing block
  is BFINAL, `InvalidCompressedData` takes precedence over `MessageTooLarge`,
  and both errors are terminal for the session. Context takeover is the default;
  `no_context_takeover` reinitializes the sender before each nonempty message
  and the receiver per message. Output is capped by the caller slice. Malformed
  input that leaves a non-clean boundary latches `InvalidCompressedData`, but
  DEFLATE has no integrity check, so some truncated or corrupted streams can
  still decode to a shorter or wrong message, including a truncated compressed
  stream completed by the RFC 7692 tail, and callers must treat decompressed
  output as untrusted. `OutputTooShort` is safely retryable; `MessageTooLarge`,
  `InvalidCompressedData`, and `CompressionFailed` latch until `reset`, but they
  occur after consumed input, so close the connection or renegotiate
  `no_context_takeover`; `reset` discards history and is not recovery for a
  context-dependent session.
  `compress` and `decompress` reject input or output that overlaps the other
  slice or any byte of the handle or its storage with `AliasedBuffer`. Storage
  is large, about 295 KiB for a deflater and 69 KiB for an inflater, caller-owned, must be
  initialized at its final address, must not be copied after init, and must
  outlive the handles. The codec is exposed from
  `src/root.zig` as the `deflate` module plus `Deflater`, `Inflater`,
  `DeflateConfig`, `DeflateError`, `DeflaterStorage`, `InflaterStorage`,
  `sync_tail`, and `max_compressed_len`, with tests in `tests/deflate-test/`
  aggregated by `tests/main.zig` and module re-export coverage in
  `tests/module-test/module_test.zig`. Wire activation and RFC 7692 negotiation
  remain blocked: the pinned zslay rejects RSV1, the handshake and upgrade layers
  do not parse offers or responses, and the connection, fragment, and split
  layers do not invoke the codec.
- `src/native_stream.zig` with the native `std.Io.net.Stream` transport edge.
  `Transport` builds the `std.Io.Reader` and `std.Io.Writer` interfaces with
  `stream.reader(io, read_buffer)` and `stream.writer(io, write_buffer)`, and
  the native `WebSocket` and `Split` wrappers delegate to
  `connection.WebSocket` and `split.Split` with no additional protocol state.
  Transport buffers are validated as non-empty, mutually disjoint, and disjoint
  from connection or split storage. Reads and writes block or suspend through
  the caller's `std.Io`, depending on the implementation; the module allocates
  nothing, starts no task, creates no event loop, and never closes the stream.
  The original `std.Io.net.Stream` keeps socket lifetime and shutdown. Detailed
  reader or writer failures are available behind the mapped `IoError`. Exported
  from `src/root.zig` with Debug and ReleaseSafe loopback tests.
- `.github/workflows/test.yml` running `zig build test --summary all` and
  `zig build check` for pull requests into `main` and pushes to `main` that
  change Zig or Zon files, `build.zig`, or workflow files. The job runs in the
  `Testing` environment so every test run appears on the deployments page.
- `src/handshake.zig` with the RFC 6455 client handshake and shared server
  upgrade primitives over caller-provided `std.Io.Reader` and `std.Io.Writer`
  values. The module generates 16 key bytes with `std.Io.randomSecure`, encodes
  and validates canonical base64 keys, re-exports the accept GUID and streaming
  SHA-1/base64 accept-token derivation from `src/upgrade.zig`, parses a bounded
  request or response head in chunks independent of the transport buffer while
  leaving coalesced frame bytes buffered, writes the client GET request,
  exposes the fastwebsockets-named `verify` response gate for status 101 plus
  `Upgrade`, `Connection`, and `Sec-WebSocket-Accept`, validates server requests
  before writing the 101 reply, and rejects duplicate
  key, version, accept, and Host headers plus body-bearing upgrade or 101
  heads. `write_response` derives `Sec-WebSocket-Accept` through the re-exported
  computation. The module adds no accept-token literal or fixed concatenation
  buffer of its own. RFC 7692 negotiation and RFC 8441 extended CONNECT stay
  deferred with their compression and HTTP/2 dependencies. The shared server
  request validation and 101 response construction are exported for the
  `src/upgrade.zig` call order. Exported from `src/root.zig` with Debug and
  ReleaseSafe tests.
- `src/upgrade.zig` with the RFC 6455 server upgrade call order. The module owns
  the single `accept_guid` constant, `accept_token_len`, `AcceptTokenBuffer`,
  and the streaming SHA-1/base64 `compute_accept_token`; `src/handshake.zig`
  re-exports those four names so client handshake callers keep working.
  `incoming` reads and strictly validates a request without writing, while
  `IncomingUpgrade.upgrade` and the one-shot `upgrade` force
  `config.role = .server` on a copy, construct the split from caller storage
  with `split.after_handshake_split`, and only then write and flush the 101
  through `handshake.write_response`. Split construction validates caller
  storage and configuration without I/O, so those failures precede every
  response byte; a failed 101 write or flush discards the already-constructed
  zero-allocation split. `upgrade_async` runs the same call order through the
  caller's `std.Io` and returns `UpgradeFut = std.Io.Future(Error!Upgrade)`; the
  future and the resolved `Upgrade` borrow the reader, writer, head storage,
  split storage, and request view until awaited or cancelled. The one-shot
  `upgrade` does not inspect `Origin`, matching fastwebsockets. No response byte
  precedes both successful request validation and successful split-storage
  validation, coalesced bytes stay buffered in the reader, and all storage is
  caller-owned and zero allocation.
  `upgrade`, `Upgrade`, `UpgradeFut`, `IncomingUpgrade`,
  `upgrade_websocket`, `upgrade_websocket_async`, `read_incoming_upgrade`,
  `is_upgrade_request`, `accept_guid`, `accept_token_len`, `AcceptTokenBuffer`,
  and `compute_accept_token` are exported from `src/root.zig`.
- zslay dependency pinned in `build.zig.zon` and exposed from `src/root.zig`,
  plus the generated `build.zig.zon.nix`, `.json`, and `.txt` views.
- Nix flake and lock file for the Zig 0.17.1 development shell, Nix formatting
  check, musl shell, and zon2nix.
- Shared `.envrc` matching the zslay and uWebZockets direnv setup.
- Pre-commit configuration for Zig formatting, generic repository hygiene, and
  zon2nix-generated dependency views.
- Repository guides for architecture, coding style, contribution, CI/CD,
  security, agent workflow, skills, and third-party attribution.
- Shared skill pack for Zig 0.17.1, TigerStyle, testing, Nix, architecture,
  review, `untangle-codebase`, agents, and graphify, pinned by
  `skills-lock.json`.
- Graphify integration for OpenCode, Codex, Claude Code, and Google
  Antigravity, including platform skills, the OpenCode plugin, Codex and Claude
  Code hooks, Antigravity rules and workflow, and reproducible install and
  check scripts.
- Claude Code agent definitions for the full twelve-role roster under
  `.claude/agents/`, with read-only tool sets for `architect`, `review`, and
  `reviewer`, inherited models, and the `graphify` skill preloaded for every
  role.
- `.github` contribution metadata: pull request template, commit convention,
  code of conduct, issue forms, and funding configuration.
- `CLAUDE.md` entry point that imports the canonical `AGENTS.md` rules.
- Architecture guidance that transport uses Zig 0.17.1 `std.Io` async I/O
  instead of libxev.
- README banner at the top of the page, matching the zslay and uWebZockets
  layout.
- Matching architect, developer, reviewer, integrator, and specialist agent
  definitions for agy, OpenCode, Codex, and Claude Code.
- `.codex/TEAM_WORKFLOW.md` with the shared handoff procedure.
- `.github/workflows/lint.yml` runs `zig fmt --check .` on pull requests into
  `main` that change Zig files, `.zon` files, or `build.zig`, using Zig 0.17.1
  through `mlugg/setup-zig`.

### Changed

- Moved all Zig tests out of library sources into the `tests/` tree. The new
  `tests/main.zig` aggregator imports category folders for module, error, frame,
  UTF-8, fragment, connection, split, handshake, and upgrade coverage, and both
  the Debug and ReleaseSafe test steps target that aggregator. The published
  Zig package remains runtime-only: `build.zig.zon` ships the build files,
  generated zon2nix views, `flake.nix`, `flake.lock`, `src/`, `LICENSE`, and
  `README.md`; tests, scripts, and the remaining documentation stay in the
  repository.
- Documented the zslay ownership boundary: header coding, length handling,
  masking, the close predicate and payload validator, masking direction,
  fragment ordering, limits, and the bounded connection state machine are
  delegated. Added compatibility notes for close echoes, message limits,
  masking, raw fragment order, and handshake verification. Removed
  `src/close.zig` and `src/mask.zig` from the target layout in favor of aliases
  and one-line delegates in `src/frame.zig`.
- Every agent definition now loads `graphify` and carries a graph-first rule
  covering `query`, `path`, `explain`, `affected`, `god-nodes`, subagent prompt
  propagation, and `graphify update .` after code changes.
- Corrected the `CODING_CONVENTION.md` header example to use zslay's length
  marker instead of copying the raw payload length into `FrameHeader`.
- Added the post-parity extension roadmap: backpressure, streaming messages,
  native `std.Io` transport, incremental UTF-8 validation, RFC 7692
  permessage-deflate, and pub/sub. The roadmap records module ownership,
  dependency order, and fail-closed limits. permessage-deflate now requires a
  zslay RSV1 extension before tachyon can advertise it.
- Marked `src/utf8.zig` implemented in the extension roadmap, moved it into the
  `framing` owner roster, and updated the matching agent definitions with the
  `std.unicode` and `std.Io.Reader` boundaries.
- `nix flake check` now runs the Debug and ReleaseSafe suites natively and in
  the musl shell using the zon2nix-prefetched packages, and `nix build`
  produces `libtachyon.a`.
- Dependency metadata now lives in `build.zig.zon`; the flake no longer pins
  zslay directly, and the zon2nix pre-commit hook generates the Nix, JSON, and
  text views.
- Documentation no longer repeats the zslay version.

### Fixed

- `split.after_handshake_split` now rejects read storage that overlaps write
  storage with `InvalidLength`, preventing a read reply from clobbering queued
  or composed write bytes before either half is constructed.
- `FragmentCollector` now advances zslay's header accounting for bytes consumed
  by a short header read, so `is_at_wire_boundary()` stays false after a
  truncated header and `reset` remains safe only at a real frame boundary.
- `FragmentCollector.init` now rejects a `message_buffer` overlapping
  `frame_buffer` or the reader buffer with `InvalidLength`, matching the split
  collector and avoiding undefined `@memcpy` overlap.
- `connection.WebSocket.init` now rejects reader or writer buffers that overlap
  each other or any caller-owned protocol storage, covering the copy from the
  reader buffer into a payload target. `FragmentCollectorRead.init` applies the
  same rule to the collector's message buffer and the read half's buffers.
- Connection, split, fragment, and native-stream storage checks now call
  `zslay.event.ranges_overlap` instead of maintaining local range predicates.
