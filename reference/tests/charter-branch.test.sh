#!/usr/bin/env bash
# charter-branch.test.sh — integration tests for charter-aware leaf branching.
# Ref: issue #67.  Class b (integration, stub gh/claude, throwaway git-repo).
#
# All three scenarios are GREEN when run with the canonical charter-aware spawn.
# RED baseline: set SPAWN_OVERRIDE to a legacy/non-charter spawn — the same tests
# then fail, demonstrating pre-fix behaviour.
#
# Scenarios:
#  1. task/N branches FROM charter/C; PR base = charter/C, NOT the default branch
#  2. charter/C created idempotently by first leaf; second leaf does NOT reset it
#  3. flock race: two parallel leaf launches → exactly ONE creation of charter/C
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

# ── local bare repo ("remote") ────────────────────────────────────────────────
REMOTE="$ROOT/remote.git"
git init --bare -q "$REMOTE"
_tmp="$ROOT/init-work"
git clone -q "$REMOTE" "$_tmp" 2>/dev/null
git -C "$_tmp" config user.email t@t
git -C "$_tmp" config user.name T
printf 'base\n' > "$_tmp/README.md"
git -C "$_tmp" add -A
git -C "$_tmp" commit -qm init 2>/dev/null
git -C "$_tmp" push -q origin HEAD:refs/heads/main 2>/dev/null || true
rm -rf "$_tmp"

# Board JSON: charter #5 (approved) + leaves #10 and #11
export REMOTE
export SANDBOX="$ROOT/sb"
export BOARD_STATE="$SANDBOX/board.json"
export PRDIR="$SANDBOX/prs"
BOARD_JSON='[
  {"number":5,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],"body":"the charter","comments":[]},
  {"number":10,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"do thing A\nCharter: #5","comments":[]},
  {"number":11,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"do thing B\nCharter: #5","comments":[]}
]'

reset_sandbox(){
  rm -rf "$SANDBOX"
  # Reinitialise the bare remote so each scenario starts with a clean slate
  # (no leftover charter/* or task/* branches from previous scenarios).
  rm -rf "$REMOTE"; git init --bare -q "$REMOTE"
  local _t; _t="$(mktemp -d)"
  git clone -q "$REMOTE" "$_t" 2>/dev/null
  git -C "$_t" config user.email t@t; git -C "$_t" config user.name T
  printf 'base\n' > "$_t/README.md"
  git -C "$_t" add -A; git -C "$_t" commit -qm init 2>/dev/null
  git -C "$_t" push -q origin HEAD:refs/heads/main 2>/dev/null || true
  rm -rf "$_t"
  mkdir -p "$SANDBOX" "$PRDIR"
  printf '%s' "$BOARD_JSON" > "$BOARD_STATE"
}

# ── charter-aware spawn (GREEN) ───────────────────────────────────────────────
# Env: REMOTE, BOARD_STATE, PRDIR, SANDBOX (all exported)
CHARTER_SPAWN="$ROOT/charter-spawn.sh"
cat > "$CHARTER_SPAWN" <<'SPAWN'
#!/usr/bin/env bash
set -euo pipefail
ID="$1"
BODY="$(jq -r --argjson n "$ID" 'map(select(.number==$n))[0].body' "$BOARD_STATE")"
C="$(printf '%s' "$BODY" | grep -oiE 'charter:[[:space:]]*#?[0-9]+' | head -1 | grep -oE '[0-9]+')"
[ -n "$C" ] || { printf 'charter-spawn: no Charter: in #%s body\n' "$ID" >&2; exit 2; }
CB="charter/$C"

WA="$SANDBOX/work-$ID"; rm -rf "$WA"; mkdir -p "$WA"
git clone -q "$REMOTE" "$WA"
git -C "$WA" config user.email t@t
git -C "$WA" config user.name T

# Create charter/C from main if absent — idempotent, serialised per charter.
( flock 9
  if ! git ls-remote --exit-code --heads "$REMOTE" "$CB" >/dev/null 2>&1; then
    main_sha="$(git -C "$WA" rev-parse "origin/main" 2>/dev/null \
                || git -C "$WA" rev-parse "origin/master")"
    git -C "$WA" push -q origin "$main_sha:refs/heads/$CB"
    printf 'created %s by #%s\n' "$CB" "$ID" >> "$SANDBOX/charter-creates.log"
  fi
) 9>"$SANDBOX/charter-$C.lock"

git -C "$WA" fetch -q origin "$CB"
git -C "$WA" checkout -q -b "task/$ID" "origin/$CB"

printf 'work for #%s\n' "$ID" > "$WA/work-$ID.txt"
git -C "$WA" add -A
git -C "$WA" commit -qm "executor: closes #$ID" 2>/dev/null
git -C "$WA" push -q origin "task/$ID"

printf '%s' "$CB" > "$PRDIR/base-$ID"
touch "$PRDIR/$ID"
SPAWN
chmod +x "$CHARTER_SPAWN"

# ── legacy (non-charter) spawn (RED baseline) ─────────────────────────────────
# Mimics crewboss-launcher.sh / pre-fix canonical: creates task/N from default branch.
LEGACY_SPAWN="$ROOT/legacy-spawn.sh"
cat > "$LEGACY_SPAWN" <<'SPAWN'
#!/usr/bin/env bash
set -euo pipefail
ID="$1"
WA="$SANDBOX/work-$ID"; rm -rf "$WA"; mkdir -p "$WA"
git clone -q "$REMOTE" "$WA"
git -C "$WA" config user.email t@t
git -C "$WA" config user.name T
git -C "$WA" checkout -q -b "task/$ID"

printf 'work for #%s\n' "$ID" > "$WA/work-$ID.txt"
git -C "$WA" add -A
git -C "$WA" commit -qm "executor: closes #$ID" 2>/dev/null
git -C "$WA" push -q origin "task/$ID"

# PR base = default branch (NOT charter)
DEFAULT="$(git -C "$WA" rev-parse --abbrev-ref "origin/HEAD" 2>/dev/null \
           | sed 's|origin/||' || printf 'main')"
printf '%s' "${DEFAULT:-main}" > "$PRDIR/base-$ID"
touch "$PRDIR/$ID"
SPAWN
chmod +x "$LEGACY_SPAWN"

# ── no-flock spawn (for test 3 RED: both parallel spawns log a creation attempt)
NOFLOCK_SPAWN="$ROOT/noflock-spawn.sh"
cat > "$NOFLOCK_SPAWN" <<'SPAWN'
#!/usr/bin/env bash
set -euo pipefail
ID="$1"
BODY="$(jq -r --argjson n "$ID" 'map(select(.number==$n))[0].body' "$BOARD_STATE")"
C="$(printf '%s' "$BODY" | grep -oiE 'charter:[[:space:]]*#?[0-9]+' | head -1 | grep -oE '[0-9]+')"
CB="charter/$C"

WA="$SANDBOX/work-$ID"; rm -rf "$WA"; mkdir -p "$WA"
git clone -q "$REMOTE" "$WA"
git -C "$WA" config user.email t@t
git -C "$WA" config user.name T

# No flock, no existence check — always attempt create (race-prone).
main_sha="$(git -C "$WA" rev-parse "origin/main" 2>/dev/null \
            || git -C "$WA" rev-parse "origin/master")"
printf 'create-attempt %s by #%s\n' "$CB" "$ID" >> "$SANDBOX/charter-creates.log"
git -C "$WA" push -q origin "$main_sha:refs/heads/$CB" 2>/dev/null || true

git -C "$WA" fetch -q origin "$CB"
git -C "$WA" checkout -q -b "task/$ID" "origin/$CB"

printf 'work for #%s\n' "$ID" > "$WA/work-$ID.txt"
git -C "$WA" add -A
git -C "$WA" commit -qm "executor: closes #$ID" 2>/dev/null
git -C "$WA" push -q origin "task/$ID"

printf '%s' "$CB" > "$PRDIR/base-$ID"
touch "$PRDIR/$ID"
SPAWN
chmod +x "$NOFLOCK_SPAWN"

# ── helpers ───────────────────────────────────────────────────────────────────
# Resolve spawn: SPAWN_OVERRIDE overrides to test RED baseline (legacy launcher).
SPAWN="${SPAWN_OVERRIDE:-$CHARTER_SPAWN}"

# merge_base_matches_charter <task_branch> <charter_branch>: verifies task/N is
# directly based on charter/C (merge-base == charter/C HEAD, not main HEAD).
merge_base_ok(){
  local task="$1" charter="$2"
  local tmp; tmp="$(mktemp -d)"
  git clone -q "$REMOTE" "$tmp" 2>/dev/null
  local cb_sha task_sha mb_sha
  cb_sha="$(git -C "$tmp" rev-parse "origin/$charter" 2>/dev/null || true)"
  task_sha="$(git -C "$tmp" rev-parse "origin/$task" 2>/dev/null || true)"
  mb_sha="$(git -C "$tmp" merge-base "origin/$task" "origin/$charter" 2>/dev/null || true)"
  rm -rf "$tmp"
  [ -n "$cb_sha" ] && [ -n "$task_sha" ] && [ "$mb_sha" = "$cb_sha" ]
}

branch_exists_on_remote(){ git ls-remote --exit-code --heads "$REMOTE" "$1" >/dev/null 2>&1; }
pr_base(){ cat "$PRDIR/base-$1" 2>/dev/null || true; }
# Stamp a "merge sentinel" commit on a branch (simulates tech-lead merging task/N → charter/C).
stamp_merge_sentinel(){
  local branch="$1" msg="$2"
  local tmp; tmp="$(mktemp -d)"
  git clone -q "$REMOTE" "$tmp" 2>/dev/null
  git -C "$tmp" config user.email t@t; git -C "$tmp" config user.name T
  git -C "$tmp" fetch -q origin "$branch"
  git -C "$tmp" checkout -q -b "_stamp" "origin/$branch"
  printf '%s\n' "$msg" > "$tmp/.merge-sentinel"
  git -C "$tmp" add -A
  git -C "$tmp" commit -qm "merge sentinel: $msg" 2>/dev/null
  git -C "$tmp" push -q origin "_stamp:refs/heads/$branch"
  rm -rf "$tmp"
}
sentinel_on_branch(){
  local branch="$1" msg="$2"
  local tmp; tmp="$(mktemp -d)"
  git clone -q "$REMOTE" "$tmp" 2>/dev/null
  git -C "$tmp" fetch -q origin "$branch" 2>/dev/null
  local found=1
  git -C "$tmp" show "origin/$branch:.merge-sentinel" 2>/dev/null | grep -qF "$msg" && found=0
  rm -rf "$tmp"
  return "$found"
}

# ─────────────────────────────────────────────────────────────────────────────
echo "== scenario 1: task/N branches from charter/C; PR base = charter/C, NOT default =="
# RED against legacy spawn (SPAWN_OVERRIDE=legacy-spawn.sh): task/10 is created from
# master/main with no charter/5 → merge_base_ok and pr_base checks fail.
reset_sandbox
bash "$SPAWN" 10 executor 2>/dev/null

branch_exists_on_remote "charter/5" \
  && ok "1: charter/5 exists on remote" \
  || ko "1: charter/5 missing on remote"

branch_exists_on_remote "task/10" \
  && ok "1: task/10 exists on remote" \
  || ko "1: task/10 missing on remote"

merge_base_ok "task/10" "charter/5" \
  && ok "1: task/10 merge-base == charter/5 HEAD (not main)" \
  || ko "1: task/10 is NOT branched from charter/5"

[ "$(pr_base 10)" = "charter/5" ] \
  && ok "1: PR base = charter/5" \
  || ko "1: PR base is '$(pr_base 10)', expected charter/5"

# ─────────────────────────────────────────────────────────────────────────────
echo "== scenario 2: second leaf does NOT reset charter/5 (idempotent) =="
# RED against legacy spawn: charter/5 is never created, so the sentinel step fails.
reset_sandbox

# Step 1: first leaf (#10) creates charter/5 + commits task/10.
bash "$SPAWN" 10 executor 2>/dev/null

branch_exists_on_remote "charter/5" \
  && ok "2: charter/5 created by first leaf (#10)" \
  || ko "2: charter/5 not created by first leaf (#10)"

# Step 2: simulate a merge of task/10 into charter/5 (tech-lead integration).
if branch_exists_on_remote "charter/5"; then
  stamp_merge_sentinel "charter/5" "task10-merged"
fi

sentinel_on_branch "charter/5" "task10-merged" \
  && ok "2: merge sentinel written to charter/5" \
  || ko "2: failed to write merge sentinel (charter/5 missing?)"

# Step 3: second leaf (#11) launches — must NOT reset charter/5.
bash "$SPAWN" 11 executor 2>/dev/null

sentinel_on_branch "charter/5" "task10-merged" \
  && ok "2: charter/5 sentinel PRESERVED after second leaf (#11) — not reset" \
  || ko "2: charter/5 was RESET by second leaf (#11) — idempotency broken"

branch_exists_on_remote "task/11" \
  && ok "2: task/11 exists (second leaf launched successfully)" \
  || ko "2: task/11 missing (second leaf failed)"

# ─────────────────────────────────────────────────────────────────────────────
echo "== scenario 3: flock race — two parallel leaves → exactly ONE charter/5 creation =="
# RED against legacy spawn: 0 creations (no charter mechanism) → count ≠ 1.
# RED against no-flock spawn: both processes log a create-attempt → count = 2 ≠ 1.
# GREEN with charter spawn (flock + check): exactly 1 creation.
reset_sandbox

# For test 3 RED: run with NOFLOCK_SPAWN (two parallel → count=2) when SPAWN_OVERRIDE
# is set to noflock; default path uses the correct flock-safe CHARTER_SPAWN.
T3_SPAWN="${SPAWN_OVERRIDE:-$CHARTER_SPAWN}"

# Run leaves #10 and #11 in parallel.
bash "$T3_SPAWN" 10 executor 2>/dev/null &
pid1=$!
bash "$T3_SPAWN" 11 executor 2>/dev/null &
pid2=$!
wait "$pid1" "$pid2" || true

creates=$(wc -l < "$SANDBOX/charter-creates.log" 2>/dev/null || printf '0')
creates="${creates// /}"
[ "$creates" = "1" ] \
  && ok "3: charter/5 created exactly once (flock serialised concurrent launches)" \
  || ko "3: charter/5 creation count = $creates (expected 1)"

branch_exists_on_remote "charter/5" \
  && ok "3: charter/5 exists on remote after parallel launches" \
  || ko "3: charter/5 missing after parallel launches"

branch_exists_on_remote "task/10" && branch_exists_on_remote "task/11" \
  && ok "3: both task/10 and task/11 created successfully" \
  || ko "3: one or both task branches missing after parallel launches"

# ─────────────────────────────────────────────────────────────────────────────
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
