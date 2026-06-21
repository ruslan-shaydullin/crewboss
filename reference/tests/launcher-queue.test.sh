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

echo
echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
