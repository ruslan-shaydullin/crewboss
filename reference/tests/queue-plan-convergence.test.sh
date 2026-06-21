#!/usr/bin/env bash
# queue-plan-convergence.test.sh — regression: plan-convergence must fire for BOTH
# charters in a multi-charter queue when policy.plan_review_role is set.
#
# The bug (#420): queue-mode head-calculation used a single _q_head that skipped
# plan-review charters ("terminal-for-queue"), so when ALL queued charters were in
# plan-review the plan-convergence gate received a null head and never fired —
# every charter with plan_review_role stranded permanently at status:plan-review.
#
# The fix (launcher): split into _q_head (leaf-execution head, skips plan-review)
# and _q_plan_head (plan-conv head, skips approved instead), so the plan-conv gate
# advances through the queue independently of leaf execution.
#
# Class EXCLUDED: heavy launcher integration — same class as plan-convergence.test.sh
# and launcher-queue.test.sh. Manifest registration handled in sibling leaf-420-3.
#
# Happy path: queue=[50,100], plan_review_role=solution-analyst in manifest,
#   both charters seeded at status:plan-review + composition:approved (no plan:agreed).
#   After N ticks BOTH charters must acquire plan:agreed and reach status:approved.
#   Any charter still on plan-review after N ticks → failed.
#
# Control case: same queue + board, NO plan_review_role in manifest. Launcher must
#   NOT apply plan:agreed to either charter (gate gated by the policy field); any
#   spurious label increments failed.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER="${LAUNCHER_OVERRIDE:-$HERE/../runtime/crewboss-launcher-gh.sh}"
BOARD_GH_SRC="$HERE/../../proto/r6/board-gh.sh"
LAUNCHABLE_SRC="$HERE/../../proto/r6/launchable.sh"
TEAM_EXAMPLE="$(cd "$HERE/../../team-example" && pwd)"
MANIFEST_LIB_SRC="$HERE/../../reference/launcher/manifest.sh"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

# ── shared state ──────────────────────────────────────────────────────────────
SANDBOX="$ROOT/sb"
BOARD_STATE="$SANDBOX/board.json"
GH_LOG="$SANDBOX/gh.log"
PLAN_REVIEW_LOG="$ROOT/plan-review.log"
export SANDBOX BOARD_STATE GH_LOG PLAN_REVIEW_LOG

# ── manifest WITH plan_review_role (happy path) ───────────────────────────────
CB_MANIFEST_ARMED="$ROOT/manifest-armed"
cp -r "$TEAM_EXAMPLE/." "$CB_MANIFEST_ARMED"
jq '.policy.plan_review_role="solution-analyst"' \
   "$CB_MANIFEST_ARMED/org.json" > "$CB_MANIFEST_ARMED/org.json.t" \
  && mv "$CB_MANIFEST_ARMED/org.json.t" "$CB_MANIFEST_ARMED/org.json"

# ── manifest WITHOUT plan_review_role (control case) ─────────────────────────
CB_MANIFEST_PLAIN="$ROOT/manifest-plain"
cp -r "$TEAM_EXAMPLE/." "$CB_MANIFEST_PLAIN"

export MANIFEST_LIB_SRC

BIN="$ROOT/bin"; mkdir -p "$BIN"

# ── flock shim (hermetic, single-launcher) ────────────────────────────────────
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/flock"
chmod +x "$BIN/flock"

# ── gh stub (stateful file-board; same contract as plan-convergence.test.sh) ──
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
  "issue create")
    title=""; body=""; label=""
    while [ $# -gt 0 ]; do
      case "$1" in --title) title="$2"; shift ;; --body|-b) body="$2"; shift ;;
        --label) label="$2"; shift ;; esac; shift
    done
    maxn=$(jq 'map(.number) | max // 0' "$BOARD_STATE" 2>/dev/null || echo 0)
    newn=$((maxn+1))
    lab_json="[]"
    [ -n "$label" ] && lab_json="$(printf '[{"name":"%s"}]' "$label")"
    jq --argjson n "$newn" --arg t "$title" --arg b "$body" --argjson l "$lab_json" \
      '. + [{"number":$n,"state":"OPEN","title":$t,"body":$b,"labels":$l,"comments":[]}]' \
      "$BOARD_STATE" > "$BOARD_STATE.t" && mv "$BOARD_STATE.t" "$BOARD_STATE"
    echo "issue create #$newn: $title" >> "$GH_LOG"
    printf 'https://github.com/test/repo/issues/%s\n' "$newn" ;;
  "auth token") echo "fake-token" ;;
  "label create") ;;
  *) echo "gh-stub UNHANDLED: $obj $verb $*" >> "$GH_LOG" ;;
esac
exit 0
GHEOF
chmod +x "$BIN/gh"

# ── plan-review stub: immediately AGREE (adds plan:agreed) ────────────────────
# Simulates the analyst reviewing and agreeing on the tech-lead's plan in a
# single round. Records each invocation so the test can verify the gate fired
# for every charter in the queue, not just the first.
PLAN_REVIEW_STUB="$ROOT/plan-review-stub.sh"
cat > "$PLAN_REVIEW_STUB" <<'PREOF'
#!/usr/bin/env bash
CID="$1"; RROLE="$2"
printf '%s %s\n' "$CID" "$RROLE" >> "$PLAN_REVIEW_LOG"
gh issue comment "$CID" -R "test/repo" \
  --body "PLAN-REVIEW: agreed — plan grounded against code, all anchors sound"
gh issue edit "$CID" -R "test/repo" --add-label plan:agreed
exit 0
PREOF
chmod +x "$PLAN_REVIEW_STUB"

# ── board helpers ──────────────────────────────────────────────────────────────
has_label(){ [ "$(jq -r --argjson n "$1" 'map(select(.number==$n))[0].labels[]?.name' \
                   "$BOARD_STATE" 2>/dev/null | grep -c "^$2$")" -ge 1 ]; }

# ── sandbox + board reset ──────────────────────────────────────────────────────
reset_sandbox(){
  local cbhome="$1"
  rm -rf "$SANDBOX"; mkdir -p "$SANDBOX"
  : > "$GH_LOG"; : > "$PLAN_REVIEW_LOG"
  rm -rf "$cbhome"; mkdir -p "$cbhome"
  cp "$BOARD_GH_SRC"   "$cbhome/board-gh.sh"
  cp "$LAUNCHABLE_SRC" "$cbhome/launchable.sh"
  chmod +x "$cbhome/board-gh.sh" "$cbhome/launchable.sh"
}

# Seed: both charters at status:plan-review + composition:approved (post-tech-lead
# state, no plan:agreed). Queue order [50,100] makes charter 50 the plan-conv head.
seed_board(){
  local cbhome="$1"
  printf '[
    {"number":50,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:plan-review"},{"name":"composition:approved"}],"body":"charter A","comments":[]},
    {"number":100,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:plan-review"},{"name":"composition:approved"}],"body":"charter B","comments":[]}
  ]\n' > "$BOARD_STATE"
  mkdir -p "$cbhome/run"
  printf '{"order":[50,100]}' > "$cbhome/run/queue.json"
}

# ── loop runner ────────────────────────────────────────────────────────────────
# CB_IDLE_CONFIRM=2: tolerate one idle tick between the two plan-conv spawns
# (charter 50 approved but charter 100 not yet spawned on the same tick).
# CB_MAX_TICKS=20: matches the budget of launcher-queue.test.sh.
run_loop(){
  local cbhome="$1" logfile="${2:-/dev/null}"; shift 2
  : > "$PLAN_REVIEW_LOG"; : > "$GH_LOG"
  PATH="$BIN:$PATH" \
    CB_REPO="test/repo" \
    CB_HOME="$cbhome" \
    CB_SPAWN="$PLAN_REVIEW_STUB" \
    CB_PLAN_SPAWN="$PLAN_REVIEW_STUB" \
    CB_PLAN_REVIEW_SPAWN="$PLAN_REVIEW_STUB" \
    CB_MANIFEST_LIB="$MANIFEST_LIB_SRC" \
    CB_POLL=0 \
    CB_MAX_TICKS=20 \
    CB_IDLE_CONFIRM=2 \
    CB_MAX_PARALLEL=4 \
    CB_RETRY_CAP=3 \
    CB_PLAN_CONVERGE_CAP=5 \
    CB_REVIEW_STALE_TICKS=999 \
    CREWBOSS_CHARTER= \
    env "$@" \
    bash "$LAUNCHER" run >"$logfile" 2>&1 || true
}

# =============================================================================
# HAPPY-PATH: queue=[50,100], plan_review_role=solution-analyst → both charters
# must acquire plan:agreed and reach status:approved within N ticks.
#
# Regression: with the bug (plan-review in the leaf-execution skip-list used for
# plan-conv too), _q_head = none when both charters are in plan-review and the
# plan-conv gate breaks immediately without processing either charter.
# =============================================================================
echo "=== HAPPY-PATH: queue=[50,100] + plan_review_role → both charters reach plan:agreed + status:approved ==="
CBHOME_H="$ROOT/cbhome_h"; LOG_H="$ROOT/loop_h.log"
reset_sandbox "$CBHOME_H"
seed_board "$CBHOME_H"

run_loop "$CBHOME_H" "$LOG_H" \
  "CB_MANIFEST=$CB_MANIFEST_ARMED"

# Charter 50: plan-convergence gate must have fired (plan:agreed acquired)
has_label 50 "plan:agreed" \
  && ok "HAPPY-PATH: charter #50 acquired plan:agreed" \
  || ko "HAPPY-PATH: charter #50 did NOT get plan:agreed (plan-convergence gate did not fire)"

# Charter 50: gate released it to status:approved
has_label 50 "status:approved" \
  && ok "HAPPY-PATH: charter #50 reached status:approved" \
  || ko "HAPPY-PATH: charter #50 still at status:plan-review (gate did not release)"

# Charter 50: no longer stranded at status:plan-review
! has_label 50 "status:plan-review" \
  && ok "HAPPY-PATH: charter #50 no longer carries status:plan-review" \
  || ko "HAPPY-PATH: charter #50 still has status:plan-review after convergence"

# Charter 100: plan-conv gate must also have fired (queue advanced past 50)
has_label 100 "plan:agreed" \
  && ok "HAPPY-PATH: charter #100 acquired plan:agreed" \
  || ko "HAPPY-PATH: charter #100 did NOT get plan:agreed (queue-mode deadlock may have re-appeared)"

# Charter 100: gate released it to status:approved
has_label 100 "status:approved" \
  && ok "HAPPY-PATH: charter #100 reached status:approved" \
  || ko "HAPPY-PATH: charter #100 still at status:plan-review (queue-mode blocked plan-convergence)"

# Charter 100: no longer stranded at status:plan-review
! has_label 100 "status:plan-review" \
  && ok "HAPPY-PATH: charter #100 no longer carries status:plan-review" \
  || ko "HAPPY-PATH: charter #100 still has status:plan-review after convergence"

# Plan-review stub must have been invoked for BOTH charters (gate actually fired)
_pr50=$(grep -c "^50 solution-analyst" "$PLAN_REVIEW_LOG" 2>/dev/null || echo 0)
[ "${_pr50:-0}" -ge 1 ] \
  && ok "HAPPY-PATH: plan-review spawned for charter #50 (count=$_pr50)" \
  || ko "HAPPY-PATH: plan-review stub NOT invoked for charter #50 (gate bypassed)"

_pr100=$(grep -c "^100 solution-analyst" "$PLAN_REVIEW_LOG" 2>/dev/null || echo 0)
[ "${_pr100:-0}" -ge 1 ] \
  && ok "HAPPY-PATH: plan-review spawned for charter #100 (count=$_pr100)" \
  || ko "HAPPY-PATH: plan-review stub NOT invoked for charter #100 (queue-mode blocked the gate)"

# =============================================================================
# CONTROL: same queue and board, NO plan_review_role in manifest. Launcher must
# NOT apply plan:agreed to either charter — gate is gated by the policy field.
# Both charters park in status:plan-review (advance unchanged); any spurious
# label (plan:agreed, status:approved) increments failed.
# =============================================================================
echo "=== CONTROL: queue=[50,100], no plan_review_role → plan:agreed NOT added, plan-review unchanged ==="
CBHOME_C="$ROOT/cbhome_c"; LOG_C="$ROOT/loop_c.log"
reset_sandbox "$CBHOME_C"
seed_board "$CBHOME_C"

run_loop "$CBHOME_C" "$LOG_C" \
  "CB_MANIFEST=$CB_MANIFEST_PLAIN"

# Gate must NOT fire without plan_review_role in manifest
! has_label 50 "plan:agreed" \
  && ok "CONTROL: plan:agreed NOT added to charter #50 (gate correctly disarmed)" \
  || ko "CONTROL: spurious plan:agreed on charter #50 (gate fired without plan_review_role)"

! has_label 100 "plan:agreed" \
  && ok "CONTROL: plan:agreed NOT added to charter #100 (gate correctly disarmed)" \
  || ko "CONTROL: spurious plan:agreed on charter #100 (gate fired without plan_review_role)"

# Both charters must park in status:plan-review (advance unchanged)
has_label 50 "status:plan-review" \
  && ok "CONTROL: charter #50 parked in status:plan-review (unchanged)" \
  || ko "CONTROL: charter #50 left status:plan-review unexpectedly"

has_label 100 "status:plan-review" \
  && ok "CONTROL: charter #100 parked in status:plan-review (unchanged)" \
  || ko "CONTROL: charter #100 left status:plan-review unexpectedly"

# status:approved must NOT appear (no plan:agreed, no gate release)
! has_label 50 "status:approved" \
  && ok "CONTROL: charter #50 NOT released to status:approved (disarmed)" \
  || ko "CONTROL: spurious status:approved on charter #50"

! has_label 100 "status:approved" \
  && ok "CONTROL: charter #100 NOT released to status:approved (disarmed)" \
  || ko "CONTROL: spurious status:approved on charter #100"

# =============================================================================
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
