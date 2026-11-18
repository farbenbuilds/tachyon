# Claude Code Guidance

`AGENTS.md` is the canonical repository guide for every coding agent, including
Claude Code. Read it before acting. This file must not restate or shadow those
rules; when the two disagree, `AGENTS.md` wins.

@AGENTS.md

## Claude Code Notes

- Environment checks are `nix flake check` and
  `pre-commit run --all-files`. Code checks are `zig fmt --check .`,
  `zig build check`, and `zig build test` inside `nix develop`.
- Use the architect -> developer -> reviewer -> integrator sequence from
  `AGENT_DIRECTORY.md` for multi-part work. Use the plain role names from that
  roster, without a project prefix, and do not invent specialist agent names
  that are not present under `.opencode/agents/`, `.codex/agents/`,
  `.claude/agents/`, or `.agents/agents/`.
- Claude Code project subagents live in `.claude/agents/`. The architect,
  `review`, and `reviewer` definitions are read-only; every definition inherits
  the parent model and preloads the project `graphify` skill.
- Do not add comments that narrate the diff. Comments explain protocol
  invariants, byte values, ownership, or a deliberate divergence.
- Do not commit, push, tag, or open a pull request unless the user explicitly
  asked for it.
- Graphify is wired through `.claude/skills/graphify/` and the PreToolUse hooks
  in `.claude/settings.json`. Refresh the project integrations with
  `sh scripts/install_graphify_integrations.sh`.

## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

Rules:
- When graphify-out/graph.json exists, run `graphify query "<question>"` before your first grep, search or source-file read for a codebase question, and put this rule in every subagent prompt that explores code. Read raw files only for lines the graph or an earlier read already located. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).
- A committed graphify-out/graph.json is rewritten whole on every build, so a large diff to it in a pull request is expected. Do not flag it as churn or suggest skipping the graph rebuild or its hooks.
