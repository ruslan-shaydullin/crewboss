#!/usr/bin/env bash
# gh-twin of crewboss-prep-spawn.sh: satisfies the launcher's `$SPAWN <id> <role>` contract
# by reading pr_repo+prompt from the REAL board (board-gh.sh get), doing the §4.5 repo prep,
# and exec'ing crewboss-spawn.sh with full args. Exit code = crewboss-spawn.sh's.
set -uo pipefail
CB_HOME="${CB_HOME:-/tmp/cbnet}"
RUN="$CB_HOME/run"
BOARD="$CB_HOME/board-gh.sh"
ID="$1"; ROLE="$2"
PR_REPO=$(bash "$BOARD" get "$ID" pr_repo)
[ -n "$PR_REPO" ] || { echo "adapter-gh: #$ID has no pr_repo" >&2; exit 2; }
GH_TOKEN="${GH_TOKEN:-$(gh auth token)}"; export GH_TOKEN
# role-aware prompt: a leaf's prompt is its issue body (self-contained brief); a tech-lead is
# told to DECOMPOSE the charter (#$ID) into leaf sub-issues and move it to plan-review.
if [ "$ROLE" = "tech-lead" ]; then
  PROMPT="You are the tech-lead. Decompose charter #$ID in repo $PR_REPO into 2-4 leaf sub-issues with: gh issue create -R $PR_REPO. Each sub-issue body MUST start with 'Charter: #$ID' and contain a self-contained task description (a cold executor sees only that issue). Add 'Depends-on: #X' only if truly ordered. Then set the charter to plan-review: gh issue edit $ID -R $PR_REPO --add-label status:plan-review --remove-label status:needs-plan. Do not write code. Charter goal:

$(bash "$BOARD" get "$ID" prompt)"
else
  PROMPT=$(bash "$BOARD" get "$ID" prompt)
fi
TS=$(date +%s)
WA="$RUN/work/$ID/repo"; rm -rf "$WA" 2>/dev/null; mkdir -p "$WA"
PF="$RUN/work/$ID/task.prompt"; printf '%s\n' "$PROMPT" > "$PF"

git clone --mirror "https://github.com/$PR_REPO.git" "$WA/mirror.git" >/dev/null 2>&1
git clone --local "$WA/mirror.git" "$WA/work" >/dev/null 2>&1
cd "$WA/work"
git remote set-url --push origin "https://x-access-token:${GH_TOKEN}@github.com/$PR_REPO.git"
git checkout -q -b "task/$ID-$TS"
echo ".task.prompt" >> "$WA/work/.git/info/exclude"
# governed mode: inject the crewboss .claude (gate + role) into the work dir so the executor
# runs role-gated (set CB_GOVERNED=1 to enable; the spawn then uses --agent <role>).
if [ "${CB_GOVERNED:-0}" = "1" ] && [ -d "$CB_HOME/gov/.claude" ]; then
  cp -r "$CB_HOME/gov/.claude" "$WA/work/.claude"
  printf '.claude\n' >> "$WA/work/.git/info/exclude"
fi

exec "$CB_HOME/crewboss-spawn.sh" "$ID" "$ROLE" "$PF" "$WA/work" "$PR_REPO"
