#!/usr/bin/env bash
# rework-prep: spawn the owning role to rework issue $ID onto charter/C.
# Usage: rework-prep.sh <id> <role>
#   CB_OLD_BRANCH set  -> integrate mode (merge prior work onto charter/C, resolve conflicts)
#   CB_OLD_BRANCH empty -> fresh-fix mode (implement the issue on charter/C)
set -uo pipefail
[ "$#" -ge 1 ] && [ "$#" -le 2 ] && [[ "$1" =~ ^[0-9]+$ ]] \
  || { echo 'usage: rework-prep.sh TASK_NUMBER [ROLE_IDENTIFIER]' >&2; exit 2; }
ID="$1"; ROLE="${2:-executor}"
[[ "$ROLE" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || { echo 'rework: invalid role identifier' >&2; exit 2; }
# shellcheck source=run-env.sh
. "$(dirname "${BASH_SOURCE[0]}")/run-env.sh" || exit 2
OLD="${CB_OLD_BRANCH:-}"
bash "$CB_HOME/crewboss-doctor.sh" --preflight || exit 2
RUN="$CB_HOME/run"
URL="https://github.com/${CB_REPO}.git"
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
5. source /cbnet/cb-pr-create.sh && cb_pr_create --base charter/$C --title \"rework(#$ID): rebase onto charter/$C\" --body \"Closes #$ID — reworked onto integration branch, conflicts resolved as additive union.\"
Then STOP at the PR. Do NOT merge. Do NOT target main — base MUST be charter/$C.

Issue #$ID:
$BODY$FEEDBACK"
else
  PROMPT="You are fixing issue #$ID on the charter integration branch charter/$C in repo $CB_REPO.
You are ALREADY on branch rework/$ID-$TS, based on origin/charter/$C. Implement the fix described below in the existing code on this branch.
Verify green: the ALLOW-filtered engine suite (run 'bash <t>' for every reference/tests/*.test.sh whose basename is listed ALLOW in reference/runtime/per-leaf-manifest; all must exit 0) — all must pass.
git add -A && git commit -m \"fix(#$ID): ...\"; git push -u origin HEAD
source /cbnet/cb-pr-create.sh && cb_pr_create --base charter/$C --title \"fix(#$ID): rework onto charter/$C\" --body \"Closes #$ID\"
STOP at the PR. Do NOT merge. base MUST be charter/$C.

Issue #$ID:
$BODY$FEEDBACK"
fi

PF="$RUN/work/$ID/task.prompt"; printf '%s' "$PROMPT" > "$PF"
if [ "${CB_GOVERNED:-1}" = 1 ] && [ -d "$CB_HOME/gov/.claude" ]; then
  mkdir -p "$WA/work/.claude"
  cp -R "$CB_HOME/gov/.claude/." "$WA/work/.claude"
  printf '.claude\n' >> "$WA/work/.git/info/exclude"
fi
if [ -n "${CB_MANIFEST:-}" ] && [ -f "$CB_MANIFEST/roles/$ROLE.md" ]; then
  mkdir -p "$WA/work/.claude/agents"
  cp "$CB_MANIFEST/roles/$ROLE.md" "$WA/work/.claude/agents/$ROLE.md"
  printf '.claude\n' >> "$WA/work/.git/info/exclude"
fi
exec "$CB_HOME/crewboss-spawn.sh" "$ID" "$ROLE" "$PF" "$WA/work" "$CB_REPO"
