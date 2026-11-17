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
  that are not present under `.opencode/agents/`, `.codex/agents/`, or
  `.agents/agents/`.
- Do not add comments that narrate the diff. Comments explain protocol
  invariants, byte values, ownership, or a deliberate divergence.
- Do not commit, push, tag, or open a pull request unless the user explicitly
  asked for it.
