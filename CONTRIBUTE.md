# tachyon - Contributing Guide

How to set up, develop, test, commit, and release tachyon. For architecture see
[CODEBASE.md](CODEBASE.md); for style see
[CODING_CONVENTION.md](CODING_CONVENTION.md).

## Repository Scope

The repository currently contains the environment, documentation, agent
rules, skill pack, and Zig package bootstrap. `build.zig` defines the public
module, static library, test, and check steps; `src/root.zig` exposes the
pinned zslay codec. Frame and connection modules are not implemented yet. The
library commands below describe the project workflow and work against the
current bootstrap.

## Local Setup

tachyon uses Nix for a reproducible Zig 0.17.1 environment. Do not install a
different Zig version globally for project work.

Prerequisites:

- Nix with flakes enabled.
- direnv, optional but recommended.

```sh
git clone https://github.com/farbenbuilds/tachyon.git
cd tachyon
direnv allow          # or run nix develop once per shell
zig version           # must print 0.17.1
```

The `.envrc` selects the musl shell automatically on musl hosts and the default
shell everywhere else, matching the zslay and uWebZockets setup. The default
shell includes Zig, zls, pre-commit, ripgrep, and zon2nix.

## Environment Commands

```sh
nix develop                 # enter the Zig 0.17.1 shell
nix flake check             # Nix formatting check
zig fmt --check .           # formatting gate
pre-commit run --all-files  # formatting and hygiene hooks
```

## Library Commands

```sh
zig build                   # static library at zig-out/lib/libtachyon.a
zig build test              # Debug and ReleaseSafe suites
zig build check             # type-check library and tests
zig fmt .                   # apply formatting
```

The zslay dependency lives in `build.zig.zon`. The `zon2nix` pre-commit hook
regenerates `build.zig.zon.nix`, `build.zig.zon.json`, and `build.zig.zon.txt`
from it; see [AGENTS.md](AGENTS.md).

## Testing

Tests use the built-in Zig test runner. The bootstrap dependency test lives in
`src/root.zig`; protocol tests will live in `src/test.zig`. The test step runs
the suite twice, once with Debug safety and once with ReleaseSafe, so overflow
and bounds behavior in release mode is exercised before review.

There is no numeric coverage target. Changed behavior needs a focused test,
including malformed input and length boundaries. The connection layer adds
Autobahn and fuzz suites; do not claim compliance before those suites pass.

## Pre-commit Hooks

The Nix shell provides `pre-commit`.

```sh
pre-commit install
pre-commit run --all-files
```

The hooks run `zig fmt`, `zig build test`, trailing-whitespace checks,
end-of-file-fixer, YAML validation, large-file checks, and merge-conflict
detection. The `zon2nix` hook regenerates `build.zig.zon.nix`,
`build.zig.zon.json`, and `build.zig.zon.txt` whenever `build.zig.zon` changes.

## Branch and Commit Convention

Use conventional commits:

```text
<type>(<scope>): <imperative subject>
```

Types: `feat`, `fix`, `perf`, `build`, `ci`, `docs`, `style`, `refactor`,
`test`. Use an imperative subject, lowercase first letter, and no trailing
period.

Examples:

```text
chore(repo): add nix flake and contributor guides
feat(connection): add automatic pong replies
fix(frame): reject fragmented control frames
```

Keep one scope per pull request. A pull request that changes the zslay
dependency, the generated zon2nix views, and the lock file is one coherent
build-scope change. Do not mix it with unrelated protocol work.

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

Describe what changed, why, the change type, linked issues, and the exact
verification commands with results. Screenshots are only useful for visual
documentation or branding changes.

## AI Agent Workflow

The canonical rules are in [AGENTS.md](AGENTS.md); the roster is in
[AGENT_DIRECTORY.md](AGENT_DIRECTORY.md). Matching definitions live in
`.agents/agents/`, `.opencode/agents/`, `.codex/agents/`, and `.claude/agents/`;
Codex also reads `.codex/TEAM_WORKFLOW.md`. Shared skills live in `.agents/skills/`
and are pinned by `skills-lock.json`. Graphify is installed for OpenCode, Codex,
Claude Code, and Google Antigravity. Refresh the checked-in skills, plugins, hooks,
rules, and workflows with `sh scripts/install_graphify_integrations.sh`, then
verify them with `sh scripts/check_graphify_integrations.sh`. Every agent
definition loads `graphify` and passes the graph-first rule into subagent
prompts.

For multi-part work, follow the architect -> developer -> reviewer -> integrator
sequence. The reviewer is read-only. The integrator verifies the combined diff
and routes findings back to the owner. No agent commits, pushes, tags, or opens
a pull request unless the user explicitly asked.

## Release Process

Releases use semantic versioning and a `v*` tag. The version in
`build.zig.zon`, the matching `CHANGELOG.md` section, and the tag must agree.

1. Land the implementation and documentation for the release on `main`.
2. Bump `.version` in `build.zig.zon`.
3. Move the `Unreleased` changelog entries into a dated `## [x.y.z]` section.
4. Run the full checks.
5. Tag the release commit and push the tag.

The release pipeline is specified in [CI_CD_PIPELINE.md](CI_CD_PIPELINE.md).
Actions workflows are not included in this change. Until they exist, attach the
`libtachyon.a` artifacts produced by the build to the GitHub release manually.

## Dependency Policy

- zslay is the only framing dependency. Do not duplicate its header, close,
  masking, fragment-order, limit, or connection-state logic in tachyon.
- Use Zig 0.17.1 `std.Io` asynchronous I/O for transport. Do not add libxev or
  another event-loop dependency.
- Use `std.compress.flate` for RFC 7692 permessage-deflate; do not add zlib,
  miniz, or another compression package. zslay must gain negotiated RSV1
  support before tachyon advertises the extension.
- Declare the dependency in `build.zig.zon`; do not duplicate its version or
  package hash in `flake.nix` or the documentation.
- Regenerate `build.zig.zon.nix`, `build.zig.zon.json`, and `build.zig.zon.txt`
  with the `zon2nix` pre-commit hook whenever `build.zig.zon` changes.
- Never edit `zig-pkg/` or the Nix store directly.
