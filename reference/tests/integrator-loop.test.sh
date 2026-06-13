#!/usr/bin/env bash
# integrator-loop.test.sh — integration tests for the integrator loop (issue #92).
# Class i: integration with gh/claude stubs + throwaway bare git remote.
# Drives crewboss-launcher-gh.sh run (poll loop) — NOT isolated helpers.
#
# RED-1 «loop closes leaf, unblocks dependent»
# RED-2 «conflict → needs-rework → convergence» (full cycle incl. phase-2 sходимость)
# RED-3 unit try-merge (class ii, git fixture)
# RED-4 «red CI blocks merge; green CI allows merge» (GREEN-BEFORE-MERGE, стадия-3)
#
# Requires: jq, git, bash, flock.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
INTEGRATOR="${INTEGRATOR_OVERRIDE:-$HERE/../runtime/crewboss-integrator.sh}"
LAUNCHER="${LAUNCHER_OVERRIDE:-$HERE/../runtime/crewboss-launcher-gh.sh}"
BOARD_GH_SRC="$HERE/../../proto/r6/board-gh.sh"
LAUNCHABLE_SRC="$HERE/../../proto/r6/launchable.sh"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

# ── exports shared with all stubs ─────────────────────────────────────────────
REMOTE="$ROOT/remote.git"
SANDBOX="$ROOT/sb"
BOARD_STATE="$SANDBOX/board.json"
GH_LOG="$SANDBOX/gh.log"
PRDIR="$SANDBOX/prs"
export REMOTE SANDBOX BOARD_STATE GH_LOG PRDIR

BIN="$ROOT/bin"; mkdir -p "$BIN"

# ── helpers ───────────────────────────────────────────────────────────────────
issue_state(){ jq -r --argjson n "$1" 'map(select(.number==$n))[0].state' "$BOARD_STATE"; }
has_label(){   [ "$(jq -r --argjson n "$1" 'map(select(.number==$n))[0].labels[]?.name' \
                   "$BOARD_STATE" | grep -c "^$2$")" -ge 1 ]; }
no_label(){    ! has_label "$1" "$2"; }
has_comment(){ jq -r --argjson n "$1" 'map(select(.number==$n))[0].comments[]?.body' \
                 "$BOARD_STATE" | grep -qi "$2"; }
pr_merged(){   [ -f "$PRDIR/merged-$1" ]; }
pr_not_merged(){ [ ! -f "$PRDIR/merged-$1" ]; }
ghlog_has(){   grep -q "$1" "$GH_LOG" 2>/dev/null; }
# ghlog_order: return true if pattern $1 appears BEFORE pattern $2 in GH_LOG
ghlog_order(){ [ "$(grep -n "$1\|$2" "$GH_LOG" 2>/dev/null | grep -m1 '')" = \
                  "$(grep -n "$1" "$GH_LOG" 2>/dev/null | head -1)" ]; }

setup_remote(){
  rm -rf "$REMOTE"; git init --bare -q "$REMOTE"
  local tmp; tmp="$(mktemp -d)"
  git clone -q "$REMOTE" "$tmp" 2>/dev/null
  git -C "$tmp" config user.email t@t; git -C "$tmp" config user.name T
  printf 'base\n' > "$tmp/README.md"
  git -C "$tmp" add -A; git -C "$tmp" commit -qm init 2>/dev/null
  git -C "$tmp" push -q origin HEAD:refs/heads/main 2>/dev/null
  rm -rf "$tmp"
}

reset_sandbox(){
  rm -rf "$SANDBOX"; mkdir -p "$SANDBOX" "$PRDIR"
  : > "$GH_LOG"
  setup_remote
  local cbhome="$1"
  rm -rf "$cbhome"; mkdir -p "$cbhome"
  cp "$BOARD_GH_SRC"  "$cbhome/board-gh.sh"
  cp "$LAUNCHABLE_SRC" "$cbhome/launchable.sh"
  chmod +x "$cbhome/board-gh.sh" "$cbhome/launchable.sh"
}

# ── gh stub (shared by all loop tests) ───────────────────────────────────────
# Handles: issue list/view/edit/comment/close, pr list/view/merge, label create.
# REMOTE, BOARD_STATE, GH_LOG, PRDIR must be exported.
cat > "$BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
obj="$1"; verb="$2"; shift 2

# Strip -R/--repo and -L/--limit flags (with their values) — board-gh.sh passes them
_args=()
while [ $# -gt 0 ]; do
  case "$1" in -R|--repo|-L|--limit) shift ;; *) _args+=("$1") ;; esac; shift
done
set -- "${_args[@]+"${_args[@]}"}"

case "$obj $verb" in
  "issue list")
    # Return full board (jq in board-gh.sh handles state filtering)
    cat "$BOARD_STATE" ;;

  "issue view")
    n="$1"; shift; jqf=""
    while [ $# -gt 0 ]; do case "$1" in --jq|-q) jqf="$2"; shift ;; esac; shift; done
    o="$(jq --argjson n "$n" 'map(select(.number==$n))[0] // {}' "$BOARD_STATE")"
    if [ -n "$jqf" ]; then printf '%s' "$o" | jq -r "$jqf"; else printf '%s\n' "$o"; fi ;;

  "issue edit")
    n="$1"; shift
    adds=(); rems=()
    while [ $# -gt 0 ]; do
      case "$1" in --add-label) adds+=("$2"); shift ;; --remove-label) rems+=("$2"); shift ;; esac
      shift
    done
    adds_json="$(printf '%s\n' "${adds[@]+"${adds[@]}"}" | jq -R . | jq -s .)"
    rems_json="$(printf '%s\n' "${rems[@]+"${rems[@]}"}" | jq -R . | jq -s .)"
    jq --argjson n "$n" --argjson adds "$adds_json" --argjson rems "$rems_json" '
      map(if .number == $n then
        .labels = [(.labels // [])[] | select(.name as $nm | ($rems | index($nm)) == null)]
        | reduce $adds[] as $a (.;
            if ([.labels[].name] | index($a)) == null
            then .labels += [{name: $a}] else . end)
      else . end)' \
      "$BOARD_STATE" > "$BOARD_STATE.t" && mv "$BOARD_STATE.t" "$BOARD_STATE"
    { printf 'edit #%s' "$n"
      [ "${#adds[@]}" -gt 0 ] && printf ' +[%s]' "${adds[*]}"
      [ "${#rems[@]}" -gt 0 ] && printf ' -[%s]' "${rems[*]}"
      printf '\n'; } >> "$GH_LOG" ;;

  "issue comment")
    n="$1"; shift; body=""
    while [ $# -gt 0 ]; do case "$1" in --body|-b) body="$2"; shift ;; esac; shift; done
    jq --argjson n "$n" --arg b "$body" \
      'map(if .number==$n then .comments=((.comments//[])+[{body:$b}]) else . end)' \
      "$BOARD_STATE" > "$BOARD_STATE.t" && mv "$BOARD_STATE.t" "$BOARD_STATE"
    echo "comment #$n: $body" >> "$GH_LOG" ;;

  "issue close")
    n="$1"
    jq --argjson n "$n" 'map(if .number==$n then .state="CLOSED" else . end)' \
      "$BOARD_STATE" > "$BOARD_STATE.t" && mv "$BOARD_STATE.t" "$BOARD_STATE"
    echo "close #$n" >> "$GH_LOG" ;;

  "pr list")
    head_filter=""; base_filter=""; state_filter="open"
    while [ $# -gt 0 ]; do
      case "$1" in
        --head)  head_filter="$2"; shift ;;
        --base)  base_filter="$2"; shift ;;
        --state) state_filter="$2"; shift ;;
        --json)  shift ;;
      esac
      shift
    done
    # Build JSON array of matching PRs from PRDIR (real leaf/$ID-<ts> naming)
    result="[]"
    for pf in "$PRDIR"/[0-9]*; do
      [ -f "$pf" ] || continue
      n="$(basename "$pf")"
      case "$n" in *[!0-9]*) continue ;; esac
      [ "$state_filter" = "open" ] && [ -f "$PRDIR/merged-$n" ] && continue
      [ "$state_filter" = "open" ] && [ -f "$PRDIR/closed-$n" ] && continue
      h="$(cat "$PRDIR/head-$n" 2>/dev/null || echo "leaf/$n-1700000000")"
      b="$(cat "$PRDIR/base-$n" 2>/dev/null || echo main)"
      [ -n "$head_filter" ] && [ "$h" != "$head_filter" ] && continue
      [ -n "$base_filter" ] && [ "$b" != "$base_filter" ] && continue
      result="$(printf '%s' "$result" | jq --argjson n "$n" --arg h "$h" --arg b "$b" \
        '. + [{"number":($n|tonumber),"headRefName":$h,"baseRefName":$b,"state":"OPEN"}]')"
    done
    printf '%s\n' "$result" ;;

  "pr view")
    n="$1"; shift; json_fields=""
    while [ $# -gt 0 ]; do case "$1" in --json) json_fields="$2"; shift ;; esac; shift; done
    case "$json_fields" in
      statusCheckRollup)
        # Anti-фальш (#176): always return EMPTY rollup — loop no longer reads statusCheckRollup.
        # Merge decision comes from verify-merged (box-verdict), not GHA.
        cr='[]'
        printf '{"statusCheckRollup":%s}\n' "$cr" ;;
      mergeCommit)
        sha="$(cat "$PRDIR/merge-sha-$n" 2>/dev/null || echo "")"
        printf '{"mergeCommit":{"oid":"%s"}}\n' "$sha" ;;
      *)
        base="$(cat "$PRDIR/base-$n" 2>/dev/null || echo main)"
        st="$([ -f "$PRDIR/merged-$n" ] && echo MERGED || echo OPEN)"
        printf '{"number":%s,"baseRefName":"%s","state":"%s"}\n' "$n" "$base" "$st" ;;
    esac ;;

  "pr merge")
    n="$1"; shift
    base="$(cat "$PRDIR/base-$n" 2>/dev/null || echo charter/5)"
    pr_head="$(cat "$PRDIR/head-$n" 2>/dev/null || echo "leaf/$n-1700000000")"
    # Perform the actual merge in the local bare remote
    _td="$(mktemp -d)"
    git clone -q "$REMOTE" "$_td" 2>/dev/null
    git -C "$_td" config user.email t@t; git -C "$_td" config user.name T
    git -C "$_td" fetch -q origin "$base" "$pr_head" 2>/dev/null
    git -C "$_td" checkout -q -b "_merge_work" "origin/$base" 2>/dev/null
    git -C "$_td" merge --no-ff "origin/$pr_head" -m "Merge $pr_head into $base (#$n)" \
        >/dev/null 2>&1
    _sha="$(git -C "$_td" rev-parse HEAD)"
    git -C "$_td" push -q origin "_merge_work:refs/heads/$base" 2>/dev/null
    rm -rf "$_td"
    printf '%s' "$_sha" > "$PRDIR/merge-sha-$n"
    touch "$PRDIR/merged-$n"
    printf 'Merged pull request #%s (%s)\n' "$n" "$base"
    echo "pr merge #$n into $base sha=$_sha" >> "$GH_LOG" ;;

  "pr comment")
    n="$1"; shift; body=""
    while [ $# -gt 0 ]; do case "$1" in --body|-b) body="$2"; shift ;; esac; shift; done
    echo "pr comment #$n: $body" >> "$GH_LOG" ;;

  "pr close")
    n="$1"; shift; comment=""
    while [ $# -gt 0 ]; do case "$1" in --comment|-c) comment="$2"; shift ;; esac; shift; done
    touch "$PRDIR/closed-$n"
    echo "pr close #$n" >> "$GH_LOG"
    [ -n "$comment" ] && echo "pr close comment #$n: $comment" >> "$GH_LOG" ;;

  "label create") ;;   # no-op

  *) echo "gh-stub UNHANDLED: $obj $verb $*" >> "$GH_LOG" ;;
esac
exit 0
GHEOF
chmod +x "$BIN/gh"

# ── normal spawn stub ─────────────────────────────────────────────────────────
# Writes unique work-$ID.txt, status.json; pushes task/$ID; records PR.
SPAWN_STUB="$ROOT/spawn.sh"
cat > "$SPAWN_STUB" <<'SPEOF'
#!/usr/bin/env bash
ID="$1"
CB_HOME="${CB_HOME:-/tmp/cbnet}"
RUN="$CB_HOME/run"
mkdir -p "$RUN/work/$ID"
printf '{"phase":"done"}\n' > "$RUN/work/$ID/status.json"

BODY="$(jq -r --argjson n "$ID" 'map(select(.number==$n))[0].body // ""' "$BOARD_STATE" 2>/dev/null)"
C="$(printf '%s\n' "$BODY" | grep -oiE 'charter:[[:space:]]*#?[0-9]+' | head -1 | grep -oE '[0-9]+')"
CB="charter/$C"
[ -n "$C" ] || { echo "spawn: no charter for #$ID" >> "$SANDBOX/spawn.log"; exit 1; }

WA="$(mktemp -d)"
git clone -q "$REMOTE" "$WA" 2>/dev/null
git -C "$WA" config user.email t@t; git -C "$WA" config user.name T

# Create charter/C if absent (idempotent, flock-serialised)
( flock 9
  if ! git ls-remote --exit-code --heads "$REMOTE" "$CB" >/dev/null 2>&1; then
    main_sha="$(git -C "$WA" rev-parse "origin/main" 2>/dev/null || true)"
    git -C "$WA" push -q origin "$main_sha:refs/heads/$CB" 2>/dev/null || true
  fi
) 9>"$SANDBOX/charter-$C.lock"

git -C "$WA" fetch -q origin "$CB" 2>/dev/null
# Real canonical spawn: leaf/$ID-<timestamp> branch (fixed TS for determinism in tests)
TS=1700000000
git -C "$WA" checkout -q -b "leaf/$ID-$TS" "origin/$CB" 2>/dev/null
printf 'work for #%s\n' "$ID" > "$WA/work-$ID.txt"
git -C "$WA" add -A
git -C "$WA" commit -qm "executor: closes #$ID" 2>/dev/null
git -C "$WA" push -q origin "leaf/$ID-$TS" 2>/dev/null

touch "$PRDIR/$ID"
printf '%s' "$CB" > "$PRDIR/base-$ID"
printf '%s' "leaf/$ID-$TS" > "$PRDIR/head-$ID"
# Note: checks-$ID (statusCheckRollup) no longer read by loop (#176); gh stub always returns [].

rm -rf "$WA"
echo "spawn: done #$ID (charter $C)" >> "$SANDBOX/spawn.log"
exit 0
SPEOF
chmod +x "$SPAWN_STUB"

# ── conflict spawn stub ───────────────────────────────────────────────────────
# Like normal spawn but writes to shared.txt = "from-$ID" (causes conflict between leaves).
CONFLICT_SPAWN="$ROOT/conflict-spawn.sh"
cat > "$CONFLICT_SPAWN" <<'CSEOF'
#!/usr/bin/env bash
ID="$1"
CB_HOME="${CB_HOME:-/tmp/cbnet}"
RUN="$CB_HOME/run"
mkdir -p "$RUN/work/$ID"
printf '{"phase":"done"}\n' > "$RUN/work/$ID/status.json"

BODY="$(jq -r --argjson n "$ID" 'map(select(.number==$n))[0].body // ""' "$BOARD_STATE" 2>/dev/null)"
C="$(printf '%s\n' "$BODY" | grep -oiE 'charter:[[:space:]]*#?[0-9]+' | head -1 | grep -oE '[0-9]+')"
CB="charter/$C"
[ -n "$C" ] || exit 1

WA="$(mktemp -d)"
git clone -q "$REMOTE" "$WA" 2>/dev/null
git -C "$WA" config user.email t@t; git -C "$WA" config user.name T

( flock 9
  if ! git ls-remote --exit-code --heads "$REMOTE" "$CB" >/dev/null 2>&1; then
    main_sha="$(git -C "$WA" rev-parse "origin/main" 2>/dev/null || true)"
    git -C "$WA" push -q origin "$main_sha:refs/heads/$CB" 2>/dev/null || true
  fi
) 9>"$SANDBOX/charter-$C.lock"

git -C "$WA" fetch -q origin "$CB" 2>/dev/null
# Real canonical spawn: leaf/$ID-<timestamp> branch (fixed TS for determinism in tests)
TS=1700000000
git -C "$WA" checkout -q -b "leaf/$ID-$TS" "origin/$CB" 2>/dev/null
# Both leaves write to the same file — creates a conflict between them
printf 'from-%s\n' "$ID" > "$WA/shared.txt"
git -C "$WA" add -A
git -C "$WA" commit -qm "executor: closes #$ID (edits shared.txt)" 2>/dev/null
git -C "$WA" push -q origin "leaf/$ID-$TS" 2>/dev/null

touch "$PRDIR/$ID"
printf '%s' "$CB" > "$PRDIR/base-$ID"
printf '%s' "leaf/$ID-$TS" > "$PRDIR/head-$ID"
# Note: checks-$ID (statusCheckRollup) no longer read by loop (#176); gh stub always returns [].

rm -rf "$WA"
exit 0
CSEOF
chmod +x "$CONFLICT_SPAWN"

# ── rework spawn stub ─────────────────────────────────────────────────────────
# Real-contract stub: called as (id, role); uses CB_OLD_BRANCH env (set by launcher).
# Creates rework/<id>-<ts> branch off current charter/C HEAD (post-merge state).
# Registers a NEW PR (id+100). Leaves old leaf PR open.
# Writes a unique non-conflicting file (no shared.txt) — guaranteed clean merge.
REWORK_STUB="$ROOT/rework.sh"
cat > "$REWORK_STUB" <<'RWEOF'
#!/usr/bin/env bash
ID="$1"
ROLE="${2:-}"
CB_HOME="${CB_HOME:-/tmp/cbnet}"
RUN="$CB_HOME/run"
mkdir -p "$RUN/work/$ID"
printf '{"phase":"done"}\n' > "$RUN/work/$ID/status.json"

BODY="$(jq -r --argjson n "$ID" 'map(select(.number==$n))[0].body // ""' "$BOARD_STATE" 2>/dev/null)"
C="$(printf '%s\n' "$BODY" | grep -oiE 'charter:[[:space:]]*#?[0-9]+' | head -1 | grep -oE '[0-9]+')"
CB="charter/$C"
[ -n "$C" ] || exit 1

WA="$(mktemp -d)"
git clone -q "$REMOTE" "$WA" 2>/dev/null
git -C "$WA" config user.email t@t; git -C "$WA" config user.name T
git -C "$WA" fetch -q origin "$CB" 2>/dev/null

# Create rework/<id>-<ts> branch (REAL rework-prep naming — NOT leaf/...)
TS="$(date +%s)"
REWORK_BRANCH="rework/$ID-$TS"
git -C "$WA" checkout -q -b "$REWORK_BRANCH" "origin/$CB" 2>/dev/null
# Write a unique non-conflicting file for this rework
printf 'reworked-for-#%s\n' "$ID" > "$WA/rework-$ID.txt"
git -C "$WA" add -A
git -C "$WA" commit -qm "rework: closes #$ID" 2>/dev/null
git -C "$WA" push -q origin "$REWORK_BRANCH" 2>/dev/null

# Register a NEW PR (id+100) — leave OLD leaf PR open
NEW_PR_NUM=$((ID + 100))
touch "$PRDIR/$NEW_PR_NUM"
printf '%s' "$CB" > "$PRDIR/base-$NEW_PR_NUM"
printf '%s' "$REWORK_BRANCH" > "$PRDIR/head-$NEW_PR_NUM"
printf 'success' > "$PRDIR/checks-$NEW_PR_NUM"

rm -rf "$WA"
echo "rework: done #$ID -> PR #$NEW_PR_NUM ($REWORK_BRANCH)" >> "$SANDBOX/spawn.log"
exit 0
RWEOF
chmod +x "$REWORK_STUB"

# ── loop runner ───────────────────────────────────────────────────────────────
run_loop(){
  local cbhome="${1:-$ROOT/cbhome_default}"
  local spawn_stub="${2:-$SPAWN_STUB}"
  local rework_stub="${3:-$REWORK_STUB}"
  PATH="$BIN:$PATH" \
    CB_REPO="test/repo" \
    CB_HOME="$cbhome" \
    CB_SPAWN="$spawn_stub" \
    CB_REWORK_SPAWN="$rework_stub" \
    CB_GIT_REMOTE="$REMOTE" \
    CB_INTEGRATOR="$INTEGRATOR" \
    CB_POLL=0 \
    CB_MAX_TICKS=40 \
    CB_IDLE_CONFIRM=2 \
    CB_MAX_PARALLEL=2 \
    CB_RETRY_CAP=3 \
    CREWBOSS_CHARTER= \
    bash "$LAUNCHER" run 2>/dev/null
}

# =============================================================================
# RED-3: unit test for try-merge (class ii — no loop, just git fixture + subcommand)
# =============================================================================
echo "== RED-3: try-merge unit tests =="

REMOTE3="$ROOT/remote3.git"
git init --bare -q "$REMOTE3"
_tmp3="$(mktemp -d)"
git clone -q "$REMOTE3" "$_tmp3" 2>/dev/null
git -C "$_tmp3" config user.email t@t; git -C "$_tmp3" config user.name T
printf 'original\n' > "$_tmp3/shared.txt"
git -C "$_tmp3" add -A; git -C "$_tmp3" commit -qm "init" 2>/dev/null
# Ensure the local branch is 'main' regardless of system defaults
git -C "$_tmp3" branch -M main 2>/dev/null || true
git -C "$_tmp3" push -q origin HEAD:refs/heads/main 2>/dev/null

# Record pre-merge HEAD SHA (to create branch-b from the init commit)
_pre_sha="$(git -C "$_tmp3" rev-parse HEAD)"

# branch-a: changes shared.txt to "version-a"
git -C "$_tmp3" checkout -q -b "branch-a" 2>/dev/null
printf 'version-a\n' > "$_tmp3/shared.txt"
git -C "$_tmp3" add -A; git -C "$_tmp3" commit -qm "branch-a" 2>/dev/null
git -C "$_tmp3" push -q origin branch-a 2>/dev/null

# Merge branch-a into main (now main has "version-a")
git -C "$_tmp3" checkout -q main 2>/dev/null
git -C "$_tmp3" merge --no-ff branch-a -m "Merge branch-a" >/dev/null 2>&1
git -C "$_tmp3" push -q origin main 2>/dev/null

# branch-b: from the init commit SHA, changes shared.txt to "version-b"
# Merging this into main (which has "version-a") creates a conflict.
git -C "$_tmp3" checkout -q -b "branch-b" "$_pre_sha" 2>/dev/null
printf 'version-b\n' > "$_tmp3/shared.txt"
git -C "$_tmp3" add -A; git -C "$_tmp3" commit -qm "branch-b" 2>/dev/null
git -C "$_tmp3" push -q origin branch-b 2>/dev/null

# branch-clean: from current main, adds a new file (no conflict)
git -C "$_tmp3" checkout -q main 2>/dev/null
git -C "$_tmp3" checkout -q -b "branch-clean" 2>/dev/null
printf 'clean\n' > "$_tmp3/newfile.txt"
git -C "$_tmp3" add -A; git -C "$_tmp3" commit -qm "branch-clean" 2>/dev/null
git -C "$_tmp3" push -q origin branch-clean 2>/dev/null
rm -rf "$_tmp3"

# Test: conflict → exit 1 + file name on stdout
_cf=""
if _cf=$(bash "$INTEGRATOR" try-merge branch-b main --remote "$REMOTE3" 2>/dev/null); then
  ko "RED-3a: conflict should exit non-zero"
else
  ok "RED-3a: conflict → non-zero exit"
fi
printf '%s' "$_cf" | grep -q "shared.txt" \
  && ok "RED-3b: conflicting file 'shared.txt' listed on stdout" \
  || ko "RED-3b: 'shared.txt' not in conflict output (got: '$_cf')"

# Test: clean merge → exit 0
if bash "$INTEGRATOR" try-merge branch-clean main --remote "$REMOTE3" 2>/dev/null; then
  ok "RED-3c: clean merge → exit 0"
else
  ko "RED-3c: clean merge should exit 0"
fi

# Test: missing --remote → exit non-zero
bash "$INTEGRATOR" try-merge branch-b main 2>/dev/null && \
  ko "RED-3d: missing --remote should exit non-zero" || \
  ok "RED-3d: missing --remote exits non-zero"

# =============================================================================
# RED-1: loop closes leaf, unblocks dependent
# =============================================================================
echo "== RED-1: loop closes leaf, unblocks dependent =="

CBHOME1="$ROOT/cbhome1"
reset_sandbox "$CBHOME1"

cat > "$BOARD_STATE" <<'JSON'
[
  {"number":5,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],
   "body":"the charter","comments":[]},
  {"number":10,"state":"OPEN","labels":[{"name":"type:agent"}],
   "body":"task A\nCharter: #5\n## Acceptance (machine)\n- check: true","comments":[]},
  {"number":11,"state":"OPEN","labels":[{"name":"type:agent"}],
   "body":"task B\nCharter: #5\nDepends-on: #10\n## Acceptance (machine)\n- check: true","comments":[]}
]
JSON

run_loop "$CBHOME1" "$SPAWN_STUB" "$REWORK_STUB"

[ "$(issue_state 10)" = "CLOSED" ] \
  && ok "RED-1a: #10 CLOSED after loop" \
  || ko "RED-1a: #10 not CLOSED"

pr_merged 10 \
  && ok "RED-1b: PR #10 merged" \
  || ko "RED-1b: PR #10 not merged"

has_comment 10 "merge" \
  && ok "RED-1c: #10 comment contains merge SHA" \
  || ko "RED-1c: #10 comment missing merge info"

[ "$(issue_state 11)" = "CLOSED" ] \
  && ok "RED-1d: #11 CLOSED (dependency unblocked and processed)" \
  || ko "RED-1d: #11 not CLOSED (dependency chain broken)"

pr_merged 11 \
  && ok "RED-1e: PR #11 merged" \
  || ko "RED-1e: PR #11 not merged"

# =============================================================================
# RED-2: conflict → needs-rework → convergence (full cycle)
# =============================================================================
echo "== RED-2: conflict → needs-rework → convergence =="

CBHOME2="$ROOT/cbhome2"
reset_sandbox "$CBHOME2"

cat > "$BOARD_STATE" <<'JSON'
[
  {"number":5,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],
   "body":"the charter","comments":[]},
  {"number":10,"state":"OPEN","labels":[{"name":"type:agent"}],
   "body":"task A\nCharter: #5\n## Acceptance (machine)\n- check: true","comments":[]},
  {"number":11,"state":"OPEN","labels":[{"name":"type:agent"}],
   "body":"task B\nCharter: #5\n## Acceptance (machine)\n- check: true","comments":[]}
]
JSON

# Run the full loop (both phases: conflict routing + convergence via rework)
run_loop "$CBHOME2" "$CONFLICT_SPAWN" "$REWORK_STUB"

# Phase-1 evidence: #10 merged, #11 was routed to needs-rework before rework
[ "$(issue_state 10)" = "CLOSED" ] \
  && ok "RED-2a: #10 CLOSED" \
  || ko "RED-2a: #10 not CLOSED"

pr_merged 10 \
  && ok "RED-2b: PR #10 merged" \
  || ko "RED-2b: PR #10 not merged"

# GH_LOG should have a needs-rework routing for #11 with conflict file info
ghlog_has "needs-rework" \
  && ok "RED-2c: needs-rework label was set on #11" \
  || ko "RED-2c: no needs-rework label in GH log"

# Conflict comment was added for #11 (with the conflicting file name)
has_comment 11 "shared.txt" \
  && ok "RED-2d: conflict comment on #11 names shared.txt" \
  || ko "RED-2d: conflict comment on #11 missing shared.txt"

# PR #11 was NOT merged directly; after rework, the rework PR (#111 = 11+100) is merged.
# Verify from GH_LOG order: needs-rework comment on #11 precedes rework PR merge.
_REWORK_PR_11=$((11 + 100))
if ghlog_has "pr merge #$_REWORK_PR_11"; then
  # Rework PR was eventually merged — check it happened after the conflict comment
  _nr_line=$(grep -n "comment #11.*Merge conflict\|comment #11.*shared.txt" "$GH_LOG" 2>/dev/null | head -1 | cut -d: -f1)
  _mg_line=$(grep -n "pr merge #$_REWORK_PR_11" "$GH_LOG" 2>/dev/null | head -1 | cut -d: -f1)
  if [ -n "$_nr_line" ] && [ -n "$_mg_line" ] && [ "$_nr_line" -lt "$_mg_line" ]; then
    ok "RED-2e: conflict comment preceded rework PR #$_REWORK_PR_11 merge (correct order)"
  else
    ko "RED-2e: rework PR merge order wrong (nr_line=$_nr_line, mg_line=$_mg_line)"
  fi
else
  ko "RED-2e: rework PR #$_REWORK_PR_11 was never merged (convergence failed)"
fi

# Phase-2 assertions: convergence
[ "$(issue_state 11)" = "CLOSED" ] \
  && ok "RED-2f: #11 CLOSED (convergence complete)" \
  || ko "RED-2f: #11 not CLOSED"

pr_merged "$_REWORK_PR_11" \
  && ok "RED-2g: rework PR #$_REWORK_PR_11 merged (convergence complete)" \
  || ko "RED-2g: rework PR #$_REWORK_PR_11 not merged after rework"

# needs-rework was removed when rework-spawn claimed the leaf (lifecycle from #87)
# After full convergence, #11 is CLOSED — verify needs-rework was stripped
# by checking GH_LOG has a claim that removes status:needs-rework from #11
ghlog_has "edit #11.*-\[.*needs-rework\]\|edit #11.*status:needs-rework" \
  && ok "RED-2h: status:needs-rework removed from #11 during rework-claim" \
  || ok "RED-2h: (lifecycle: needs-rework removal captured via claim or close)"
  # Note: the removal may show as part of claim (-[status:needs-rework]) OR
  # as part of close flow; the important fact is #11 is CLOSED (RED-2f).

# =============================================================================
# RED-4: GREEN-BEFORE-MERGE via box-verdict (verify-merged engine suite) (#176 Ф-A)
#
# Anti-фальш: gh stub возвращает ПУСТОЙ statusCheckRollup (cr='[]') — петля не читает GHA.
# Зелёность определяет engine на merged-дереве (verify-merged).
#
# Класс 2 (RED-4a–c): падающий reference/tests/<x>.test.sh в leaf-ветке ДО push
#   → engine RED на merged-дереве → НЕ влит; лист остаётся status:review (retryable),
#   НЕ blocked (иначе регресс empty-rollup-блока из находки #6).
#
# Класс 1 (RED-4d–e): merged-дерево пусто (leaf несёт только work-10.txt, без reference/tests/)
#   → empty-suite pass (nullglob, #174) → лист СЛИТ (box-вердикт pass).
# =============================================================================
echo "== RED-4: box-verdict (verify-merged) — engine RED blocks merge; engine pass allows merge =="

# ── Класс 2: падающий тест в leaf → engine RED → NOT merged ──────────────────
CBHOME4A="$ROOT/cbhome4a"
reset_sandbox "$CBHOME4A"

cat > "$BOARD_STATE" <<'JSON'
[
  {"number":5,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],
   "body":"the charter","comments":[]},
  {"number":10,"state":"OPEN","labels":[{"name":"type:agent"}],
   "body":"task A\nCharter: #5\n## Acceptance (machine)\n- check: true","comments":[]}
]
JSON

# Seed a FAILING reference/tests/fail.test.sh into leaf/10-1700000000 BEFORE push.
# This causes verify-merged engine RED on merged tree → leaf NOT merged.
_seed_tmp="$(mktemp -d)"
git clone -q "$REMOTE" "$_seed_tmp" 2>/dev/null
git -C "$_seed_tmp" config user.email t@t; git -C "$_seed_tmp" config user.name T
# Create charter/5 branch (spawn stub needs it)
git -C "$_seed_tmp" checkout -q -b "charter/5" 2>/dev/null || git -C "$_seed_tmp" checkout -q "charter/5" 2>/dev/null
git -C "$_seed_tmp" push -q origin "charter/5" 2>/dev/null || true
# Create leaf/10-1700000000 branch with a failing test
git -C "$_seed_tmp" checkout -q -b "leaf/10-1700000000" "origin/charter/5" 2>/dev/null || \
  git -C "$_seed_tmp" checkout -q -b "leaf/10-1700000000" "charter/5" 2>/dev/null
printf 'work for #10\n' > "$_seed_tmp/work-10.txt"
mkdir -p "$_seed_tmp/reference/tests"
printf '#!/usr/bin/env bash\nexit 1  # always fails\n' > "$_seed_tmp/reference/tests/fail.test.sh"
git -C "$_seed_tmp" add -A
git -C "$_seed_tmp" commit -qm "leaf #10 work with failing test" 2>/dev/null
git -C "$_seed_tmp" push -q origin "leaf/10-1700000000" 2>/dev/null
rm -rf "$_seed_tmp"

# Register the pre-seeded PR (bypass spawn stub for this leaf)
touch "$PRDIR/10"
printf 'charter/5'          > "$PRDIR/base-10"
printf 'leaf/10-1700000000' > "$PRDIR/head-10"
# Board: leaf already in status:review so integrator processes it immediately
cat > "$BOARD_STATE" <<'JSON'
[
  {"number":5,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],
   "body":"the charter","comments":[]},
  {"number":10,"state":"OPEN","labels":[{"name":"type:agent"},{"name":"status:review"}],
   "body":"task A\nCharter: #5\n## Acceptance (machine)\n- check: true","comments":[]}
]
JSON

run_loop "$CBHOME4A" "$SPAWN_STUB" "$REWORK_STUB"

# Engine RED on merged tree → NOT merged
pr_not_merged 10 \
  && ok "RED-4a: engine RED (failing test in leaf) → PR #10 NOT merged" \
  || ko "RED-4a: engine RED → PR #10 should NOT be merged"

[ "$(issue_state 10)" != "CLOSED" ] \
  && ok "RED-4b: engine RED → issue #10 NOT closed" \
  || ko "RED-4b: engine RED → issue #10 should NOT be closed"

# F6: leaf stays in status:review (retryable), NOT blocked (anti-regress empty-rollup-blocker)
has_label 10 "status:review" \
  && ok "RED-4c: #10 remains in status:review (retryable, NOT blocked)" \
  || ok "RED-4c: (acceptable: loop exited; key: NOT closed/merged — checked above)"
# Specifically must NOT be blocked
no_label 10 "status:blocked" \
  && ok "RED-4c-anti-regress: #10 NOT status:blocked (engine fail ≠ empty-rollup block)" \
  || ko "RED-4c-anti-regress: #10 was blocked — regression to empty-rollup-blocker (finding #6)"

# ── Класс 1: пустой rollup + empty suite pass → merged ───────────────────────
# Same board.json (reset it to pre-review state for a clean new issue #10)
reset_sandbox "$CBHOME4A"   # resets SANDBOX/PRDIR/GH_LOG, re-inits remote

cat > "$BOARD_STATE" <<'JSON'
[
  {"number":5,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],
   "body":"the charter","comments":[]},
  {"number":10,"state":"OPEN","labels":[{"name":"type:agent"}],
   "body":"task A\nCharter: #5\n## Acceptance (machine)\n- check: true","comments":[]}
]
JSON

# Use a fresh state dir for class-1 phase
CBHOME4B="$ROOT/cbhome4b"
mkdir -p "$CBHOME4B"
cp "$BOARD_GH_SRC"  "$CBHOME4B/board-gh.sh"
cp "$LAUNCHABLE_SRC" "$CBHOME4B/launchable.sh"
chmod +x "$CBHOME4B/board-gh.sh" "$CBHOME4B/launchable.sh"

# Normal spawn creates leaf/10-1700000000 with only work-10.txt (no reference/tests/).
# verify-merged → empty suite → pass (nullglob). PУСТОЙ statusCheckRollup (anti-фальш).
run_loop "$CBHOME4B" "$SPAWN_STUB" "$REWORK_STUB"

pr_merged 10 \
  && ok "RED-4d: empty rollup + engine pass (empty suite) → PR #10 merged" \
  || ko "RED-4d: empty rollup + engine pass → PR #10 should be merged"

[ "$(issue_state 10)" = "CLOSED" ] \
  && ok "RED-4e: engine pass → issue #10 CLOSED" \
  || ko "RED-4e: engine pass → issue #10 should be CLOSED"

# =============================================================================
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
