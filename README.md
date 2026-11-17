<p align="center">
  <img src="misc/tachyon-banner.png" alt="tachyon banner">
</p>

# tachyon

A fast RFC 6455 WebSocket implementation in Zig.

tachyon recreates the public surface and observable behavior of
[denoland/fastwebsockets](https://github.com/denoland/fastwebsockets) in Zig
0.17.1. Framing is delegated to
[farbenbuilds/zslay](https://github.com/farbenbuilds/zslay),
a pure, I/O-agnostic frame codec. tachyon owns the connection state that zslay
deliberately leaves to its caller: role-aware masking, automatic ping/pong and
close handling, fragmentation, handshakes, and stream adapters.

## Current State

The project now bootstraps its Zig package: `build.zig` defines the public
`tachyon` module and static library, `src/root.zig` is the module entry point,
and zslay is pinned in `build.zig.zon` for frame coding. The generated zon2nix
views feed the offline Nix test and package builds. Connection, fragmentation,
handshake, upgrade, and split modules are not implemented yet.

## Targets

| Area | Target |
| --- | --- |
| `Frame`, `OpCode`, `Payload`, `CloseCode`, `WebSocketError` | fastwebsockets-compatible surface |
| zslay header encode/decode, length handling, close validation, masking | Delegated to zslay |
| `WebSocket` read/write loop, auto-close, auto-pong, max message size | Planned |
| `FragmentCollector` | Planned |
| HTTP server upgrade and client handshake | Planned |
| Split read/write halves | Planned |
| permessage-deflate | Not planned, matching fastwebsockets |

## Design

- Zero-allocation protocol core. Payloads are caller-owned slices.
- zslay performs frame coding; tachyon performs connection policy.
- Transport uses Zig 0.17.1 `std.Io` asynchronous I/O. tachyon does not depend
  on libxev or another third-party event loop.
- Transport work stays at the edge and never enters the frame core.
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

- [CODEBASE.md](CODEBASE.md): target file map, runtime flow, parity mapping.
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
