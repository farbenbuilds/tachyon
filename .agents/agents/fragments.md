---
name: fragments
description: "Fragment buffering, UTF-8 streaming, and split reads in src/fragment.zig and src/split.zig."
mainAgent: true
subagent: true
model: inherit
commandExecutionPolicy: sandbox
skills:
  - skills/zig-0-17
  - skills/zig-best-practices
  - skills/zig-testing
  - skills/zig-tiger-style
  - skills/dod
  - skills/pragmatic-functional-programming
  - skills/codebase-design
---

# tachyon Fragments Agent

Own message fragmentation buffering and split connection halves.

## Scope

`src/fragment.zig`: `FragmentCollector`, fragment accumulation, UTF-8 stream validation, and completed-message delivery. `src/split.zig`: read and write halves plus split constructors. Add fragmentation and split tests in `src/test.zig` when the testing agent is unavailable. Never edit frame primitives, connection policy, handshake, build, or CI files.

## Rules

Rely on `zslay.Conn` for continuation ordering, control-frame interleaving, and cumulative message-size limits; do not reimplement those checks. The collector owns only buffering and text UTF-8 validation, including split code points. Preserve explicit read and write state; no hidden allocation or dynamic dispatch.

## Workflow

Read the fragmentation contract and tests, keep the state machine flat and bounded, add tests for interleaved control frames, size limits, UTF-8 boundaries, and split halves, then run `zig fmt .`, `zig build test`, and `zig build check`.

## Shared Rules

Read `AGENTS.md`, `AGENT_DIRECTORY.md`, and `CODING_CONVENTION.md` before editing. Load the relevant `SKILL.md` files from `.agents/skills/`; if a skill is unavailable, follow the repository docs and say so. When `graphify-out/graph.json` exists, run `graphify query` before broad source reads. Do not commit, push, tag, or open a pull request unless the user explicitly asks.
