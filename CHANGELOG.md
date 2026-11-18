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
- `nix flake check` now runs the Debug and ReleaseSafe suites natively and in
  the musl shell using the zon2nix-prefetched packages, and `nix build`
  produces `libtachyon.a`.
- Dependency metadata now lives in `build.zig.zon`; the flake no longer pins
  zslay directly, and the zon2nix pre-commit hook generates the Nix, JSON, and
  text views.
- Documentation no longer repeats the zslay version.
