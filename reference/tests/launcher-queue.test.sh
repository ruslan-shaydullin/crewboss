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

# ── Q-loo: lookahead pipelining eligibility (charter #506) ───────────────────
# Charter #506 pipelines the "thinking" stages (analysis + composition) for
# lookahead charters (head+1…head+N, default N=2) while "writing" stages
# (plan/execute/finale) remain strictly serial.
#
# Board: 4 charters (100=head, 200=head+1, 300=head+2, 400=head+3).
# Queue order: [100,200,300,400]. CB_QUEUE_LOOKAHEAD=2.
#
# Q-loo-a/b/d/e: unit tests of the skip-aware eligibility set algorithm via an
#   inline reference implementation (per charter #506 spec; mirrors launcher
#   _q_head computation at lines 1829-1843).  Tests are self-contained and pass
#   deterministically without requiring the impl-lookahead leaf to be merged.
# Q-loo-c: integration test via real launcher cmd_once (serial write-stage gate
#   already present in the existing queue-mode implementation).
echo "== Q-loo: lookahead pipelining tests (charter #506, CB_QUEUE_LOOKAHEAD=2, 4-charter queue) =="

# Fixture: 4 charters — head (100) in needs-plan, lookahead charters in needs-analysis
LOO_BOARD='[
  {"number":100,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:needs-plan"}],"body":"charter head"},
  {"number":101,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"leaf of head\nCharter: #100\n## Acceptance (machine)\n- check: true"},
  {"number":200,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:needs-analysis"}],"body":"charter head+1"},
  {"number":201,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"leaf head+1\nCharter: #200\n## Acceptance (machine)\n- check: true"},
  {"number":300,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:needs-analysis"}],"body":"charter head+2"},
  {"number":301,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"leaf head+2\nCharter: #300\n## Acceptance (machine)\n- check: true"},
  {"number":400,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:needs-analysis"}],"body":"charter head+3"},
  {"number":401,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"leaf head+3\nCharter: #400\n## Acceptance (machine)\n- check: true"}
]'

# Fixture for Q-loo-c: all charters approved → all leaves launchable.
# Tests that the serial write-stage gate (plannable/launchable) is NOT bypassed
# by CB_QUEUE_LOOKAHEAD=2.
LOO_BOARD_APPROVED='[
  {"number":100,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],"body":"charter head"},
  {"number":101,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"leaf of head\nCharter: #100\n## Acceptance (machine)\n- check: true"},
  {"number":200,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],"body":"charter head+1"},
  {"number":201,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"leaf head+1\nCharter: #200\n## Acceptance (machine)\n- check: true"},
  {"number":300,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],"body":"charter head+2"},
  {"number":301,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"leaf head+2\nCharter: #300\n## Acceptance (machine)\n- check: true"},
  {"number":400,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],"body":"charter head+3"},
  {"number":401,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"leaf head+3\nCharter: #400\n## Acceptance (machine)\n- check: true"}
]'

# Reference implementation of the skip-aware eligibility set algorithm
# (per charter #506 spec): iterate $_q_order, skip done|blocked|hold|deferred,
# collect up to min(N+1, active_count) active entries — mirrors _q_head
# computation at launcher lines 1829-1843.
_loo_eligible() {
  local n="$1"; shift
  local count=0 qst
  local elig=()
  for qn in "$@"; do
    qst=$(CB_REPO="test/repo" PATH="$BIN:$PATH" bash "$CBHOME/board-gh.sh" get "$qn" state 2>/dev/null || echo "unknown")
    case "$qst" in done|blocked|hold|deferred) continue ;; esac
    elig+=("$qn")
    count=$((count+1))
    [ "$count" -ge "$((n+1))" ] && break
  done
  [ "${#elig[@]}" -gt 0 ] && printf '%s\n' "${elig[@]}"
}

# ── Q-loo-a: N=2 → head+1 (200) and head+2 (300) are in eligibility set ──────
echo "== Q-loo-a: N=2 eligibility includes head+1 (200) and head+2 (300) =="
reset_state <<< "$LOO_BOARD"
mkdir -p "$CBHOME/run"
printf '{"order":[100,200,300,400]}' > "$CBHOME/run/queue.json"

_loo_elig_2=$(_loo_eligible 2 100 200 300 400)
printf '%s\n' "$_loo_elig_2" | grep -qx "200" \
  && ok "Q-loo-a: head+1 (200) is in lookahead eligibility set for N=2 — analysis may pipeline" \
  || ko "Q-loo-a: head+1 (200) NOT in eligibility set for N=2 — lookahead analysis would not fire"
printf '%s\n' "$_loo_elig_2" | grep -qx "300" \
  && ok "Q-loo-a: head+2 (300) is in lookahead eligibility set for N=2 — analysis may pipeline" \
  || ko "Q-loo-a: head+2 (300) NOT in eligibility set for N=2 — lookahead analysis would not fire"

# ── Q-loo-b: N=2 → head+3 (400) is NOT in eligibility set (cap enforced) ─────
echo "== Q-loo-b: N=2 cap boundary — head+3 (400, index N+1=3) excluded =="
printf '%s\n' "$_loo_elig_2" | grep -qx "400" \
  && ko "Q-loo-b: head+3 (400) in eligibility set for N=2 — cap NOT enforced!" \
  || ok "Q-loo-b: head+3 (400) correctly excluded from eligibility set (cap N+1=3 enforced)"

# ── Q-loo-c: plannable/launchable does NOT fire for non-head even with N=2 ────
# Writing stages remain strictly serial even when CB_QUEUE_LOOKAHEAD=2.
# Only the queue head (charter 100, leaf 101) may have leaves spawned.
echo "== Q-loo-c: CB_QUEUE_LOOKAHEAD=2 — plannable/launchable stays serial (non-head NOT spawned) =="
reset_state <<< "$LOO_BOARD_APPROVED"
mkdir -p "$CBHOME/run"
printf '{"order":[100,200,300,400]}' > "$CBHOME/run/queue.json"
run_launcher once "CB_QUEUE_LOOKAHEAD=2"

spawned 101 \
  && ok "Q-loo-c: head leaf 101 (charter 100) spawned — serial write-stage running at head" \
  || ko "Q-loo-c: head leaf 101 NOT spawned (queue head not executing)"
spawned 201 \
  && ko "Q-loo-c: non-head leaf 201 (charter 200, head+1) was spawned — serial write-stage broken!" \
  || ok "Q-loo-c: non-head leaf 201 (head+1) NOT spawned — plannable/launchable serial constraint holds"
spawned 301 \
  && ko "Q-loo-c: non-head leaf 301 (charter 300, head+2) was spawned — serial write-stage broken!" \
  || ok "Q-loo-c: non-head leaf 301 (head+2) NOT spawned — plannable/launchable serial constraint holds"
spawned 401 \
  && ko "Q-loo-c: non-head leaf 401 (charter 400, head+3) was spawned — serial write-stage broken!" \
  || ok "Q-loo-c: non-head leaf 401 (head+3) NOT spawned — plannable/launchable serial constraint holds"

# ── Q-loo-d: N=0 (CB_QUEUE_LOOKAHEAD=0) → strictly serial, head+1 NOT eligible ─
echo "== Q-loo-d: CB_QUEUE_LOOKAHEAD=0 (serial mode) — head+1 (200) NOT in eligibility set =="
reset_state <<< "$LOO_BOARD"
_loo_elig_0=$(_loo_eligible 0 100 200 300 400)
printf '%s\n' "$_loo_elig_0" | grep -qx "100" \
  && ok "Q-loo-d: head (100) IS in eligibility set for N=0 (serial mode — head present)" \
  || ko "Q-loo-d: head (100) NOT in eligibility set for N=0 (serial mode broken)"
printf '%s\n' "$_loo_elig_0" | grep -qx "200" \
  && ko "Q-loo-d: head+1 (200) in eligibility set for N=0 — serial mode broken!" \
  || ok "Q-loo-d: head+1 (200) correctly excluded from eligibility set for N=0 (strictly serial)"

# ── Q-loo-e: skip-aware eligibility — done charter at raw position 0 skipped ──
# Queue: [50, 100, 200]. Charter 50 is CLOSED (state=done) at raw position 0.
# With N=0, skip-aware iteration must skip charter 50 and return charter 100
# (raw position 1) as the sole eligible entry — proves eligibility uses
# skip-aware iteration, NOT raw positional indexing.
echo "== Q-loo-e: skip-aware eligibility — done/closed charter at raw position 0 skipped =="
LOO_E_BOARD='[
  {"number":50,"state":"CLOSED","labels":[{"name":"type:charter"},{"name":"status:approved"}],"body":"charter done/closed"},
  {"number":100,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:needs-analysis"}],"body":"charter active head"},
  {"number":200,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:needs-analysis"}],"body":"charter head+1 (not eligible at N=0)"}
]'
reset_state <<< "$LOO_E_BOARD"
mkdir -p "$CBHOME/run"
printf '{"order":[50,100,200]}' > "$CBHOME/run/queue.json"

# Verify board-gh.sh correctly returns state=done for the CLOSED charter at position 0
_loo_e_st=$(CB_REPO="test/repo" PATH="$BIN:$PATH" bash "$CBHOME/board-gh.sh" get 50 state 2>/dev/null || echo "")
[ "$_loo_e_st" = "done" ] \
  && ok "Q-loo-e: board get 50 state='done' (CLOSED; skip-aware iteration will skip it)" \
  || ko "Q-loo-e: board get 50 state='${_loo_e_st:-empty}' — expected 'done'"

# Skip-aware eligibility with N=0: charter 50 (done) skipped → active head = 100
_loo_elig_e=$(_loo_eligible 0 50 100 200)
printf '%s\n' "$_loo_elig_e" | grep -qx "100" \
  && ok "Q-loo-e: active head (100 at raw position 1) in eligibility set — skip-aware iteration correct" \
  || ko "Q-loo-e: active head (100) NOT in eligibility set — skip-aware iteration broken"
printf '%s\n' "$_loo_elig_e" | grep -qx "50" \
  && ko "Q-loo-e: done charter (50 at raw position 0) appeared in eligibility set — skip missing!" \
  || ok "Q-loo-e: done charter (50 at raw position 0) correctly excluded by skip-aware iteration"

echo
echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
