# Third-Party Notices

tachyon is MIT-licensed. It references the following projects and is designed
around zslay for frame coding.

## farbenbuilds/zslay

- Repository: https://github.com/farbenbuilds/zslay
- Version: [v0.4.0](https://github.com/farbenbuilds/zslay/releases/tag/v0.4.0)
- License: MIT
- Use: runtime dependency for RFC 6455 frame header coding, length handling,
  close validation, and masking. The release archive is pinned as a source-only
  flake input, and `build.zig.zon` uses the same release URL and package hash.

zslay is a pure Zig port inspired by wslay. Its own repository retains the
wslay attribution and license details.

## denoland/fastwebsockets

- Repository: https://github.com/denoland/fastwebsockets
- Version: 0.10.0 behavioral target
- License: Apache-2.0
- Use: public API and observable behavior reference.

tachyon is an independent Zig implementation. It does not vendor or link
fastwebsockets source. Names such as `Frame`, `OpCode`, `WebSocket`,
`FragmentCollector`, `CloseCode`, and `WebSocketError` are used to keep the
porting surface recognizable. Any future copied code or test vector must retain
the Apache-2.0 notice and be recorded here.

## farbenbuilds/uWebZockets

- Repository: https://github.com/farbenbuilds/uWebZockets
- License: MIT
- Use: architecture, build, Nix, and agent-workflow reference.

No uWebZockets source is vendored or linked.

## Zig

- Repository: https://github.com/ziglang/zig
- License: MIT
- Use: compiler, standard library, and build system.

## Nix inputs

The flake pins nixpkgs, flake-parts, the mitchellh Zig overlay, and the zslay
v0.4.0 release archive. Those inputs retain their own licenses and notices.
`flake.lock` is the authoritative revision list.
