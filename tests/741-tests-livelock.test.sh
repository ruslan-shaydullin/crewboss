#!/usr/bin/env bash
# 741-tests-livelock.test.sh — ALLOW-class unit tests for charter #741 livelock fix
#
# Scenario (2): Livelock escalation — infra-error tick counter reaches N; verify
#               status:blocked is written with a descriptive message, NOT infinite retry.
#
# Charter #741 §4 intent: exit-3 (retryable/pending) must count ticks and route to
# status:blocked after N ticks, not retry silently forever. The NEW counter is for
# infra-error ticks only; the existing N-confirmation counter (integrator lines 497-519)
# for red-code confirmation is UNCHANGED.
#
# ALLOW-class: pure-function stubs; no real launcher loop, no real GHA, no background
# processes, no timing/poll/sleep, no recursive verify-merged calls.
# Criterion: verdict = f(stubbed tick counter + board call log); no live infra.
set -uo pipefail

pass=0; fail=0
ok()  { printf 'ok   %s\n' "$*"; pass=$((pass+1)); }
ko()  { printf 'FAIL %s\n' "$*"; fail=$((fail+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"
STATE="$TMP/state"; mkdir -p "$STATE"
BOARD_LOG="$TMP/board.log"
LIVELOCK_N="${CB_LIVELOCK_N:-5}"    # pending-threshold N (charter #741 §4)

# ── Reference implementation: infra-error tick counter (charter #741 §4) ────
#
# Separate from the N-confirmation counter (crewboss-integrator.sh lines 497-519).
# This counter tracks consecutive infra-error (exit-3/pending) ticks per leaf.
# On reaching N: write status:blocked with human-readable message; stop retrying.
#
# _infra_tick <leaf_id> <state_dir> <n_threshold>
#   Returns 0 if under threshold (retry allowed).
#   Returns 1 if threshold reached (block required); writes sentinel.
_infra_tick() {
  local lid="$1" sdir="$2" n_threshold="${3:-$LIVELOCK_N}"
  local tick_file="$sdir/${lid}_infra_ticks"
  local ticks=0
  [ -f "$tick_file" ] && ticks="$(cat "$tick_file" 2>/dev/null || echo 0)"
  ticks=$((ticks + 1))
  printf '%s' "$ticks" > "$tick_file"
  if [ "$ticks" -ge "$n_threshold" ]; then
    # Threshold reached: signal caller to route to blocked
    return 1
  fi
  return 0
}

# _livelock_route <leaf_id> <state_dir> <n_threshold>
# Simulates the launcher routing a leaf to status:blocked with a descriptive message.
# Writes to BOARD_LOG (simulates `board route ... status:blocked <msg>`).
_livelock_route() {
  local lid="$1" sdir="$2" n_threshold="${3:-$LIVELOCK_N}"
  local tick_file="$sdir/${lid}_infra_ticks"
  local ticks=0
  [ -f "$tick_file" ] && ticks="$(cat "$tick_file" 2>/dev/null || echo 0)"
  local msg="verify-merged: livelock detected — $ticks consecutive infra-error ticks (pending threshold=$n_threshold) — routed to status:blocked for human triage"
  printf 'route %s status:blocked %s\n' "$lid" "$msg" >> "$BOARD_LOG"
  printf 'blocked' > "$sdir/${lid}_status"
  return 0
}

# Simulate the verify-merged loop behaviour (charter #741 §4):
#   Each tick: verify-merged exits 3 (pending/infra-error) → _infra_tick bumps counter.
#   On reaching N: _livelock_route writes status:blocked message.
_simulate_pending_ticks() {
  local lid="$1" sdir="$2" n_threshold="${3:-$LIVELOCK_N}"
  local i=0
  while [ $i -lt $((n_threshold + 1)) ]; do
    i=$((i + 1))
    # Simulate verify-merged exit 3 (pending/infra-error)
    if ! _infra_tick "$lid" "$sdir" "$n_threshold"; then
      # Threshold reached: route to blocked
      _livelock_route "$lid" "$sdir" "$n_threshold"
      return 0
    fi
    # Under threshold: would retry next tick — just continue loop
  done
  # Should never reach here (loop should have routed to blocked)
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Scenario 2: Livelock escalation — infra-error tick counter ==="
LIVELOCK_N=5

# 2a: Counter increments correctly below threshold
mkdir -p "$STATE/leaf42"
TICK_FILE="$STATE/leaf42_infra_ticks"
rm -f "$TICK_FILE"

for i in 1 2 3 4; do
  _infra_tick "leaf42" "$STATE" "$LIVELOCK_N"
  ticks="$(cat "$TICK_FILE" 2>/dev/null || echo 0)"
  [ "$ticks" = "$i" ] \
    && ok "S2-tick-$i: counter = $i after tick $i (under threshold, returns 0)" \
    || ko "S2-tick-$i: expected counter=$i, got '$ticks'"
done

# 2b: At threshold (tick N): returns 1 (block required)
rc=0
_infra_tick "leaf42" "$STATE" "$LIVELOCK_N" || rc=$?
[ "$rc" = "1" ] \
  && ok "S2b: tick $LIVELOCK_N reaches threshold → _infra_tick returns 1 (block required)" \
  || ko "S2b: expected rc=1 at threshold, got '$rc'"

# 2c: Full simulation: N ticks → status:blocked written with descriptive message
rm -f "$BOARD_LOG" "$STATE/leaf42_infra_ticks" "$STATE/leaf42_status"
mkdir -p "$STATE"
_simulate_pending_ticks "leaf42" "$STATE" "$LIVELOCK_N"

[ -f "$BOARD_LOG" ] \
  && ok "S2c: board route called (board.log written)" \
  || ko "S2c: board route NOT called after N ticks (livelock NOT resolved)"

grep -q "status:blocked" "$BOARD_LOG" 2>/dev/null \
  && ok "S2c: board route writes status:blocked" \
  || ko "S2c: status:blocked NOT written to board"

grep -q "human" "$BOARD_LOG" 2>/dev/null \
  && ok "S2c: blocked message is human-readable (contains 'human')" \
  || ko "S2c: blocked message missing human-readable content"

grep -q "infra" "$BOARD_LOG" 2>/dev/null \
  && ok "S2c: blocked message describes infra-error cause" \
  || ko "S2c: blocked message missing infra-error description"

grep -q "livelock\|pending.*threshold\|threshold.*pending" "$BOARD_LOG" 2>/dev/null \
  && ok "S2c: blocked message references livelock/pending-threshold" \
  || ko "S2c: blocked message missing livelock/threshold context"

[ -f "$STATE/leaf42_status" ] && [ "$(cat "$STATE/leaf42_status")" = "blocked" ] \
  && ok "S2c: leaf status written as 'blocked' after N ticks" \
  || ko "S2c: leaf status not 'blocked': '$(cat "$STATE/leaf42_status" 2>/dev/null)'"

# 2d: Counter does NOT route to blocked before N ticks (no false-positive livelock)
rm -f "$BOARD_LOG" "$STATE/leaf42_infra_ticks" "$STATE/leaf42_status"
LIVELOCK_N=5

# Simulate N-1 ticks (should not block)
for i in $(seq 1 $((LIVELOCK_N - 1))); do
  _infra_tick "leaf42" "$STATE" "$LIVELOCK_N" || true
done

[ ! -f "$BOARD_LOG" ] \
  && ok "S2d: $((LIVELOCK_N-1)) ticks (< N=$LIVELOCK_N) does NOT write blocked status" \
  || ko "S2d: false-positive livelock at $((LIVELOCK_N-1)) ticks (< N=$LIVELOCK_N)"

# 2e: Infra-error counter is SEPARATE from the red-confirmation counter
#     (integrator lines 497-519 counter tracks suite_rc=1; this tracks pending/exit-3)
rm -f "$STATE/leaf42_infra_ticks" "$STATE/leaf42_redcount"
# Simulate 3 infra-error ticks (using infra counter)
for i in 1 2 3; do
  _infra_tick "leaf42" "$STATE" "$LIVELOCK_N" || true
done
# Red-confirmation counter should be untouched by infra-error ticks
[ ! -f "$STATE/leaf42_redcount" ] \
  && ok "S2e: infra-error ticks do NOT touch the red-confirmation counter (separate counters)" \
  || ko "S2e: infra-error ticks incorrectly touched red-confirmation counter"

# ─────────────────────────────────────────────────────────────────────────────
echo
printf '=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
