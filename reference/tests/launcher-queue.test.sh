#!/usr/bin/env bash
# launcher-queue.test.sh — queue-mode integration tests for the canonical launcher.
#
# Tests Q-a, Q-b, Q-c (issue #281).
# Class i: integration with stubs (stateful board-JSON + gh stub + CB_SPAWN stub).
# Follows the same pattern as reference/tests/launcher-gh-scope.test.sh.
#
# Board: charter A (number=50, leaf=51), charter B (number=100, leaf=101),
#        charter C (number=200, leaf=201, for Q-b only).
# B > A numerically, so without a queue, A's leaf (51) would be picked first by
# default ascending sort from board launchable.
#
# Q-a: queue.json {"order":[100,50]} → B is head (higher number first),
#      B's leaf (101) spawned before A's leaf (51).
# Q-b: charter C (200) not in queue → its leaf (201) never spawned even if launchable.
# Q-c: absent queue.json → both A (51) and B (101) are spawned (regression lock).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
LAUNCHER="$HERE/../runtime/crewboss-launcher-gh.sh"
BOARD_GH_SRC="$REPO_ROOT/proto/r6/board-gh.sh"
LAUNCHABLE_SRC="$REPO_ROOT/proto/r6/launchable.sh"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"
CBHOME="$ROOT/cbhome"
SPAWN_LOG="$ROOT/spawn.log"

export BOARD_STATE="$ROOT/board.json"
export GH_LOG="$ROOT/gh.log"

mkdir -p "$BIN" "$CBHOME"

# Install board-gh.sh and launchable.sh (canonical proto/r6 versions) into CBHOME
cp "$BOARD_GH_SRC"   "$CBHOME/board-gh.sh"
cp "$LAUNCHABLE_SRC" "$CBHOME/launchable.sh"
chmod +x "$CBHOME/board-gh.sh" "$CBHOME/launchable.sh"

pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

# ── gh stub: stateful board JSON mutations ────────────────────────────────────
cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
obj="$1"; verb="$2"; shift 2
# strip -R/--repo and -L flags (with their values)
_args=()
while [ $# -gt 0 ]; do
  case "$1" in
    -R|--repo) shift ;;
    -L)        shift ;;
    *) _args+=("$1") ;;
  esac
  shift
done
set -- "${_args[@]+"${_args[@]}"}"

case "$obj $verb" in
  "issue list")
    state="all"
    while [ $# -gt 0 ]; do
      case "$1" in --state) state="$2"; shift ;; esac; shift
    done
    if [ "$state" = "open" ]; then
      jq '[.[] | select(.state == "OPEN")]' "$BOARD_STATE"
    else
      cat "$BOARD_STATE"
    fi ;;
  "issue view")
    n="$1"
    jq --argjson n "$n" '[.[] | select(.number==$n)][0] // {}' "$BOARD_STATE" ;;
  "issue edit")
    n="$1"; shift; add=""; rem=""
    while [ $# -gt 0 ]; do case "$1" in
      --add-label)    add="$2"; shift ;;
      --remove-label) rem="$2"; shift ;;
    esac; shift; done
    jq --argjson n "$n" --arg add "$add" --arg rem "$rem" '
      map(if .number==$n then
        .labels = [(.labels // [])[]]
          | (if $rem != "" then .labels = [(.labels[]) | select(.name != $rem)] else . end)
          | (if $add != "" and ([.labels[].name] | index($add)) == null
             then .labels += [{name: $add}] else . end)
      else . end)' \
      "$BOARD_STATE" > "$BOARD_STATE.t" && mv "$BOARD_STATE.t" "$BOARD_STATE"
    echo "edit #$n +[$add] -[$rem]" >> "$GH_LOG" ;;
  "label create") true ;;
  *) echo "stub gh UNHANDLED: $obj $verb $*" >> "$GH_LOG" ;;
esac
exit 0
GH
chmod +x "$BIN/gh"

# ── spawn stub: records calls, writes status.json (phase=done) for run routing ─
SPAWN_LOG_PATH="$SPAWN_LOG"
CBHOME_PATH="$CBHOME"
cat > "$ROOT/stub-spawn.sh" << EOF
#!/usr/bin/env bash
id="\$1"; role="\$2"
echo "spawned \$id \$role" >> "${SPAWN_LOG_PATH}"
mkdir -p "${CBHOME_PATH}/run/work/\$id"
printf '{"phase":"done"}' > "${CBHOME_PATH}/run/work/\$id/status.json"
exit 0
EOF
chmod +x "$ROOT/stub-spawn.sh"

# ── helpers ──────────────────────────────────────────────────────────────────
reset_state(){
  rm -rf "$CBHOME/run"
  rm -f "$SPAWN_LOG" "$GH_LOG"
  touch "$SPAWN_LOG" "$GH_LOG"
  cat > "$BOARD_STATE"   # board JSON on stdin
}

spawned(){
  # spawned <id>: true if any spawn call for issue $1 appears in SPAWN_LOG
  grep -q "^spawned $1 " "$SPAWN_LOG" 2>/dev/null
}

run_launcher(){
  # run_launcher <subcommand> [VAR=value ...]
  local sub="${1:-once}"; shift || true
  (
    export CB_REPO="test/repo"
    export CB_HOME="$CBHOME"
    export CB_SPAWN="$ROOT/stub-spawn.sh"
    export CB_MAX_PARALLEL=10
    export CB_RETRY_CAP=2
    export CB_POLL=0
    export CB_IDLE_CONFIRM=1
    export CB_MAX_TICKS=20
    # Prevent integrator stale-guard from moving review leaves to blocked during
    # short test runs (default threshold=10 ticks fires before CB_MAX_TICKS=20).
    export CB_REVIEW_STALE_TICKS=999
    # Isolate from caller's environment so unscoped runs are not accidentally
    # scoped, and non-CB_SPAWN spawn scripts default to the test stub.
    # CB_MANIFEST/CB_MANIFEST_LIB must also be cleared: an inherited CB_MANIFEST
    # pointing to a box-local path would fail manifest_validate and exit 65 before
    # any queue logic runs (and would inject --require-composition into launchable,
    # silently making all leaves non-launchable even when the path exists).
    unset CREWBOSS_CHARTER CB_PLAN_SPAWN CB_ANALYSIS_SPAWN CB_APPROVAL_SPAWN CB_CONFLICT_SPAWN CB_REWORK_SPAWN CB_MANIFEST CB_MANIFEST_LIB
    # Apply explicit overrides.
    for kv in "$@"; do export "${kv?}"; done
    PATH="$BIN:$PATH" bash "$LAUNCHER" "$sub"
  ) >/dev/null 2>&1
}

# ── Board fixture ─────────────────────────────────────────────────────────────
# Charter A = 50 (low number), leaf = 51.
# Charter B = 100 (high number), leaf = 101.  B > A, so without a queue the
# default ascending sort from board launchable returns A's leaf (51) first.
# Charter C = 200 (not in queue), leaf = 201.
QUEUE_BOARD='[
  {"number":50,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],"body":"charter A"},
  {"number":51,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"leaf of A\nCharter: #50\n## Acceptance (machine)\n- check: true"},
  {"number":100,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],"body":"charter B"},
  {"number":101,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"leaf of B\nCharter: #100\n## Acceptance (machine)\n- check: true"},
  {"number":200,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],"body":"charter C"},
  {"number":201,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"leaf of C\nCharter: #200\n## Acceptance (machine)\n- check: true"}
]'

# ── Q-a + Q-b: queue {"order":[100,50]} — B before A, C excluded ─────────────
echo "== Q-a+Q-b: queue-mode order=[100,50] — B (101) before A (51), C (201) excluded =="
reset_state <<< "$QUEUE_BOARD"

# Write queue.json so queue-mode activates
mkdir -p "$CBHOME/run"
printf '{"order":[100,50]}' > "$CBHOME/run/queue.json"

# Run 1: head=100 (charter B), spawn B's leaf (101)
run_launcher once

# Advance queue: close charter B (state→done/terminal-for-queue) so A becomes head
jq 'map(if .number==100 then .state="CLOSED" else . end)' \
  "$BOARD_STATE" > "$BOARD_STATE.t" && mv "$BOARD_STATE.t" "$BOARD_STATE"

# Run 2: head=50 (charter A now), spawn A's leaf (51)
run_launcher once

# Q-a: leaf 101 (B) must appear in spawn log BEFORE leaf 51 (A)
b_line=$(grep -n "^spawned 101 " "$SPAWN_LOG" 2>/dev/null | head -1 | cut -d: -f1)
a_line=$(grep -n "^spawned 51 "  "$SPAWN_LOG" 2>/dev/null | head -1 | cut -d: -f1)
if [ -n "$b_line" ] && [ -n "$a_line" ] && [ "$b_line" -lt "$a_line" ]; then
  ok "Q-a: leaf 101 (charter B=100) spawned at line $b_line before leaf 51 (charter A=50) at line $a_line — queue order respected"
else
  ko "Q-a: expected leaf 101 before 51 in spawn log (101@${b_line:-MISSING}, 51@${a_line:-MISSING})"
fi

# Q-b: leaf 201 (charter C=200, not in queue) must never be spawned
spawned 201 \
  && ko "Q-b: leaf 201 (charter C=200, not in queue) was spawned — queue filter missing!" \
  || ok "Q-b: leaf 201 (charter C=200, not in queue) correctly excluded by queue-mode"

# ── Q-c: absent queue.json → regression check — both A and B spawned ──────────
echo "== Q-c: absent queue.json → no queue restriction — both A (51) and B (101) spawned =="
reset_state <<< "$QUEUE_BOARD"
# (No queue.json → absent → existing behaviour unchanged)
run_launcher once

spawned 101 \
  && ok "Q-c: leaf 101 (charter B) spawned without queue — regression lock OK" \
  || ko "Q-c: leaf 101 NOT spawned without queue — regression!"

spawned 51 \
  && ok "Q-c: leaf 51 (charter A) spawned without queue — regression lock OK" \
  || ko "Q-c: leaf 51 NOT spawned without queue — regression!"

# ── Q-hold: held charter at head → queue advances to B ────────────────────────
# Regression for the Q-hold failure mode: charter A (50) carries the `hold`
# label and sits at the head of the queue.  Without the fix, _q_head resolves
# to 50 (board get 50 state returned "approved"), so leaf 51 is spawned instead
# of leaf 101 — freezing forward progress for charter B.
# Fix (leaf/686-impl): board-gh.sh state chain gains a `hold` branch BEFORE
# status:blocked; launcher _q_head / _q_plan_head / _q_accept_head skip "hold".
#
# Board: charter A=50 (hold+approved, head of queue), leaf A=51;
#        charter B=100 (approved), leaf B=101.  Queue: [50,100].
# Assertions:
#   (1) board get 50 state  → "hold"    (board-gh.sh hold-branch patch)
#   (2) charter A (50) visible in queue order after launcher run (not purged)
#   (3) leaf 101 IS spawned  (queue advanced to B)
#   (4) leaf 51 is NOT spawned (held charter correctly skipped)
echo "== Q-hold: held charter A (50) at queue head → B (100) becomes head, leaf 101 spawned =="

HOLD_BOARD='[
  {"number":50,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"hold"},{"name":"status:approved"}],"body":"charter A (held)"},
  {"number":51,"state":"OPEN","labels":[{"name":"type:agent"},{"name":"status:approved"}],"body":"leaf of A\nCharter: #50\n## Acceptance (machine)\n- check: true"},
  {"number":100,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],"body":"charter B"},
  {"number":101,"state":"OPEN","labels":[{"name":"type:agent"},{"name":"status:approved"}],"body":"leaf of B\nCharter: #100\n## Acceptance (machine)\n- check: true"}
]'

reset_state <<< "$HOLD_BOARD"
mkdir -p "$CBHOME/run"
printf '{"order":[50,100]}' > "$CBHOME/run/queue.json"

# (1) Unit check: board get 50 state returns "hold"
# Verifies the board-gh.sh hold-branch patch (leaf/686-impl): the `hold` label
# must be detected BEFORE status:approved in the state jq chain.
_bstate=$(CB_REPO="test/repo" PATH="$BIN:$PATH" bash "$CBHOME/board-gh.sh" get 50 state 2>/dev/null || echo "")
[ "$_bstate" = "hold" ] \
  && ok "Q-hold: board get 50 state returns 'hold' (board-gh.sh hold-branch patch verified)" \
  || ko "Q-hold: board get 50 state returned '${_bstate:-empty}' — expected 'hold' (board-gh.sh patch from leaf/686-impl not yet applied)"

# Run the launcher; _q_head must skip charter A (hold) and resolve to B (100)
run_launcher once

# (2) Queue order invariant: charter A must remain visible in queue.json
# The launcher reads but must NOT modify queue.json; a held charter is skipped,
# not purged, so the queue retains the full order for future advancement.
_q50=$(jq -r 'if (.order | index(50)) != null then "yes" else "no" end' \
         "$CBHOME/run/queue.json" 2>/dev/null || echo "no")
[ "$_q50" = "yes" ] \
  && ok "Q-hold: charter A (50) remains in queue order (not purged by launcher)" \
  || ko "Q-hold: charter A (50) unexpectedly absent from queue.json after launcher run"

# (3) Leaf 101 (charter B=100) MUST be spawned
spawned 101 \
  && ok "Q-hold: leaf 101 (charter B=100) IS spawned — queue advanced past held A=50" \
  || ko "Q-hold: leaf 101 NOT spawned — queue did not advance past held charter A=50"

# (4) Leaf 51 (charter A=50, held) must NOT be spawned
spawned 51 \
  && ko "Q-hold: leaf 51 (charter A=50, held) was spawned — hold not respected by queue!" \
  || ok "Q-hold: leaf 51 (charter A=50, held) correctly NOT spawned"


# ── Lookahead eligibility helper (spec contract for Q-loo-* tests) ────────────
# _q_eligible_set: compute the analysis-eligible charter set under the
# CB_QUEUE_LOOKAHEAD policy (charter #506). Implements the CONTRACT that
# crewboss-launcher-gh.sh must satisfy after the implementation leaf lands:
#   - Skip done|blocked|hold|deferred entries (matching _q_head semantics,
#     runtime lines 1406-1421 — NOT a raw positional slice).
#   - Output at most N+1 entries: head (index 0) through head+N (index N).
#   - N=0 → strictly serial (only head); identical to the current baseline.
#
# Args:
#   $1  space-separated charter IDs in priority queue order
#   $2  CB_QUEUE_LOOKAHEAD value (N ≥ 0)
#   $3  name of bash function: f <id> → state string (e.g. "needs-analysis")
# Output: one eligible charter ID per line, in queue priority order.
_q_eligible_set(){
  local order="$1" n="$2" state_fn="$3"
  local count=0
  for id in $order; do
    local st
    st=$("$state_fn" "$id")
    case "$st" in done|blocked|hold|deferred) continue ;; esac
    printf '%s\n' "$id"
    [ "$count" -ge "$n" ] && return 0
    count=$((count+1))
  done
}

# Board fixture for Q-loo-* integration tests: 4 charters (50,100,200,300),
# each with one approved leaf (51,101,201,301). All charters status:approved
# so every leaf is launchable — used by Q-loo-c (write-stage serialization).
LOO_BOARD='[
  {"number":50,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],"body":"charter 1"},
  {"number":51,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"leaf of charter 1\nCharter: #50\n## Acceptance (machine)\n- check: true"},
  {"number":100,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],"body":"charter 2"},
  {"number":101,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"leaf of charter 2\nCharter: #100\n## Acceptance (machine)\n- check: true"},
  {"number":200,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],"body":"charter 3"},
  {"number":201,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"leaf of charter 3\nCharter: #200\n## Acceptance (machine)\n- check: true"},
  {"number":300,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],"body":"charter 4"},
  {"number":301,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"leaf of charter 4\nCharter: #300\n## Acceptance (machine)\n- check: true"}
]'

# ── Q-loo-a (positive lookahead) ──────────────────────────────────────────────
# With CB_QUEUE_LOOKAHEAD=2 and ≥4 active charters in the queue, the analysis-
# eligible set must include head+1 (index 1) and head+2 (index 2) in addition to
# the head (index 0). Verifies the _q_eligible_set contract for N=2.
echo "== Q-loo-a: CB_QUEUE_LOOKAHEAD=2 — analysis eligible includes head+1 and head+2 =="

_q_loo_state_active(){ echo "needs-analysis"; }  # all four charters are active

_loo_a_set=$(_q_eligible_set "10 20 30 40" 2 _q_loo_state_active)

printf '%s\n' "$_loo_a_set" | grep -q "^20$" \
  && ok "Q-loo-a: head+1 (20) IS in analysis eligible set with LOOKAHEAD=2" \
  || ko "Q-loo-a: head+1 (20) NOT in analysis eligible set with LOOKAHEAD=2"

printf '%s\n' "$_loo_a_set" | grep -q "^30$" \
  && ok "Q-loo-a: head+2 (30) IS in analysis eligible set with LOOKAHEAD=2" \
  || ko "Q-loo-a: head+2 (30) NOT in analysis eligible set with LOOKAHEAD=2"

# ── Q-loo-b (negative cap boundary) ──────────────────────────────────────────
# With CB_QUEUE_LOOKAHEAD=2 (N=2) the eligible set covers indices 0..2. Index 3
# (head+3) must NOT appear — proves the cap is enforced, not merely that head+1
# and head+2 appear incidentally.
echo "== Q-loo-b: CB_QUEUE_LOOKAHEAD=2 — analysis does NOT fire for head+3 (index 3) =="

# Reuse _loo_a_set (same queue [10,20,30,40], N=2) — avoids recomputation.
printf '%s\n' "$_loo_a_set" | grep -q "^40$" \
  && ko "Q-loo-b: head+3 (40) IN eligible set — lookahead cap N=2 not enforced!" \
  || ok "Q-loo-b: head+3 (40) NOT in eligible set — lookahead cap N=2 correctly enforced"

# ── Q-loo-c (negative behavior — write-stage serialization) ───────────────────
# Regardless of CB_QUEUE_LOOKAHEAD, launchable/plannable (write-stage dispatches)
# must only fire for the queue HEAD, not for head+1 or beyond.
# Integration test: 4-charter queue, all charters approved with launchable leaves.
# Even with LOOKAHEAD=2, only the head leaf (51) must be spawned; non-head leaves
# (101, 201, …) must remain untouched.
echo "== Q-loo-c: write-stage serialization — launchable fires for head (51) only =="
reset_state <<< "$LOO_BOARD"
mkdir -p "$CBHOME/run"
printf '{"order":[50,100,200,300]}' > "$CBHOME/run/queue.json"
run_launcher once "CB_QUEUE_LOOKAHEAD=2"

spawned 51 \
  && ok "Q-loo-c: head leaf (51, charter 50) spawned — head dispatched correctly" \
  || ko "Q-loo-c: head leaf (51, charter 50) NOT spawned — head dispatch broken!"

spawned 101 \
  && ko "Q-loo-c: leaf 101 (charter 100=head+1) spawned — write-stage leaked beyond head!" \
  || ok "Q-loo-c: leaf 101 (head+1) NOT spawned — write-stage serialization enforced with LOOKAHEAD=2"

spawned 201 \
  && ko "Q-loo-c: leaf 201 (charter 200=head+2) spawned — write-stage leaked beyond head!" \
  || ok "Q-loo-c: leaf 201 (head+2) NOT spawned — write-stage serialization enforced with LOOKAHEAD=2"

# ── Q-loo-d (N=0 serial mode) ─────────────────────────────────────────────────
# CB_QUEUE_LOOKAHEAD=0 is strictly serial: only the head (index 0) is eligible
# for analysis. head+1 (index 1) must NOT appear in the eligible set — this is
# identical to the current baseline behaviour where no lookahead exists.
echo "== Q-loo-d: CB_QUEUE_LOOKAHEAD=0 — serial mode, head+1 NOT in eligible set =="

# _q_loo_state_active defined above: returns "needs-analysis" for all IDs.
_loo_d_set=$(_q_eligible_set "10 20" 0 _q_loo_state_active)

printf '%s\n' "$_loo_d_set" | grep -q "^10$" \
  && ok "Q-loo-d: head (10) IS in eligible set with LOOKAHEAD=0 — head always included" \
  || ko "Q-loo-d: head (10) NOT in eligible set with LOOKAHEAD=0 — broken!"

printf '%s\n' "$_loo_d_set" | grep -q "^20$" \
  && ko "Q-loo-d: head+1 (20) IN eligible set with LOOKAHEAD=0 — serial mode broken!" \
  || ok "Q-loo-d: head+1 (20) NOT in eligible set with LOOKAHEAD=0 — serial mode correct"

# ── Q-loo-e (skip-aware eligibility — done/held at raw position 0) ────────────
# Eligibility-set construction must skip done|blocked|hold|deferred entries,
# matching _q_head semantics (runtime lines 1406-1421). It must NOT use a raw
# positional slice. With hold at raw index 0 and CB_QUEUE_LOOKAHEAD=0:
#   - raw index 0 (charter 10, held) is skipped → NOT in the eligible set
#   - raw index 1 (charter 20, active) becomes the actual head → IS in the set
# This proves the eligibility walk is state-filtered, not a raw slice.
echo "== Q-loo-e: hold at raw index 0 — actual head resolves to first active (raw index 1) =="

_q_loo_e_state(){
  case "$1" in 10) echo "hold" ;; *) echo "needs-analysis" ;; esac
}
_loo_e_set=$(_q_eligible_set "10 20 30" 0 _q_loo_e_state)

printf '%s\n' "$_loo_e_set" | grep -q "^10$" \
  && ko "Q-loo-e: held charter (10 at raw index 0) IS in eligible set — hold not skipped!" \
  || ok "Q-loo-e: held charter (10 at raw index 0) NOT in eligible set — hold correctly skipped"

printf '%s\n' "$_loo_e_set" | grep -q "^20$" \
  && ok "Q-loo-e: first active charter (20 at raw index 1) IS eligible — skip-aware head correct" \
  || ko "Q-loo-e: first active charter (20 at raw index 1) NOT eligible — eligibility broken"

echo
echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
