# Third-Party Notices

tachyon is MIT-licensed. It references the following projects and is designed
around zslay for framing and wire-state validation.

## farbenbuilds/zslay

- Repository: https://github.com/farbenbuilds/zslay
- License: MIT
- Use: runtime dependency for RFC 6455 frame header coding, length handling,
  the close predicate and payload validation, masking, masking direction,
  fragment ordering, limits, and the bounded connection state machine. The
  dependency is declared in `build.zig.zon` and locked by the generated zon2nix
  views.

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
- Use: compiler, standard library (including `std.Io` and
  `std.compress.flate`), and build system.

## Agent skill pack

The shared skill files under `.agents/skills/` are vendored from the sources
recorded in `skills-lock.json`, including `zigcc/skills`,
`full-stack-skills/zig-skills`, `mattpocock/skills`, `caldoai/skills`, and the
other entries in that lock file. Each skill retains its upstream license and
attribution. Graphify copies under `.opencode/skills/graphify/` and
`.codex/skills/graphify/` are version-stamped `0.9.92`.

The Code of Conduct is adapted from Contributor Covenant 2.1. The commit
convention is adapted from the Angular commit convention.

## Nix inputs

The flake pins nixpkgs, flake-parts, the mitchellh Zig overlay, and zon2nix.
Those inputs retain their own licenses and notices. `flake.lock` is the
authoritative revision list; Zig package dependencies are locked separately by
`build.zig.zon` and the generated zon2nix views.
