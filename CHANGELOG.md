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
