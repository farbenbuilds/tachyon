# Repository Guidelines

## Project Identity

tachyon is a Zig 0.17.1 recreation of
[denoland/fastwebsockets](https://github.com/denoland/fastwebsockets). The
behavioral target is the fastwebsockets 0.10.0 surface: raw frame reads and
writes, automatic close and pong handling, automatic mask application, maximum
message limits, vectored writes, fragmentation collection, HTTP server upgrade,
client handshake, split read/write halves, and the native `std.Io.net.Stream`
adapter. The 0.10.0 surface is the parity baseline, not the ceiling: the
bounded zero-allocation pub/sub hub is implemented in `src/pubsub.zig` as a
post-parity application layer documented in `CODEBASE.md`. Chunked
streaming is implemented in `src/stream.zig`: `MessageReader` yields
caller-borrowed payload chunks with an explicit FIN, and `MessageWriter` queues
fragmented chunks through the connection's watermark-aware enqueue path. The
RFC 7692 permessage-deflate is implemented through `src/deflate.zig` plus
negotiated RSV1 plumbing in the frame, connection, stream, fragment, handshake,
and upgrade layers. The default no-extension path remains strict, and the codec
stays edge-composed rather than automatic. Backpressure is implemented in
`src/backpressure.zig` as an opt-in byte/frame watermark policy over zslay's
bounded transmit ring. Incremental UTF-8 validation is implemented in
`src/utf8.zig`: the fragment collector validates assembled messages across
fragments, the stream reader validates chunked text across frames, and the raw
connection read path validates clear FIN text frames.

The framing engine is
[farbenbuilds/zslay](https://github.com/farbenbuilds/zslay). It is declared in
`build.zig.zon`, and `zon2nix` generates `build.zig.zon.nix` for offline Nix
builds. tachyon must not reimplement zslay's header codec, length validation,
close predicate or payload validator, or XOR masking. The same rule covers
zslay's `Conn` state machine: masking direction, fragment ordering, frame and
message limits, close-code policy, and the bounded transmit queue stay in
zslay. tachyon calls the close validator on inbound frames and owns the echo
obligation. Read `CODEBASE.md`, especially the Compatibility Notes, before
changing the boundary between the two libraries.

## Current State

The package is complete for the fastwebsockets 0.10.0 parity baseline and the
post-parity layers. `build.zig` and `build.zig.zon` define the public module,
the static library, Debug and ReleaseSafe tests over `tests/main.zig`, the
`check` step, the repository-only `autobahn-server` step, and the zslay
dependency; the default `zig build` is library-only. `src/root.zig` re-exports
the frame, connection, transport, message, handshake, and edge-extension layers.
README is the user overview; CODEBASE is the detailed architecture and
compatibility map. `build.zig.zon.nix`, `.json`, and `.txt` are generated
zon2nix views for offline Nix builds.

The default path is strict: no extension, RSV1 rejected until negotiated, and
`allow_rsv1` is opt-in. zslay owns framing and wire state. Backpressure,
streaming, native stream, UTF-8, permessage-deflate, pub/sub, negotiated RSV1,
and permessage-deflate negotiation are implemented; compression remains
edge-composed and is never automatic in the stream layer.

Tests are aggregated by `tests/main.zig` and run in Debug and ReleaseSafe.
Library sources contain no test blocks. The Autobahn fixture is
`tests/autobahn-test/server.zig`; the workflow covers the case set `1-7, 9-13`.
Group 8 is absent from the pinned testsuite, and the action's default list omits
it, so the gate covers every case the suite ships. Compression cases 11-13 are
enabled through the fixture's negotiated permessage-deflate composition.

See [CODEBASE.md#target-source-layout](CODEBASE.md#target-source-layout) for the
full file map and [tests/README.md](tests/README.md) for the test categories.

## Non-Negotiable Architecture

These rules apply to the implementation:

- Keep the frame layer pure. Given the same input it returns the same output and
  writes only into caller-owned memory.
- Keep zslay as the only frame codec and wire-state owner. Do not duplicate
  header parsing, length decoding, masking, close validation, masking direction,
  fragment ordering, frame/message limits, or the bounded transmit queue in
  tachyon.
- Keep optional extensions at the edge. Backpressure, streaming, native stream,
  UTF-8, deflate, and pub/sub must not add allocation, I/O, or negotiation
  state to the frame core.
- The protocol core is zero-allocation and I/O-agnostic. Allocators belong in
  examples, tests, or an explicit caller-owned buffer boundary, never in frame
  or connection state transitions.
- Backpressure is explicit: bounded queues and watermarks, no unbounded
  buffering, no dropped frames, and no busy waiting.
- Compression is fail-closed: bound decompressed output by the configured
  message limit before delivery, and never apply compression to control frames.
  Negotiated RSV1 and permessage-deflate negotiation are implemented, but the
  stream layer never compresses or inflates automatically. The application
  composes `src/deflate.zig` at the edge, validates text after inflate, and keeps
  the default no-extension path strict.
- Text UTF-8 validation is incremental and zero-allocation; it must handle code
  points split across frames and must never substitute replacement characters.
- Transport work belongs at the edge. The connection layer consumes
  caller-provided readers and writers; it does not open sockets or spawn tasks.
- Use Zig 0.17.1 `std.Io` asynchronous I/O for the transport and example
  layers. Do not add libxev or another third-party event loop. uWebZockets uses
  libxev for its own engine; tachyon deliberately follows the standard library
  instead.
- Use static dispatch. Core routing uses `switch` over explicit enums, not
  vtables or function-pointer tables. C ABI callbacks, if a C surface is added
  later, are the only documented exception and must not route parser paths.
- Invalid wire input returns a typed error. Never substitute a default, clamp
  silently, or continue after a protocol violation.
- Every peer-controlled length is bounded before allocation or indexing.

## Repository Structure

Core paths are `build.zig`, `build.zig.zon`, `src/root.zig`, `src/*.zig`,
`tests/`, `examples/`, `benches/`, and `.github/workflows/`, including
`.github/workflows/bench.yml`. The opt-in `examples` and `benches` steps require
a full checkout; the default `zig build` stays library-only. The benchmark
workflow is manual and weekly, not a PR gate.
The full module and test layout is in
[CODEBASE.md#target-source-layout](CODEBASE.md#target-source-layout); ownership
is in [AGENT_DIRECTORY.md](AGENT_DIRECTORY.md). Keep one owner per file and hand
cross-scope work to the owning agent or reviewer instead of editing it in the
same pass.

## Functional Core

The frame layer is a pure transformation over caller-owned buffers. Stateful
behavior belongs to the connection layer and must be explicit in its parameters.

- Use flat iterative loops with early returns. Recursion is prohibited in frame
  and connection paths.
- Use guard clauses and `switch` rather than nested `if`/`else` ladders.
- Keep mutation narrow: an operation may mutate only the buffer or state record
  named in its contract.
- Do not add logging, clocks, randomness, environment reads, or allocation to
  frame parsing. Randomness for client keys belongs in the connection or
  handshake boundary.
- Compile-time assertions should prove header sizes and layout relationships;
  zslay owns close-range policy and its own layout invariants.

## Build, Test, and Development Commands

Environment commands:

```sh
nix develop                 # reproducible Zig 0.17.1 shell
direnv allow                # optional automatic shell entry
zig version                 # must print 0.17.1
nix flake check             # Nix formatting check
pre-commit run --all-files  # hygiene hooks
```

Library commands:

```sh
zig build                   # static library
zig build test              # Debug and ReleaseSafe suites over tests/main.zig
zig build check             # type-check library and tests
zig build autobahn-server -Doptimize=ReleaseSafe  # repository-only Autobahn echo fixture
zig fmt --check .           # formatting gate
```

The `autobahn-server` step builds and installs `zig-out/bin/tachyon-autobahn`
without changing the default library-only `zig build`; it requires a full
checkout because the package excludes `tests/`.

Cross-target compile checks reuse the `check` step with a target override:

```sh
zig build check -Dtarget=x86_64-linux-musl
```

CI compile-checks x86_64-linux-gnu, x86_64-linux-musl, aarch64-linux-gnu,
aarch64-linux-musl, x86-linux-musl, x86_64-macos, aarch64-macos, and
x86_64-windows. These are compile-only checks. Runtime coverage is the native
Debug and ReleaseSafe suite on x86_64-linux-gnu plus the host and musl tests in
`nix flake check`; no CI runtime claim is made for macOS or Windows. See
`CODEBASE.md#platform-support`.

Use `zig fmt .` to apply formatting. Do not install project tools globally
outside the Nix shell.

zslay is declared in `build.zig.zon`. The `zon2nix` pre-commit hook regenerates
`build.zig.zon.nix`, `build.zig.zon.json`, and `build.zig.zon.txt` whenever
`build.zig.zon` changes. The flake consumes the generated Nix expression so the
build has no network access and no duplicated version pin. When the dependency
changes, update `build.zig.zon`, run `pre-commit run zon2nix --all-files` (or
`sh scripts/update_zon_files.sh`), and commit the generated files with it.

## Coding Style and Naming

- Follow `zig fmt`: four-space indentation and a 120-character line limit.
- Use `snake_case` for files, functions, and variables.
- Use `PascalCase` for types, type-level constants, and error names.
- Prefix future exported C functions with `tachyon_`.
- Prefer early returns, explicit error sets, shallow control flow, and sparse
  comments that explain why rather than restating the code.
- Define public types at file scope with explicit names. Extract repeated
  compound types into aliases instead of nesting anonymous structs.
- Use `_len` for byte counts and `_sent` for stream progress.
- Do not use emojis in code, documentation, branches, commits, or reviews.
- Delete unused imports, dead code, and commented-out blocks in the same change.
- Do not add `TODO`, `FIXME`, `XXX`, or `HACK` markers. File an issue or land the
  change.

See [CODING_CONVENTION.md](CODING_CONVENTION.md) for the full rule set and Zig
0.17.1 notes.

## Testing Guidelines

Use Zig `test` blocks in `tests/<category>-test/*.zig`, aggregated by
`tests/main.zig`, named `<Area>: <behavior>`, for example
`Frame: encodes a masked extended-length header`. Add a new category folder as
`tests/<area>-test/` and import its files from `tests/main.zig`. Shared fixtures
and test-only readers and writers belong in `tests/support.zig`. Library sources
contain no test blocks; do not add tests back to `src/`.

- Every behavioral change needs a focused regression test.
- Cover boundary lengths 0, 1, 125, 126, 127, 65535, 65536, and the configured
  maximum where the changed code interprets lengths.
- Cover malformed input: reserved bits, fragmented control frames, one-byte
  close payloads, invalid close codes, invalid UTF-8 reasons, and truncated
  headers.
- Keep payloads caller-owned in tests; do not introduce a test allocator into
  the frame core.
- Run both Debug and ReleaseSafe before review.
- The Autobahn integration fixture at `tests/autobahn-test/server.zig` is
  implemented and gated by `.github/workflows/autobahn.yml` over the configured
  case set `1-7, 9-13`. Group 8 is absent from the pinned testsuite, and the
  action's default list omits it, so the gate covers every case the suite ships.
  Compression groups 11-13 are enabled through negotiated permessage-deflate
  fixture composition. Fuzzing and a full loopback echo suite remain future
  work. A green run is evidence only for the configured case set, not a full
  Autobahn or compression compliance claim.

## Security and Protocol Rules

- Enforce client-to-server masking and server-to-client unmasked frames.
- Reject nonzero RSV bits until an extension is negotiated.
- Reject fragmented control frames and control payloads above 125 bytes.
- Validate close length, close code, and UTF-8 reason before echoing. Never
  reuse unvalidated reason bytes in a 1002 reply.
- Cap message size before buffering or indexing.
- Treat every peer-supplied length as untrusted, including extended lengths.
- Seed client mask keys from a uniform, secret source in production; a
  deterministic seed is only a test seam. The connection never reads ambient
  randomness.
- Do not log payload bytes at any severity.
- Security reports follow [SECURITY.md](SECURITY.md).

## Commit and Pull Request Guidelines

History follows conventional commits:
`<type>(<scope>): <imperative subject>`.

Common types are `feat`, `fix`, `perf`, `build`, `ci`, `docs`, `style`,
`refactor`, and `test`. Keep subjects lowercase and omit the trailing period.
Example: `docs(repo): add flake and agent guides`.

Pull requests must:

- explain what changed and why,
- identify the change type,
- link issues with `Closes #123` when applicable,
- list the verification commands and their results,
- confirm formatting and checks,
- keep one scoped concern per pull request,
- avoid screenshots unless the change is visual documentation or branding.

Do not commit, push, tag, or open a pull request unless the user explicitly
asked for it.

## Sub-Agent Directory and Workflow

The shared ownership map and review workflow live in
[AGENT_DIRECTORY.md](AGENT_DIRECTORY.md). Matching definitions live under
`.agents/agents/`, `.opencode/agents/`, `.codex/agents/`, and `.claude/agents/`;
Codex also reads `.codex/TEAM_WORKFLOW.md`. The shared skill pack is vendored
under `.agents/skills/` and pinned by `skills-lock.json`; an agent must not
reference a definition or skill that is not present in the repository.

For coordinated work, follow this sequence:

1. Architect: read the request, inspect the tree, state assumptions, name
   affected paths and owners, define acceptance criteria, and list checks. The
   architect does not edit.
2. Developer: implement only the assigned slice, keep edits inside owned paths,
   and report changed files plus commands actually run.
3. Reviewer: read-only review of correctness, protocol behavior, security,
   tests, style, scope, and evidence. Report findings with file and line
   references.
4. Integrator: route findings to owners, re-review changed areas, verify the
   final combined diff, and prepare the delivery summary.

Keep one owner per pull request scope. Never let two agents edit the same file
concurrently. Small documentation-only changes may combine architect and
developer work but still need integrator verification.

## Optional Herdr Orchestration

[Herdr](https://herdr.dev) is optional. Use it only when the user explicitly
asks for Herdr, `herdr` is installed, and `HERDR_ENV=1` is set in an active
Herdr session. If Herdr was requested but the environment check fails, report
the problem and stop; do not silently switch to another orchestration mode. If
Herdr was not requested, ignore this section.

The binary is authoritative for syntax. Start with:

```sh
test "${HERDR_ENV:-}" = 1
herdr --help
herdr agent
herdr agent list
herdr pane list
```

Split a worker pane, start the matching agent kind, and send a self-contained
prompt with scope boundaries, exact paths, acceptance criteria, and verification
commands. Worker panes do not see the orchestrator transcript. Leaf workers do
not delegate further. A blocked worker surfaces its approval request to the
user; the orchestrator does not answer it. Do not close panes or stop the Herdr
server unless the user asked.

## Skills

The shared skill pack lives in `.agents/skills/` and is pinned by
`skills-lock.json`. Graphify has platform copies under `.opencode/skills/`,
`.codex/skills/`, `.claude/skills/`, and `.agents/skills/`, with the OpenCode
plugin at `.opencode/plugins/graphify.js`, the Codex hook at
`.codex/hooks.json`, the Claude Code hooks at `.claude/settings.json`, and the
Antigravity rules and workflow under `.agents/rules/` and `.agents/workflows/`.
Refresh them with `scripts/install_graphify_integrations.sh`; verify them with
`scripts/check_graphify_integrations.sh`. [SKILL.md](SKILL.md) is the
human-readable catalog; [AGENT_DIRECTORY.md](AGENT_DIRECTORY.md) maps skills to
owners.

For Zig work, apply `zig-0-17`, `zig-best-practices`, `zig-testing`, and
`zig-tiger-style`. Use TigerStyle for safety ideas such as entry assertions,
bounded loops, and compile-time layout invariants, while keeping tachyon's
`snake_case` naming, 120-column limit, and zero allocation contract.

For Nix work, apply `nix-best-practices` and `nix-hermetic`. For architecture
and review work, use `codebase-design`, `improve-codebase-architecture`,
`grilling`, `grill-me`, `domain-modeling`,
`thermo-nuclear-code-quality-review`, and `untangle-codebase` when the user
requests the pass. `untangle-codebase` is manual-only. Keep `skills-lock.json`
and this document in sync when adding or removing a skill.

## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

When the user types `/graphify`, use the installed graphify skill or instructions before doing anything else.

Rules:
- When graphify-out/graph.json exists, run `graphify query "<question>"` before your first grep, search or source-file read for a codebase question, and put this rule in every subagent prompt that explores code. Read raw files only for lines the graph or an earlier read already located. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- Dirty graphify-out/ files are expected after hooks or incremental updates; dirty graph files are not a reason to skip graphify. Only skip graphify if the task is about stale or incorrect graph output, or the user explicitly says not to use it.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).
- A committed graphify-out/graph.json is rewritten whole on every build, so a large diff to it in a pull request is expected. Do not flag it as churn or suggest skipping the graph rebuild or its hooks.
