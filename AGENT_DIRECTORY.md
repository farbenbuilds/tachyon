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
| `.claude/agents/<name>.md` | Claude Code project subagents. |
| `.codex/TEAM_WORKFLOW.md` | Codex team procedure and handoff contract. |
| `.agents/skills/<name>/SKILL.md` | Shared project skills pinned in `skills-lock.json`, plus the Antigravity graphify copy. |
| `.opencode/skills/graphify/` | Graphify skill for OpenCode. |
| `.opencode/plugins/graphify.js` | OpenCode graph reminder plugin. |
| `.codex/skills/graphify/` | Graphify skill for Codex. |
| `.codex/hooks.json` | Codex graphify hook. |
| `.codex/config.toml` | Codex multi-agent configuration. |
| `.claude/skills/graphify/` | Graphify skill for Claude Code. |
| `.claude/settings.json` | Claude Code graphify PreToolUse hooks. |
| `.claude/CLAUDE.md` | Claude Code project skill registration. |
| `.agents/skills/graphify/` | Graphify skill for Google Antigravity. |
| `.agents/rules/graphify.md` | Antigravity always-on graphify rule. |
| `.agents/workflows/graphify.md` | Antigravity graphify workflow. |
| `scripts/install_graphify_integrations.sh` | Refresh all four project-scoped integrations. |
| `scripts/check_graphify_integrations.sh` | Verify integration files and version parity. |
| `AGENTS.md`, `CLAUDE.md` | Canonical agent rules and the Claude Code entry point. |
| `SKILL.md` | Human-readable skill summary. |

The names are the same in every client: `architect`, `developer`, `reviewer`,
`integrator`, `framing`, `connection`, `fragments`, `handshake`, `testing`,
`review`, `release`, and `docs`. They never carry a project prefix.

Claude Code reads `.claude/agents/<name>.md` automatically. The `architect`,
`review`, and `reviewer` roles restrict `tools` to `Read`, `Grep`, `Glob`, and
`Bash`; every definition uses `model: inherit` and preloads the project
`graphify` skill.

## Roster

| Agent | Area | Owned paths |
| --- | --- | --- |
| `framing` | Frame facade, close-code aliases, masking delegation, errors, incremental UTF-8 | `src/frame.zig`, `src/error.zig`, `src/utf8.zig` |
| `connection` | Connection policy over `zslay.Conn`, control replies, limits, backpressure policy, and the native `std.Io.net.Stream` adapter | `src/connection.zig`, `src/backpressure.zig`, `src/native_stream.zig` |
| `fragments` | Message buffering and shared UTF-8 streaming in `src/fragment.zig`; split read/write halves in `src/split.zig` | `src/fragment.zig`, `src/split.zig` |
| `handshake` | Client handshake and server upgrade | `src/handshake.zig`, `src/upgrade.zig` |
| `testing` | Unit and integration coverage, plus future Autobahn, fuzz, and loopback suites | `tests/**` |
| `review` | Read-only review | any changed file |
| `release` | Build, Nix, packaging, dependency generation, CI | `build.zig`, `build.zig.zon`, `flake.nix`, `flake.lock`, `scripts/update_zon_files.sh`, `.pre-commit-config.yaml`, `.github/workflows/` |
| `docs` | Human and agent documentation | root `*.md`, `.github/*.md`, `.github/ISSUE_TEMPLATE/`, `.codex/TEAM_WORKFLOW.md` |
| `architect` | Read-only planning and routing | affected paths |
| `developer` | Implementation coordination | specialist-owned paths |
| `reviewer` | Read-only quality gate | any changed file |
| `integrator` | Findings, final diff, verification | affected paths through owners |

`src/connection.zig` is a current file owned by the `connection` agent.
`src/native_stream.zig` and `src/backpressure.zig` have also landed under the
`connection` owner.
`src/handshake.zig` and `src/upgrade.zig` are current files owned by the
`handshake` agent. The upgrade module owns the RFC 6455 accept GUID,
accept-token derivation, and server call order, while `src/handshake.zig`
re-exports those names for client callers and keeps the server request and
response primitives. Tests live in `tests/` category folders aggregated by
`tests/main.zig` and belong to the `testing` agent; work that needs new coverage
hands the test change to `testing` instead of editing the test tree in the same
pass.

## Planned Extension Ownership

These modules are roadmap items, not current files. Existing agent definitions
remain scoped to current files; expand the owner and matching definition before
implementation. `src/utf8.zig` has landed under the `framing` owner,
`src/connection.zig`, `src/backpressure.zig`, and `src/native_stream.zig` under
`connection`, and `src/fragment.zig` and `src/split.zig` under `fragments`, so
those are current files rather than roadmap items.

| Module | Planned owner | Dependency |
| --- | --- | --- |
| `src/stream.zig` | `fragments` | connection, UTF-8, backpressure |
| `src/deflate.zig` | `connection`; `handshake` owns negotiation | zslay negotiated RSV1, `std.compress.flate`, stream |
| `src/pubsub.zig` | new `pubsub` specialist when the module starts | stream, backpressure |

A new `pubsub` definition must be added to `.agents/agents/`, `.opencode/agents/`,
`.codex/agents/`, and `.claude/agents/`, plus the roster and `SKILL.md`, before
`src/pubsub.zig` is created.

## Agent Tooling Change Ownership

This historical agent-tooling change owns `.agents/agents/`, `.opencode/agents/`,
`.codex/agents/`, `.claude/agents/`, `.codex/TEAM_WORKFLOW.md`, the OpenCode,
Codex, Claude Code, and Antigravity graphify integration files,
`scripts/install_graphify_integrations.sh`,
`scripts/check_graphify_integrations.sh`, `.pre-commit-config.yaml`,
`.gitattributes`, and the root guides. The roots stay aligned with the zslay
boundary and extension roadmap in `CODEBASE.md`. An independent read-only
review pass checks links, scope, and consistency with the target architecture.

The UTF-8 extension change owns `src/utf8.zig`, `src/frame.zig`, `src/root.zig`,
the `tests/utf8-test/` and `tests/frame-test/` suites, the root guides,
`CHANGELOG.md`, and the framing and fragments definitions.

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

Graphify is installed for OpenCode, Codex, Claude Code, and Google Antigravity
under their platform skill and instruction surfaces. OpenCode loads the plugin,
Codex and Claude Code run their hook entries, and Antigravity reads the
always-on rule and workflow. Every agent definition loads `graphify` and must
pass the graph-first rule into subagent prompts. Refresh with
`scripts/install_graphify_integrations.sh` and verify with
`scripts/check_graphify_integrations.sh`.

## graphify

When `graphify-out/graph.json` exists, codebase questions start with
`graphify query "<question>"` before broad grep or source reads. Use
`graphify path` and `graphify explain` for relationships and concepts, and
`graphify affected` and `graphify god-nodes` for impact and hubs. Every
architect, developer, reviewer, and integrator handoff carries that rule.
Refresh with `graphify update .` after code changes. `graphify-out/` is
generated and gitignored.
