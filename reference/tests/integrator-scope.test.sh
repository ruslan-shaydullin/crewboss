#!/usr/bin/env bash
# integrator-scope.test.sh — charter-scope tests for integrator + finale loops (issue #114).
# Class i: integration with gh/git stubs + throwaway bare git remote.
# Drives crewboss-launcher-gh.sh run loop.
#
# RED-a (integrator+finale scope): CREWBOSS_CHARTER=5 with two-charter board:
#   - Integrator must merge ONLY charter-5 leaf (#10); charter-6 leaf (#20) untouched.
#   - Finale must create draft PR for charter/5→main ONLY; charter/6 PR NOT created.
#   Before fix: board review-leaves unscoped → #20 also merged; _charter_finale_cycle
#               unscoped → charter/6 PR also created. Both RED before fix.
#
# RED-b (regression lock): same board without CREWBOSS_CHARTER → both leaves merged,
#   both draft PRs created.
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

# ── shared exported state ─────────────────────────────────────────────────────
REMOTE="$ROOT/remote.git"
SANDBOX="$ROOT/sb"
BOARD_STATE="$SANDBOX/board.json"
GH_LOG="$SANDBOX/gh.log"
PRDIR="$SANDBOX/prs"
GATEDIR="$ROOT/gatedir"   # empty dir: no CREWBOSS_NOGATE markers → gate passes
export REMOTE SANDBOX BOARD_STATE GH_LOG PRDIR

BIN="$ROOT/bin"; mkdir -p "$BIN" "$GATEDIR"

# ── helpers ───────────────────────────────────────────────────────────────────
issue_state(){ jq -r --argjson n "$1" 'map(select(.number==$n))[0].state' "$BOARD_STATE"; }
pr_merged(){     [ -f "$PRDIR/merged-$1" ]; }
pr_not_merged(){ [ ! -f "$PRDIR/merged-$1" ]; }
ghlog_has(){     grep -q "$1" "$GH_LOG" 2>/dev/null; }
# charter_pr_created: gh pr create was called with head=charter/<N>
charter_pr_created(){     ghlog_has "pr create.*head=charter/$1 "; }
charter_pr_not_created(){ ! charter_pr_created "$1"; }

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

# Create charter/N branch in the remote (one commit ahead of main)
setup_charter_branch(){
  local cid="$1"
  local tmp; tmp="$(mktemp -d)"
  git clone -q "$REMOTE" "$tmp" 2>/dev/null
  git -C "$tmp" config user.email t@t; git -C "$tmp" config user.name T
  git -C "$tmp" checkout -q -b "charter/$cid" 2>/dev/null
  printf 'charter %s\n' "$cid" > "$tmp/charter-$cid.txt"
  git -C "$tmp" add -A; git -C "$tmp" commit -qm "charter $cid setup" 2>/dev/null
  git -C "$tmp" push -q origin "charter/$cid" 2>/dev/null
  rm -rf "$tmp"
}

# Create a leaf branch for issue <lid> based off charter/<cid> and register a PR
setup_leaf_pr(){
  local lid="$1" cid="$2"
  local tmp; tmp="$(mktemp -d)"
  git clone -q "$REMOTE" "$tmp" 2>/dev/null
  git -C "$tmp" config user.email t@t; git -C "$tmp" config user.name T
  git -C "$tmp" fetch -q origin "charter/$cid" 2>/dev/null
  local TS=1700000000
  git -C "$tmp" checkout -q -b "leaf/$lid-$TS" "origin/charter/$cid" 2>/dev/null
  printf 'work for #%s\n' "$lid" > "$tmp/work-$lid.txt"
  git -C "$tmp" add -A; git -C "$tmp" commit -qm "executor: closes #$lid" 2>/dev/null
  git -C "$tmp" push -q origin "leaf/$lid-$TS" 2>/dev/null
  rm -rf "$tmp"
  # Register PR in PRDIR (same convention as integrator-loop.test.sh)
  touch "$PRDIR/$lid"
  printf 'charter/%s' "$cid"       > "$PRDIR/base-$lid"
  printf 'leaf/%s-%s' "$lid" "$TS" > "$PRDIR/head-$lid"
  printf 'success'                 > "$PRDIR/checks-$lid"
}

reset_sandbox(){
  rm -rf "$SANDBOX"; mkdir -p "$SANDBOX" "$PRDIR"
  : > "$GH_LOG"
  setup_remote
  local cbhome="$1"
  rm -rf "$cbhome"; mkdir -p "$cbhome"
  cp "$BOARD_GH_SRC"   "$cbhome/board-gh.sh"
  cp "$LAUNCHABLE_SRC" "$cbhome/launchable.sh"
  chmod +x "$cbhome/board-gh.sh" "$cbhome/launchable.sh"
}

# ── gh stub ───────────────────────────────────────────────────────────────────
# Supports: issue list/view/edit/comment/close, pr list/view/merge/create/checks/ready,
#           label create.
# BOARD_STATE, GH_LOG, PRDIR must be exported.
cat > "$BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
obj="$1"; verb="$2"; shift 2

# Strip -R/--repo and -L/--limit flags with their values
_args=()
while [ $# -gt 0 ]; do
  case "$1" in -R|--repo|-L|--limit) shift ;; *) _args+=("$1") ;; esac; shift
done
set -- "${_args[@]+"${_args[@]}"}"

case "$obj $verb" in
  "issue list")
    cat "$BOARD_STATE" ;;

  "issue view")
    n="$1"; shift
    jq --argjson n "$n" 'map(select(.number==$n))[0] // {}' "$BOARD_STATE" ;;

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

  "pr create")
    # parse: --draft --base <base> --head <head> --title <t> --body <b>
    _head=""; _base="main"; _draft=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --head)  _head="$2"; shift ;;
        --base)  _base="$2"; shift ;;
        --draft) _draft="1" ;;
        --title) shift ;;
        --body)  shift ;;
      esac
      shift
    done
    # auto-assign PR number starting at 1001
    _next="$(cat "$PRDIR/next_pr" 2>/dev/null || echo 1001)"
    _pn="$_next"
    printf '%s' "$((_next + 1))" > "$PRDIR/next_pr"
    touch "$PRDIR/$_pn"
    printf '%s' "$_head" > "$PRDIR/head-$_pn"
    printf '%s' "$_base" > "$PRDIR/base-$_pn"
    [ -n "$_draft" ] && touch "$PRDIR/draft-$_pn"
    printf 'success' > "$PRDIR/checks-$_pn"
    echo "pr create #$_pn head=$_head base=$_base draft=$_draft" >> "$GH_LOG"
    printf 'https://github.com/test/repo/pull/%s\n' "$_pn" ;;

  "pr checks")
    n="$1"
    status="$(cat "$PRDIR/checks-$n" 2>/dev/null || echo success)"
    echo "pr checks #$n status=$status" >> "$GH_LOG"
    [ "$status" = "success" ] && exit 0 || exit 1 ;;

  "pr ready")
    n="$1"
    rm -f "$PRDIR/draft-$n" 2>/dev/null || true
    echo "pr ready #$n" >> "$GH_LOG" ;;

  "label create") ;;

  *) echo "gh-stub UNHANDLED: $obj $verb $*" >> "$GH_LOG" ;;
esac
exit 0
GHEOF
chmod +x "$BIN/gh"

# ── no-op spawn stub (leaves pre-set to status:review — spawn not needed) ─────
cat > "$ROOT/spawn.sh" <<'SPEOF'
#!/usr/bin/env bash
exit 0
SPEOF
chmod +x "$ROOT/spawn.sh"

# ── loop runner ───────────────────────────────────────────────────────────────
run_loop(){
  local cbhome="$1"; shift
  # remaining args are VAR=value env overrides (e.g. CREWBOSS_CHARTER=5)
  env CB_REPO="test/repo" \
      CB_HOME="$cbhome" \
      CB_SPAWN="$ROOT/spawn.sh" \
      CB_GIT_REMOTE="$REMOTE" \
      CB_INTEGRATOR="$INTEGRATOR" \
      CB_GATE_REPO_DIR="$GATEDIR" \
      CB_POLL=0 \
      CB_MAX_TICKS=30 \
      CB_IDLE_CONFIRM=2 \
      CB_MAX_PARALLEL=4 \
      CB_RETRY_CAP=2 \
      CB_FINALE_CHECKS_POLL=0 \
      CB_FINALE_CHECKS_TIMEOUT=5 \
      "$@" \
      PATH="$BIN:$PATH" \
      bash "$LAUNCHER" run 2>/dev/null
}

# =============================================================================
# RED-a: CREWBOSS_CHARTER=5 — integrator scopes to charter 5 only;
#        finale creates PR for charter/5 but NOT charter/6.
# =============================================================================
echo "== RED-a: scoped run (CREWBOSS_CHARTER=5) =="

CBHOME_A="$ROOT/cbhome_a"
reset_sandbox "$CBHOME_A"

# Set up charter branches (both ahead of main in remote)
setup_charter_branch 5
setup_charter_branch 6

# Board: two charters (approved), each with one leaf in status:review
cat > "$BOARD_STATE" <<'JSON'
[
  {"number":5,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:approved"}],
   "body":"charter five","comments":[]},
  {"number":6,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:approved"}],
   "body":"charter six","comments":[]},
  {"number":10,"state":"OPEN",
   "labels":[{"name":"type:agent"},{"name":"status:review"}],
   "body":"leaf A\nCharter: #5\n## Acceptance (machine)\n- check: true","comments":[]},
  {"number":20,"state":"OPEN",
   "labels":[{"name":"type:agent"},{"name":"status:review"}],
   "body":"leaf C\nCharter: #6\n## Acceptance (machine)\n- check: true","comments":[]}
]
JSON

# Create leaf branches + PR records for both leaves (both have green CI)
setup_leaf_pr 10 5
setup_leaf_pr 20 6

run_loop "$CBHOME_A" CREWBOSS_CHARTER=5

# ── integrator scope assertions ───────────────────────────────────────────────
pr_merged 10 \
  && ok "RED-a: #10 (charter-5 leaf) PR merged by scoped integrator" \
  || ko "RED-a: #10 PR NOT merged — integrator scope broken"

[ "$(issue_state 10)" = "CLOSED" ] \
  && ok "RED-a: #10 (charter-5 leaf) issue CLOSED" \
  || ko "RED-a: #10 issue NOT closed — integrator scope broken"

pr_not_merged 20 \
  && ok "RED-a: #20 (charter-6 leaf) PR NOT merged (scope respected)" \
  || ko "RED-a: #20 PR merged — SCOPE VIOLATION (integrator unscoped)"

[ "$(issue_state 20)" != "CLOSED" ] \
  && ok "RED-a: #20 (charter-6 leaf) NOT closed (scope respected)" \
  || ko "RED-a: #20 closed — SCOPE VIOLATION (integrator unscoped)"

# ── finale scope assertions ───────────────────────────────────────────────────
charter_pr_created 5 \
  && ok "RED-a: draft PR for charter/5→main created (finale scoped)" \
  || ko "RED-a: draft PR for charter/5 NOT created — finale not triggered"

charter_pr_not_created 6 \
  && ok "RED-a: draft PR for charter/6→main NOT created (scope respected)" \
  || ko "RED-a: draft PR for charter/6 created — SCOPE VIOLATION (finale unscoped)"

# =============================================================================
# RED-b: regression lock — no CREWBOSS_CHARTER → both charters processed
# =============================================================================
echo "== RED-b: unscoped run (no CREWBOSS_CHARTER) processes both charters =="

CBHOME_B="$ROOT/cbhome_b"
reset_sandbox "$CBHOME_B"

# Same charter branches (re-created in fresh remote)
setup_charter_branch 5
setup_charter_branch 6

# Same board as RED-a
cat > "$BOARD_STATE" <<'JSON'
[
  {"number":5,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:approved"}],
   "body":"charter five","comments":[]},
  {"number":6,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:approved"}],
   "body":"charter six","comments":[]},
  {"number":10,"state":"OPEN",
   "labels":[{"name":"type:agent"},{"name":"status:review"}],
   "body":"leaf A\nCharter: #5\n## Acceptance (machine)\n- check: true","comments":[]},
  {"number":20,"state":"OPEN",
   "labels":[{"name":"type:agent"},{"name":"status:review"}],
   "body":"leaf C\nCharter: #6\n## Acceptance (machine)\n- check: true","comments":[]}
]
JSON

setup_leaf_pr 10 5
setup_leaf_pr 20 6

# Run WITHOUT CREWBOSS_CHARTER (explicitly unset to avoid inheriting from outer env)
( unset CREWBOSS_CHARTER 2>/dev/null || true
  run_loop "$CBHOME_B"
)

# Both leaf PRs must be merged
pr_merged 10 \
  && ok "RED-b: #10 (charter-5 leaf) merged (unscoped)" \
  || ko "RED-b: #10 NOT merged — regression in unscoped run"

pr_merged 20 \
  && ok "RED-b: #20 (charter-6 leaf) merged (unscoped — both expected)" \
  || ko "RED-b: #20 NOT merged — regression: unscoped should merge all review leaves"

# Both issues must be closed
[ "$(issue_state 10)" = "CLOSED" ] \
  && ok "RED-b: #10 CLOSED (unscoped)" \
  || ko "RED-b: #10 NOT closed — regression"

[ "$(issue_state 20)" = "CLOSED" ] \
  && ok "RED-b: #20 CLOSED (unscoped — both expected)" \
  || ko "RED-b: #20 NOT closed — regression"

# Both charter finale PRs must be created
charter_pr_created 5 \
  && ok "RED-b: draft PR for charter/5 created (unscoped)" \
  || ko "RED-b: draft PR for charter/5 NOT created — regression"

charter_pr_created 6 \
  && ok "RED-b: draft PR for charter/6 created (unscoped — both expected)" \
  || ko "RED-b: draft PR for charter/6 NOT created — regression: unscoped should create both"

# =============================================================================
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
