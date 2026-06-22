#!/usr/bin/env bash
# per-charter-auto-gate.test.sh — deterministic integration test for per-charter
# auto:plan-approve and auto:merge labels (#401).
#
# Charter #401 adds per-charter labels auto:plan-approve and auto:merge that OR
# with global CB_AUTO_PLAN_APPROVE / CB_AUTO_MERGE env flags to control gate
# progression.  Four scenarios:
#
#   Scenario 1 — per-charter auto:plan-approve, no global env:
#       charter has label auto:plan-approve; CB_AUTO_PLAN_APPROVE unset.
#       Expected: launcher advances charter plan-review → status:approved.
#
#   Scenario 2 — no auto label, no env → manual gate stays:
#       charter has neither label nor CB_AUTO_PLAN_APPROVE=1.
#       Expected: charter stays at status:plan-review.
#
#   Scenario 3 — per-charter auto:merge + green CI → merged (RED-b pattern):
#       charter has label auto:merge; CB_AUTO_MERGE unset; ci_state=pending;
#       stub gh pr checks exits 0 (all checks passed).
#       Expected: pr-merge invocation recorded in stub log.
#       CRITICAL: ci_state=pending forces the pending→green transition to reach
#       the auto-merge gate at _finale_check_ci line 487. Pre-seeding green
#       would short-circuit via the early-return guard (lines 442-446) and miss
#       the code under test.
#
#   Scenario 4 — per-charter auto:merge + red CI → NOT merged (RED-b pattern):
#       same as Scenario 3 except stub gh pr checks exits non-zero with failure.
#       Expected: pr-merge NOT called; PR stays open.
#
# Pattern: plan-convergence.test.sh stub-agent pattern — real launcher binary,
# file-based board, stub gh binary that records calls.
#
# Requires: jq, git, bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER="${LAUNCHER_OVERRIDE:-$HERE/../runtime/crewboss-launcher-gh.sh}"
INTEGRATOR="${INTEGRATOR_OVERRIDE:-$HERE/../runtime/crewboss-integrator.sh}"
BOARD_GH_SRC="$HERE/../../proto/r6/board-gh.sh"
LAUNCHABLE_SRC="$HERE/../../proto/r6/launchable.sh"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

# ── shared state ──────────────────────────────────────────────────────────────
SANDBOX="$ROOT/sb"
BOARD_STATE="$SANDBOX/board.json"
GH_LOG="$SANDBOX/gh.log"
PRDIR="$SANDBOX/prs"
PLAN_LOG="$ROOT/plan.log"
REMOTE="$ROOT/remote.git"
export SANDBOX BOARD_STATE GH_LOG PRDIR PLAN_LOG REMOTE

BIN="$ROOT/bin"; mkdir -p "$BIN"

# ── flock shim (macOS compat, single-launcher) ───────────────────────────────
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/flock"
chmod +x "$BIN/flock"

# ── setup_remote: bare remote with charter/5 ahead of main ───────────────────
setup_remote(){
  rm -rf "$REMOTE"; git init --bare -q "$REMOTE"
  local tmp; tmp="$(mktemp -d)"
  git clone -q "$REMOTE" "$tmp" 2>/dev/null
  git -C "$tmp" config user.email t@t; git -C "$tmp" config user.name T
  printf 'base\n' > "$tmp/README.md"
  git -C "$tmp" add -A; git -C "$tmp" commit -qm "init" 2>/dev/null
  git -C "$tmp" push -q origin HEAD:refs/heads/main 2>/dev/null
  git -C "$tmp" checkout -q -b "charter/5" 2>/dev/null
  printf 'leaf-work\n' > "$tmp/leaf.txt"
  git -C "$tmp" add -A; git -C "$tmp" commit -qm "leaf work" 2>/dev/null
  git -C "$tmp" push -q origin "charter/5" 2>/dev/null
  rm -rf "$tmp"
}

# ── reset_sandbox ─────────────────────────────────────────────────────────────
reset_sandbox(){
  rm -rf "$SANDBOX"; mkdir -p "$SANDBOX" "$PRDIR"
  : > "$GH_LOG"
  local cbhome="$1"
  rm -rf "$cbhome"; mkdir -p "$cbhome"
  cp "$BOARD_GH_SRC"   "$cbhome/board-gh.sh"
  cp "$LAUNCHABLE_SRC" "$cbhome/launchable.sh"
  chmod +x "$cbhome/board-gh.sh" "$cbhome/launchable.sh"
}

# ── board helpers ─────────────────────────────────────────────────────────────
has_label(){ [ "$(jq -r --argjson n "$1" 'map(select(.number==$n))[0].labels[]?.name' \
                   "$BOARD_STATE" 2>/dev/null | grep -c "^$2$")" -ge 1 ]; }

# ── gh stub ───────────────────────────────────────────────────────────────────
# Handles: issue list/view/edit/comment/close, pr list/create/checks/ready/merge,
# auth token, label create.  PR checks exit code and output driven by
# $PRDIR/charter-checks-<charter_n>: "success"|"failure"|"pending".
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
    state_filter="open"
    while [ $# -gt 0 ]; do
      case "$1" in --state) state_filter="$2"; shift ;; --json) shift ;; esac; shift
    done
    case "$state_filter" in
      open)   jq '[.[] | select(.state=="OPEN")]' "$BOARD_STATE" ;;
      all)    cat "$BOARD_STATE" ;;
      closed) jq '[.[] | select(.state=="CLOSED")]' "$BOARD_STATE" ;;
      *)      cat "$BOARD_STATE" ;;
    esac ;;
  "issue view")
    n="$1"; shift; jqf=""
    while [ $# -gt 0 ]; do
      case "$1" in --jq|-q) jqf="$2"; shift ;; --json) shift ;; esac; shift
    done
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
    head=""; base_filter=""; state_filter="open"
    while [ $# -gt 0 ]; do
      case "$1" in
        --head)  head="$2"; shift ;;
        --base)  base_filter="$2"; shift ;;
        --state) state_filter="$2"; shift ;;
        --json)  shift ;;
      esac; shift
    done
    echo "pr-list --head=${head} --state=${state_filter}" >> "$GH_LOG"
    if printf '%s' "$head" | grep -q '^charter/'; then
      n="${head#charter/}"
      if [ -f "$PRDIR/charter-pr-$n" ] && [ "$state_filter" = "open" ]; then
        pr_num="$(cat "$PRDIR/charter-pr-$n")"
        printf '[{"number":%s,"baseRefName":"main","headRefName":"charter/%s"}]\n' "$pr_num" "$n"
      else
        echo "[]"
      fi
    else
      echo "[]"
    fi ;;
  "pr create")
    draft=false; base="main"; head=""; title=""; body=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --draft)    draft=true ;;
        --base)     base="$2"; shift ;;
        --head)     head="$2"; shift ;;
        --title|-t) title="$2"; shift ;;
        --body|-b)  body="$2"; shift ;;
      esac; shift
    done
    echo "pr-create ${head}->${base} draft=${draft}" >> "$GH_LOG"
    if printf '%s' "$head" | grep -q '^charter/'; then
      charter_n="${head#charter/}"
      pr_num=$((5000 + charter_n))
      printf '%s' "$pr_num" > "$PRDIR/charter-pr-$charter_n"
      printf 'https://github.com/test/repo/pull/%s\n' "$pr_num"
    fi ;;
  "pr ready")
    n="$1"
    echo "pr-ready $n" >> "$GH_LOG" ;;
  "pr checks")
    n="$1"
    echo "pr-checks $n" >> "$GH_LOG"
    # Resolve charter number from known PR numbers ($PRDIR/charter-pr-<charter_n>)
    charter_n=""
    for f in "$PRDIR"/charter-pr-[0-9]*; do
      [ -f "$f" ] || continue
      stored="$(cat "$f" 2>/dev/null)"
      if [ "$stored" = "$n" ]; then
        charter_n="${f##*/charter-pr-}"
        break
      fi
    done
    [ -z "$charter_n" ] && exit 1
    status="$(cat "$PRDIR/charter-checks-$charter_n" 2>/dev/null || echo success)"
    case "$status" in
      success) exit 0 ;;
      failure) printf 'X check: failed\n'; exit 1 ;;
      pending) printf '- check: pending\n'; exit 1 ;;
      *)       exit 1 ;;
    esac ;;
  "pr merge")
    n="$1"; shift
    echo "pr-merge $n" >> "$GH_LOG" ;;
  "auth token") echo "fake-token" ;;
  "label create") ;;
  *) echo "gh-stub UNHANDLED: $obj $verb $*" >> "$GH_LOG" ;;
esac
exit 0
GHEOF
chmod +x "$BIN/gh"

# ── plan stub (moves charter needs-plan → plan-review) ────────────────────────
PLAN_STUB="$ROOT/plan-stub.sh"
cat > "$PLAN_STUB" <<'PSEOF'
#!/usr/bin/env bash
CID="$1"
printf 'plan-stub: #%s\n' "$CID" >> "$PLAN_LOG"
gh issue edit "$CID" -R "test/repo" \
  --remove-label status:needs-plan \
  --add-label status:plan-review
exit 0
PSEOF
chmod +x "$PLAN_STUB"

# ── run loop for plan scenarios (Scenarios 1/2, no git remote) ───────────────
run_plan_loop(){
  local cbhome="$1" logfile="${2:-/dev/null}"; shift 2
  : > "$PLAN_LOG"; : > "$GH_LOG"
  PATH="$BIN:$PATH" \
    CB_REPO="test/repo" \
    CB_HOME="$cbhome" \
    CB_SPAWN="$PLAN_STUB" \
    CB_PLAN_SPAWN="$PLAN_STUB" \
    CB_MANIFEST="" \
    CB_POLL=0 \
    CB_MAX_TICKS=40 \
    CB_IDLE_CONFIRM=2 \
    CB_MAX_PARALLEL=4 \
    CB_RETRY_CAP=3 \
    CREWBOSS_CHARTER= \
    env "$@" \
    bash "$LAUNCHER" run >"$logfile" 2>&1 || true
}

# ── run loop for finale scenarios (Scenarios 3/4, needs git remote) ──────────
run_finale_loop(){
  local cbhome="$1" logfile="${2:-/dev/null}"; shift 2
  : > "$GH_LOG"
  PATH="$BIN:$PATH" \
    CB_REPO="test/repo" \
    CB_HOME="$cbhome" \
    CB_GIT_REMOTE="$REMOTE" \
    CB_INTEGRATOR="$INTEGRATOR" \
    CB_MANIFEST="" \
    CB_POLL=0 \
    CB_MAX_TICKS=10 \
    CB_IDLE_CONFIRM=2 \
    CB_MAX_PARALLEL=2 \
    CB_RETRY_CAP=2 \
    CB_FINALE_CHECKS_TIMEOUT=0 \
    CREWBOSS_CHARTER= \
    env "$@" \
    bash "$LAUNCHER" run >"$logfile" 2>&1 || true
}

# Board seed helpers
seed_plan_review(){
  # Charter at needs-plan + composition:approved + review:agreed (+ optional extra labels)
  local extra="${1:-}"
  local labels='[{"name":"type:charter"},{"name":"status:needs-plan"},{"name":"composition:approved"},{"name":"review:agreed"}]'
  if [ -n "$extra" ]; then
    labels=$(printf '%s' "$labels" | jq --arg lbl "$extra" '. + [{"name":$lbl}]')
  fi
  jq -n --argjson l "$labels" \
    '[{"number":5,"state":"OPEN","labels":$l,"body":"charter goal","comments":[]}]' \
    > "$BOARD_STATE"
}

seed_finale(){
  # Charter at status:approved with auto:merge label, no open leaves.
  local extra="${1:-}"
  local labels='[{"name":"type:charter"},{"name":"status:approved"},{"name":"auto:merge"}]'
  if [ -n "$extra" ]; then
    labels=$(printf '%s' "$labels" | jq --arg lbl "$extra" '. + [{"name":$lbl}]')
  fi
  jq -n --argjson l "$labels" \
    '[{"number":5,"state":"OPEN","labels":$l,"body":"charter goal","comments":[]}]' \
    > "$BOARD_STATE"
}

# Pre-seed the finale state dir: ci_state=pending + pr_ts=now + pre-created PR.
# This puts _finale_check_ci on the pending→green/red path (not the cached-terminal
# early-return path), which is the path that reaches the auto-merge gate.
preseed_finale_state(){
  local cbhome="$1" pr_num="${2:-5005}"
  local state_dir="$cbhome/run/state/finale-5"
  mkdir -p "$state_dir"
  printf '%s' "pending"        > "$state_dir/ci_state"
  printf '%s' "$(date +%s)"   > "$state_dir/pr_ts"
  # Pre-seed the PR so gh pr list returns it (existing-PR path in _charter_finale_cycle).
  printf '%s' "$pr_num" > "$PRDIR/charter-pr-5"
}

# =============================================================================
# Scenario 1: per-charter auto:plan-approve label, CB_AUTO_PLAN_APPROVE unset
#   Setup: charter at needs-plan with label auto:plan-approve.
#   Expected: after one launcher run, charter advances to status:approved.
# =============================================================================
echo "=== Scenario 1: auto:plan-approve label → plan auto-approved (no global env) ==="
CBHOME_1="$ROOT/cbhome_1"; LOG_1="$ROOT/s1.log"
reset_sandbox "$CBHOME_1"
seed_plan_review "auto:plan-approve"

run_plan_loop "$CBHOME_1" "$LOG_1"

has_label 5 "status:approved" \
  && ok "S1: charter auto-approved via auto:plan-approve label → status:approved" \
  || ko "S1: charter NOT approved (expected auto-approve via label, got label set: $(jq -r '.[0].labels[].name' "$BOARD_STATE" 2>/dev/null | tr '\n' ','))"

! has_label 5 "status:plan-review" \
  && ok "S1: status:plan-review removed after auto-approve" \
  || ko "S1: status:plan-review still present after auto-approve"

# =============================================================================
# Scenario 2: no auto label, no global env → manual gate stays
#   Setup: charter at needs-plan with NO auto:plan-approve label.
#   Expected: charter stays at status:plan-review (human gate not cleared).
# =============================================================================
echo "=== Scenario 2: no auto label, no env → charter stays at status:plan-review ==="
CBHOME_2="$ROOT/cbhome_2"; LOG_2="$ROOT/s2.log"
reset_sandbox "$CBHOME_2"
seed_plan_review  # no extra label

run_plan_loop "$CBHOME_2" "$LOG_2"

has_label 5 "status:plan-review" \
  && ok "S2: charter correctly stays at status:plan-review (manual gate required)" \
  || ko "S2: charter unexpectedly left plan-review (got: $(jq -r '.[0].labels[].name' "$BOARD_STATE" 2>/dev/null | tr '\n' ','))"

! has_label 5 "status:approved" \
  && ok "S2: status:approved NOT set (gate requires human approval without label)" \
  || ko "S2: status:approved was set despite no auto label and no env flag"

# =============================================================================
# Scenario 3: per-charter auto:merge + green CI → merged (RED-b pattern)
#   Setup: charter approved + auto:merge label; pre-seeded PR; ci_state=pending;
#          stub gh pr checks exits 0 (green CI).  CB_AUTO_MERGE unset.
#   Expected: pr-merge invocation recorded in stub log.
# =============================================================================
echo "=== Scenario 3: auto:merge label + green CI → pr-merge recorded (RED-b) ==="
CBHOME_3="$ROOT/cbhome_3"; LOG_3="$ROOT/s3.log"
reset_sandbox "$CBHOME_3"
setup_remote
seed_finale
preseed_finale_state "$CBHOME_3" "5005"
# charter-checks-5 absent → stub defaults to "success" (exit 0)

run_finale_loop "$CBHOME_3" "$LOG_3"

grep -q "pr-merge" "$GH_LOG" \
  && ok "S3: pr-merge invoked — auto:merge label triggered merge on green CI" \
  || ko "S3: pr-merge NOT found in gh log (expected auto-merge via auto:merge label)"

grep -q "pr-ready" "$GH_LOG" \
  && ok "S3: pr-ready called before merge (CI green → promoted to ready)" \
  || ko "S3: pr-ready NOT called (expected CI-green promotion before merge)"

# =============================================================================
# Scenario 4: per-charter auto:merge + red CI → NOT merged (RED-b pattern)
#   Setup: same as Scenario 3 except stub gh pr checks exits non-zero (failure).
#   Expected: pr-merge is NOT called; PR stays open/draft.
# =============================================================================
echo "=== Scenario 4: auto:merge label + red CI → pr-merge NOT called (RED-b) ==="
CBHOME_4="$ROOT/cbhome_4"; LOG_4="$ROOT/s4.log"
reset_sandbox "$CBHOME_4"
# Remote already set up; reuse or re-create
setup_remote
seed_finale
preseed_finale_state "$CBHOME_4" "5005"
printf 'failure' > "$PRDIR/charter-checks-5"   # CI failure → pr checks exits 1

run_finale_loop "$CBHOME_4" "$LOG_4"

! grep -q "pr-merge" "$GH_LOG" \
  && ok "S4: pr-merge NOT called — red CI correctly blocks auto-merge" \
  || ko "S4: pr-merge was called despite red CI (should stay draft/open)"

grep -q "pr-checks" "$GH_LOG" \
  && ok "S4: pr-checks was called (CI path exercised, not short-circuited)" \
  || ko "S4: pr-checks NOT called (test may have short-circuited before CI check)"

# =============================================================================
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
