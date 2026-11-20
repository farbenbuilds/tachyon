# Repository Guidelines

## Project Identity

tachyon is a Zig 0.17.1 recreation of
[denoland/fastwebsockets](https://github.com/denoland/fastwebsockets). The
behavioral target is the fastwebsockets 0.10.0 surface: raw frame reads and
writes, automatic close and pong handling, automatic mask application, maximum
message limits, vectored writes, fragmentation collection, HTTP server upgrade,
client handshake, split read/write halves, and the native `std.Io.net.Stream`
adapter. The 0.10.0 surface is the parity baseline, not the ceiling:
streaming messages, permessage-deflate (RFC 7692), and pub/sub are planned
post-parity extensions documented in `CODEBASE.md`. Backpressure is now
implemented in `src/backpressure.zig` as an opt-in byte/frame watermark policy
over zslay's bounded transmit ring. Incremental UTF-8
validation is implemented in `src/utf8.zig`: the fragment collector validates
assembled messages across fragments and the raw connection read path validates
clear FIN text frames.

The framing engine is
[farbenbuilds/zslay](https://github.com/farbenbuilds/zslay). It is declared in
`build.zig.zon`, and `zon2nix` generates `build.zig.zon.nix` for offline Nix
builds. tachyon must not reimplement zslay's header codec, length validation,
close predicate or payload validator, or XOR masking. The same rule covers
zslay's `Conn` state machine: masking direction, fragment ordering, frame and
message limits, close-code policy, and the bounded transmit queue stay in
zslay. tachyon calls the close validator on inbound frames and owns the echo
obligation. Read `CODEBASE.md`, especially the Compatibility Notes, before
changing the boundary between the two libraries.

## Current State

The repository now contains the Zig package on top of the environment and
documentation foundation:

- `build.zig` and `build.zig.zon` define the public `tachyon` module, the
  static library, the Debug and ReleaseSafe test steps over `tests/main.zig`,
  the `check` step, and the zslay dependency.
- `src/root.zig` is the module entry point; it re-exports zslay, the frame
  facade, the UTF-8 validator, the WebSocket error model, the fragment
  accumulator and collector, the connection layer, the split read and write
  halves, the native stream adapter, and the HTTP handshake primitives.
- `src/frame.zig` implements the frame facade: `Frame`, `Payload`, the `OpCode`
  and `CloseCode` aliases with conversions, `unmask`/`unmask_at` delegations,
  the header-length bridge, `std.Io.Writer` vectored writes, and caller-buffer
  writes.
- `src/error.zig` implements the fastwebsockets 0.10.0 error taxonomy, zslay
  boundary normalization, `std.Io` reader/writer/stream mappings, the status
  out-parameter helper, and the close-code policy.
- `src/utf8.zig` implements incremental zero-allocation text validation:
  complete ranges use `std.unicode`, split code points stay in a `State` value,
  `validate_reader` adapts arbitrary `std.Io.Reader` chunk sizes, and
  `Frame.is_utf8` delegates to the same validator.
- `src/fragment.zig` implements the read-side fragment layer: the `Fragments`
  accumulator over caller-owned message storage and `FragmentCollector`, which
  drives `zslay.Conn` over a caller-provided `std.Io.Reader` with a caller-owned
  `frame_buffer` that bounds one frame payload. It collects text and binary
  continuations, validates text incrementally across fragments, unmasks inbound
  frames in place, and returns control frames to the caller without disturbing
  the in-progress message. Every protocol, frame, and I/O `read_frame` failure
  is latched and returned until `reset`; a zero `max_message_size` is a
  configuration rejection that returns `FrameTooLarge` without latching. The
  collector returns close frames after zslay's header-level checks only, so
  close-code and reason validation remains with the connection layer. It sends
  no automatic pong or close replies.
- `src/connection.zig` implements the role-aware `WebSocket` policy over one
  `zslay.Conn`. The caller supplies a `std.Io.Reader`, a `std.Io.Writer`, and
  caller-owned `frame_buffer`, `tx_nodes`, `write_buffer`, `close_buffer`, and
  optional `mask_scratch` storage. `Options` defaults auto-mask, auto-close,
  auto-pong, and writev to true, the writev threshold to 1024 bytes, and the
  exclusive maximum message size to 64 MiB. `MaskKeySource` is a seeded ChaCha8
  source. The raw read path suppresses pings and writes exact pongs, validates a
  close reason as UTF-8 before the close code, echoes a valid close payload
  exactly when no close was already observed, and answers an invalid code with
  1002 and the validated reason when it fits `close_buffer`, otherwise an empty
  reason. Automatic pong and close replies are flushed before `read_frame`
  returns. A client with `auto_apply_mask` off does not attempt automatic
  replies: pings are delivered, and closes are validated but not echoed or
  answered with 1002. `closed` gates non-close reads and writes; read failures
  latch until `reset` and write failures until `reset_tx`; clear FIN text frames
  are validated; writes use the vectored path above the threshold and the copied
  path at or below it; a zero maximum rejects before consuming. `read_event` is
  the shared read step: `read_frame` loops over it and sends the reply.
  `FragmentCollector` remains the assembled-message API.
- `src/split.zig` implements the split read/write surface: `WebSocketRead`,
  `WebSocketWrite`, `Split`, `after_handshake_split`/`init`, caller-owned
  `ReadStorage`, `WriteStorage`, and `Storage`, and `FragmentCollectorRead`.
  Because `zslay.Conn` couples RX and TX, each half owns an independent
  `connection.WebSocket` and `zslay.Conn`; both may share the same external
  `std.Io.Reader` and `std.Io.Writer` pointers because each uses one direction.
  The read half drives `WebSocket.read_event` and never writes; the write half
  drives `write_frame`/`flush` and never reads. Automatic pong and close
  obligations are forwarded through a sink with `send_obligation(Frame)`,
  `is_closed()`, and `failure()`; `WebSocketWrite` implements all three and
  writes then flushes each obligation. `FragmentCollectorRead` wraps a
  `WebSocketRead` by value with a caller-owned `message_buffer`, assembles
  continuations and split UTF-8 code points, and rejects a `message_buffer`
  overlapping the read `frame_buffer` with `InvalidLength`. All storage is
  caller-owned and zero allocation.
- `src/backpressure.zig` implements the opt-in flow-control policy over zslay's
  bounded transmit ring. `Limits` carries byte and frame high/low watermarks;
  `Flow` tracks queued payload bytes and completed frames, pauses data admission
  at a high mark, resumes at both low marks, and lets automatic control replies
  through while paused. Application controls other than close stop at the data
  capacity so one node stays reserved. `ConnectionOptions.backpressure`
  configures it per connection; `enqueue_frame` batches without draining,
  `write_frame` remains the drain-and-write path, and `flush` is the `std.Io`
  wait point. The policy stores no frame, never spins, and returns `WouldBlock`
  before mask-key or zslay queue side effects. The high frame mark must fit
  `tx_nodes` after reserving one node for automatic control replies. Read pacing
  stays with the caller because the raw connection has no inbound frame queue.
- `src/native_stream.zig` implements the `std.Io.net.Stream` transport edge.
  `Transport` builds `std.Io.Reader` and `std.Io.Writer` interfaces with
  `stream.reader(io, read_buffer)` and `stream.writer(io, write_buffer)`, then
  the native `WebSocket` and `Split` wrappers delegate to
  `connection.WebSocket` and `split.Split`. Transport buffers must be non-empty,
  mutually disjoint, and disjoint from connection or split storage; a bound
  transport must keep a stable address because the connection stores pointers to
  its embedded interfaces. Reads and writes block or suspend through the
  caller's `std.Io`, depending on the implementation. The module adds no
  allocation, event loop, task, or implicit socket close; the original
  `std.Io.net.Stream` keeps socket lifetime and shutdown.
- `src/handshake.zig` implements the RFC 6455 HTTP handshake boundary:
  canonical 16-byte key generation through `std.Io.randomSecure`, base64 key
  encoding and validation, `std.Io.Reader`/`Writer` request and response heads,
  client request construction and response verification, server request
  validation, and `101 Switching Protocols` response construction. It verifies
  `Sec-WebSocket-Accept` as deliberate hardening beyond fastwebsockets 0.10.0,
  accepts `Connection` and `Upgrade` token lists, rejects duplicate key,
  version, accept, and Host fields plus body-bearing upgrade or 101 heads,
  requires an origin-form target and RFC token header names, leaves bytes after
  the head buffered for the frame path, reads the head in chunks independent of
  the transport reader's buffer, and never allocates or opens a socket. The
  server primitives (`is_request`, `validate_request`, `read_request`, and
  `write_response`) are shared from this module, and it re-exports
  `accept_guid`, `accept_token_len`, `AcceptTokenBuffer`, and
  `compute_accept_token` from `src/upgrade.zig` so client callers keep working;
  the accept GUID literal and streaming accept-token derivation are owned by
  `src/upgrade.zig`.
- `src/upgrade.zig` implements the RFC 6455 server upgrade call order and owns
  the `accept_guid` constant plus the accept-token derivation. `incoming` reads
  and strictly validates a request without writing; `IncomingUpgrade.upgrade`
  and the one-shot `upgrade` force the server role on a config copy, construct
  the zero-allocation split from caller storage with
  `split.after_handshake_split`, and only then write and flush the 101 through
  `handshake.write_response`. Split construction validates caller storage and
  configuration without I/O, so those failures precede every response byte; a
  failed 101 write or flush discards the constructed split. `upgrade_async`
  returns `UpgradeFut = std.Io.Future(Error!Upgrade)`; the future and the
  resolved `Upgrade` borrow the reader, writer, head storage, split storage, and
  request view, so callers must await or cancel before releasing them. The
  one-shot `upgrade` does not inspect `Origin`, matching fastwebsockets, and it
  is not an authentication boundary; callers with cookie or ambient
  authentication should use `incoming`, inspect `request.head`, and apply origin
  policy before `.upgrade`. `IncomingUpgrade` fields are public, so callers that
  need the validation guarantee must use `incoming`. No response bytes are
  written before both request validation and split-storage validation succeed,
  coalesced bytes stay buffered in the reader, and all storage is caller-owned
  with no allocation, socket, or task opened outside the caller-provided
  `std.Io`. Root exports include `upgrade`, `Upgrade`,
  `UpgradeFut`, `IncomingUpgrade`, `upgrade_websocket`,
  `upgrade_websocket_async`, `read_incoming_upgrade`, `is_upgrade_request`,
  `accept_guid`, `accept_token_len`, `AcceptTokenBuffer`, and
  `compute_accept_token`.
- `build.zig.zon.nix`, `build.zig.zon.json`, and `build.zig.zon.txt` are the
  generated zon2nix views used by the flake for offline builds.
- `flake.nix`, `flake.lock`, and `.envrc` provide the Zig 0.17.1 shell.
- `.pre-commit-config.yaml` holds the hygiene and formatting hooks.
- `.agents/skills/` holds the shared skill pack and `.agents/agents/` holds the
  agy agent definitions.
- `.opencode/`, `.codex/`, and `.claude/` hold the matching OpenCode, Codex,
  and Claude Code agent definitions, plus platform-specific graphify skills,
  plugins, hooks, and settings. `.agents/rules/` and `.agents/workflows/` carry
  the Google Antigravity graphify integration.
- The root Markdown guides define the architecture and process.

The test suite lives under `tests/` and is aggregated by `tests/main.zig`.
Category folders such as `tests/frame-test/`, `tests/connection-test/`, and
`tests/native-stream-test/` mirror the protocol layers, and `tests/support.zig`
holds shared fixtures and test-only readers and writers. The suite covers the
dependency boundary, the error model, the frame facade, the incremental UTF-8
validator, the fragment accumulator and collector, the connection policy, raw
frame path, and write paths, the split reads and writes, the native stream
transport over a loopback `std.Io.net.Stream` pair, the HTTP handshake, and
the server upgrade call order, including validated-only `incoming`, split
construction before the 101 write and flush, the forced server role, and the
async future and its borrows; `tests/module-test/module_test.zig` adds fragment,
connection, split, native-stream, and handshake re-export tests. Library sources
contain no test blocks.

## Non-Negotiable Architecture

These rules apply to the implementation:

- Keep the frame layer pure. Given the same input it returns the same output and
  writes only into caller-owned memory.
- Keep zslay as the only frame codec and wire-state owner. Do not duplicate
  header parsing, length decoding, masking, close validation, masking direction,
  fragment ordering, frame/message limits, or the bounded transmit queue in
  tachyon.
- Keep optional extensions at the edge. Backpressure, streaming, native stream,
  UTF-8, deflate, and pub/sub must not add allocation, I/O, or negotiation
  state to the frame core.
- The protocol core is zero-allocation and I/O-agnostic. Allocators belong in
  examples, tests, or an explicit caller-owned buffer boundary, never in frame
  or connection state transitions.
- Backpressure is explicit: bounded queues and watermarks, no unbounded
  buffering, no dropped frames, and no busy waiting.
- Compression is fail-closed: bound decompressed output by the configured
  message limit before delivery, and never apply compression to control frames.
  permessage-deflate is blocked on zslay negotiated RSV1 support; land the codec
  change in zslay before enabling the extension in tachyon.
- Text UTF-8 validation is incremental and zero-allocation; it must handle code
  points split across frames and must never substitute replacement characters.
- Transport work belongs at the edge. The connection layer consumes
  caller-provided readers and writers; it does not open sockets or spawn tasks.
- Use Zig 0.17.1 `std.Io` asynchronous I/O for the transport and example
  layers. Do not add libxev or another third-party event loop. uWebZockets uses
  libxev for its own engine; tachyon deliberately follows the standard library
  instead.
- Use static dispatch. Core routing uses `switch` over explicit enums, not
  vtables or function-pointer tables. C ABI callbacks, if a C surface is added
  later, are the only documented exception and must not route parser paths.
- Invalid wire input returns a typed error. Never substitute a default, clamp
  silently, or continue after a protocol violation.
- Every peer-controlled length is bounded before allocation or indexing.

## Repository Structure

Current files:

| Path | Purpose |
| --- | --- |
| `build.zig`, `build.zig.zon` | Public module, static library, Debug and ReleaseSafe test steps over `tests/main.zig`, `check` step, and the zslay dependency. |
| `build.zig.zon.nix`, `.json`, `.txt` | Generated zon2nix views for offline Nix builds and dependency audits. |
| `src/root.zig` | Public module entry point; re-exports zslay, the frame facade, the UTF-8 validator, the error model, the fragment accumulator and collector, the connection layer, the split read and write halves, the native stream adapter, the HTTP handshake primitives, and the server upgrade call order. |
| `src/frame.zig` | `Frame`, `Payload`, `OpCode` and `CloseCode` aliases with conversions, `unmask`/`unmask_at`, the header-length bridge, and write paths. |
| `src/error.zig` | `WebSocketError` set, zslay and `std.Io` mappings, descriptions, close-code policy, and classification helpers. |
| `src/utf8.zig` | Incremental UTF-8 validation: `std.unicode` complete ranges, split code-point `State`, and a `std.Io.Reader` adapter. |
| `src/fragment.zig` | `Fragments` accumulator and `FragmentCollector` over `zslay.Conn`: caller-owned `frame_buffer` that bounds one frame payload and `message_buffer` that bounds one collected message, streaming text validation, and control-frame pass-through. |
| `src/connection.zig` | Role-aware `WebSocket` policy over `zslay.Conn`: caller-owned reader, writer, and storage, automatic pong and close replies, seeded mask source, exclusive limits, closed gating, failure latches, and vectored or copied writes. |
| `src/split.zig` | Split `WebSocketRead`, `WebSocketWrite`, and `Split` over independent `connection.WebSocket`/`zslay.Conn` values, caller-owned read and write storage, sink-forwarded obligations, and `FragmentCollectorRead`. |
| `src/native_stream.zig` | Implemented `std.Io.net.Stream` transport binding: caller-owned reader and writer buffers, native `WebSocket` and `Split` wrappers, buffer-alias validation, caller-owned socket lifetime, and no allocation or task spawning. |
| `src/handshake.zig` | RFC 6455 client handshake and shared server upgrade primitives: `std.Io` request/response heads, key generation and validation, accept-token re-exports from `src/upgrade.zig`, token-list validation, and the `101` response. |
| `src/upgrade.zig` | RFC 6455 server upgrade call order: `incoming` validation without writing, split construction from caller storage before the 101 write and flush through `handshake.write_response`, forced server role, and `upgrade_async` over `std.Io.Future`. |
| `tests/main.zig` | Test aggregator; imports every category test file so one module runs under Debug and ReleaseSafe. |
| `tests/support.zig` | Shared fixtures and test-only readers and writers. |
| `tests/<category>-test/` | Unit coverage grouped by protocol area: module, error, frame, UTF-8, fragment, connection, split, handshake, and upgrade. |
| `tests/README.md` | Test tree, aggregator, category naming, and run instructions. |
| `flake.nix`, `flake.lock` | Zig 0.17.1 shell, zon2nix, Nix formatting check, and musl shell. |
| `.envrc` | direnv entry point; selects the musl shell when the host uses musl. |
| `.pre-commit-config.yaml` | Formatting, hygiene, and zon2nix hooks. |
| `.github/workflows/lint.yml` | Pull-request Zig formatting lint with Zig 0.17.1. |
| `.github/workflows/test.yml` | Pull-request and main-push Zig test and check jobs for Zig or Zon changes. |
| `scripts/update_zon_files.sh` | Regenerates `build.zig.zon.nix`, `.json`, and `.txt` with zon2nix. |
| `.agents/skills/`, `skills-lock.json` | Shared skill pack, lock file, and the Antigravity graphify skill copy. |
| `.agents/agents/`, `.opencode/agents/`, `.codex/agents/`, `.claude/agents/` | Matching agent definitions for agy, OpenCode, Codex, and Claude Code. |
| `.agents/rules/`, `.agents/workflows/` | Google Antigravity graphify always-on rules and workflow. |
| `.codex/TEAM_WORKFLOW.md` | Codex team procedure and handoff contract. |
| `.opencode/`, `.codex/`, `.claude/` | Graphify skill copies, plugins, hooks, and client configuration. |
| `scripts/install_graphify_integrations.sh` | Refreshes the four project-scoped graphify integrations. |
| `scripts/check_graphify_integrations.sh` | Pre-commit gate for graphify skill, hook, and agent wiring consistency. |
| `.gitattributes` | Linguist rules for agent tooling, generated output, docs, and `.zon` files. |
| `.gitignore` | Nix, Zig, build, graph, and editor output. |
| `README.md`, root `*.md` | Banner, architecture, contributor, security, release, and agent guides. |

Target source layout, roughly in dependency order:

| Path | Purpose |
| --- | --- |
| `build.zig`, `build.zig.zon` | Public module, static library, test steps over the `tests/` tree, and the zslay dependency. |
| `src/root.zig` | Public module entry point and re-exports. |
| `src/error.zig` | `WebSocketError` set, zslay and `std.Io` mappings, descriptions, close-code policy, and classification helpers. |
| `src/frame.zig` | `Frame`, `Payload`, `OpCode` alias, `CloseCode` alias and conversions, `unmask`/`unmask_at`, header-length bridge, and write paths. |
| `src/utf8.zig` | Incremental zero-allocation UTF-8 validation for text messages: `std.unicode` complete ranges, split code-point `State`, and a `std.Io.Reader` adapter. |
| `src/backpressure.zig` | Implemented: byte/frame watermarks, data admission, control headroom, and close draining over zslay's bounded queue. |
| `src/connection.zig` | Implemented: role-aware `WebSocket` policy over `zslay.Conn`, caller-owned storage, automatic pong and close replies, seeded mask source, exclusive limits, closed gating, failure latches, vectored or copied writes, and opt-in backpressure. |
| `src/fragment.zig` | Implemented: `Fragments` accumulator and read-side `FragmentCollector` over `zslay.Conn`, caller-owned frame and message buffers, streaming UTF-8, and control-frame pass-through. |
| `src/stream.zig` | Planned extension: chunked message reader/writer for large messages. |
| `src/split.zig` | Implemented: `WebSocketRead`, `WebSocketWrite`, and `Split` over independent `connection.WebSocket`/`zslay.Conn` values, caller-owned read and write storage, sink-forwarded automatic replies, and `FragmentCollectorRead`. |
| `src/native_stream.zig` | Implemented: `std.Io.net.Stream` transport binding plus native `WebSocket` and `Split` wrappers over the connection layers, caller-owned buffers, and alias validation. |
| `src/deflate.zig` | Planned extension: RFC 7692 permessage-deflate state and context takeover. |
| `src/pubsub.zig` | Planned extension: bounded topic hub and fanout over the frame/stream API. |
| `src/handshake.zig` | Implemented: RFC 6455 client handshake and shared server upgrade primitives over `std.Io.Reader`/`Writer`, including key generation, accept-token re-exports from `src/upgrade.zig`, head parsing, and response construction. |
| `src/upgrade.zig` | Implemented: RFC 6455 server upgrade call order over the validated `handshake` request and response primitives, including the accept-token derivation, split construction from caller storage before the 101 write and flush, the forced server role, and `upgrade`, `incoming`, and `upgrade_async`. |
| `tests/main.zig` | Aggregates the category test files for the Debug and ReleaseSafe test steps. |
| `tests/support.zig` | Shared test fixtures and protocol helpers. |
| `tests/<category>-test/*.zig` | Unit tests grouped by area: module, error, backpressure, frame, UTF-8, fragment, connection, split, native stream, handshake, and upgrade. |
| `tests/<integration>-test/` | Planned Autobahn, fuzz, and loopback integration suites; no adapter exists yet. |

The handshake/upgrade pair deliberately forms a small re-export cycle:
`src/upgrade.zig` uses the handshake request and response primitives, and
`src/handshake.zig` re-exports the accept-token names from `src/upgrade.zig`.
Treat the pair as one dependency unit rather than a strict ordering.

There is no target `src/close.zig` or `src/mask.zig`. zslay already owns the
close predicate, payload validator, outgoing close validation, and masking;
tachyon applies inbound close policy, owns the echo, and exposes aliases plus
one-line delegations from `src/frame.zig`. Do not create a second enum, range
table, or XOR loop. See `CODEBASE.md#compatibility-notes` before adapting a
zslay behavior.

Planned extension rows are roadmap items; their files do not exist yet.
`src/native_stream.zig`, `src/handshake.zig`, and `src/upgrade.zig` are
implemented. Extend the planned owner in `AGENT_DIRECTORY.md` and the matching
agent definitions before creating
one of these modules.

Keep one owner per file. Cross-scope work is handed to the owning agent or
reviewer instead of edited in the same pass.

## Functional Core

The frame layer is a pure transformation over caller-owned buffers. Stateful
behavior belongs to the connection layer and must be explicit in its parameters.

- Use flat iterative loops with early returns. Recursion is prohibited in frame
  and connection paths.
- Use guard clauses and `switch` rather than nested `if`/`else` ladders.
- Keep mutation narrow: an operation may mutate only the buffer or state record
  named in its contract.
- Do not add logging, clocks, randomness, environment reads, or allocation to
  frame parsing. Randomness for client keys belongs in the connection or
  handshake boundary.
- Compile-time assertions should prove header sizes and layout relationships;
  zslay owns close-range policy and its own layout invariants.

## Build, Test, and Development Commands

Environment commands:

```sh
nix develop                 # reproducible Zig 0.17.1 shell
direnv allow                # optional automatic shell entry
zig version                 # must print 0.17.1
nix flake check             # Nix formatting check
pre-commit run --all-files  # hygiene hooks
```

Library commands:

```sh
zig build                   # static library
zig build test              # Debug and ReleaseSafe suites over tests/main.zig
zig build check             # type-check library and tests
zig fmt --check .           # formatting gate
```

Use `zig fmt .` to apply formatting. Do not install project tools globally with
`apt`, `brew`, or `npm`.

zslay is declared in `build.zig.zon`. The `zon2nix` pre-commit hook regenerates
`build.zig.zon.nix`, `build.zig.zon.json`, and `build.zig.zon.txt` whenever
`build.zig.zon` changes. The flake consumes the generated Nix expression so the
build has no network access and no duplicated version pin. When the dependency
changes, update `build.zig.zon`, run `pre-commit run zon2nix --all-files` (or
`sh scripts/update_zon_files.sh`), and commit the generated files with it.

## Coding Style and Naming

- Follow `zig fmt`: four-space indentation and a 120-character line limit.
- Use `snake_case` for files, functions, and variables.
- Use `PascalCase` for types, type-level constants, and error names.
- Prefix future exported C functions with `tachyon_`.
- Prefer early returns, explicit error sets, shallow control flow, and sparse
  comments that explain why rather than restating the code.
- Define public types at file scope with explicit names. Extract repeated
  compound types into aliases instead of nesting anonymous structs.
- Use `_len` for byte counts and `_sent` for stream progress.
- Do not use emojis in code, documentation, branches, commits, or reviews.
- Delete unused imports, dead code, and commented-out blocks in the same change.
- Do not add `TODO`, `FIXME`, `XXX`, or `HACK` markers. File an issue or land the
  change.

See [CODING_CONVENTION.md](CODING_CONVENTION.md) for the full rule set and Zig
0.17.1 notes.

## Testing Guidelines

Use Zig `test` blocks in `tests/<category>-test/*.zig`, aggregated by
`tests/main.zig`, named `<Area>: <behavior>`, for example
`Frame: encodes a masked extended-length header`. Add a new category folder as
`tests/<area>-test/` and import its files from `tests/main.zig`. Shared fixtures
and test-only readers and writers belong in `tests/support.zig`. Library sources
contain no test blocks; do not add tests back to `src/`.

- Every behavioral change needs a focused regression test.
- Cover boundary lengths 0, 1, 125, 126, 127, 65535, 65536, and the configured
  maximum where the changed code interprets lengths.
- Cover malformed input: reserved bits, fragmented control frames, one-byte
  close payloads, invalid close codes, invalid UTF-8 reasons, and truncated
  headers.
- Keep payloads caller-owned in tests; do not introduce a test allocator into
  the frame core.
- Run both Debug and ReleaseSafe before review.
- Autobahn, fuzzing, and loopback echo suites belong under `tests/` as future
  integration category folders; none is implemented yet. The connection layer
  has unit coverage only. Do not claim compliance before those suites exist and
  pass.

## Security and Protocol Rules

- Enforce client-to-server masking and server-to-client unmasked frames.
- Reject nonzero RSV bits until an extension is negotiated.
- Reject fragmented control frames and control payloads above 125 bytes.
- Validate close length, close code, and UTF-8 reason before echoing. Never
  reuse unvalidated reason bytes in a 1002 reply.
- Cap message size before buffering or indexing.
- Treat every peer-supplied length as untrusted, including extended lengths.
- Seed client mask keys from a uniform, secret source in production; a
  deterministic seed is only a test seam. The connection never reads ambient
  randomness.
- Do not log payload bytes at any severity.
- Security reports follow [SECURITY.md](SECURITY.md).

## Commit and Pull Request Guidelines

History follows conventional commits:
`<type>(<scope>): <imperative subject>`.

Common types are `feat`, `fix`, `perf`, `build`, `ci`, `docs`, `style`,
`refactor`, and `test`. Keep subjects lowercase and omit the trailing period.
Example: `docs(repo): add flake and agent guides`.

Pull requests must:

- explain what changed and why,
- identify the change type,
- link issues with `Closes #123` when applicable,
- list the verification commands and their results,
- confirm formatting and checks,
- keep one scoped concern per pull request,
- avoid screenshots unless the change is visual documentation or branding.

Do not commit, push, tag, or open a pull request unless the user explicitly
asked for it.

## Sub-Agent Directory and Workflow

The shared ownership map and review workflow live in
[AGENT_DIRECTORY.md](AGENT_DIRECTORY.md). Matching definitions live under
`.agents/agents/`, `.opencode/agents/`, `.codex/agents/`, and `.claude/agents/`;
Codex also reads `.codex/TEAM_WORKFLOW.md`. The shared skill pack is vendored
under `.agents/skills/` and pinned by `skills-lock.json`; an agent must not
reference a definition or skill that is not present in the repository.

For coordinated work, follow this sequence:

1. Architect: read the request, inspect the tree, state assumptions, name
   affected paths and owners, define acceptance criteria, and list checks. The
   architect does not edit.
2. Developer: implement only the assigned slice, keep edits inside owned paths,
   and report changed files plus commands actually run.
3. Reviewer: read-only review of correctness, protocol behavior, security,
   tests, style, scope, and evidence. Report findings with file and line
   references.
4. Integrator: route findings to owners, re-review changed areas, verify the
   final combined diff, and prepare the delivery summary.

Keep one owner per pull request scope. Never let two agents edit the same file
concurrently. Small documentation-only changes may combine architect and
developer work but still need integrator verification.

## Optional Herdr Orchestration

[Herdr](https://herdr.dev) is optional. Use it only when the user explicitly
asks for Herdr, `herdr` is installed, and `HERDR_ENV=1` is set in an active
Herdr session. If Herdr was requested but the environment check fails, report
the problem and stop; do not silently switch to another orchestration mode. If
Herdr was not requested, ignore this section.

The binary is authoritative for syntax. Start with:

```sh
test "${HERDR_ENV:-}" = 1
herdr --help
herdr agent
herdr agent list
herdr pane list
```

Split a worker pane, start the matching agent kind, and send a self-contained
prompt with scope boundaries, exact paths, acceptance criteria, and verification
commands. Worker panes do not see the orchestrator transcript. Leaf workers do
not delegate further. A blocked worker surfaces its approval request to the
user; the orchestrator does not answer it. Do not close panes or stop the Herdr
server unless the user asked.

## Skills

The shared skill pack lives in `.agents/skills/` and is pinned by
`skills-lock.json`. Graphify has platform copies under `.opencode/skills/`,
`.codex/skills/`, `.claude/skills/`, and `.agents/skills/`, with the OpenCode
plugin at `.opencode/plugins/graphify.js`, the Codex hook at
`.codex/hooks.json`, the Claude Code hooks at `.claude/settings.json`, and the
Antigravity rules and workflow under `.agents/rules/` and `.agents/workflows/`.
Refresh them with `scripts/install_graphify_integrations.sh`; verify them with
`scripts/check_graphify_integrations.sh`. [SKILL.md](SKILL.md) is the
human-readable catalog; [AGENT_DIRECTORY.md](AGENT_DIRECTORY.md) maps skills to
owners.

For Zig work, apply `zig-0-17`, `zig-best-practices`, `zig-testing`, and
`zig-tiger-style`. Use TigerStyle for safety ideas such as entry assertions,
bounded loops, and compile-time layout invariants, while keeping tachyon's
`snake_case` naming, 120-column limit, and zero allocation contract.

For Nix work, apply `nix-best-practices` and `nix-hermetic`. For architecture
and review work, use `codebase-design`, `improve-codebase-architecture`,
`grilling`, `grill-me`, `domain-modeling`,
`thermo-nuclear-code-quality-review`, and `untangle-codebase` when the user
requests the pass. `untangle-codebase` is manual-only. Keep `skills-lock.json`
and this document in sync when adding or removing a skill.

## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

When the user types `/graphify`, use the installed graphify skill or instructions before doing anything else.

Rules:
- When graphify-out/graph.json exists, run `graphify query "<question>"` before your first grep, search or source-file read for a codebase question, and put this rule in every subagent prompt that explores code. Read raw files only for lines the graph or an earlier read already located. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- Dirty graphify-out/ files are expected after hooks or incremental updates; dirty graph files are not a reason to skip graphify. Only skip graphify if the task is about stale or incorrect graph output, or the user explicitly says not to use it.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).
- A committed graphify-out/graph.json is rewritten whole on every build, so a large diff to it in a pull request is expected. Do not flag it as churn or suggest skipping the graph rebuild or its hooks.
