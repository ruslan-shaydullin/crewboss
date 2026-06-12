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
  PROMPT="You are the tech-lead. Decompose charter #$ID in repo $PR_REPO into 2-4 leaf sub-issues with: gh issue create -R $PR_REPO. Each sub-issue body MUST:
1. Start with 'Charter: #$ID'
2. Contain a self-contained task description (a cold executor sees only that issue)
3. Include a '## Acceptance (machine)' section with at least one '- check: <cmd>' or '- test: <file>' line

After creating each sub-issue N, add the required label: gh issue edit N -R $PR_REPO --add-label type:agent

Add 'Depends-on: #X' only if truly ordered. Then set the charter to plan-review: gh issue edit $ID -R $PR_REPO --add-label status:plan-review --remove-label status:needs-plan. Do not write code. Charter goal:

$(bash "$BOARD" get "$ID" prompt)"
else
  TS=$(date +%s)
  BRANCH="task/$ID-$TS"
  # Charter-aware: if the leaf belongs to a charter, the PR must target charter/C, not main.
  CHARTER=$(bash "$BOARD" get "$ID" charter 2>/dev/null || true)
  CB=""
  [ -n "$CHARTER" ] && CB="charter/$CHARTER"
  if [ -n "$CB" ]; then
    BRANCH="leaf/$ID-$TS"   # charter leaves must use leaf/ prefix so integrator can find them
    PROMPT="You are the executor for issue #$ID in repo $PR_REPO.
Hard rules for THIS run:
- You are ALREADY on branch \`$BRANCH\`, based on the charter integration branch \`$CB\` (NOT main). Sibling leaves of charter #$CHARTER may already be merged into \`$CB\`. Commit your work on THIS branch. Do NOT create or switch to any other branch.
- When the work is done and the verification gate is green, push this branch (\`git push -u origin HEAD\`) and open ONE pull request: \`gh pr create --base $CB --title '<short>' --body 'Closes #$ID'\`. The PR base MUST be \`$CB\`, NOT main. Then STOP — do not merge, do not touch other issues.
- This issue is self-contained; everything you need is below.

---- TASK (issue #$ID) ----
$(bash "$BOARD" get "$ID" prompt)"
  else
    PROMPT="You are the executor for issue #$ID in repo $PR_REPO. Hard rules for THIS run:
- You are ALREADY on the correct git branch \`$BRANCH\` (run \`git branch --show-current\` to confirm). Commit your work on THIS branch. Do NOT create or switch to any other branch (do NOT invent \`task/<charter>\`).
- When the work is done and the verification gate is green, push the current branch (\`git push -u origin HEAD\`) and open ONE pull request with \`gh pr create\`; the PR body MUST contain the line \`Closes #$ID\`. Then STOP — do not merge, do not touch other issues.
- This issue is self-contained; everything you need is below.

---- TASK (issue #$ID) ----
$(bash "$BOARD" get "$ID" prompt)"
  fi
fi
TS="${TS:-$(date +%s)}"
# nsjail writes in-jail files as host-root (uid-map), so a prior run's node_modules is
# undeletable by us — sudo-fallback the cleanup or the work dir stays poisoned forever.
WA="$RUN/work/$ID/repo"
rm -rf "$WA" 2>/dev/null || sudo rm -rf "$WA" 2>/dev/null || true
mkdir -p "$WA"
PF="$RUN/work/$ID/task.prompt"; printf '%s\n' "$PROMPT" > "$PF"

# Shared local mirror cache: clone/refresh ONCE from GitHub (under flock), then every leaf
# clones from disk — no concurrent network clones (which throttle on a private repo).
CACHE_DIR="$CB_HOME/repo-cache"; mkdir -p "$CACHE_DIR"
CACHE="$CACHE_DIR/$(printf '%s' "$PR_REPO" | tr '/' '_').git"
# Build the cache ONCE per run (under flock); then it is READ-ONLY — never refreshed mid-run.
# Refreshing a mirror while a sibling leaf clones --local from it corrupts that clone, so we
# don't. The cache is (re)warmed at run start; leaves see main as of run start. Good enough.
(
  flock 9
  if [ ! -d "$CACHE" ]; then
    mc=0
    until git clone --mirror "https://x-access-token:${GH_TOKEN}@github.com/$PR_REPO.git" "$CACHE.tmp" >/dev/null 2>&1; do
      mc=$((mc+1)); [ "$mc" -ge 3 ] && { echo "adapter-gh: cache mirror clone failed for $PR_REPO" >&2; exit 2; }
      rm -rf "$CACHE.tmp"; sleep $((mc*3))
    done
    mv "$CACHE.tmp" "$CACHE"   # atomic publish: a half-built cache is never visible to readers
  fi
) 9>"$CACHE_DIR/.lock" || exit 2
git clone --local "$CACHE" "$WA/work" >/dev/null 2>&1 \
  || { echo "adapter-gh: local clone from cache failed" >&2; exit 2; }
[ -e "$WA/work/.git" ] || { echo "adapter-gh: work tree has no .git — empty clone" >&2; exit 2; }
cd "$WA/work"
git remote set-url --push origin "https://x-access-token:${GH_TOKEN}@github.com/$PR_REPO.git"
if [ -n "${CB:-}" ]; then
  # Ensure charter/C exists on origin (create off origin/main once, serialised per charter).
  mkdir -p "$RUN"
  ( flock 9
    if ! git ls-remote --exit-code --heads origin "$CB" >/dev/null 2>&1; then
      main_sha=$(git rev-parse "origin/main" 2>/dev/null \
                 || git rev-parse "origin/master" 2>/dev/null || true)
      [ -n "$main_sha" ] && git push -q origin "$main_sha:refs/heads/$CB" 2>/dev/null || true
    fi
  ) 9>"$RUN/charter-${CHARTER}.lock"
  git fetch -q origin "$CB" 2>/dev/null || true
  git checkout -q -b "$BRANCH" "origin/$CB"
else
  git checkout -q -b "$BRANCH"
fi
echo ".task.prompt" >> "$WA/work/.git/info/exclude"
# governed mode: inject the crewboss .claude (gate + role) into the work dir so the executor
# runs role-gated (set CB_GOVERNED=1 to enable; the spawn then uses --agent <role>).
if [ "${CB_GOVERNED:-0}" = "1" ] && [ -d "$CB_HOME/gov/.claude" ]; then
  cp -r "$CB_HOME/gov/.claude" "$WA/work/.claude"
  printf '.claude\n' >> "$WA/work/.git/info/exclude"
fi

exec "$CB_HOME/crewboss-spawn.sh" "$ID" "$ROLE" "$PF" "$WA/work" "$PR_REPO"
