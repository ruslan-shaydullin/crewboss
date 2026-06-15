#!/usr/bin/env bash
# rework-contract.test.sh — rework-prep argument contract and integrator rework-naming fix.
# Issue #115.
#
# RED-a: full integration — honest rework-stub (id,role + CB_OLD_BRANCH check);
#        integrator picks rework/<id>-* PR, merges it, closes old leaf PR with comment.
# RED-b: unit rework-prep.sh — called as (id,role) with CB_OLD_BRANCH set;
#        task.prompt must NOT contain "origin/executor"; mode selected by CB_OLD_BRANCH.
#
# Requires: jq, git, bash, flock.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
INTEGRATOR="${INTEGRATOR_OVERRIDE:-$HERE/../runtime/crewboss-integrator.sh}"
LAUNCHER="${LAUNCHER_OVERRIDE:-$HERE/../runtime/crewboss-launcher-gh.sh}"
REWORK_PREP="${REWORK_PREP_OVERRIDE:-$HERE/../runtime/rework-prep.sh}"
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
issue_state(){  jq -r --argjson n "$1" 'map(select(.number==$n))[0].state' "$BOARD_STATE"; }
pr_merged(){    [ -f "$PRDIR/merged-$1" ]; }
pr_closed(){    [ -f "$PRDIR/closed-$1" ]; }
pr_not_merged(){ [ ! -f "$PRDIR/merged-$1" ]; }
ghlog_has(){    grep -q "$1" "$GH_LOG" 2>/dev/null; }

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

# ── gh stub (full-featured: issue + pr including close/comment) ───────────────
cat > "$BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
obj="$1"; verb="$2"; shift 2

_args=()
while [ $# -gt 0 ]; do
  case "$1" in -R|--repo|-L|--limit) shift ;; *) _args+=("$1") ;; esac; shift
done
set -- "${_args[@]+"${_args[@]}"}"

case "$obj $verb" in
  "issue list")
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
        status="$(cat "$PRDIR/checks-$n" 2>/dev/null || echo success)"
        case "$status" in
          success) cr='[{"conclusion":"SUCCESS","status":"COMPLETED"}]' ;;
          failure) cr='[{"conclusion":"FAILURE","status":"COMPLETED"}]' ;;
          pending) cr='[{"conclusion":null,"status":"IN_PROGRESS"}]' ;;
          *)       cr='[]' ;;
        esac
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

  "label create") ;;

  *) echo "gh-stub UNHANDLED: $obj $verb $*" >> "$GH_LOG" ;;
esac
exit 0
GHEOF
chmod +x "$BIN/gh"

# ── conflict spawn stub ───────────────────────────────────────────────────────
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
TS=1700000000
git -C "$WA" checkout -q -b "leaf/$ID-$TS" "origin/$CB" 2>/dev/null
printf 'from-%s\n' "$ID" > "$WA/shared.txt"
git -C "$WA" add -A
git -C "$WA" commit -qm "executor: closes #$ID (edits shared.txt)" 2>/dev/null
git -C "$WA" push -q origin "leaf/$ID-$TS" 2>/dev/null

touch "$PRDIR/$ID"
printf '%s' "$CB" > "$PRDIR/base-$ID"
printf '%s' "leaf/$ID-$TS" > "$PRDIR/head-$ID"
[ -f "$PRDIR/checks-$ID" ] || printf 'success' > "$PRDIR/checks-$ID"

rm -rf "$WA"
exit 0
CSEOF
chmod +x "$CONFLICT_SPAWN"

# ── rework stub (REAL CONTRACT: CB_OLD_BRANCH checked; rework/<id>-<ts>; NEW PR) ──
# Called as rework.sh <id> <role> with CB_OLD_BRANCH exported by launcher.
# Asserts CB_OLD_BRANCH is non-empty (exits with error on violation — makes RED-a red).
# Creates rework/<id>-<ts> branch and a NEW PR (id+100). Leaves old leaf PR open.
REWORK_STUB="$ROOT/rework.sh"
cat > "$REWORK_STUB" <<'RWEOF'
#!/usr/bin/env bash
ID="$1"
ROLE="${2:-}"

# CONTRACT ASSERT: CB_OLD_BRANCH must be set by the launcher
if [ -z "${CB_OLD_BRANCH:-}" ]; then
  echo "rework-stub CONTRACT ERROR: CB_OLD_BRANCH not set for #$ID (role=$ROLE)" \
    >> "$SANDBOX/spawn.log"
  exit 1
fi

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
printf 'reworked-for-#%s\n' "$ID" > "$WA/rework-$ID.txt"
git -C "$WA" add -A
git -C "$WA" commit -qm "rework: closes #$ID" 2>/dev/null
git -C "$WA" push -q origin "$REWORK_BRANCH" 2>/dev/null

# Register a NEW PR (id+100) — leave OLD leaf PR open (don't touch it)
NEW_PR_NUM=$((ID + 100))
touch "$PRDIR/$NEW_PR_NUM"
printf '%s' "$CB" > "$PRDIR/base-$NEW_PR_NUM"
printf '%s' "$REWORK_BRANCH" > "$PRDIR/head-$NEW_PR_NUM"
printf 'success' > "$PRDIR/checks-$NEW_PR_NUM"

rm -rf "$WA"
echo "rework: done #$ID -> PR #$NEW_PR_NUM ($REWORK_BRANCH) CB_OLD_BRANCH=$CB_OLD_BRANCH" \
  >> "$SANDBOX/spawn.log"
exit 0
RWEOF
chmod +x "$REWORK_STUB"

# ── loop runner ───────────────────────────────────────────────────────────────
run_loop(){
  local cbhome="${1:-$ROOT/cbhome_default}"
  local spawn_stub="${2:-$CONFLICT_SPAWN}"
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
    bash "$LAUNCHER" run 2>/dev/null
}

# =============================================================================
# RED-a: full integration — real rework contract (CB_OLD_BRANCH + rework/<id>-*)
# =============================================================================
echo "== RED-a: full rework contract (CB_OLD_BRANCH + rework/<id>-* naming) =="

CBHOME_A="$ROOT/cbhome_a"
reset_sandbox "$CBHOME_A"

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

run_loop "$CBHOME_A" "$CONFLICT_SPAWN" "$REWORK_STUB"

# Both leaves should be CLOSED after convergence
[ "$(issue_state 10)" = "CLOSED" ] \
  && ok "RED-a-1: #10 CLOSED" \
  || ko "RED-a-1: #10 not CLOSED"

[ "$(issue_state 11)" = "CLOSED" ] \
  && ok "RED-a-2: #11 CLOSED" \
  || ko "RED-a-2: #11 not CLOSED"

# The conflicting leaf (deterministically #11 — processed second by integrator) gets
# a rework PR (id+100 = 111); the rework PR must have been merged by the integrator.
_REWORK_PR_11=$((11 + 100))
pr_merged "$_REWORK_PR_11" \
  && ok "RED-a-3: rework PR #$_REWORK_PR_11 (rework/<id>-*) merged by integrator" \
  || ko "RED-a-3: rework PR #$_REWORK_PR_11 not merged — integrator missed rework/<id>-* naming"

# The old leaf PR #11 must NOT have been merged (it's superseded by rework)
pr_not_merged 11 \
  && ok "RED-a-4: old leaf PR #11 NOT merged (correctly superseded)" \
  || ko "RED-a-4: old leaf PR #11 wrongly merged"

# The old leaf PR #11 must have been closed with "superseded by rework" comment
pr_closed 11 \
  && ok "RED-a-5: old leaf PR #11 closed (superseded by rework)" \
  || ko "RED-a-5: old leaf PR #11 not closed after rework merge"

ghlog_has "superseded by rework" \
  && ok "RED-a-6: 'superseded by rework' comment logged for old leaf PR" \
  || ko "RED-a-6: 'superseded by rework' comment not found in GH log"

# CB_OLD_BRANCH contract: spawn.log must NOT contain CONTRACT ERROR
if grep -q "CONTRACT ERROR" "$SANDBOX/spawn.log" 2>/dev/null; then
  ko "RED-a-7: CB_OLD_BRANCH was NOT set when rework-stub was called (launcher bug)"
else
  ok "RED-a-7: CB_OLD_BRANCH correctly set by launcher for rework-stub"
fi

# Conflict routing: #11 must have received a needs-rework label (conflict detected)
ghlog_has "needs-rework" \
  && ok "RED-a-8: needs-rework routing was triggered for conflicting leaf" \
  || ko "RED-a-8: needs-rework routing not found in GH log"

# =============================================================================
# RED-b: unit rework-prep.sh — argument contract (CB_OLD_BRANCH, not $2)
# =============================================================================
echo "== RED-b: rework-prep.sh argument contract (CB_OLD_BRANCH, not \$2) =="

CBHOME_B="$ROOT/cbhome_b"
mkdir -p "$CBHOME_B"

# Minimal gh stub for rework-prep unit test (replaces the full gh stub)
cat > "$BIN/gh" <<'GHEOF_B'
#!/usr/bin/env bash
_args=()
while [ $# -gt 0 ]; do
  case "$1" in -R|--repo|-L|--limit) shift ;; *) _args+=("$1") ;; esac; shift
done
set -- "${_args[@]+"${_args[@]}"}"
obj="${1:-}"; verb="${2:-}"
shift 2 2>/dev/null || true

case "$obj $verb" in
  "auth token")
    echo "test-token" ;;
  "issue view")
    jqf=""
    while [ $# -gt 0 ]; do
      case "$1" in --jq) jqf="$2"; shift ;; --json) shift ;; esac; shift
    done
    body="task for issue
Charter: #5"
    if [ "$jqf" = ".body" ]; then
      printf '%s\n' "$body"
    elif printf '%s' "$jqf" | grep -q comments; then
      # #209: serve the latest verify-merged RED reason as a fabricated comment fixture
      printf '{"comments":[{"body":"%s"}]}\n' "${CB_FIXTURE_COMMENT:-}" | jq -r "$jqf"
    else
      printf '{"body":"task for issue Charter: #5"}\n'
    fi
    ;;
  *) ;;
esac
exit 0
GHEOF_B
chmod +x "$BIN/gh"

# Minimal git stub for rework-prep unit test
cat > "$BIN/git" <<'GITEOF'
#!/usr/bin/env bash
# Strip -C DIR
args=()
while [ $# -gt 0 ]; do
  case "$1" in -C) shift; shift ;; *) args+=("$1"); shift ;; esac
done
set -- "${args[@]+"${args[@]}"}"
subcmd="${1:-}"
case "$subcmd" in
  clone)
    dest=""
    for a in "$@"; do case "$a" in -*) ;; *) dest="$a" ;; esac; done
    [ -n "$dest" ] && mkdir -p "$dest"
    ;;
esac
exit 0
GITEOF
chmod +x "$BIN/git"

# crewboss-spawn.sh stub in CB_HOME (rework-prep calls exec to it at the end)
cat > "$CBHOME_B/crewboss-spawn.sh" <<'SPEOF'
#!/usr/bin/env bash
exit 0
SPEOF
chmod +x "$CBHOME_B/crewboss-spawn.sh"

CB_RUN_B="$CBHOME_B/run"

# ── B1: CB_OLD_BRANCH=leaf/11-1700000000 + called as (11, executor) → integrate mode ──
rm -rf "$CB_RUN_B"
PATH="$BIN:$PATH" \
  CB_HOME="$CBHOME_B" \
  CB_REPO="test/repo" \
  CB_OLD_BRANCH="leaf/11-1700000000" \
  bash "$REWORK_PREP" 11 executor 2>/dev/null

PROMPT_B1="$CB_RUN_B/work/11/task.prompt"
if [ -f "$PROMPT_B1" ]; then
  grep -q "origin/executor" "$PROMPT_B1" \
    && ko "RED-b1: task.prompt contains 'origin/executor' (\$2 used as old branch — bug)" \
    || ok "RED-b1: task.prompt does NOT contain 'origin/executor' (CB_OLD_BRANCH used correctly)"

  grep -q "origin/leaf/11-1700000000" "$PROMPT_B1" \
    && ok "RED-b2: task.prompt references CB_OLD_BRANCH value 'leaf/11-1700000000'" \
    || ko "RED-b2: task.prompt does NOT reference CB_OLD_BRANCH value (got first line: $(head -1 "$PROMPT_B1"))"

  grep -q "git merge --no-edit" "$PROMPT_B1" \
    && ok "RED-b3: integrate mode selected (CB_OLD_BRANCH non-empty → merge prompt)" \
    || ko "RED-b3: integrate mode NOT selected (expected 'git merge --no-edit' in prompt)"
else
  ko "RED-b1: task.prompt not created"
  ko "RED-b2: task.prompt not created"
  ko "RED-b3: task.prompt not created"
fi

# ── B2: CB_OLD_BRANCH="" → fresh-fix mode (no merge in prompt) ──
rm -rf "$CB_RUN_B"
PATH="$BIN:$PATH" \
  CB_HOME="$CBHOME_B" \
  CB_REPO="test/repo" \
  CB_OLD_BRANCH="" \
  bash "$REWORK_PREP" 11 executor 2>/dev/null

PROMPT_B2="$CB_RUN_B/work/11/task.prompt"
if [ -f "$PROMPT_B2" ]; then
  grep -q "git merge --no-edit" "$PROMPT_B2" \
    && ko "RED-b4: fresh-fix mode: prompt wrongly contains 'git merge --no-edit'" \
    || ok "RED-b4: fresh-fix mode selected (CB_OLD_BRANCH empty → no merge in prompt)"
else
  ko "RED-b4: task.prompt not created for fresh-fix mode"
fi

# ── B3: $2=executor with CB_OLD_BRANCH set → still integrate mode (not mixed up) ──
rm -rf "$CB_RUN_B"
PATH="$BIN:$PATH" \
  CB_HOME="$CBHOME_B" \
  CB_REPO="test/repo" \
  CB_OLD_BRANCH="leaf/11-1700000000" \
  bash "$REWORK_PREP" 11 executor 2>/dev/null

PROMPT_B3="$CB_RUN_B/work/11/task.prompt"
if [ -f "$PROMPT_B3" ]; then
  grep -q "origin/executor" "$PROMPT_B3" \
    && ko "RED-b5: \$2 (executor) used as old branch — CB_OLD_BRANCH ignored (bug)" \
    || ok "RED-b5: \$2 (executor) NOT used as old branch — CB_OLD_BRANCH correctly used"
else
  ko "RED-b5: task.prompt not created"
fi

# ── B6 (#209): fresh-fix prompt verifies via the GENERIC engine ALLOW-suite, not the ui/npm hardcode ──
#    (the npm hardcode is what HUNG rework on a clean/non-ui tree — E-finding root)
rm -rf "$CB_RUN_B"
PATH="$BIN:$PATH" \
  CB_HOME="$CBHOME_B" \
  CB_REPO="test/repo" \
  CB_OLD_BRANCH="" \
  bash "$REWORK_PREP" 11 executor 2>/dev/null
PROMPT_B6="$CB_RUN_B/work/11/task.prompt"
if [ -f "$PROMPT_B6" ]; then
  grep -qE "npm ci|npm run build" "$PROMPT_B6" \
    && ko "RED-b6: prompt STILL hardcodes npm verify (hangs on non-ui/clean tree)" \
    || ok "RED-b6: prompt does NOT hardcode npm verify"
  grep -q "App.tsx" "$PROMPT_B6" \
    && ko "RED-b6: prompt STILL hardcodes ui/app/src/App.tsx" \
    || ok "RED-b6: prompt does NOT hardcode App.tsx (generic)"
  { grep -q "per-leaf-manifest" "$PROMPT_B6" && grep -q "ALLOW" "$PROMPT_B6"; } \
    && ok "RED-b6: prompt verifies via the ALLOW-filtered engine suite (gate-equivalent)" \
    || ko "RED-b6: prompt does not reference the ALLOW engine suite"
else
  ko "RED-b6: task.prompt not created"
  ko "RED-b6: task.prompt not created"
  ko "RED-b6: task.prompt not created"
fi

# ── B7 (#209): the latest verify-merged RED reason is carried into the rework prompt (targeted, not blind) ──
rm -rf "$CB_RUN_B"
PATH="$BIN:$PATH" \
  CB_HOME="$CBHOME_B" \
  CB_REPO="test/repo" \
  CB_OLD_BRANCH="" \
  CB_FIXTURE_COMMENT="verify-merged confirmed engine RED — failing: acceptance-block" \
  bash "$REWORK_PREP" 11 executor 2>/dev/null
PROMPT_B7="$CB_RUN_B/work/11/task.prompt"
if [ -f "$PROMPT_B7" ]; then
  grep -q "acceptance-block" "$PROMPT_B7" \
    && ok "RED-b7: rework prompt carries the named failing test from gate feedback (not blind)" \
    || ko "RED-b7: prompt lacks the RED reason from comments (blind rework)"
else
  ko "RED-b7: task.prompt not created"
fi

# =============================================================================
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
