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
close policy, owns the close echo, and adds the fastwebsockets API surface:
automatic ping/pong and close handling, fragment buffering and UTF-8 checks,
handshakes, and stream adapters. The 0.10.0 surface is the parity baseline;
backpressure, streaming messages, native `std.Io` transport, incremental UTF-8,
permessage-deflate, and pub/sub are planned post-parity extensions. Deliberate
hardening and compatibility exceptions are recorded in
[CODEBASE.md](CODEBASE.md#compatibility-notes); the extension order and
constraints are in
[CODEBASE.md](CODEBASE.md#extension-roadmap).

## Current State

The project now bootstraps its Zig package: `build.zig` defines the public
`tachyon` module and static library, `src/root.zig` is the module entry point,
and zslay is pinned in `build.zig.zon` for framing and wire-state validation.
The generated zon2nix views feed the offline Nix test and package builds.
`src/error.zig` implements the fastwebsockets 0.10.0 error taxonomy, zslay
boundary normalization, `std.Io` transport mappings, and the close-code policy.
`src/frame.zig` implements the fastwebsockets-compatible frame facade: `Frame`,
`Payload`, the `OpCode` and `CloseCode` aliases with conversions,
`unmask`/`unmask_at` delegations, the header-length bridge, `std.Io.Writer`
vectored writes, and caller-buffer writes. `src/root.zig` re-exports the facade
and the error model.
Connection, fragmentation, handshake, upgrade, and split modules are not
implemented yet. No separate close or masking module is planned; zslay owns the
close predicate, payload validator, and mask routine. The extension roadmap
adds backpressure, streaming, native `std.Io` transport, incremental UTF-8,
permessage-deflate, and pub/sub after the parity baseline lands.

## Targets

| Area | Target |
| --- | --- |
| `Frame`, `OpCode`, `Payload`, `CloseCode` | Implemented fastwebsockets-compatible surface over zslay |
| `WebSocketError` | fastwebsockets 0.10.0 error taxonomy with zslay and `std.Io` mappings |
| zslay header coding, length handling, masking, fragment ordering, limits | Delegated to zslay |
| Close predicate and payload validator | zslay; inbound policy and echo in tachyon |
| `WebSocket` read/write loop, auto-close, auto-pong, max message size | Planned |
| `FragmentCollector` | Planned |
| HTTP server upgrade and client handshake | Planned |
| Split read/write halves | Planned |
| Backpressure and bounded write watermarks | Planned extension |
| Incremental UTF-8 validation across fragments | Planned extension |
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
- Transport work stays at the edge and never enters the frame core.
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
