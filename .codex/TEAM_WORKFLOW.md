# Codex Agent Team

Codex custom agents in `.codex/agents/` mirror the specialists in
`.opencode/agents/`, `.claude/agents/`, and `.agents/agents/` and add the four
workflow roles. Root project instructions remain in `AGENTS.md`; the ownership
map remains in `AGENT_DIRECTORY.md`.

## Procedure

1. `architect` reads the request, relevant instructions, and specialist
   ownership boundaries. It returns assumptions, a scoped plan, dependencies,
   and acceptance criteria. It does not edit files.
2. `developer` implements the assigned slice. For protocol or subsystem work,
   the root agent selects the matching specialist as the developer or asks it
   for focused guidance. Independent slices may run in parallel only when they
   do not edit the same files.
3. `reviewer` receives the final diff and verification evidence after
   implementation. It is read-only and reports actionable findings with
   file and line references. Findings return to the developer; changed work
   gets another review.
4. `integrator` takes the architect plan, developer report, and reviewer
   findings; checks ownership boundaries, scope, required commands, and the
   final diff; then prepares the delivery summary. Integration does not
   override project gates or silently discard findings. Every opened or updated
   pull request is assigned to its owner and carries at least one existing
   repository label; an unassigned or unlabeled pull request is not ready for
   review.

The root agent owns orchestration and the final response. No phase is complete
until its output is returned. Apply relevant skills from `.agents/skills/` and
the project rules in `AGENTS.md`, `AGENT_DIRECTORY.md`, and
`CODING_CONVENTION.md`. Report commands and their actual outcomes; never claim
checks that were not run.

## Graphify

When `graphify-out/graph.json` exists, each phase starts codebase questions with
`graphify query "<question>"` before broad grep or source reads. Use
`graphify path` and `graphify explain` for relationships and concepts, and
`graphify affected` and `graphify god-nodes` for impact and hubs. The architect
passes this rule into every worker prompt. The developer runs `graphify update .`
after code changes. The reviewer confirms graph use and freshness before
reporting ready for integration. If the graph is missing or stale, say so and
fall back to source reads.

Architecture work may use `codebase-design`,
`improve-codebase-architecture`, `domain-modeling`, and `grilling`; the
architect owns the vocabulary and the plan. Reviewers may add
`thermo-nuclear-code-quality-review` as a second lens on structural diffs.
Whole-codebase refactor requests may use `untangle-codebase`; its decision log
stays outside the repository and every behavior-preserving slice runs the
project gates. Project overrides in `AGENTS.md` win over vendored defaults,
including the no-emoji rule and the scratch-only architecture report.
