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
# Inline git credential helper (issue #149 — token hygiene).
# Registered via GIT_CONFIG_* (highest git precedence). Inline function → no file path →
# valid in both host and jail namespaces. nsjail keep_env (-e) + --env GH_TOKEN carry both.
# shellcheck disable=SC2016
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=credential.helper
export GIT_CONFIG_VALUE_0='!f(){ echo username=x-access-token; echo password=$GH_TOKEN; }; f'
# role-aware prompt: a leaf's prompt is its issue body (self-contained brief); a tech-lead is
# told to DECOMPOSE the charter (#$ID) into leaf sub-issues and move it to plan-review.
# In manifest mode, if the role is an analysis role, build the analyst prompt.
_IS_ANALYSIS_ROLE=0
_IS_APPROVAL_ROLE=0
_IS_REVIEW_ROLE=0
_IS_MANIFEST_ROLE=0
_MANIFEST_LOADED=0
if [ -n "${CB_MANIFEST:-}" ]; then
  # Load manifest library to check analysis roles and all manifest roles
  _HERE_PREP_CHK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  _MLIB_CHK=""
  if [ -n "${CB_MANIFEST_LIB:-}" ]; then
    _MLIB_CHK="$CB_MANIFEST_LIB"
  elif [ -f "$_HERE_PREP_CHK/../launcher/manifest.sh" ]; then
    _MLIB_CHK="$_HERE_PREP_CHK/../launcher/manifest.sh"
  elif [ -f "$CB_HOME/manifest.sh" ]; then
    _MLIB_CHK="$CB_HOME/manifest.sh"
  fi
  if [ -n "$_MLIB_CHK" ] && [ -f "$_MLIB_CHK" ]; then
    # shellcheck source=../launcher/manifest.sh
    source "$_MLIB_CHK"
    _ANALYSIS_ROLES=$(manifest_analysis_roles "$CB_MANIFEST" 2>/dev/null || true)
    for _ar in $_ANALYSIS_ROLES; do
      [ "$_ar" = "$ROLE" ] && _IS_ANALYSIS_ROLE=1 && break
    done
    _APPROVAL_ROLE_ID=$(manifest_policy "$CB_MANIFEST" approval_role 2>/dev/null || true)
    [ -n "$_APPROVAL_ROLE_ID" ] && [ "$_APPROVAL_ROLE_ID" = "$ROLE" ] && _IS_APPROVAL_ROLE=1
    _REVIEW_ROLE_ID=$(manifest_policy "$CB_MANIFEST" review_role 2>/dev/null || true)
    [ -n "$_REVIEW_ROLE_ID" ] && [ "$_REVIEW_ROLE_ID" = "$ROLE" ] && _IS_REVIEW_ROLE=1
    _MANIFEST_ROLES=$(manifest_roles "$CB_MANIFEST" 2>/dev/null || true)
    if [ -n "$_MANIFEST_ROLES" ]; then
      _MANIFEST_LOADED=1
      for _mr in $_MANIFEST_ROLES; do
        [ "$_mr" = "$ROLE" ] && _IS_MANIFEST_ROLE=1 && break
      done
    fi
  fi
fi
# Loop-agent detection: roles with an agent definition file in reference/.claude/agents/<ROLE>.md
# (in-repo path for dev/CI) or in $CB_HOME/gov/.claude/agents/<ROLE>.md (box with CB_GOVERNED).
# These are launcher-loop-spawned roles (git-resolver, observer, etc.) — distinct from manifest
# roles (which live in CB_MANIFEST/roles/) and from the hard-coded tech-lead path.
_LOOP_AGENT_FILE=""
_HERE_LA="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$_HERE_LA/../.claude/agents/$ROLE.md" ]; then
  _LOOP_AGENT_FILE="$_HERE_LA/../.claude/agents/$ROLE.md"
elif [ "${CB_GOVERNED:-0}" = "1" ] && [ -f "${CB_HOME:-}/gov/.claude/agents/$ROLE.md" ]; then
  _LOOP_AGENT_FILE="${CB_HOME:-}/gov/.claude/agents/$ROLE.md"
fi
# The STANDARD loop roles have their own dispatch and an agent file in .claude/agents/ too:
# executor → leaf/<id>- branch (integrator finds the PR by that prefix); tech-lead → its branch;
# analyst/boss/integrator/task-helper are delegation roles, not launcher-loop leaf spawns. They
# MUST NOT route through the loop-agent branch (that broke executor → loop-agent/ branch → the
# integrator could not find the PR). The loop-agent branch is ONLY for the NEW ops-roles
# (git-resolver, observer, role-builder, test-planner). [fix: #275 L1 regression, 2026-06-17]
case "$ROLE" in executor|tech-lead|analyst|boss|integrator|task-helper) _LOOP_AGENT_FILE="" ;; esac
if [ "$_IS_ANALYSIS_ROLE" = "1" ]; then
  TS=$(date +%s)
  BRANCH="task/$ID-$TS"
  _ROLE_PROMPT=$(manifest_role_prompt "$CB_MANIFEST" "$ROLE" 2>/dev/null || true)
  _RUBRIC=$(cat "$CB_MANIFEST/rubric.json" 2>/dev/null || echo "{}")
  _MROLES=$(manifest_roles "$CB_MANIFEST" 2>/dev/null | tr '\n' ' ' || true)
  PROMPT="You are the $ROLE for charter #$ID in repo $(bash "$BOARD" get "$ID" pr_repo).

$_ROLE_PROMPT

## Rubric (objective complexity triggers — apply as a floor, not a vibe)
\`\`\`json
$_RUBRIC
\`\`\`

## Artifact contract
Produce a machine-readable composition block as a comment on the charter issue, then move the charter to team-review.

The composition block MUST use EXACTLY this format:

## Composition (machine)
- approach: <one line>
- role: <role-id>
- leaf: <leaf-id> -> <role-id>
- est_cost_usd: <number>

(Repeat '- role:' and '- leaf:' lines as needed for each role and leaf.)

Each '- leaf:' line MUST be EXACTLY '- leaf: <leaf-id> -> <role-id>' and end there — NO inline '[...]' brackets, NO spec/notes text after the role-id. Put any per-leaf detail in a SEPARATE '## Leaf specs (human)' section BELOW the machine block, never inside the '- leaf:' lines.

## Available roles — use ONLY these EXACT role-ids; NEVER invent a role (no 'go-backend-dev', 'python-dev', etc.)
$_MROLES
Assign worker leaves to an implementation role (e.g. 'executor'). Do NOT assign leaves to manager/analyst roles. If a needed capability has no role here, say so in 'approach' rather than inventing a role-id.

## Instructions
1. Study the charter issue AND any prior review feedback: gh issue view $ID -R $(bash "$BOARD" get "$ID" pr_repo) --comments
   If a prior 'REVIEW: changes-requested' comment exists, your NEW composition MUST address every 'фикс:' point in it — do NOT repeat the rejected composition unchanged.
2. Apply rubric triggers as an objective floor — name every role a complete solution needs.
3. Post the composition block as a comment: gh issue comment $ID -R $(bash "$BOARD" get "$ID" pr_repo) --body '<composition block>'
4. Move the charter to team-review: gh issue edit $ID -R $(bash "$BOARD" get "$ID" pr_repo) --remove-label status:needs-analysis --add-label status:team-review"
elif [ "$_IS_APPROVAL_ROLE" = "1" ]; then
  # Approval-role spawn: CTO (or configured approval_role) reviews and approves/rejects composition.
  # By analogy with analysis-role: prompt = manifest_role_prompt + composition artifact + outcome instructions.
  TS=$(date +%s)
  BRANCH="task/$ID-$TS"
  _ROLE_PROMPT=$(manifest_role_prompt "$CB_MANIFEST" "$ROLE" 2>/dev/null || true)
  _COMP_BODY=$(gh issue view "$ID" -R "$PR_REPO" --json comments \
    | jq -r '[.comments[] | select(.body | contains("## Composition (machine)"))] | last | .body // ""' \
    2>/dev/null || true)
  PROMPT="You are the $ROLE for charter #$ID in repo $PR_REPO.

$_ROLE_PROMPT

## Your task: Approve or reject the proposed team composition

The analysis team has proposed the following composition for charter #$ID:

$_COMP_BODY

## Instructions

1. Review the charter issue: gh issue view $ID -R $PR_REPO
2. Evaluate the composition: roles, scope, leaf assignments, and overall soundness.
3. Make one of the following decisions:

**To approve** (composition is sound — proceed to planning):
   gh issue edit $ID -R $PR_REPO --add-label composition:approved --add-label status:needs-plan --remove-label status:team-review

**To reject** (composition needs revision — return to analysis):
   gh issue comment $ID -R $PR_REPO --body 'Approval rejected: <your explanation>'
   gh issue edit $ID -R $PR_REPO --remove-label status:team-review --add-label status:needs-analysis"
elif [ "$_IS_REVIEW_ROLE" = "1" ]; then
  # Review-role spawn (#334 convergence loop): SUBSTANCE review of the composition, code-grounded.
  # AGREE -> set review:agreed (cost/cto gate proceeds next tick). CRITIQUE -> actionable feedback
  # comment + route back to needs-analysis so the analyst revises (the analyst reads the critique).
  TS=$(date +%s)
  BRANCH="task/$ID-$TS"
  _ROLE_PROMPT=$(manifest_role_prompt "$CB_MANIFEST" "$ROLE" 2>/dev/null || true)
  _RUBRIC=$(cat "$CB_MANIFEST/rubric.json" 2>/dev/null || echo "{}")
  _COMP_BODY=$(gh issue view "$ID" -R "$PR_REPO" --json comments \
    | jq -r '[.comments[] | select(.body | contains("## Composition (machine)"))] | last | .body // ""' \
    2>/dev/null || true)
  PROMPT="You are the $ROLE for charter #$ID in repo $PR_REPO.

$_ROLE_PROMPT

## Rubric (objective floor)
\`\`\`json
$_RUBRIC
\`\`\`

## The composition under review
$_COMP_BODY

## Judge the composition BY SUBSTANCE against four grounded anchors
1. Rubric — did the analyst respect the objective triggers above?
2. Real code — READ the repo (you have Read/Bash); is the approach feasible and does it fit reality? what gotchas were missed?
3. Acceptance — what would PROVE this is done/correct? is a verification plan implied?
4. Intent — does the plan still serve what charter #$ID actually asks?

## Instructions
1. Study the charter + read the relevant code: gh issue view $ID -R $PR_REPO
2. Output ONE verdict (default to rigor — do NOT agree on a plausible-but-ungrounded plan):

**AGREE** (genuinely sound on all four anchors):
   gh issue comment $ID -R $PR_REPO --body 'REVIEW: agreed — <one-line why>'
   gh issue edit $ID -R $PR_REPO --add-label review:agreed

**CRITIQUE** (otherwise — feedback the analyst can act on, then send back):
   gh issue comment $ID -R $PR_REPO --body 'REVIEW: changes-requested
- что: <concrete flaw> | почему: <which anchor + how> | фикс: <what to change>
(one line per issue)'
   gh issue edit $ID -R $PR_REPO --remove-label status:team-review --add-label status:needs-analysis"
elif [ -n "$_LOOP_AGENT_FILE" ] && [ "$_IS_ANALYSIS_ROLE" = "0" ] && [ "$_IS_APPROVAL_ROLE" = "0" ] && [ "$_IS_REVIEW_ROLE" = "0" ] && [ "$ROLE" != "tech-lead" ]; then
  # Loop-agent branch: roles defined in reference/.claude/agents/ (git-resolver, observer, etc.)
  # These are spawned directly by the launcher loop (not by manifest pipeline or tech-lead path).
  # Prompt: describe the specific instance task; agent persona comes from --agent $ROLE.
  TS=$(date +%s)
  BRANCH="loop-agent/$ID-$TS"
  PROMPT="Resolve the merge conflict on charter #$ID (branch \`charter/$ID\`) in repo $PR_REPO.

1. Fetch \`origin/charter/$ID\` and create a local branch to work on it.
2. Merge \`origin/main\` into it, then resolve all conflicts:
   - SHA/manifest files (\`runtime-manifest.tsv\`) → run \`bash regen-manifest.sh\` to regenerate; do NOT manually pick SHAs.
   - Code conflicts → resolve by semantic intent (understand both sides, produce correct merged result).
   - Config/schema files → prefer union of changes; flag ambiguity with a comment.
3. Run the ALLOW suite (each ALLOW entry in \`reference/runtime/per-leaf-manifest\`) — all must pass before push.
4. Push the resolved branch: \`git push -f origin HEAD:refs/heads/charter/$ID\`.
5. Remove the conflict label from the charter issue: \`gh issue edit $ID -R $PR_REPO --remove-label status:needs-conflict-resolution\`."
elif [ "$ROLE" = "tech-lead" ]; then
  TS=$(date +%s)
  BRANCH="tech-lead/$ID-$TS"
  # Base tech-lead prompt — phrasing locked (HD-1 / legacy-pin #135); do NOT alter without pin bump.
  _TL_PROMPT="You are the tech-lead. Decompose charter #$ID in repo $PR_REPO into 2-4 leaf sub-issues with: gh issue create -R $PR_REPO. Each sub-issue body MUST:
1. Start with 'Charter: #$ID'
2. Contain a self-contained task description (a cold executor sees only that issue)
3. Include a '## Acceptance (machine)' section with at least one '- check: <cmd>' or '- test: <file>' line

After creating each sub-issue N, add the required label: gh issue edit N -R $PR_REPO --add-label type:agent

Add 'Depends-on: #X' only if truly ordered. Then set the charter to plan-review: gh issue edit $ID -R $PR_REPO --add-label status:plan-review --remove-label status:needs-plan. Do not write code. Charter goal:

$(bash "$BOARD" get "$ID" prompt)"
  if [ -n "${CB_MANIFEST:-}" ]; then
    # Manifest mode: augment prompt with approved composition.
    # Parsing delegated to composition-parse.sh (#134) — do NOT duplicate format logic here.
    _HERE_PREP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _COMP_BODY=$(gh issue view "$ID" -R "$PR_REPO" --json comments \
      | jq -r '[.comments[] | select(.body | contains("## Composition (machine)"))] | last | .body // ""' \
      2>/dev/null || true)
    _COMP_TSV=""
    if [ -n "$_COMP_BODY" ]; then
      _COMP_TSV=$(printf '%s\n' "$_COMP_BODY" \
        | bash "$_HERE_PREP/composition-parse.sh" "$CB_MANIFEST" 2>/dev/null) || _COMP_TSV=""
    fi
    if [ -n "$_COMP_TSV" ]; then
      _COMP_ROLES=$(printf '%s\n' "$_COMP_TSV" | awk -F'\t' '$1=="role"{print $2}')
      _COMP_LEAVES=$(printf '%s\n' "$_COMP_TSV" | awk -F'\t' '$1=="leaf"{printf "%s -> %s\n",$2,$3}')
      PROMPT="$_TL_PROMPT

## Approved composition (charter #$ID)
Leaf assignments (symbolic leaf-id -> role-id):
$_COMP_LEAVES
Roles in this charter: $(printf '%s' "$_COMP_ROLES" | tr '\n' ' ')

For each sub-issue N you create, additionally run:
  gh issue edit N -R $PR_REPO --add-label role:<role-id>
where <role-id> is from the composition map above — do NOT invent role-ids.
Sub-issues correspond 1:1 to the composition; map symbolic leaf-ids to the created issue numbers yourself."
    else
      PROMPT="$_TL_PROMPT"
    fi
  else
    PROMPT="$_TL_PROMPT"
  fi
else
  TS=$(date +%s)
  BRANCH="task/$ID-$TS"
  # Charter-aware: if the leaf belongs to a charter, the PR must target charter/C, not main.
  CHARTER=$(bash "$BOARD" get "$ID" charter 2>/dev/null || true)
  CB=""
  [ -n "$CHARTER" ] && CB="charter/$CHARTER"
  # Manifest-role fail-fast: if CB_MANIFEST is set and ROLE is unknown to the manifest,
  # a typo in the role: label would silently fall through to a generic executor prompt.
  # Instead, bail immediately with a clear error so the operator can fix the label.
  if [ "$_MANIFEST_LOADED" = "1" ] && [ "$_IS_MANIFEST_ROLE" = "0" ]; then
    echo "prep-spawn: role '$ROLE' not found in manifest $CB_MANIFEST (check role: label for typo)" >&2
    exit 2
  fi
  if [ -n "$CB" ]; then
    BRANCH="leaf/$ID-$TS"   # charter leaves must use leaf/ prefix so integrator can find them
    if [ "$_IS_MANIFEST_ROLE" = "1" ]; then
      # Role-resolved spawn: insert role body (from manifest) before ---- TASK ----
      # so the executor knows its persona. Hard-rules block is preserved verbatim.
      _ROLE_BODY=$(manifest_role_prompt "$CB_MANIFEST" "$ROLE" 2>/dev/null || true)
      PROMPT="You are the executor for issue #$ID in repo $PR_REPO.
Hard rules for THIS run:
- You are ALREADY on branch \`$BRANCH\`, based on the charter integration branch \`$CB\` (NOT main). Sibling leaves of charter #$CHARTER may already be merged into \`$CB\`. Commit your work on THIS branch. Do NOT create or switch to any other branch.
- When the work is done and the verification gate is green, push this branch (\`git push -u origin HEAD\`) and open ONE pull request: \`gh pr create --base $CB --title '<short>' --body 'Closes #$ID'\`. The PR base MUST be \`$CB\`, NOT main. Then STOP — do not merge, do not touch other issues.
- This issue is self-contained; everything you need is below.

$_ROLE_BODY

---- TASK (issue #$ID) ----
$(bash "$BOARD" get "$ID" prompt)"
    else
      PROMPT="You are the executor for issue #$ID in repo $PR_REPO.
Hard rules for THIS run:
- You are ALREADY on branch \`$BRANCH\`, based on the charter integration branch \`$CB\` (NOT main). Sibling leaves of charter #$CHARTER may already be merged into \`$CB\`. Commit your work on THIS branch. Do NOT create or switch to any other branch.
- When the work is done and the verification gate is green, push this branch (\`git push -u origin HEAD\`) and open ONE pull request: \`gh pr create --base $CB --title '<short>' --body 'Closes #$ID'\`. The PR base MUST be \`$CB\`, NOT main. Then STOP — do not merge, do not touch other issues.
- This issue is self-contained; everything you need is below.

---- TASK (issue #$ID) ----
$(bash "$BOARD" get "$ID" prompt)"
    fi
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
# Default BRANCH for the plan/tech-lead path (decompose-only role: runs gh issue
# create, pushes no code). It is set explicitly only in the executor branch above,
# so without this default the git checkout below (line ~131) hits `set -u`:
# "BRANCH: unbound variable" and the plan spawn dies before Claude. The branch is a
# throwaway here — the tech-lead never pushes it. (Surfaced by the first end-to-end
# autonomous control run; the plan path was previously only exercised operator-side.)
BRANCH="${BRANCH:-task/$ID-$TS}"
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
# Manifest-role agent injection: materialise the role definition from the manifest into
# the work-tree .claude/agents/ directory so the executor runs with its role persona.
# Precedent: CB_GOVERNED cp + .git/info/exclude injection above.
if [ "$_IS_MANIFEST_ROLE" = "1" ] && [ -n "${CB_MANIFEST:-}" ]; then
  mkdir -p "$WA/work/.claude/agents"
  cp "$CB_MANIFEST/roles/$ROLE.md" "$WA/work/.claude/agents/$ROLE.md"
  grep -qxF '.claude' "$WA/work/.git/info/exclude" 2>/dev/null \
    || printf '.claude\n' >> "$WA/work/.git/info/exclude"
fi

# AgentConfigMap P1 (#356): resolve the role's fs.work capability from the manifest and pass
# it to the spawn primitive. `fs_work: ro` → /work mounted read-only (analyst/reviewer can't
# write the repo, enforced by nsjail). Absent → unset → spawn defaults to rw (back-compat).
if [ -n "${CB_MANIFEST:-}" ] && [ -f "$CB_MANIFEST/roles/$ROLE.md" ]; then
  CB_FS_WORK=$(manifest_role_field "$CB_MANIFEST" "$ROLE" fs_work 2>/dev/null \
    | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
  export CB_FS_WORK
fi

exec "$CB_HOME/crewboss-spawn.sh" "$ID" "$ROLE" "$PF" "$WA/work" "$PR_REPO"
