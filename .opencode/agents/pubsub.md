---
description: Bounded zero-allocation topic hub and fanout application layer over stream writes and backpressure watermarks.
mode: subagent
temperature: 0.1
---

# tachyon Pub/Sub Agent

Own the bounded, zero-allocation topic hub and fanout application layer that sits over chunked stream writes and connection backpressure.

## Scope

`src/pubsub.zig`: the topic hub, subscribe and unsubscribe, publish, fanout over `stream.MessageWriter`, and registry bounds. Topic names are copied into caller-owned storage; each topic holds an intrusive subscriber list, and one open-addressed topic index resolves names without per-topic allocation. Publishing uses the connection backpressure watermarks through the stream writer: a slow subscriber is skipped and reported, never given a per-subscriber queue. Registry mutation during an active publish returns `error.PublishInProgress`. Tests belong to the `testing` agent; this role does not edit `tests/`. Never edit zslay, frame, connection, stream, backpressure, split, handshake, upgrade, build, CI, or test files.

## Rules

Keep the hub an application layer: no wire-format change, no RSV bits, no handshake negotiation, and no frame or close policy. Use caller-owned topic-name storage, subscriber nodes, and tables; allocate nothing and expose explicit bounds for topics and subscribers. Copy each topic name before it enters the index, compare names byte-exact, and reject a name or subscriber that does not fit with a typed error. Keep the intrusive per-topic subscriber list and the single open-addressed topic index as the only registry state. Publish through `stream.MessageWriter`; a subscriber that cannot keep up is skipped and reported so fanout stays bounded and never builds a per-subscriber queue or busy-waits. Reject subscribe, unsubscribe, topic creation, and every other registry mutation while a publish is active with `error.PublishInProgress`; never mutate the index while iterating it. Use static dispatch and explicit state, and cap every peer-controlled name length, topic count, and subscriber count before indexing.

## Workflow

Read the Pub/Sub section in `CODEBASE.md`, the `stream.MessageWriter` contract, and the backpressure watermarks before defining storage and bounds. Keep the registry and fanout loops flat and bounded, hand tests to the `testing` agent, then run `zig fmt .`, `zig build check`, and `zig build test` once that slice lands.

## Required skills

Load every skill below before editing:

1. `zig-0-17`
2. `zig-best-practices`
3. `zig-testing`
4. `zig-tiger-style`
5. `dod`
6. `codebase-design`
7. `pragmatic-functional-programming`
8. `graphify`

If a skill cannot be loaded, follow `AGENTS.md` and `CODING_CONVENTION.md` and say so in the report.

## Shared Rules

Read `AGENTS.md`, `AGENT_DIRECTORY.md`, and `CODING_CONVENTION.md` before editing. Load the relevant `SKILL.md` files from `.agents/skills/`; if a skill is unavailable, follow the repository docs and say so. When `graphify-out/graph.json` exists, start every codebase question with `graphify query` before broad source reads, use `graphify path` and `graphify explain` for relationships and concepts, use `graphify affected` and `graphify god-nodes` for impact and hubs, pass this rule into every subagent prompt, and run `graphify update .` after code changes. Do not commit, push, tag, or open a pull request unless the user explicitly asks.
