# tachyon - Agent Directory

Ownership map and review workflow for coding agents. `AGENTS.md` is the
canonical rule set; this document assigns scopes and describes handoffs.

Matching definitions exist for every role:

| Path | Purpose |
| --- | --- |
| `.agents/agents/<name>.md` | agy agent definitions. |
| `.opencode/agents/<name>.md` | OpenCode specialist definitions. |
| `.opencode/agents/team/<name>.md` | OpenCode architect, developer, reviewer, and integrator roles. |
| `.codex/agents/<name>.toml` | Codex project agents. |
| `.codex/TEAM_WORKFLOW.md` | Codex team procedure and handoff contract. |
| `.agents/skills/<name>/SKILL.md` | Shared project skills, pinned in `skills-lock.json`. |
| `.opencode/skills/graphify/` | Graphify skill for OpenCode. |
| `.opencode/plugins/graphify.js` | OpenCode graph reminder plugin. |
| `.codex/skills/graphify/` | Graphify skill for Codex. |
| `.codex/hooks.json` | Codex graphify hook. |
| `.codex/config.toml` | Codex multi-agent configuration. |
| `AGENTS.md`, `CLAUDE.md` | Canonical agent rules and the Claude Code entry point. |
| `SKILL.md` | Human-readable skill summary. |

The names are the same in every client: `architect`, `developer`, `reviewer`,
`integrator`, `framing`, `connection`, `fragments`, `handshake`, `testing`,
`review`, `release`, and `docs`. They never carry a project prefix.

## Roster

| Agent | Area | Owned paths |
| --- | --- | --- |
| `framing` | Frame facade, close-code aliases, masking delegation, errors | `src/frame.zig`, `src/error.zig` |
| `connection` | Connection policy over `zslay.Conn`, control replies, limits | `src/connection.zig` |
| `fragments` | Message buffering, UTF-8 streaming, split reads | `src/fragment.zig`, `src/split.zig` |
| `handshake` | Client handshake and server upgrade | `src/handshake.zig`, `src/upgrade.zig` |
| `testing` | Unit, Autobahn, fuzz, and echo coverage | `src/test.zig`, `tests/`, `fuzz/` |
| `review` | Read-only review | any changed file |
| `release` | Build, Nix, packaging, dependency generation, CI | `build.zig`, `build.zig.zon`, `flake.nix`, `flake.lock`, `scripts/update_zon_files.sh`, `.pre-commit-config.yaml`, `.github/workflows/` |
| `docs` | Human and agent documentation | root `*.md`, `.github/*.md`, `.github/ISSUE_TEMPLATE/`, `.codex/TEAM_WORKFLOW.md` |
| `architect` | Read-only planning and routing | affected paths |
| `developer` | Implementation coordination | specialist-owned paths |
| `reviewer` | Read-only quality gate | any changed file |
| `integrator` | Findings, final diff, verification | affected paths through owners |

## Planned Extension Ownership

These modules are roadmap items, not current files. Existing agent definitions
remain scoped to current files; expand the owner and matching definition before
implementation.

| Module | Planned owner | Dependency |
| --- | --- | --- |
| `src/utf8.zig` | `framing` | `std.unicode` for contiguous slices |
| `src/backpressure.zig` | `connection` | `zslay.Queue` and connection state |
| `src/native_stream.zig` | `connection` | Zig 0.17.1 `std.Io.Reader`/`Writer` |
| `src/stream.zig` | `fragments` | connection, UTF-8, backpressure |
| `src/deflate.zig` | `connection`; `handshake` owns negotiation | zslay negotiated RSV1, `std.compress.flate`, stream |
| `src/pubsub.zig` | new `pubsub` specialist when the module starts | stream, backpressure |

A new `pubsub` definition must be added to `.agents/agents/`, `.opencode/agents/`,
and `.codex/agents/`, plus the roster and `SKILL.md`, before `src/pubsub.zig` is
created.

## Current Change Ownership

This documentation change owns `CODEBASE.md`, `AGENTS.md`,
`AGENT_DIRECTORY.md`, `README.md`, `CHANGELOG.md`, `CODING_CONVENTION.md`,
`CONTRIBUTE.md`, `SECURITY.md`, `THIRD_PARTY_NOTICES.md`, `SKILL.md`, and the
matching framing, connection, and fragments agent definitions. The roots stay
aligned with the zslay boundary and extension roadmap in `CODEBASE.md`. An
independent read-only review pass checks links, scope, and consistency with the
target architecture.

## Delivery Rules

1. Follow architect -> developer -> reviewer -> integrator for multi-part work.
2. Keep one owner per pull request scope and one writer per file.
3. The architect is read-only and produces scope, owners, acceptance criteria,
   risks, and checks.
4. The developer reports changed files, behavior covered, commands actually run,
   and unresolved risks. Never claim an unrun check passed.
5. The reviewer is read-only and reports severity-ranked findings with file and
   line references.
6. The integrator routes findings to owners, re-reviews changed areas, and
   verifies the final combined diff.
7. Cross-scope changes are handed to the owning agent instead of edited in the
   same pass.
8. No agent commits, pushes, tags, or opens a pull request unless the user
   explicitly asked.

## Required Checks

Documentation and environment changes:

```sh
nix flake check
pre-commit run --all-files
```

Implementation changes also require:

```sh
zig fmt --check .
zig build check
zig build test --summary all
```

## Skill Coverage

| Skill | Loaded by |
| --- | --- |
| `zig-0-17` | framing, connection, fragments, handshake, testing, release, review, architect, developer, reviewer, integrator |
| `zig-best-practices` | framing, connection, fragments, handshake, testing, review |
| `zig-testing` | framing, connection, fragments, handshake, testing |
| `zig-tiger-style` | framing, connection, fragments, handshake, testing, review, architect, reviewer, integrator |
| `pragmatic-functional-programming` | framing, connection, review, architect, reviewer |
| `dod` | framing, connection, fragments, testing |
| `codebase-design` | connection, fragments, handshake, review, architect, developer, reviewer, integrator |
| `improve-codebase-architecture` | architect |
| `grilling`, `grill-me` | architect |
| `domain-modeling` | docs, architect |
| `thermo-nuclear-code-quality-review` | review, reviewer |
| `untangle-codebase` | review, architect, developer, reviewer, integrator (manual-only pass) |
| `ponytail` | review, release, docs, architect, developer, reviewer, integrator |
| `caveman` | docs |
| `context7` | handshake, docs |
| `github-git` | review, release, docs, developer, reviewer, integrator |
| `nix-best-practices` | release |
| `nix-hermetic` | release |
| `herdr` | architect, developer, integrator |
| `graphify` | every code-exploration role |

Graphify is installed for OpenCode and Codex under their platform skill folders.
agy runs the `graphify` CLI directly.

## graphify

When `graphify-out/graph.json` exists, codebase questions start with
`graphify query "<question>"` before broad grep or source reads. Use
`graphify path` and `graphify explain` for relationships and concepts. Refresh
with `graphify update .` after code changes. `graphify-out/` is generated and
gitignored.
