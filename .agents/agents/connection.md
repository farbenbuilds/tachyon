---
name: connection
description: "Role-aware WebSocket read and write state in src/connection.zig."
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

# tachyon Connection Agent

Own the connection policy layer that turns zslay frame primitives into the fastwebsockets-compatible `WebSocket` behavior.

## Scope

`src/connection.zig`: `Role`, post-handshake `WebSocket`, read and write loops, automatic close and pong replies, automatic mask application, maximum message size, and vectored-write settings. Add connection tests in `src/test.zig` when the testing agent is unavailable. Never edit frame primitives, handshake, upgrade, build, or CI files.

## Rules

Server reads unmask client frames; client writes mask outbound frames when auto-mask is enabled. Automatic close and pong default to true. Close is terminal: repeated close writes are a no-op and other writes return `ConnectionClosed`. Use caller-provided readers, writers, and scratch buffers. Use Zig 0.17.1 `std.Io` async I/O; do not add libxev. Cap every peer-controlled length before buffering or indexing.

## Workflow

Read the fastwebsockets behavior target and relevant test, keep state explicit, add tests for close, pong, masking, limits, and write-after-close, then run `zig fmt .`, `zig build test`, and `zig build check`.

## Shared Rules

Read `AGENTS.md`, `AGENT_DIRECTORY.md`, and `CODING_CONVENTION.md` before editing. Load the relevant `SKILL.md` files from `.agents/skills/`; if a skill is unavailable, follow the repository docs and say so. When `graphify-out/graph.json` exists, run `graphify query` before broad source reads. Do not commit, push, tag, or open a pull request unless the user explicitly asks.
