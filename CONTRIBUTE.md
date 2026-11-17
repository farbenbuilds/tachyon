# tachyon - Contributing Guide

How to set up, develop, test, commit, and release tachyon. For architecture see
[CODEBASE.md](CODEBASE.md); for style see
[CODING_CONVENTION.md](CODING_CONVENTION.md).

## Repository Scope

This change contains the environment, documentation, agent rules, and skill
pack. It does not contain Zig sources or a build graph. The library commands
below describe the project workflow; environment and documentation changes use
the flake, formatting, and hygiene checks.

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

The zslay release URL, package hash, flake input, generated `build.zig.zon.nix`,
and cache seed must stay aligned as described in [AGENTS.md](AGENTS.md).

## Testing

Tests use the built-in Zig test runner and live in `src/test.zig`. The test step
runs the suite twice, once with Debug safety and once with ReleaseSafe, so
overflow and bounds behavior in release mode is exercised before review.

There is no numeric coverage target. Changed behavior needs a focused test,
including malformed input and length boundaries. The connection layer adds
Autobahn and fuzz suites; do not claim compliance before those suites pass.

## Pre-commit Hooks

The Nix shell provides `pre-commit`.

```sh
pre-commit install
pre-commit run --all-files
```

The hooks run `zig fmt`, trailing-whitespace checks, end-of-file-fixer, YAML
validation, large-file checks, and merge-conflict detection. Add the
`zig-build-test` hook when the build graph lands.

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

Keep one scope per pull request. A pull request that changes the zslay pin, the
flake seed, and the lock file is one coherent build-scope change. Do not mix it
with unrelated protocol work.

## Pull Request Checklist

Before opening a pull request:

- [ ] `nix flake check` for flake or environment changes
- [ ] `zig fmt --check .`
- [ ] `pre-commit run --all-files`
- [ ] `zig build check` for code changes
- [ ] `zig build test --summary all` for code changes
- [ ] documentation links and code fences checked for documentation changes
- [ ] zslay release URL, hash, flake input, generated zon2nix file, and archive
  seed agree
- [ ] no generated output, payload dumps, or secrets committed
- [ ] changelog updated for user-visible behavior

Describe what changed, why, the change type, linked issues, and the exact
verification commands with results. Screenshots are only useful for visual
documentation or branding changes.

## AI Agent Workflow

The canonical rules are in [AGENTS.md](AGENTS.md); the roster is in
[AGENT_DIRECTORY.md](AGENT_DIRECTORY.md). Shared skills live in
`.agents/skills/` and are pinned by `skills-lock.json`. Graphify is installed
for OpenCode under `.opencode/skills/graphify/` with its plugin at
`.opencode/plugins/graphify.js`, and for Codex under `.codex/skills/graphify/`
with its hook at `.codex/hooks.json`.

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

- zslay is the only framing dependency.
- Use Zig 0.17.1 `std.Io` asynchronous I/O for transport. Do not add libxev or
  another event-loop dependency.
- Pin a published release archive and its package hash. Do not pin a branch or a
  mutable URL.
- Update the flake input, `build.zig.zon`, generated `build.zig.zon.nix`, cache
  seed, lock file, and documentation in one pull request.
- Never edit `zig-pkg/` or the Nix store directly.
- If zslay changes its package name, version, archive hash, or published paths,
  regenerate the hash with `zig fetch` from the release URL, run `zon2nix
  build.zig.zon > build.zig.zon.nix`, and update every reference together.
