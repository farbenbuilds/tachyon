# Codebase Map

tachyon is a Zig 0.17.1 WebSocket implementation that will recreate the behavior
of denoland/fastwebsockets while delegating frame coding to
[farbenbuilds/zslay](https://github.com/farbenbuilds/zslay). This document maps
the current tree, the intended connection architecture, and the fastwebsockets
surface each target module owns.

## Current State

This change contains the environment and documentation foundation:

- `flake.nix` and `flake.lock` for the Zig 0.17.1 environment and zon2nix,
- `.envrc`, `.gitignore`, `.gitattributes`, and `.pre-commit-config.yaml`,
- `scripts/update_zon_files.sh` for generated dependency views,
- the human and agent guides,
- the shared skill pack, graphify integration, and `skills-lock.json`,
- matching agent definitions for agy, OpenCode, and Codex,
- the `.github` contribution metadata, templates, and code of conduct,
- the project banner under `misc/`.

It does not contain `build.zig`, `build.zig.zon`, `src/`, tests, benchmarks,
examples, fuzz targets, or Actions workflows.

## Target Runtime Flow

### Frame encoding

`Frame` will hold a `fin` bit, an opcode, an optional masking key, and a
caller-owned payload slice. Header encoding delegates to `zslay.encode_header`
so control-frame limits, reserved bits, masking-key consistency, and
extended-length canonicalization stay in one codec.

### Frame masking

`tachyon.unmask` and `tachyon.mask_payload` will forward to `zslay.mask` at key
position zero. zslay XORs in wide-word chunks while preserving the four-byte key
schedule. Payload memory stays caller-owned.

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

The connection layer will read bytes into a caller-provided buffer, ask zslay to
decode the header, wait for the full payload, and then apply role policy:

- server reads unmask client frames when `auto_apply_mask` is enabled,
- ping frames produce an automatic pong obligation unless `auto_pong` is off,
- close frames validate length, code, and reason, then produce an echo
  obligation unless `auto_close` is off,
- message limits are checked before payload buffering,
- text frames are validated as UTF-8 before delivery or after fragment
  collection.

### Connection writes

The connection layer will apply the client mask when required, reject writes
after a close frame, encode the header, write header and payload, and optionally
use vectored writes above the configured threshold. It does not allocate; the
caller supplies any scratch space needed by the chosen stream adapter.

### Fragmentation

`FragmentCollector` will accumulate text and binary continuations until `fin`,
enforce message limits across fragments, and validate text as one UTF-8 stream.
Control frames may interleave and must not be buffered as message fragments.

### Handshake and upgrade

The client handshake generates a 16-byte key, verifies `101 Switching
Protocols`, `Upgrade: websocket`, and `Connection: Upgrade`, and returns a
post-handshake socket. The server upgrade validates `Sec-WebSocket-Key` and
`Sec-WebSocket-Version: 13`, computes the SHA-1 and Base64 accept token, and
returns the response plus the upgraded stream.

## Target Source Layout

| File | Purpose |
| --- | --- |
| `src/root.zig` | Public module entry point and re-exports. |
| `src/frame.zig` | `Frame`, `OpCode`, `Payload`, `MaxHeaderLen`, header-length calculation, and the zslay encode bridge. |
| `src/close.zig` | Non-exhaustive `CloseCode` enum, `from_u16`, `to_u16`, and `is_allowed` range policy. |
| `src/mask.zig` | `unmask` and `mask_payload` wrappers over zslay's masking routine. |
| `src/error.zig` | `WebSocketError` set mirroring fastwebsockets failure categories. |
| `src/connection.zig` | Role-aware `WebSocket` state, read/write loops, automatic control replies, mask direction, limits. |
| `src/fragment.zig` | `FragmentCollector`, split-read collector, UTF-8 streaming, message-size accounting. |
| `src/handshake.zig` | Client request and response verification, key generation. |
| `src/upgrade.zig` | Server upgrade validation and response construction. |
| `src/split.zig` | Read and write halves plus split constructors. |
| `src/test.zig` | Unit tests for close codes, masking, framing, fragmentation, and connection policy. |
| `src/bench.zig` | Frame and connection microbenchmarks. |
| `tests/autobahn.zig` | Autobahn|TestSuite adapter and report handling. |
| `fuzz/frame.zig` | Bounded frame and connection fuzz targets. |

The layout follows the fastwebsockets module split, with Zig-specific names and
no hidden allocator or runtime dependency.

## fastwebsockets to tachyon Mapping

| fastwebsockets | tachyon | Status |
| --- | --- | --- |
| `Frame` | `Frame` | Target |
| `OpCode` | `OpCode` (zslay enum) | Target |
| `Payload` | `Payload` (caller-owned slice) | Target |
| `CloseCode` | `CloseCode` | Target |
| `WebSocketError` | `WebSocketError` | Target |
| `unmask` | `unmask` / `mask_payload` | Target |
| `Role` | `Role` | Planned with connection layer |
| `WebSocket` | `WebSocket` | Planned |
| `FragmentCollector` | `FragmentCollector` | Planned |
| `handshake::client` | `handshake.client` | Planned |
| `upgrade::upgrade` | `upgrade.upgrade` | Planned |
| `upgrade::is_upgrade_request` | `upgrade.is_request` | Planned |
| `WebSocketRead` / `WebSocketWrite` | split halves | Planned |
| `FragmentCollectorRead` | split collector | Planned |
| `set_writev` / `set_writev_threshold` | same setters | Planned |
| `set_auto_close` / `set_auto_pong` | same setters | Planned |
| `set_auto_apply_mask` | same setter | Planned |
| `set_max_message_size` | same setter | Planned |
| permessage-deflate | not supported | Out of scope, matching upstream |

## Dependency Boundary

The dependency is [farbenbuilds/zslay](https://github.com/farbenbuilds/zslay).
`build.zig.zon` declares it, and the `zon2nix` pre-commit hook generates
`build.zig.zon.nix`, `build.zig.zon.json`, and `build.zig.zon.txt`. The flake
consumes the generated Nix expression, so dependency versions and hashes live in
one place instead of being repeated in `flake.nix`.

zslay owns:

- RFC 6455 header layout and serialization,
- extended-length canonicalization and limits,
- masking,
- close-payload validation and close-code ranges,
- the optional connection state machine used by other consumers.

tachyon owns:

- the fastwebsockets-compatible frame and connection API,
- role policy and automatic control replies,
- fragmentation collection,
- `std.Io` stream adapters, handshakes, and upgrades,
- tests, examples, benchmarks, and the Nix/CI packaging surface.

Do not copy zslay internals into tachyon. If zslay lacks a required primitive,
change zslay first, publish a release, update `build.zig.zon`, regenerate the
zon2nix views, and commit them in the same tachyon pull request.

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

Future build files:

| File | Purpose |
| --- | --- |
| `build.zig` | Public `tachyon` module, static library, Debug and ReleaseSafe tests, and `check` step. |
| `build.zig.zon` | Package metadata, minimum Zig version, zslay dependency, and published paths. |
| `build.zig.zon.nix` | Generated by zon2nix so the flake can prefetch every package dependency for offline Nix builds. |
| `build.zig.zon.json`, `build.zig.zon.txt` | Generated dependency metadata and URL lists for audits and tooling. |

## Project Support Files

- `README.md` introduces the library and its current status.
- `AGENTS.md` and `CLAUDE.md` define agent rules; `AGENT_DIRECTORY.md` owns the
  roster and workflow.
- `CODING_CONVENTION.md` defines the Zig style and safety contract.
- `CONTRIBUTE.md` covers setup, checks, commits, and releases.
- `CI_CD_PIPELINE.md` records the pipeline contract. Actions workflows are not
  included in this change.
- `SECURITY.md` covers reporting and supported versions.
- `CHANGELOG.md` records landed changes.
- `THIRD_PARTY_NOTICES.md` records fastwebsockets, zslay, and uWebZockets
  attribution.
- `SKILL.md` summarizes the vendored skill pack and graphify setup.
- `.agents/skills/` and `skills-lock.json` hold the shared skill pack.
- `.agents/agents/`, `.opencode/agents/`, and `.codex/agents/` hold the matching
  agent definitions.
- `.codex/TEAM_WORKFLOW.md` defines the Codex team procedure.
- `.opencode/` and `.codex/` hold the graphify skill copies, plugin, hooks, and
  client configuration.
- `misc/tachyon-banner.png` is the README banner asset.
- `.github/` holds the pull request template, commit convention, code of
  conduct, issue forms, and funding metadata.
