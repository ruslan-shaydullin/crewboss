#!/usr/bin/env bash
# gc-stale-leaves.test.sh — stale-leaf GC regression test (#449 / charter #444).
#
# When the plan-reviewer routes a charter back to needs-plan (critique path), the
# launcher must close all open type:agent leaves of THAT charter so stale work-items
# do not execute against the outdated plan.
#
# The GC filter uses numsAfter numeric equality so that charter #5 does NOT
# accidentally close leaves of charter #50 (a naive contains("Charter: #5") match
# would match "Charter: #50" as a string-prefix — the exact bug this test guards).
#
# Class d integration-stub: real launcher + board-gh.sh, stubbed gh (file-board).
# Mirror of plan-convergence.test.sh (#382).
#
# Scenario A — single-charter happy path
#   Charter #5 at plan-review + 2 open type:agent stale leaves.
#   Plan-reviewer critiques (→ needs-plan). GC must close both leaves.
#
# Scenario B — multi-charter prefix isolation (mandatory)
#   Charter #5 AND #50 both at plan-review, each with a stale leaf.
#   Plan-reviewer critiques #5 only. Only #5's leaf must be closed; #50's stays open.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER="${LAUNCHER_OVERRIDE:-$HERE/../runtime/crewboss-launcher-gh.sh}"
BOARD_GH_SRC="$HERE/../../proto/r6/board-gh.sh"
LAUNCHABLE_SRC="$HERE/../../proto/r6/launchable.sh"
TEAM_EXAMPLE="$(cd "$HERE/../../team-example" && pwd)"
MANIFEST_LIB_SRC="$HERE/../launcher/manifest.sh"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

# ── shared state ──────────────────────────────────────────────────────────────
SANDBOX="$ROOT/sb"
BOARD_STATE="$SANDBOX/board.json"
GH_LOG="$SANDBOX/gh.log"
PLAN_LOG="$ROOT/plan.log"
PLAN_REVIEW_LOG="$ROOT/plan-review.log"
export SANDBOX BOARD_STATE GH_LOG PLAN_LOG PLAN_REVIEW_LOG

# CB_MANIFEST: copy of team-example, with plan_review_role added (arms the gate)
CB_MANIFEST_DIR="$ROOT/manifest"
cp -r "$TEAM_EXAMPLE/." "$CB_MANIFEST_DIR"
jq '.policy.plan_review_role="solution-analyst"' "$CB_MANIFEST_DIR/org.json" \
  > "$CB_MANIFEST_DIR/org.json.t" \
  && mv "$CB_MANIFEST_DIR/org.json.t" "$CB_MANIFEST_DIR/org.json"
export CB_MANIFEST_DIR MANIFEST_LIB_SRC

BIN="$ROOT/bin"; mkdir -p "$BIN"

# ── flock shim (hermetic, single-launcher) ────────────────────────────────────
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/flock"
chmod +x "$BIN/flock"

# ── board helpers ─────────────────────────────────────────────────────────────
issue_state(){ jq -r --argjson n "$1" 'map(select(.number==$n))[0] |
  if .state=="CLOSED" then "CLOSED"
  elif ([.labels[]?.name]|any(.=="status:approved")) then "approved"
  elif ([.labels[]?.name]|any(.=="status:plan-review")) then "plan-review"
  elif ([.labels[]?.name]|any(.=="status:needs-plan")) then "needs-plan"
  else "open" end' "$BOARD_STATE" 2>/dev/null; }

# ── gh stub (file-board) ──────────────────────────────────────────────────────
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

# ── tech-lead (plan) spawn stub ───────────────────────────────────────────────
# Moves the charter from needs-plan → plan-review (simulates re-plan after critique).
PLAN_STUB="$ROOT/plan-stub.sh"
cat > "$PLAN_STUB" <<'PSEOF'
#!/usr/bin/env bash
CID="$1"; PROLE="$2"
printf '%s %s\n' "$CID" "$PROLE" >> "$PLAN_LOG"
gh issue edit "$CID" -R "test/repo" \
  --remove-label status:needs-plan \
  --add-label status:plan-review
exit 0
PSEOF
chmod +x "$PLAN_STUB"

# ── loop runner ───────────────────────────────────────────────────────────────
reset_sandbox(){
  rm -rf "$SANDBOX"; mkdir -p "$SANDBOX"
  : > "$GH_LOG"
  : > "$PLAN_LOG"; : > "$PLAN_REVIEW_LOG"
  local cbhome="$1"
  rm -rf "$cbhome"; mkdir -p "$cbhome"
  cp "$BOARD_GH_SRC"   "$cbhome/board-gh.sh"
  cp "$LAUNCHABLE_SRC" "$cbhome/launchable.sh"
  chmod +x "$cbhome/board-gh.sh" "$cbhome/launchable.sh"
}

# seed_board_json: write a valid JSON board file using jq --null-input to avoid
# literal-newline issues with printf/heredoc. Bodies use JSON \n escaping.
seed_board_json(){
  local json="$1"
  printf '%s' "$json" | jq '.' > "$BOARD_STATE"
}

run_loop(){
  local cbhome="$1" logfile="${2:-/dev/null}"; shift 2
  PATH="$BIN:$PATH" \
    CB_REPO="test/repo" \
    CB_HOME="$cbhome" \
    CB_SPAWN="$PLAN_STUB" \
    CB_PLAN_SPAWN="$PLAN_STUB" \
    CB_PLAN_REVIEW_SPAWN="${PLAN_REVIEW_STUB:-/dev/null}" \
    CB_MANIFEST="$CB_MANIFEST_DIR" \
    CB_MANIFEST_LIB="$MANIFEST_LIB_SRC" \
    CB_POLL=0 \
    CB_MAX_TICKS=80 \
    CB_IDLE_CONFIRM=2 \
    CB_MAX_PARALLEL=4 \
    CB_RETRY_CAP=3 \
    CREWBOSS_CHARTER= \
    env "$@" \
    bash "$LAUNCHER" run >"$logfile" 2>&1 || true
}

# =============================================================================
# Scenario A — single-charter happy path
#
# Charter #5 at plan-review + 2 open type:agent stale leaves (Charter: #5).
# Plan-reviewer critiques → charter goes to needs-plan → GC fires.
# Assertion: both stale leaves are CLOSED; neither appears in board launchable.
# =============================================================================
echo "=== Scenario A: single-charter GC (charter #5 critique → stale leaves closed) ==="

# Plan-reviewer stub: always critique (route charter back to needs-plan)
PLAN_REVIEW_STUB="$ROOT/pr-stub-a.sh"
cat > "$PLAN_REVIEW_STUB" <<'PREOF'
#!/usr/bin/env bash
CID="$1"; RROLE="$2"
printf '%s %s\n' "$CID" "$RROLE" >> "$PLAN_REVIEW_LOG"
gh issue comment "$CID" -R "test/repo" \
  --body "PLAN-REVIEW: changes-requested — add regen step"
gh issue edit "$CID" -R "test/repo" \
  --remove-label status:plan-review \
  --add-label status:needs-plan
exit 0
PREOF
chmod +x "$PLAN_REVIEW_STUB"

CBHOME_A="$ROOT/cbhome_a"; LOG_A="$ROOT/loop_a.log"
reset_sandbox "$CBHOME_A"

# Seed board: charter #5 at plan-review + 2 stale type:agent leaves.
# Bodies use JSON \n (the two characters backslash+n), not literal newlines.
seed_board_json '[
  {"number":5,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:plan-review"},
             {"name":"composition:approved"},{"name":"review:agreed"}],
   "body":"charter goal","comments":[]},
  {"number":10,"state":"OPEN",
   "labels":[{"name":"type:agent"},{"name":"status:approved"}],
   "body":"Charter: #5","comments":[]},
  {"number":11,"state":"OPEN",
   "labels":[{"name":"type:agent"},{"name":"status:approved"}],
   "body":"Charter: #5","comments":[]}
]'

run_loop "$CBHOME_A" "$LOG_A" "CB_PLAN_CONVERGE_CAP=1"

# Both stale leaves must be CLOSED
_st10=$(issue_state 10)
[ "$_st10" = "CLOSED" ] \
  && ok "Scenario-A: stale leaf #10 is CLOSED after GC" \
  || ko "Scenario-A: stale leaf #10 state=$_st10 (expected CLOSED)"

_st11=$(issue_state 11)
[ "$_st11" = "CLOSED" ] \
  && ok "Scenario-A: stale leaf #11 is CLOSED after GC" \
  || ko "Scenario-A: stale leaf #11 state=$_st11 (expected CLOSED)"

# Board launchable must not list either closed leaf
_launch_a=$(PATH="$BIN:$PATH" CB_REPO="test/repo" CB_HOME="$CBHOME_A" \
  bash "$CBHOME_A/board-gh.sh" launchable 2>/dev/null || true)
printf '%s\n' "${_launch_a:-}" | grep -qE '^10$' \
  && ko "Scenario-A: stale leaf #10 appeared in board launchable (should be CLOSED)" \
  || ok "Scenario-A: stale leaf #10 absent from board launchable"
printf '%s\n' "${_launch_a:-}" | grep -qE '^11$' \
  && ko "Scenario-A: stale leaf #11 appeared in board launchable (should be CLOSED)" \
  || ok "Scenario-A: stale leaf #11 absent from board launchable"

# GC close must appear in the GH log
grep -q "close #10\|close #11" "$GH_LOG" \
  && ok "Scenario-A: GC close(s) recorded in gh log" \
  || ko "Scenario-A: no GC close in gh log (GC did not fire)"

# =============================================================================
# Scenario B — multi-charter prefix isolation (mandatory)
#
# Charter #5 AND charter #50 both at plan-review.  Each has a stale leaf.
# Plan-reviewer critiques #5 only (agrees on #50).
# Assertion: #5's stale leaf is CLOSED; #50's stale leaf remains OPEN.
#
# The IDs #5 and #50 are the critical choice: "Charter: #5" is a string-prefix
# of "Charter: #50", so a naive contains("Charter: #5") match would incorrectly
# close the #50 leaf.  The numsAfter numeric-equality filter must NOT do that.
# =============================================================================
echo "=== Scenario B: multi-charter prefix isolation (#5 closed, #50 untouched) ==="

# Critique-once flag: present → critique charter #5 once; absent → agree.
CRITIQUE_FLAG_B="$ROOT/critique-flag-b"
touch "$CRITIQUE_FLAG_B"
export CRITIQUE_FLAG_B

# Plan-reviewer stub: critique #5 the FIRST time only; agree on everything else.
PLAN_REVIEW_STUB="$ROOT/pr-stub-b.sh"
cat > "$PLAN_REVIEW_STUB" <<'PREOF'
#!/usr/bin/env bash
CID="$1"; RROLE="$2"
printf '%s %s\n' "$CID" "$RROLE" >> "$PLAN_REVIEW_LOG"
if [ "$CID" = "5" ] && [ -f "$CRITIQUE_FLAG_B" ]; then
  rm -f "$CRITIQUE_FLAG_B"
  gh issue comment "$CID" -R "test/repo" \
    --body "PLAN-REVIEW: changes-requested — add regen step"
  gh issue edit "$CID" -R "test/repo" \
    --remove-label status:plan-review \
    --add-label status:needs-plan
  exit 0
fi
# Agree (charter #50 always agrees; charter #5 agrees on 2nd pass)
gh issue comment "$CID" -R "test/repo" \
  --body "PLAN-REVIEW: agreed — plan grounded, all anchors sound"
gh issue edit "$CID" -R "test/repo" --add-label plan:agreed
exit 0
PREOF
chmod +x "$PLAN_REVIEW_STUB"

CBHOME_B="$ROOT/cbhome_b"; LOG_B="$ROOT/loop_b.log"
reset_sandbox "$CBHOME_B"
# Re-create the critique flag after reset_sandbox
touch "$CRITIQUE_FLAG_B"

# Seed board:
#   Charter #5  at plan-review + stale leaf #10 (Charter: #5)
#   Charter #50 at plan-review + stale leaf #51 (Charter: #50)
seed_board_json '[
  {"number":5,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:plan-review"},
             {"name":"composition:approved"},{"name":"review:agreed"}],
   "body":"charter 5 goal","comments":[]},
  {"number":50,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:plan-review"},
             {"name":"composition:approved"},{"name":"review:agreed"}],
   "body":"charter 50 goal","comments":[]},
  {"number":10,"state":"OPEN",
   "labels":[{"name":"type:agent"},{"name":"status:approved"}],
   "body":"Charter: #5","comments":[]},
  {"number":51,"state":"OPEN",
   "labels":[{"name":"type:agent"},{"name":"status:approved"}],
   "body":"Charter: #50","comments":[]}
]'

run_loop "$CBHOME_B" "$LOG_B" "CB_PLAN_CONVERGE_CAP=3" "CB_MAX_PARALLEL=1"

# Charter #5's stale leaf must be CLOSED (GC fired on critique)
_st10b=$(issue_state 10)
[ "$_st10b" = "CLOSED" ] \
  && ok "Scenario-B: charter-#5 stale leaf #10 is CLOSED after critique+GC" \
  || ko "Scenario-B: charter-#5 stale leaf #10 state=$_st10b (expected CLOSED — GC missed it)"

# Charter #50's stale leaf must remain OPEN (GC must NOT cross-match)
_st51b=$(issue_state 51)
[ "$_st51b" != "CLOSED" ] \
  && ok "Scenario-B: charter-#50 stale leaf #51 is NOT closed (numsAfter isolation correct)" \
  || ko "Scenario-B: charter-#50 stale leaf #51 is CLOSED (prefix false-match — numsAfter bug!)"

# GC log must mention closing leaf #10 for charter #5
grep -q "gc-stale-leaves.*#10\|closed.*#10" "$LOG_B" \
  && ok "Scenario-B: GC close of leaf #10 logged" \
  || ko "Scenario-B: GC close of leaf #10 NOT in launcher log"

# GC log must NOT mention closing leaf #51 (charter #50's leaf)
grep -q "gc-stale-leaves.*#51\|gc.*close.*#51" "$LOG_B" \
  && ko "Scenario-B: GC incorrectly tried to close leaf #51 (charter #50 leaf)" \
  || ok "Scenario-B: GC did NOT touch leaf #51 (charter #50 correctly isolated)"

# =============================================================================
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
