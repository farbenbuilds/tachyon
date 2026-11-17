# Repository Guidelines

## Project Identity

tachyon is a Zig 0.17.1 recreation of
[denoland/fastwebsockets](https://github.com/denoland/fastwebsockets). The
behavioral target is the fastwebsockets 0.10.0 surface: raw frame reads and
writes, automatic close and pong handling, automatic mask application, maximum
message limits, vectored writes, fragmentation collection, HTTP server upgrade,
client handshake, and split read/write halves. permessage-deflate is out of
scope, matching upstream.

The framing engine is
[farbenbuilds/zslay](https://github.com/farbenbuilds/zslay). It is declared in
`build.zig.zon`, and `zon2nix` generates `build.zig.zon.nix` for offline Nix
builds. tachyon must not reimplement zslay's header codec, length validation,
close-payload validation, or XOR masking. Read `CODEBASE.md` before changing the
boundary between the two libraries.

## Current State

This change is the environment and documentation foundation:

- `flake.nix`, `flake.lock`, and `.envrc` provide the Zig 0.17.1 shell.
- `.pre-commit-config.yaml` holds the hygiene and formatting hooks.
- `.agents/skills/` holds the shared skill pack and `.agents/agents/` holds the
  agy agent definitions.
- `.opencode/` and `.codex/` hold the matching OpenCode and Codex agent
  definitions, the platform-specific graphify integration, and client
  configuration.
- The root Markdown guides define the architecture and process.
- There is no `build.zig`, `build.zig.zon`, `src/` tree, test suite, or library
  artifact in this change.

Do not describe the connection, fragmentation, handshake, upgrade, or split
modules as implemented before they exist and are tested.

## Non-Negotiable Architecture

These rules apply to the implementation:

- Keep the frame layer pure. Given the same input it returns the same output and
  writes only into caller-owned memory.
- Keep zslay as the only frame codec. Do not duplicate header parsing, length
  decoding, masking, or close validation in tachyon.
- The protocol core is zero-allocation and I/O-agnostic. Allocators belong in
  examples, tests, or an explicit caller-owned buffer boundary, never in frame
  or connection state transitions.
- Transport work belongs at the edge. The planned connection layer consumes
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

Current environment and documentation files:

| Path | Purpose |
| --- | --- |
| `flake.nix`, `flake.lock` | Zig 0.17.1 shell, zon2nix, Nix formatting check, and musl shell. |
| `.envrc` | direnv entry point; selects the musl shell when the host uses musl. |
| `.pre-commit-config.yaml` | Formatting, hygiene, and zon2nix hooks. |
| `scripts/update_zon_files.sh` | Regenerates `build.zig.zon.nix`, `.json`, and `.txt` with zon2nix. |
| `.agents/skills/`, `skills-lock.json` | Shared skill pack and lock file. |
| `.agents/agents/`, `.opencode/agents/`, `.codex/agents/` | Matching agent definitions for agy, OpenCode, and Codex. |
| `.codex/TEAM_WORKFLOW.md` | Codex team procedure and handoff contract. |
| `.opencode/`, `.codex/` | Graphify skill copies, hooks, and client configuration. |
| `.gitattributes` | Linguist rules for agent tooling, generated output, docs, and `.zon` files. |
| `.gitignore` | Nix, Zig, build, graph, and editor output. |
| `README.md`, root `*.md` | Banner, architecture, contributor, security, release, and agent guides. |

Target source layout, in dependency order:

| Path | Purpose |
| --- | --- |
| `build.zig`, `build.zig.zon` | Public module, static library, tests, and the zslay dependency. |
| `src/root.zig` | Public module entry point and re-exports. |
| `src/frame.zig` | `Frame`, `OpCode`, `Payload`, header-length calculation, zslay encode bridge. |
| `src/close.zig` | RFC 6455 close code enum, conversion, and allowed-value policy. |
| `src/mask.zig` | Thin masking wrapper over zslay's wide-word implementation. |
| `src/error.zig` | `WebSocketError` set matching the fastwebsockets failure model. |
| `src/connection.zig` | Role-aware read/write state, auto-pong, auto-close, mask direction, limits. |
| `src/fragment.zig` | `FragmentCollector` and split-read collector state. |
| `src/handshake.zig` | Client request and response verification, key generation. |
| `src/upgrade.zig` | Server upgrade validation and response construction. |
| `src/split.zig` | Read and write halves plus split constructors. |
| `src/test.zig` | Unit tests for all protocol layers. |

Keep one owner per file. Cross-scope work is handed to the owning agent or
reviewer instead of edited in the same pass.

## Functional Core

The frame layer is a pure transformation over caller-owned buffers. Stateful
behavior belongs to the connection layer and must be explicit in its parameters.

- Use flat iterative loops with early returns. Recursion is prohibited in frame
  and connection paths.
- Use guard clauses and `switch` rather than nested `if`/`else` ladders.
- Keep mutation narrow: an operation may mutate only the buffer or state record
  named in its contract.
- Do not add logging, clocks, randomness, environment reads, or allocation to
  frame parsing. Randomness for client keys belongs in the handshake boundary.
- Compile-time assertions should prove header sizes, close ranges, and layout
  relationships.

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
zig build test              # Debug and ReleaseSafe suites
zig build check             # type-check library and tests
zig fmt --check .           # formatting gate
```

Use `zig fmt .` to apply formatting. Do not install project tools globally with
`apt`, `brew`, or `npm`.

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

Use Zig `test` blocks in `src/test.zig`, named `<Area>: <behavior>`, for example
`Frame: encodes a masked extended-length header`.

- Every behavioral change needs a focused regression test.
- Cover boundary lengths 0, 1, 125, 126, 127, 65535, 65536, and the configured
  maximum where the changed code interprets lengths.
- Cover malformed input: reserved bits, fragmented control frames, one-byte
  close payloads, invalid close codes, invalid UTF-8 reasons, and truncated
  headers.
- Keep payloads caller-owned in tests; do not introduce a test allocator into
  the frame core.
- Run both Debug and ReleaseSafe before review.
- Autobahn, fuzzing, and loopback echo adapters arrive with the connection
  layer. Do not claim compliance before those suites exist and pass.

## Security and Protocol Rules

- Enforce client-to-server masking and server-to-client unmasked frames.
- Reject nonzero RSV bits until an extension is negotiated.
- Reject fragmented control frames and control payloads above 125 bytes.
- Validate close length, close code, and UTF-8 reason before echoing.
- Cap message size before buffering or indexing.
- Treat every peer-supplied length as untrusted, including extended lengths.
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
`.agents/agents/`, `.opencode/agents/`, and `.codex/agents/`; Codex also reads
`.codex/TEAM_WORKFLOW.md`. The shared skill pack is vendored under
`.agents/skills/` and pinned by `skills-lock.json`; an agent must not reference a
definition or skill that is not present in the repository.

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
`skills-lock.json`. Graphify has platform copies under `.opencode/skills/` and
`.codex/skills/`, with the OpenCode plugin at `.opencode/plugins/graphify.js`
and the Codex hook at `.codex/hooks.json`. [SKILL.md](SKILL.md) is the
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

A knowledge graph may be generated under `graphify-out/`, which is gitignored.
When `graphify-out/graph.json` exists, run `graphify query "<question>"` before
the first broad grep, search, or source read for a codebase question, and put
that rule in every subagent prompt that explores code. Use
`graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"`
for focused concepts. After code changes, run `graphify update .` to refresh the
graph. Do not commit `graphify-out/`.
