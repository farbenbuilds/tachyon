#!/usr/bin/env sh

set -eu

if ! command -v graphify >/dev/null 2>&1; then
    echo "graphify is not installed; run: uv tool install graphifyy" >&2
    exit 1
fi

graphify opencode install --project
graphify codex install --project
graphify install --project --platform claude
graphify antigravity install --project

# The installers keep a backup when a checked-in skill differs from the package.
find . -name '*.graphify-bak' -delete
find .opencode .codex .claude .agents -name 'SKILL.md.bak' -delete 2>/dev/null || true

for path in \
    .codex/hooks.json \
    .codex/skills/graphify/.graphify_version \
    .opencode/skills/graphify/.graphify_version \
    .claude/skills/graphify/.graphify_version \
    .agents/skills/graphify/.graphify_version \
    .claude/settings.json; do
    if [ -f "$path" ] && [ -n "$(tail -c 1 "$path")" ]; then
        printf '\n' >> "$path"
    fi
done

echo "Graphify integrations refreshed for OpenCode, Codex, Claude Code, and Google Antigravity."
