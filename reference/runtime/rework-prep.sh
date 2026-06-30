#!/usr/bin/env bash
# rework-prep: spawn a jailed executor to rework issue $ID onto charter/C.
# Usage: rework-prep.sh <id> <role>
#   CB_OLD_BRANCH set  -> integrate mode (merge prior work onto charter/C, resolve conflicts)
#   CB_OLD_BRANCH empty -> fresh-fix mode (implement the issue on charter/C)
set -uo pipefail
CB_HOME="${CB_HOME:-$HOME/cbnet}"; RUN="$CB_HOME/run"
CB_REPO="${CB_REPO:-stratch1989/crewboss}"
ID="$1"; OLD="${CB_OLD_BRANCH:-}"
GH_TOKEN="$(gh auth token)"; export GH_TOKEN
URL="https://x-access-token:${GH_TOKEN}@github.com/${CB_REPO}.git"
BODY="$(gh issue view "$ID" -R "$CB_REPO" --json body --jq .body 2>/dev/null)"
# Carry the latest gate feedback (verify-merged RED reason) into the prompt so rework is targeted, not blind.
REDREASON="$(gh issue view "$ID" -R "$CB_REPO" --json comments --jq '[.comments[].body | select(test("verify-merged confirmed engine RED"))] | last // ""' 2>/dev/null)"
FEEDBACK=""; [ -n "$REDREASON" ] && FEEDBACK="

Most recent gate feedback to address specifically: $REDREASON
Note (#1110): the feedback above now carries the EXACT failing assertion (— failing: <test>: <assertion>). Read it before changing code. If the assertion pins OUTDATED/stale text (e.g. an old literal you legitimately changed) while your implementation is actually correct, the fix is to UPDATE THE ASSERTION in the test — not to revert your code."
C="$(printf '%s' "$BODY" | grep -oiE 'charter:[[:space:]]*#?[0-9]+' | head -1 | grep -oE '[0-9]+')"
[ -n "$C" ] || { echo "rework #$ID: no 'Charter: #N' in body" >&2; exit 2; }
WA="$RUN/work/$ID/repo"
rm -rf "$WA" 2>/dev/null || sudo rm -rf "$WA" 2>/dev/null || true
mkdir -p "$WA"
git clone -q "$URL" "$WA/work" || { echo "rework: clone failed" >&2; exit 2; }
cd "$WA/work"
git remote set-url --push origin "$URL"
TS="$(date +%s)"
git checkout -q -b "rework/$ID-$TS" "origin/charter/$C" || { echo "rework: no charter/$C" >&2; exit 2; }

if [ -n "$OLD" ]; then
  PROMPT="You are reworking issue #$ID onto the charter integration branch charter/$C in repo $CB_REPO.
You are ALREADY on branch rework/$ID-$TS, based on origin/charter/$C — sibling leaves of charter #$C are ALREADY merged here (their changes are already present on this branch).
Your earlier work for this issue is on origin/$OLD. Do this, in order:
1. git merge --no-edit origin/$OLD
2. Resolve EVERY conflict by KEEPING BOTH sides (the additive union): siblings added their feature next to yours in the same files — preserve both; when function/component signatures differ, keep the SUPERSET (all params). Do NOT delete sibling features.
3. Verify green: the ALLOW-filtered engine suite (run 'bash <t>' for every reference/tests/*.test.sh whose basename is listed ALLOW in reference/runtime/per-leaf-manifest; all must exit 0) — all must pass; fix until green.
4. git add -A && git commit if the merge left a commit, then: git push -u origin HEAD
5. gh pr create --base charter/$C --title \"rework(#$ID): rebase onto charter/$C\" --body \"Closes #$ID — reworked onto integration branch, conflicts resolved as additive union.\"
Then STOP at the PR. Do NOT merge. Do NOT target main — base MUST be charter/$C.

Issue #$ID:
$BODY$FEEDBACK"
else
  PROMPT="You are fixing issue #$ID on the charter integration branch charter/$C in repo $CB_REPO.
You are ALREADY on branch rework/$ID-$TS, based on origin/charter/$C. Implement the fix described below in the existing code on this branch.
Verify green: the ALLOW-filtered engine suite (run 'bash <t>' for every reference/tests/*.test.sh whose basename is listed ALLOW in reference/runtime/per-leaf-manifest; all must exit 0) — all must pass.
git add -A && git commit -m \"fix(#$ID): ...\"; git push -u origin HEAD
gh pr create --base charter/$C --title \"fix(#$ID): rework onto charter/$C\" --body \"Closes #$ID\"
STOP at the PR. Do NOT merge. base MUST be charter/$C.

Issue #$ID:
$BODY$FEEDBACK"
fi

PF="$RUN/work/$ID/task.prompt"; printf '%s' "$PROMPT" > "$PF"
exec "$CB_HOME/crewboss-spawn.sh" "$ID" executor "$PF" "$WA/work" "$CB_REPO"
