# tachyon - Contributing Guide

Start with [README.md](README.md) for the feature summary and quick start. This
guide covers setup, checks, commits, and the manual release. For architecture see
[CODEBASE.md](CODEBASE.md); for style see
[CODING_CONVENTION.md](CODING_CONVENTION.md).

## Repository Scope

The repository contains the Zig package, tests, Nix environment, documentation,
agent rules, skill pack, examples, and benchmarks. `build.zig` defines the public
module, static library, tests, `check`, and repository-only `autobahn-server`,
`examples`, and `benches` steps. See [CODEBASE.md#target-source-layout](CODEBASE.md#target-source-layout) and [AGENT_DIRECTORY.md](AGENT_DIRECTORY.md) for modules and ownership.

## Local Setup

tachyon uses Nix for a reproducible Zig 0.17.1 environment. Do not install a
different Zig version globally for project work. Nix with flakes is required;
direnv is optional but recommended.

```sh
git clone https://github.com/farbenbuilds/tachyon.git
cd tachyon
direnv allow          # or run nix develop once per shell
zig version           # must print 0.17.1
```

The `.envrc` selects the musl shell on musl hosts and the default shell
elsewhere; the default includes Zig, zls, pre-commit, ripgrep, and zon2nix.

## Environment Commands

```sh
nix develop                 # enter the Zig 0.17.1 shell
nix flake check             # Nix formatting and test checks
zig fmt --check .           # formatting gate
pre-commit run --all-files  # formatting and hygiene hooks
```

## Library Commands

```sh
zig build                   # static library at zig-out/lib/libtachyon.a
zig build test              # Debug and ReleaseSafe suites over tests/main.zig
zig build check             # type-check library and tests
zig build autobahn-server -Doptimize=ReleaseSafe
zig build examples          # echo servers and client
zig build benches -Doptimize=ReleaseSafe
zig fmt .                   # apply formatting
```

`examples` and `benches` require a full checkout; see `examples/README.md` and `benches/README.md` for setup and the Node runner.

The zslay dependency lives in `build.zig.zon`. The `zon2nix` pre-commit hook
regenerates `build.zig.zon.nix`, `build.zig.zon.json`, and `build.zig.zon.txt`
from it; see [AGENTS.md](AGENTS.md).

## Testing

Tests use the built-in Zig test runner. `tests/main.zig` aggregates every
category file under `tests/` for Debug and ReleaseSafe; `tests/support.zig`
holds shared fixtures. See [tests/README.md](tests/README.md) for categories
and naming.

Changed behavior needs a focused test, including malformed input and length
boundaries, and both Debug and ReleaseSafe must pass. See
[AGENTS.md#testing-guidelines](AGENTS.md#testing-guidelines) for the full rule
set. The Autobahn gate covers cases 1-7 and 9-13; group 8 is absent from the
pinned testsuite and the action's default list omits it, so every shipped case
is covered. Compression cases 11-13 are enabled through the fixture. Fuzz and
full loopback suites remain planned. A green run is evidence only for the
configured case set, not full compliance.

## Pre-commit Hooks

The Nix shell provides `pre-commit`.

```sh
pre-commit install
pre-commit run --all-files
```

The hooks run `zig fmt`, `zig build test`, trailing-whitespace, EOF, YAML,
large-file, and merge-conflict checks, plus `zon2nix` regeneration when
`build.zig.zon` changes.

## Branch and Commit Convention

Use conventional commits:

```text
<type>(<scope>): <imperative subject>
```

Types: `feat`, `fix`, `perf`, `build`, `ci`, `docs`, `style`, `refactor`,
`test`. Use an imperative, lowercase subject with no trailing period. Keep one
scope per pull request, including dependency bumps and generated views.

## Pull Request Checklist

Before opening a pull request:

- [ ] `nix flake check` for flake or environment changes
- [ ] `zig fmt --check .`
- [ ] `pre-commit run --all-files`
- [ ] `zig build check` for code changes
- [ ] `zig build test --summary all` for code changes
- [ ] documentation links and code fences checked for documentation changes
- [ ] `build.zig.zon` and the generated zon2nix views agree
- [ ] no generated output, payload dumps, or secrets committed
- [ ] changelog updated for user-visible behavior

Describe what changed, why, the change type, linked issues, and verification
commands with results. Screenshots are only for visual documentation changes.

## AI Agent Workflow

The canonical rules are in [AGENTS.md](AGENTS.md); the roster is in
[AGENT_DIRECTORY.md](AGENT_DIRECTORY.md). Matching definitions live in
`.agents/agents/`, `.opencode/agents/`, `.codex/agents/`, and `.claude/agents/`;
Codex also reads `.codex/TEAM_WORKFLOW.md`. Shared skills live in
`.agents/skills/` and are pinned by `skills-lock.json`. Refresh and verify the
graphify integrations with `sh scripts/install_graphify_integrations.sh` and
`sh scripts/check_graphify_integrations.sh`.

For multi-part work, follow the architect -> developer -> reviewer -> integrator
sequence. The reviewer is read-only; the integrator verifies the combined diff
and routes findings back to the owner. No agent commits, pushes, tags, or opens
a pull request unless the user explicitly asked.

## Release Process

Releases use semantic versioning and an annotated `v*` tag. The tag,
`build.zig.zon` `.version`, `flake.nix` version, and changelog section agree.

1. Land the release changes on `main` and confirm a clean tree.
2. Set the same semantic version in `build.zig.zon` and `flake.nix`.
3. Move `Unreleased` entries into a dated changelog section and leave
   `Unreleased` empty.
4. Run the full checks.
5. The maintainer creates and pushes the annotated tag.
6. The maintainer creates the GitHub release manually from the changelog notes.
   No artifacts are built or uploaded, and there is no publish workflow.

The published package is runtime-only: `.paths` ships the build files, generated views, `flake.nix`, `flake.lock`, `src/`, `LICENSE`, and `README.md`.

## Dependency Policy

- zslay is the only framing dependency. Do not duplicate its header, close,
  masking, fragment-order, limit, or connection-state logic in tachyon.
- Use Zig 0.17.1 `std.Io` asynchronous I/O for transport. Do not add libxev or
  another event-loop dependency.
- Use `std.compress.flate` for RFC 7692 permessage-deflate; do not add zlib,
  miniz, or another compression package. Negotiated RSV1 and the codec are
  implemented, and compression remains edge-composed.
- Declare the dependency in `build.zig.zon`; do not duplicate its version or
  package hash in `flake.nix` or the documentation.
- Regenerate `build.zig.zon.nix`, `build.zig.zon.json`, and `build.zig.zon.txt`
  with the `zon2nix` pre-commit hook whenever `build.zig.zon` changes.
- Never edit `zig-pkg/` or the Nix store directly.
