<p align="center">
  <img src="misc/tachyon-banner.png" alt="tachyon banner">
</p>

# tachyon

A fast RFC 6455 WebSocket implementation in Zig.

tachyon recreates the public surface and observable behavior of
[denoland/fastwebsockets](https://github.com/denoland/fastwebsockets) 0.10.0 in
Zig 0.17.1. Framing is delegated to
[farbenbuilds/zslay](https://github.com/farbenbuilds/zslay), a pure,
I/O-agnostic framing engine with a bounded connection state machine. zslay owns
header coding, masking, the close predicate and payload validator, masking
direction, fragment ordering, and frame/message limits. tachyon applies inbound
close policy, owns the close echo, and covers the fastwebsockets API surface
incrementally: automatic ping/pong and close handling, fragment buffering,
split read/write halves, UTF-8 checks, the client handshake, and the server
upgrade call order are implemented; stream adapters remain planned. The 0.10.0
surface is the parity baseline;
backpressure, streaming messages, native `std.Io` transport, permessage-deflate,
and pub/sub are planned post-parity extensions. Incremental UTF-8 validation is implemented
in `src/utf8.zig`: the fragment collector validates assembled messages across
fragments and the raw connection read path validates clear FIN text frames.
Deliberate hardening and compatibility exceptions are recorded in
[CODEBASE.md](CODEBASE.md#compatibility-notes); the extension order and
constraints are in
[CODEBASE.md](CODEBASE.md#extension-roadmap).

## Current State

The project provides its Zig package: `build.zig` defines the public
`tachyon` module and static library, `src/root.zig` is the module entry point,
and zslay is pinned in `build.zig.zon` for framing and wire-state validation.
The generated zon2nix views feed the offline Nix test and package builds.
`src/error.zig` implements the fastwebsockets 0.10.0 error taxonomy, zslay
boundary normalization, `std.Io` transport mappings, and the close-code policy.
`src/frame.zig` implements the fastwebsockets-compatible frame facade: `Frame`,
`Payload`, the `OpCode` and `CloseCode` aliases with conversions,
`unmask`/`unmask_at` delegations, the header-length bridge, `std.Io.Writer`
vectored writes, and caller-buffer writes. `src/utf8.zig` adds incremental
zero-allocation text validation: complete ranges go through `std.unicode`,
split code points are carried across `std.Io` read chunks, and `Frame.is_utf8`
delegates to the same validator. `src/fragment.zig` adds the read-side fragment
layer: the `Fragments` accumulator over caller-owned message storage and the
`FragmentCollector`, which drives `zslay.Conn` over a caller-provided
`std.Io.Reader`, unmasks inbound frames, passes control frames through, and
validates text incrementally across fragments; protocol, frame, and I/O read
failures are latched until `reset`. `src/connection.zig` adds the role-aware
`WebSocket` policy over one `zslay.Conn`: caller-provided reader and writer,
caller-owned frame, transmit-node, write, close, and optional mask-scratch
storage, automatic pong and close replies, a seeded mask key source, an
exclusive maximum message size, closed gating, read and write latches, and
vectored or copied writes. `read_frame` flushes automatic pong and close replies
before returning. A client with `auto_apply_mask` off delivers control frames
instead of attempting replies: pings pass through, and closes are validated but
not echoed or answered with 1002. `src/split.zig` adds the split surface:
`WebSocketRead`, `WebSocketWrite`, `Split`, `after_handshake_split`/`init`,
caller-owned `ReadStorage`, `WriteStorage`, and `Storage`, and
`FragmentCollectorRead`. Each half owns an independent `connection.WebSocket`
and `zslay.Conn`; both may share the external reader and writer pointers because
each uses one direction. The read half drives `read_event` and forwards
automatic pong and close obligations through
`WebSocketWrite.send_obligation`, which writes and flushes before returning; the
write half drives `write_frame` and `flush` and never reads.
`FragmentCollectorRead` assembles continuations and split UTF-8 code points over
a caller-owned `message_buffer` and rejects overlap with the read `frame_buffer`
with `InvalidLength`. All storage is caller-owned and zero allocation.
`src/handshake.zig` adds the RFC 6455 HTTP handshake boundary over caller-provided
`std.Io.Reader` and `std.Io.Writer` values: secure 16-byte key generation,
canonical base64 validation, accept-token re-exports from `src/upgrade.zig`,
request and response head parsing bounded by caller storage, client response
verification including `Sec-WebSocket-Accept`, server request validation, and
`101 Switching Protocols` response construction. Bytes after the header stay
buffered for the frame path, and the module never allocates or opens a socket.
`src/root.zig` re-exports the facade, the error model, the UTF-8 validator, the
fragment accumulator and collector, the connection layer, the split halves, the
handshake primitives, and the server upgrade call order.

`src/upgrade.zig` implements the server call order over those primitives:
`incoming` reads and strictly validates a request without writing,
`IncomingUpgrade.upgrade` and the one-shot `upgrade` force the server role,
construct the split from caller storage, and only then write and flush the
computed 101 response; storage failures therefore precede every response byte,
and a failed 101 write or flush discards the constructed zero-allocation split.
`upgrade_async` returns a `std.Io.Future` for the same call order; the future and
the resolved `Upgrade` borrow the reader, writer, head storage, split storage,
and request view, so callers must await or cancel before releasing them. The
module owns the RFC 6455 accept GUID and accept-token derivation;
`src/handshake.zig` re-exports those names for client callers. The one-shot
`upgrade` does not inspect `Origin`, matching fastwebsockets; callers with
cookie or ambient authentication should use `incoming`, inspect `request.head`,
and apply origin policy before `.upgrade`. No response bytes are written before
both request validation and split-storage validation succeed, coalesced frame
bytes stay buffered, and every storage region is caller-owned and zero
allocation.
The fragment collector is deliberately read-only, while the connection and split
read paths own automatic replies. No separate close or masking module is
planned; zslay owns the close predicate, payload validator, and mask routine.
The remaining extension roadmap adds backpressure, streaming, native `std.Io`
transport, permessage-deflate, and pub/sub after the parity baseline lands.

## Targets

| Area | Target |
| --- | --- |
| `Frame`, `OpCode`, `Payload`, `CloseCode` | Implemented fastwebsockets-compatible surface over zslay |
| `WebSocketError` | fastwebsockets 0.10.0 error taxonomy with zslay and `std.Io` mappings |
| zslay header coding, length handling, masking, fragment ordering, limits | Delegated to zslay |
| Close predicate and payload validator | zslay; inbound policy and echo in tachyon |
| `WebSocket` read/write loop, auto-close, auto-pong, max message size | Implemented over one `zslay.Conn` with caller-owned storage, closed gating, failure latches, and a seeded mask key source |
| `Fragments`, `FragmentCollector` | Implemented read-side collector over `zslay.Conn` with a caller-owned `frame_buffer` that bounds one frame payload and a `message_buffer` that bounds one collected message |
| Client handshake and server upgrade | Implemented `handshake` primitives plus the `upgrade` call order in `src/upgrade.zig`: validated-only `incoming`, split construction from caller storage before the 101 write and flush, forced server role, and an async future whose resolved `Upgrade` also borrows caller storage |
| Split read/write halves | Implemented `Split`, `WebSocketRead`, `WebSocketWrite`, and `FragmentCollectorRead` over independent `connection.WebSocket`/`zslay.Conn` values with caller-owned storage and sink-forwarded obligations |
| Backpressure and bounded write watermarks | Planned extension |
| Incremental UTF-8 validation across fragments | Implemented in `src/utf8.zig`: the fragment collector validates assembled messages and the raw connection read path validates clear FIN text frames |
| Streaming message reader/writer | Planned extension |
| Native `std.Io.Reader`/`Writer` transport adapter | Planned extension |
| permessage-deflate (RFC 7692) | Planned extension beyond 0.10.0 parity |
| Pub/Sub topic hub and fanout | Planned application layer |

## Design

- Zero-allocation protocol core. Payloads are caller-owned slices.
- zslay performs frame coding and wire-state validation; tachyon performs API
  policy and transport.
- Transport uses Zig 0.17.1 `std.Io` asynchronous I/O. tachyon does not depend
  on libxev or another third-party event loop.
- Transport work stays at the edge and never enters the frame core. The
  connection layer consumes caller-provided readers and writers and owns no
  socket or task.
- Split halves own independent `connection.WebSocket` and `zslay.Conn` values,
  share the caller's reader and writer pointers, and route automatic replies
  through `send_obligation`. All split storage is caller-owned and zero
  allocation.
- The server upgrade reads and strictly validates the request, constructs the
  split from caller storage, and only then writes and flushes the 101, so
  storage failures precede every response byte; a failed 101 write or flush
  discards the constructed zero-allocation split. `upgrade_async` and the
  resolved `Upgrade` borrow the reader, writer, head storage, split storage, and
  request view until the `std.Io.Future` is awaited or cancelled.
- Extensions are optional modules at the edge. Backpressure is bounded and
  explicit, UTF-8 validation is incremental, and decompression is capped by the
  message limit before delivery.
- permessage-deflate negotiates only after zslay gains negotiated RSV1 support;
  Zig's `std.compress.flate` supplies the raw deflate codec.
- Pub/Sub is an application layer over frames and streams, not a wire-format
  change.
- Zig 0.17.1 is pinned through the Nix flake.
- Invalid wire input returns a typed error instead of a fallback.

## Environment

```sh
git clone https://github.com/farbenbuilds/tachyon.git
cd tachyon
direnv allow          # or: nix develop
zig version           # 0.17.1
nix flake check       # formatting and test checks
nix build             # static library through zon2nix-prefetched packages
```

Library commands:

```sh
zig build
zig build test
zig build check
zig fmt --check .
```

## Documentation

- [CODEBASE.md](CODEBASE.md): target file map, runtime flow, parity mapping,
  compatibility notes, and extension roadmap.
- [CODING_CONVENTION.md](CODING_CONVENTION.md): style and safety rules.
- [CONTRIBUTE.md](CONTRIBUTE.md): setup, checks, commits, releases.
- [CI_CD_PIPELINE.md](CI_CD_PIPELINE.md): pipeline contract.
- [SECURITY.md](SECURITY.md): vulnerability reporting.
- [AGENTS.md](AGENTS.md): rules for coding agents.
- [AGENT_DIRECTORY.md](AGENT_DIRECTORY.md): ownership and review roles.
- [SKILL.md](SKILL.md): vendored skill catalog and graphify setup.
- [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md): dependency attribution.
- [.github/](.github/): pull request template, commit convention, code of
  conduct, issue forms, and funding metadata.

## License

MIT. See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
