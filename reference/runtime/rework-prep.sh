#!/usr/bin/env bash
# rework-prep: spawn a jailed executor to rework issue $ID onto charter/2.
# Usage: rework-prep.sh <id> [old-task-branch]
#   old-branch given  -> integrate mode (merge prior work onto charter/2, resolve conflicts)
#   no old-branch      -> fresh-fix mode (implement the issue on charter/2)
set -uo pipefail
CB_HOME="${CB_HOME:-$HOME/cbnet}"; RUN="$CB_HOME/run"
ID="$1"; OLD="${2:-}"
GH_TOKEN="$(gh auth token)"; export GH_TOKEN
URL="https://x-access-token:${GH_TOKEN}@github.com/stratch1989/crewboss.git"
WA="$RUN/work/$ID/repo"
rm -rf "$WA" 2>/dev/null || sudo rm -rf "$WA" 2>/dev/null || true
mkdir -p "$WA"
git clone -q "$URL" "$WA/work" || { echo "rework: clone failed" >&2; exit 2; }
cd "$WA/work"
git remote set-url --push origin "$URL"
TS="$(date +%s)"
git checkout -q -b "rework/$ID-$TS" origin/charter/2 || { echo "rework: no charter/2" >&2; exit 2; }
BODY="$(gh issue view "$ID" -R stratch1989/crewboss --json body --jq .body 2>/dev/null)"

if [ -n "$OLD" ]; then
  PROMPT="You are reworking issue #$ID onto the charter integration branch charter/2 in repo stratch1989/crewboss.
You are ALREADY on branch rework/$ID-$TS, based on origin/charter/2 — sibling leaves of charter #2 are ALREADY merged here (their code is in ui/app/src/App.tsx, styles.css, api.ts, etc).
Your earlier work for this issue is on origin/$OLD. Do this, in order:
1. git merge --no-edit origin/$OLD
2. Resolve EVERY conflict by KEEPING BOTH sides (the additive union): siblings added their feature next to yours in the same files — preserve both; when function/component signatures differ, keep the SUPERSET (all params). Do NOT delete sibling features.
3. Verify green: (cd ui/app && npm ci && npx tsc --noEmit && npm run build) — all must pass; fix until green.
4. git add -A && git commit if the merge left a commit, then: git push -u origin HEAD
5. gh pr create --base charter/2 --title \"rework(#$ID): rebase onto charter/2\" --body \"Closes #$ID — reworked onto integration branch, conflicts resolved as additive union.\"
Then STOP at the PR. Do NOT merge. Do NOT target main — base MUST be charter/2.

Issue #$ID:
$BODY"
else
  PROMPT="You are fixing issue #$ID on the charter integration branch charter/2 in repo stratch1989/crewboss.
You are ALREADY on branch rework/$ID-$TS, based on origin/charter/2. Implement the fix described below in the existing code (the New Issue / charter creation modal lives in ui/app/src/App.tsx).
Verify green: (cd ui/app && npm ci && npx tsc --noEmit && npm run build) — all must pass.
git add -A && git commit -m \"fix(#$ID): ...\"; git push -u origin HEAD
gh pr create --base charter/2 --title \"fix(#$ID): modal close + confirm\" --body \"Closes #$ID\"
STOP at the PR. Do NOT merge. base MUST be charter/2.

Issue #$ID:
$BODY"
fi

PF="$RUN/work/$ID/task.prompt"; printf '%s' "$PROMPT" > "$PF"
exec "$CB_HOME/crewboss-spawn.sh" "$ID" executor "$PF" "$WA/work" stratch1989/crewboss
