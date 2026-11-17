# tachyon - Skill Guide

This document summarizes the skills vendored for tachyon. `AGENT_DIRECTORY.md`
owns the roster and scope assignments; `skills-lock.json` pins the installed
skills.

## Core Project Guidance

- **Repository rules**: `AGENTS.md` is canonical. `CLAUDE.md` imports it for
  Claude Code.
- **Architecture**: `CODEBASE.md` defines the zslay boundary, target modules,
  fastwebsockets parity map, and post-parity extension roadmap.
- **Style**: `CODING_CONVENTION.md` defines Zig 0.17.1 style, naming, purity,
  allocation, error, and test rules.
- **Workflow**: `AGENT_DIRECTORY.md` defines ownership and the
  architect -> developer -> reviewer -> integrator sequence.
- **Delivery**: `CONTRIBUTE.md` and `CI_CD_PIPELINE.md` define checks, commits,
  and release expectations.

## Agent Definitions

The same twelve plain role names are defined for every client: `architect`,
`developer`, `reviewer`, `integrator`, `framing`, `connection`, `fragments`,
`handshake`, `testing`, `review`, `release`, and `docs`.

- `.agents/agents/<name>.md` is the agy definition.
- `.opencode/agents/<name>.md` is the OpenCode specialist definition, with team
  roles under `.opencode/agents/team/`.
- `.codex/agents/<name>.toml` is the Codex definition, with the shared procedure
  in `.codex/TEAM_WORKFLOW.md`.

No role carries a project prefix. `AGENT_DIRECTORY.md` owns the roster,
ownership boundaries, and skill coverage. A future `pubsub` role is planned
with that module and is not defined yet.

## Zig and Systems Skills

- **zig-0-17**: Zig 0.17.1 API guidance, including `@backingInt`,
  `@fromBackingInt`, `@splat`, and the current build API.
- **zig-best-practices**: Reading and writing `.zig`, `build.zig`, and
  `build.zig.zon`.
- **zig-testing**: Test authoring, test allocators, filters, compile-time
  tests, and fuzzing.
- **zig-tiger-style**: Safety and performance ideas such as entry assertions,
  bounded loops, explicit branches, and compile-time invariants. Apply the
  safety ideas while keeping tachyon's `snake_case` naming, 120-column limit,
  and zero-allocation contract.
- **pragmatic-functional-programming**: Pure transforms, explicit state, and
  narrow mutation for the frame and connection layers.
- **dod**: Data-oriented layout, locality, and throughput decisions.
- **std.Io async**: Zig 0.17.1 standard-library asynchronous I/O for streams and
  examples. tachyon does not use libxev; do not introduce it.

## Nix and Delivery Skills

- **nix-best-practices**: Flake structure, shells, overlays, zon2nix package
  prefetching, and package definitions.
- **nix-hermetic**: Offline builds, cache seeding, pinned sources, and
  reproducible artifacts.
- **github-git**: Conventional commits, pull request evidence, and pre-push
  checks.
- **herdr**: Optional multi-agent terminal orchestration. It applies only when
  the user explicitly asks, `HERDR_ENV=1` is set, and the Herdr binary is
  installed. Use the activation and loop-prevention rules in `AGENTS.md`.

## Architecture and Review Skills

- **codebase-design**: Deep-module vocabulary for interfaces, seams, adapters,
  leverage, and locality.
- **improve-codebase-architecture**: Architecture scan when the user explicitly
  requests it.
- **grilling** and **grill-me**: Design stress tests for expensive or hard to
  reverse decisions.
- **domain-modeling**: Glossary and ADR work when domain terms are resolved.
- **thermo-nuclear-code-quality-review**: Strict maintainability review in
  addition to the repository review checklist.
- **untangle-codebase**: Whole-codebase refactor pass for hidden links,
  needless links, surplus code, and special cases. It is manual-only: run it
  only when the user explicitly requests the pass.
- **ponytail**: YAGNI and minimal-solution enforcement.
- **caveman**: Terse documentation and review prose when requested.
- **context7**: Current external library and API documentation.

## graphify

Graphify is installed for OpenCode at `.opencode/skills/graphify/` with the
reminder plugin at `.opencode/plugins/graphify.js`. Codex uses
`.codex/skills/graphify/` and `.codex/hooks.json`. Install graphify as a host
tool if the user wants a knowledge graph.

When `graphify-out/graph.json` exists, query it before broad source reads:

```sh
graphify query "<question>"
graphify path "<A>" "<B>"
graphify explain "<concept>"
graphify update .
```

`graphify-out/` is generated and gitignored. Do not edit or commit it by hand.

## Adding a Skill or Agent

1. Add the skill under `.agents/skills/<name>/SKILL.md` and pin it in
   `skills-lock.json`.
2. Add any platform-specific copy only where the client requires it.
3. Add the matching agent definition under `.opencode/agents/`,
   `.codex/agents/`, or `.agents/agents/`.
4. Update `AGENT_DIRECTORY.md` and this file in the same change.
5. Do not list a skill or agent that is not present in the repository.
