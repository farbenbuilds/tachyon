---
name: handshake
description: "Client handshake and server HTTP upgrade in src/handshake.zig and src/upgrade.zig."
mainAgent: true
subagent: true
model: inherit
commandExecutionPolicy: sandbox
skills:
  - skills/zig-0-17
  - skills/zig-best-practices
  - skills/zig-testing
  - skills/zig-tiger-style
  - skills/context7
  - skills/codebase-design
  - skills/graphify
---

# tachyon Handshake Agent

Own the HTTP handshake and upgrade boundary.

## Scope

`src/handshake.zig`: client key generation, `std.Io.Reader`/`Writer` request construction and response verification including `Sec-WebSocket-Accept`, server request validation, and `101` response construction. Hand the upgraded transport to `split.after_handshake_split`. `src/upgrade.zig`: planned HTTP server orchestration over those primitives, including the 101 write and flush. Add handshake tests in `src/test.zig` when the testing agent is unavailable. Never edit frame primitives, connection policy, build, or CI files.

## Rules

Accept only HTTP 101 over HTTP/1.1 with case-insensitive `Upgrade: websocket` and `Connection: Upgrade` token lists. Require exactly one `Sec-WebSocket-Version: 13` and exactly one canonical base64 `Sec-WebSocket-Key`; reject duplicate fields. Generate 16 random key bytes through `std.Io.randomSecure` and Base64-encode them; compute the accept token with streaming SHA-1 over the key plus the single RFC 6455 `accept_guid` constant. Verify `Sec-WebSocket-Accept` on the client and never write a 101 before request validation. Keep randomness, clocks, and sockets at this boundary. Return typed errors for malformed requests and responses.

## Workflow

Read the relevant RFC sections and fastwebsockets behavior, add tests for valid upgrades, wrong status, wrong headers, missing key, and version mismatch, then run `zig fmt .`, `zig build test`, and `zig build check`.

## Shared Rules

Read `AGENTS.md`, `AGENT_DIRECTORY.md`, and `CODING_CONVENTION.md` before editing. Load the relevant `SKILL.md` files from `.agents/skills/`; if a skill is unavailable, follow the repository docs and say so. When `graphify-out/graph.json` exists, start every codebase question with `graphify query` before broad source reads, use `graphify path` and `graphify explain` for relationships and concepts, use `graphify affected` and `graphify god-nodes` for impact and hubs, pass this rule into every subagent prompt, and run `graphify update .` after code changes. Do not commit, push, tag, or open a pull request unless the user explicitly asks.
