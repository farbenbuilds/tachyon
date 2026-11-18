#!/usr/bin/env sh

set -eu

fail() {
    echo "graphify integration check failed: $*" >&2
    exit 1
}

required="
.opencode/skills/graphify/SKILL.md
.opencode/plugins/graphify.js
.codex/skills/graphify/SKILL.md
.codex/hooks.json
.claude/skills/graphify/SKILL.md
.claude/settings.json
.agents/skills/graphify/SKILL.md
.agents/rules/graphify.md
.agents/workflows/graphify.md
"
for path in $required; do
    [ -f "$path" ] || fail "missing $path"
done

version=$(cat .opencode/skills/graphify/.graphify_version)
for path in .codex .claude .agents; do
    other=$(cat "$path/skills/graphify/.graphify_version")
    [ "$other" = "$version" ] || fail "$path graphify version $other does not match $version"
done

for path in .opencode .codex .claude .agents; do
    for reference in add-watch exports extraction-spec github-and-merge hooks query transcribe update; do
        [ -f "$path/skills/graphify/references/$reference.md" ] || fail "missing $path/skills/graphify/references/$reference.md"
    done
done

grep -q 'hook-guard search' .claude/settings.json || fail '.claude/settings.json has no graphify search hook'
grep -q 'hook-guard read' .claude/settings.json || fail '.claude/settings.json has no graphify read hook'
grep -q 'hook-check' .codex/hooks.json || fail '.codex/hooks.json has no graphify hook'
grep -q 'graphify query' .agents/rules/graphify.md || fail '.agents/rules/graphify.md lacks the graphify query rule'
grep -q 'graphify' .opencode/plugins/graphify.js || fail '.opencode/plugins/graphify.js lacks the graphify reminder'

for path in .agents/agents/*.md; do
    grep -q 'skills/graphify' "$path" || fail "$path does not load skills/graphify"
done

for path in .agents/agents/*.md .opencode/agents/*.md .opencode/agents/team/*.md .codex/agents/*.toml; do
    grep -q 'graphify affected' "$path" || fail "$path lacks the graph-first rule"
done

for path in AGENTS.md CLAUDE.md .codex/TEAM_WORKFLOW.md; do
    grep -q 'graphify query' "$path" || fail "$path lacks the graphify query rule"
done

echo "Graphify integrations verified for OpenCode, Codex, Claude Code, and Google Antigravity."
