#!/usr/bin/env bash
# gh-twin of crewboss-prep-spawn.sh: satisfies the launcher's `$SPAWN <id> <role>` contract
# by reading pr_repo+prompt from the REAL board (board-gh.sh get), doing the §4.5 repo prep,
# and exec'ing crewboss-spawn.sh with full args. Exit code = crewboss-spawn.sh's.
set -uo pipefail
CB_HOME="${CB_HOME:-/tmp/cbnet}"
RUN="$CB_HOME/run"
BOARD="$CB_HOME/board-gh.sh"
ID="$1"; ROLE="$2"
# Source manifest library when CB_MANIFEST is set (analysis-role prompt support). [#136]
# Same search order as the launcher: CB_MANIFEST_LIB override → adjacent launcher/ → CB_HOME.
if [ -n "${CB_MANIFEST:-}" ]; then
  HERE_SPAWN="$(cd "$(dirname "$0")" && pwd)"
  _mlib_spawn=""
  if [ -n "${CB_MANIFEST_LIB:-}" ]; then
    _mlib_spawn="$CB_MANIFEST_LIB"
  elif [ -f "$HERE_SPAWN/../launcher/manifest.sh" ]; then
    _mlib_spawn="$HERE_SPAWN/../launcher/manifest.sh"
  elif [ -f "$CB_HOME/manifest.sh" ]; then
    _mlib_spawn="$CB_HOME/manifest.sh"
  fi
  [ -n "$_mlib_spawn" ] && [ -f "$_mlib_spawn" ] && source "$_mlib_spawn" || true
fi
PR_REPO=$(bash "$BOARD" get "$ID" pr_repo)
[ -n "$PR_REPO" ] || { echo "adapter-gh: #$ID has no pr_repo" >&2; exit 2; }
GH_TOKEN="${GH_TOKEN:-$(gh auth token)}"; export GH_TOKEN
# Inline git credential helper (issue #149 — token hygiene).
# Registered via GIT_CONFIG_* (highest git precedence). Inline function → no file path →
# valid in both host and jail namespaces. nsjail keep_env (-e) + --env GH_TOKEN carry both.
# shellcheck disable=SC2016
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=credential.helper
export GIT_CONFIG_VALUE_0='!f(){ echo username=x-access-token; echo password=$GH_TOKEN; }; f'
# role-aware prompt: a leaf's prompt is its issue body (self-contained brief); a tech-lead is
# told to DECOMPOSE the charter (#$ID) into leaf sub-issues and move it to plan-review.
# An analysis role (manifest mode, from policy.analysis_roles) gets a prompt built from the
# role file body + rubric.json + artifact contract + routing instruction. [#136]
if [ "$ROLE" = "tech-lead" ]; then
  PROMPT="You are the tech-lead. Decompose charter #$ID in repo $PR_REPO into 2-4 leaf sub-issues with: gh issue create -R $PR_REPO. Each sub-issue body MUST:
1. Start with 'Charter: #$ID'
2. Contain a self-contained task description (a cold executor sees only that issue)
3. Include a '## Acceptance (machine)' section with at least one '- check: <cmd>' or '- test: <file>' line

After creating each sub-issue N, add the required label: gh issue edit N -R $PR_REPO --add-label type:agent

Add 'Depends-on: #X' only if truly ordered. Then set the charter to plan-review: gh issue edit $ID -R $PR_REPO --add-label status:plan-review --remove-label status:needs-plan. Do not write code. Charter goal:

$(bash "$BOARD" get "$ID" prompt)"
elif [ -n "${CB_MANIFEST:-}" ] && \
     type manifest_analysis_roles >/dev/null 2>&1 && \
     manifest_analysis_roles "${CB_MANIFEST}" 2>/dev/null | grep -qx "${ROLE}"; then
  # Analysis role: compose prompt from role-file body + rubric + artifact contract. [#136]
  _role_prompt=$(manifest_role_prompt "$CB_MANIFEST" "$ROLE" 2>/dev/null || echo "")
  _rubric_content=$(cat "$CB_MANIFEST/rubric.json" 2>/dev/null || echo "{}")
  PROMPT="${_role_prompt}

## Rubric (objective floor — apply to every decision)
\`\`\`json
${_rubric_content}
\`\`\`

## Artifact contract (N-3 canon — parseable by composition-parse.sh)
Post exactly the following block as a comment on charter issue #${ID}:

  gh issue comment ${ID} -R ${PR_REPO} --body '<comment-body>'

The comment body MUST contain this block verbatim (roles/leaves are repeatable lines):

\`\`\`
## Composition (machine)
- approach: <одна строка описания подхода>
- role: <role-id>
- leaf: <leaf-id> -> <role-id>
- est_cost_usd: <число>
\`\`\`

After posting the comment, route the charter to team-review:

  gh issue edit ${ID} -R ${PR_REPO} --remove-label status:needs-analysis --add-label status:team-review

Charter goal (issue body):

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

# Shared local mirror cache: refreshed from GitHub on every dispatch (under flock); the local
# clone is also taken under the same lock so no leaf ever clones from a mid-fetch cache.
CACHE_DIR="$CB_HOME/repo-cache"; mkdir -p "$CACHE_DIR"
CACHE="$CACHE_DIR/$(printf '%s' "$PR_REPO" | tr '/' '_').git"
(
  flock 9
  if [ ! -d "$CACHE" ]; then
    mc=0
    until git clone --mirror "https://github.com/$PR_REPO.git" "$CACHE.tmp" >/dev/null 2>&1; do
      mc=$((mc+1)); [ "$mc" -ge 3 ] && { echo "adapter-gh: cache mirror clone failed for $PR_REPO" >&2; exit 2; }
      rm -rf "$CACHE.tmp"; sleep $((mc*3))
    done
    mv "$CACHE.tmp" "$CACHE"   # atomic publish: a half-built cache is never visible to readers
  else
    git --git-dir "$CACHE" fetch --prune origin '+refs/heads/*:refs/heads/*' >/dev/null 2>&1 \
      || { echo "adapter-gh: cache refresh failed for $PR_REPO" >&2; exit 2; }
  fi
  git clone --local "$CACHE" "$WA/work" >/dev/null 2>&1 \
    || { echo "adapter-gh: local clone from cache failed" >&2; exit 2; }
) 9>"$CACHE_DIR/.lock" || exit 2
[ -e "$WA/work/.git" ] || { echo "adapter-gh: work tree has no .git — empty clone" >&2; exit 2; }
cd "$WA/work"
# Push URL token-free; credential helper provides GH_TOKEN at push time.
git remote set-url --push origin "https://github.com/$PR_REPO.git"
if [ -n "${CB:-}" ]; then
  # Ensure charter/C exists on origin (create off origin/main once, serialised per charter).
  mkdir -p "$RUN"
  ( flock 9
    if ! git ls-remote --exit-code --heads origin "$CB" >/dev/null 2>&1; then
      main_sha=$(git rev-parse "origin/main" 2>/dev/null \
                 || git rev-parse "origin/master" 2>/dev/null || true)
      [ -n "$main_sha" ] && git push -q origin "$main_sha:refs/heads/$CB" 2>/dev/null \
        && git update-ref "refs/remotes/origin/$CB" "$main_sha" \
        || true   # tolerate: a sibling may have concurrently created it
    fi
    # Freshness guard: if charter/C is behind main with no own commits → fast-forward push;
    # if it has own commits and is stale → loud dispatch refusal.
    if git rev-parse --verify -q "refs/remotes/origin/$CB" >/dev/null 2>&1; then
      behind=$(git rev-list --count "origin/$CB..origin/main" 2>/dev/null || echo 0)
      if [ "$behind" -gt 0 ]; then
        own=$(git rev-list --count "origin/main..origin/$CB" 2>/dev/null || echo 0)
        if [ "$own" -eq 0 ]; then
          main_sha=$(git rev-parse "origin/main" 2>/dev/null \
                     || git rev-parse "origin/master" 2>/dev/null || true)
          git push -q origin "$main_sha:refs/heads/$CB" 2>/dev/null \
            && git update-ref "refs/remotes/origin/$CB" "$main_sha" \
            || { echo "adapter-gh: ff push of $CB failed" >&2; exit 2; }
        else
          echo "adapter-gh: $CB is behind origin/main by $behind commits with $own own commits — stale base, dispatch refused" >&2
          exit 2
        fi
      fi
    fi
  ) 9>"$RUN/charter-${CHARTER}.lock" || exit 2
  if ! git rev-parse --verify -q "refs/remotes/origin/$CB" >/dev/null 2>&1; then
    git fetch -q origin "$CB" 2>/dev/null \
      || { echo "adapter-gh: fetch $CB failed" >&2; exit 2; }
  fi
  if ! git checkout -q -b "$BRANCH" "origin/$CB"; then
    echo "adapter-gh: $CB missing after create attempt" >&2; exit 2
  fi
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
