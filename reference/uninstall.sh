#!/usr/bin/env bash
# crewboss — remove what install.sh added from THIS repo. Reversible cleanup.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
DEST="$ROOT/.claude"
HOOK_CMD='$CLAUDE_PROJECT_DIR/.claude/hooks/crewboss-gate.sh'
LOCAL="$DEST/settings.local.json"

rm -f "$DEST"/agents/tech-lead.md "$DEST"/agents/executor.md "$DEST"/agents/task-helper.md "$DEST"/agents/boss.md "$DEST"/agents/analyst.md
rm -f "$DEST"/hooks/crewboss-gate.sh

# remove only OUR PreToolUse entry from settings.local.json; drop the file if it ends empty
if [ -f "$LOCAL" ] && command -v jq >/dev/null; then
  # filter at the COMMAND level, not the entry level: drop only OUR command from each entry's
  # hooks[], then drop entries that became empty. A foreign hook sharing an entry survives.
  out="$(jq --arg cmd "$HOOK_CMD" '
    if .hooks.PreToolUse then
      .hooks.PreToolUse |= ( map(.hooks |= map(select(.command != $cmd)))
                             | map(select((.hooks | length) > 0)) )
      | if (.hooks.PreToolUse | length) == 0 then del(.hooks.PreToolUse) else . end
    else . end
    | if (.hooks // {} | length) == 0 then del(.hooks) else . end
  ' "$LOCAL")"
  if [ "$out" = "{}" ]; then rm -f "$LOCAL"; else printf '%s\n' "$out" > "$LOCAL"; fi
fi

rmdir "$DEST/hooks" "$DEST/agents" 2>/dev/null || true
echo "✓ crewboss uninstalled from $DEST"
