#!/usr/bin/env bash
# crewboss — install the reference config into THIS repo for a dogfood run.
# Idempotent + reversible (see uninstall.sh). Local-only: agents/hook are untracked,
# settings.local.json is gitignored. Requires jq.
#
# After install:  claude --agent tech-lead
# Tech-lead task (paste):
#   Ты тех-лид. Сначала триаж: `gh issue list` — не плодить дубли. Затем аудит
#   quarter-ts/src по трём осям: логические/корректностные баги, security-гэпы,
#   архитектура. На каждую РЕАЛЬНО НОВУЮ конкретную проблему (file:line) — заведи
#   GitHub issue с метками (status:ready, type:bug|agent, prio:P1–P3). Не дублируй
#   #25/#30/#37/#39/#40/#41 — уточняй их комментом. Дедуп жёстко, качество важнее.
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
echo "Run the tech-lead :  claude --agent tech-lead   (then paste the task in this file's header)"
echo "Uninstall         :  bash reference/uninstall.sh"
