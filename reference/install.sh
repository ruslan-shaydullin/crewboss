#!/usr/bin/env bash
# crewboss — copy the reference config into the current Git repository.
# Requires jq. Existing same-named agents/hook are replaced; hook wiring is
# merged into settings.local.json. Review and back up existing config first.
#
# After install:  claude --agent tech-lead
# For a new setup, prefer the documented `crewboss init` CLI instead.
set -euo pipefail
command -v jq >/dev/null || { echo "crewboss install needs jq"; exit 1; }

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.claude" && pwd)"
ROOT="$(git rev-parse --show-toplevel)"
DEST="$ROOT/.claude"
HOOK_CMD='$CLAUDE_PROJECT_DIR/.claude/hooks/crewboss-gate.sh'
LOCAL="$DEST/settings.local.json"

mkdir -p "$DEST/agents" "$DEST/hooks"
cp "$SRC"/agents/*.md "$DEST/agents/"
cp "$SRC"/hooks/crewboss-gate.sh "$DEST/hooks/"
chmod +x "$DEST/hooks/crewboss-gate.sh"

# wire the PreToolUse hook into settings.local.json (merge if present, idempotent)
if [ -f "$LOCAL" ]; then base="$(cat "$LOCAL")"; else base='{}'; fi
printf '%s' "$base" | jq --arg cmd "$HOOK_CMD" '
  .hooks //= {} | .hooks.PreToolUse //= [] |
  if any(.hooks.PreToolUse[]?.hooks[]?.command; . == $cmd) then .
  else .hooks.PreToolUse += [{matcher:"Bash",hooks:[{type:"command",command:$cmd}]}] end
' > "$LOCAL.tmp" && mv "$LOCAL.tmp" "$LOCAL"

echo "✓ crewboss installed into $DEST"
echo "  agents : $(ls "$DEST"/agents | tr '\n' ' ')"
echo "  hook   : .claude/hooks/crewboss-gate.sh"
echo "  wiring : .claude/settings.local.json (gitignored)"
echo
echo "Run the tech-lead :  claude --agent tech-lead"
echo "Uninstall helper  :  $(dirname "$SRC")/uninstall.sh"
