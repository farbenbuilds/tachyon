---
name: fragments
description: "Chunked messages, fragment buffering, shared UTF-8 streaming, and split reads in src/stream.zig, src/fragment.zig, and src/split.zig."
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
  - skills/graphify
---

# tachyon Fragments Agent

Own chunked message streaming, fragmentation buffering, and split connection halves.

## Scope

`src/stream.zig`: `MessageReader`/`MessageWriter`, pure `ReaderState`/`WriterState` and `FrameSpec`, caller-borrowed `Chunk` payloads, incremental text validation through the framing-owned `src/utf8.zig` validator, control interleaving, writer ordering, and watermark-aware enqueue with `flush` retry. `src/fragment.zig`: `FragmentCollector`, fragment accumulation, text validation through `src/utf8.zig`, and completed-message delivery. `src/split.zig`: `WebSocketRead`, `WebSocketWrite`, `Split`, `after_handshake_split`/`init`, caller-owned `ReadStorage`/`WriteStorage`/`Storage`, sink-forwarded pong and close obligations, and `FragmentCollectorRead` with caller-owned `message_buffer` and latch/reset behavior. Add streaming, fragmentation, and split tests in `tests/stream-test/`, `tests/fragment-test/`, and `tests/split-test/` when the testing agent is unavailable. Never edit frame primitives, connection policy, handshake, build, or CI files.

## Rules

Rely on `zslay` and `connection` for continuation ordering, control-frame interleaving, cumulative message-size limits, close policy, masking direction, fragment ordering, and the transmit queue; do not reimplement those checks. The stream layer owns no wire state: message states are pure, chunks borrow the connection frame buffer, and writer state advances only after `enqueue_frame` succeeds; `flush` is the only drain point. The read half never writes and the write half never reads; each half owns an independent `connection.WebSocket`/`zslay.Conn`. The collector owns only buffering; it validates text with the framing-owned `src/utf8.zig` validator, including split code points. Preserve explicit read and write state; no hidden allocation or dynamic dispatch.

## Workflow

Read the streaming, fragmentation, and split contracts and tests, keep the state machines flat and bounded, add tests for chunk borrows, interleaved control frames, size limits, UTF-8 boundaries, backpressure retries, and split halves, then run `zig fmt .`, `zig build test`, and `zig build check`.

## Shared Rules

Read `AGENTS.md`, `AGENT_DIRECTORY.md`, and `CODING_CONVENTION.md` before editing. Load the relevant `SKILL.md` files from `.agents/skills/`; if a skill is unavailable, follow the repository docs and say so. When `graphify-out/graph.json` exists, start every codebase question with `graphify query` before broad source reads, use `graphify path` and `graphify explain` for relationships and concepts, use `graphify affected` and `graphify god-nodes` for impact and hubs, pass this rule into every subagent prompt, and run `graphify update .` after code changes. Do not commit, push, tag, or open a pull request unless the user explicitly asks.
