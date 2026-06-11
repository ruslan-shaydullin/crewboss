#!/usr/bin/env bash
# charter-aware leaf dispatch (CB_SPAWN override for the launcher).
# Runs an executor for leaf $ID on its charter's INTEGRATION branch charter/C
# (C derived from the issue body "Charter: #C"). The leaf branches OFF charter/C
# and opens its PR INTO charter/C — never main. charter/C is created off main on
# first use (under a per-charter flock). Honors the "review = whole charter" model.
# Usage (matches launcher contract): charter-leaf-prep.sh <id> <role>
set -uo pipefail
CB_HOME="${CB_HOME:-$HOME/cbnet}"; RUN="$CB_HOME/run"
ID="$1"; ROLE="${2:-executor}"
GH_TOKEN="$(gh auth token)"; export GH_TOKEN
URL="https://x-access-token:${GH_TOKEN}@github.com/stratch1989/crewboss.git"
BODY="$(gh issue view "$ID" -R stratch1989/crewboss --json body --jq .body 2>/dev/null)"
C="$(printf '%s' "$BODY" | grep -oiE 'charter:[[:space:]]*#?[0-9]+' | head -1 | grep -oE '[0-9]+')"
[ -n "$C" ] || { echo "leaf #$ID: no 'Charter: #N' in body" >&2; exit 2; }
CB="charter/$C"

WA="$RUN/work/$ID/repo"
rm -rf "$WA" 2>/dev/null || sudo rm -rf "$WA" 2>/dev/null || true
mkdir -p "$WA"
git clone -q "$URL" "$WA/work" || { echo "leaf #$ID: clone failed" >&2; exit 2; }
cd "$WA/work"
git remote set-url --push origin "$URL"

# ensure charter/C exists on origin (create off origin/main if absent), serialized per charter
mkdir -p "$RUN"
( flock 9
  if ! git ls-remote --exit-code --heads origin "$CB" >/dev/null 2>&1; then
    main_sha="$(git rev-parse origin/main)"
    git push -q origin "$main_sha:refs/heads/$CB" 2>/dev/null || true
  fi
) 9>"$RUN/charter-$C.lock"

git fetch -q origin "$CB" 2>/dev/null || true
TS="$(date +%s)"
if git rev-parse --verify -q "origin/$CB" >/dev/null; then
  git checkout -q -b "leaf/$ID-$TS" "origin/$CB"
else
  echo "leaf #$ID: $CB missing after create attempt" >&2; exit 2
fi

PROMPT="You are the executor for issue #$ID in repo stratch1989/crewboss.
Hard rules for THIS run:
- You are ALREADY on branch leaf/$ID-$TS, based on the charter integration branch '$CB' (NOT main). Sibling leaves of charter #$C may already be merged into '$CB'. Commit your work on THIS branch. Do NOT create or switch to any other branch.
- When the work is done and the verification gate is green, push this branch (git push -u origin HEAD) and open ONE pull request: gh pr create --base $CB --title '<short>' --body 'Closes #$ID'. The PR base MUST be '$CB', NOT main. Then STOP — do not merge, do not touch other issues.
- This issue is self-contained; everything you need is below.

---- TASK (issue #$ID) ----
$BODY"
PF="$RUN/work/$ID/task.prompt"; printf '%s' "$PROMPT" > "$PF"
exec "$CB_HOME/crewboss-spawn.sh" "$ID" "$ROLE" "$PF" "$WA/work" stratch1989/crewboss
