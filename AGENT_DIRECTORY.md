# tachyon - Agent Directory

Ownership map and review workflow for coding agents. `AGENTS.md` is the
canonical rule set; this document assigns scopes and describes handoffs.

Shared skills are vendored under `.agents/skills/` and pinned by
`skills-lock.json`. Graphify has platform copies under `.opencode/skills/` and
`.codex/skills/`. Platform-specific specialist agent definitions are not present
in this change; do not reference an agent definition that is not in the
repository.

| Path | Purpose |
| --- | --- |
| `.agents/skills/<name>/SKILL.md` | Shared project skills, pinned in `skills-lock.json`. |
| `.opencode/skills/graphify/` | Graphify skill for OpenCode. |
| `.opencode/plugins/graphify.js` | OpenCode graph reminder plugin. |
| `.codex/skills/graphify/` | Graphify skill for Codex. |
| `.codex/hooks.json` | Codex graphify hook. |
| `.codex/config.toml` | Codex multi-agent configuration. |
| `.opencode/agents/<name>.md` | OpenCode sub-agent definitions, when present. |
| `.opencode/agents/team/` | OpenCode team roles, when present. |
| `.codex/agents/<name>.toml` | Codex project agents, when present. |
| `.agents/agents/<name>.md` | agy custom agents, when present. |
| `AGENTS.md`, `CLAUDE.md` | Canonical agent rules and the Claude Code entry point. |
| `SKILL.md` | Human-readable skill summary. |

## Roster

| Agent | Area | Owned paths | Status |
| --- | --- | --- | --- |
| `framing` | Frame codec bridge, close codes, masking, errors | `src/frame.zig`, `src/close.zig`, `src/mask.zig`, `src/error.zig` | Planned |
| `connection` | Connection state, control replies, limits | `src/connection.zig` | Planned |
| `fragments` | Message collection and split reads | `src/fragment.zig`, `src/split.zig` | Planned |
| `handshake` | Client handshake and server upgrade | `src/handshake.zig`, `src/upgrade.zig` | Planned |
| `testing` | Unit, Autobahn, fuzz, and echo coverage | `src/test.zig`, `tests/`, `fuzz/` | Planned |
| `review` | Read-only review | any changed file | Active by process |
| `release` | Build, Nix, packaging, CI | `build.zig`, `build.zig.zon`, `flake.nix`, `.github/workflows/` | Planned |
| `docs` | Root documentation and agent guides | root `*.md`, `.github/*.md`, `.github/ISSUE_TEMPLATE/` | Active by process |
| `architect` | Read-only planning and routing | affected paths | Active by process |
| `developer` | Implementation coordination | specialist-owned paths | Active by process |
| `reviewer` | Read-only quality gate | any changed file | Active by process |
| `integrator` | Findings, final diff, verification | affected paths through owners | Active by process |

OpenCode and agy use the plain hyphenated names where needed; Codex uses the
matching underscore name only when a definition requires it. The role names
themselves never carry a project prefix.

## Current Change Ownership

This change owns the combined documentation, flake, `.envrc`, `.github`
metadata, and skill pack. No implementation specialist is needed for it. The
architect, developer, reviewer, and integrator roles are filled by the root agent
and an independent read-only review pass.

Documentation work may combine architect and developer phases. It still needs a
reviewer pass for link accuracy, scope, and consistency with the target
architecture.

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
| `zig-0-17` | framing, connection, fragments, handshake, testing, review, release, architect, developer, reviewer, integrator |
| `zig-best-practices` | framing, connection, fragments, handshake, testing, review |
| `zig-testing` | testing, review |
| `zig-tiger-style` | framing, connection, fragments, handshake, testing, review, architect, developer, reviewer, integrator |
| `pragmatic-functional-programming` | framing, connection, review, architect, reviewer |
| `dod` | framing, connection, fragments, testing |
| `codebase-design` | review, architect, developer, reviewer, integrator |
| `improve-codebase-architecture` | architect |
| `grilling`, `grill-me` | architect |
| `domain-modeling` | docs, architect |
| `thermo-nuclear-code-quality-review` | review, reviewer |
| `untangle-codebase` | review, architect, integrator (manual-only pass) |
| `ponytail` | review, release, docs, architect, reviewer, integrator |
| `caveman` | docs |
| `context7` | handshake, docs |
| `github-git` | review, release, docs, reviewer, integrator |
| `nix-best-practices` | release, docs |
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
