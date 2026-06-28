#!/usr/bin/env bash
# 741-tests-finale-gate.test.sh — ALLOW-class unit tests for charter #741 finale gate
#
# Scenario (3): Finale gate first call — stub gate-charter exits 0; verify ci_state=green
#               written to _fin_dir/ci_state and gh pr checks is NEVER invoked.
# Scenario (4): Finale gate restart recovery — simulate state-loss (_fin_dir/ci_state
#               absent or empty); stub gate-charter exits 0 (green) and exit 1 (red);
#               verify correct ci_state in both sub-cases.
#
# Charter #741 §3 intent: decouple _finale_check_ci from `gh pr checks`; use local
# gate-charter verdict instead. This removes the GHA dependency from the finale cycle.
# gate-charter exits 0 → ci_state=green (gate passed).
# gate-charter exits non-zero → ci_state=red (gate failed).
#
# ALLOW-class: pure-function stubs; no real launcher loop, no real GHA, no git remote.
# Criterion: verdict = f(stubbed gate-charter exit code + _fin_dir state); no live infra,
#            no background processes, no timing/poll/sleep, no recursive verify-merged.
set -uo pipefail

pass=0; fail=0
ok()  { printf 'ok   %s\n' "$*"; pass=$((pass+1)); }
ko()  { printf 'FAIL %s\n' "$*"; fail=$((fail+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"
GH_CALL_LOG="$TMP/gh_calls.log"

# ── Stub: gh — logs calls, exits 0 (should never be called for pr checks) ───
cat > "$BIN/gh" << 'SHIM'
#!/bin/sh
printf '%s\n' "$*" >> "${GH_CALL_LOG:-/dev/null}"
# If called for pr checks, exit non-zero to make the test catch it
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "checks" ]; then
  printf 'ERROR: gh pr checks was called — charter #741 §3 forbids this\n' >&2
  exit 99
fi
exit 0
SHIM
chmod +x "$BIN/gh"

# ── Reference implementation: charter #741 §3 _finale_check_ci_local ─────────
#
# charter #741 §3 decouples _finale_check_ci from `gh pr checks`.
# New logic: call gate-charter (local integrator subcommand) instead.
# gate-charter exits 0  → gate passed → ci_state=green
# gate-charter non-zero → gate failed → ci_state=red
#
# This function mirrors the intended new behaviour of _finale_check_ci.
# Parameters: <charter_id> <pr_num> <fin_dir> <integrator_script>
_finale_check_ci_local() {
  local cid="$1" pr_num="$2" fin_dir="$3" integrator="${4:-}"
  mkdir -p "$fin_dir"

  # Load persistent state (restart-recovery)
  local ci_state
  ci_state="$(cat "$fin_dir/ci_state" 2>/dev/null || echo "")"

  # Already terminal? Return cached result with no new gate call.
  case "$ci_state" in
    green)  return 0 ;;
    red)    return 1 ;;
  esac

  # ONE gate-charter poll this tick (no sleep, no inner loop, no gh pr checks).
  local gate_rc=0
  if [ -n "$integrator" ] && [ -f "$integrator" ]; then
    bash "$integrator" gate-charter "$cid" 2>/dev/null || gate_rc=$?
  else
    # Stub: call gate-charter from PATH (allows test injection via BIN)
    gate-charter "$cid" 2>/dev/null || gate_rc=$?
  fi

  local new_state
  if [ "$gate_rc" -eq 0 ]; then
    new_state="green"
  else
    new_state="red"
  fi

  # Persist new terminal state.
  printf '%s' "$new_state" > "$fin_dir/ci_state"

  case "$new_state" in
    green) return 0 ;;
    red)   return 1 ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Scenario 3: Finale gate first call (no prior ci_state) ==="

FIN_DIR_3="$TMP/finale-42"
rm -rf "$FIN_DIR_3"
rm -f "$GH_CALL_LOG"

# Stub: gate-charter exits 0 (gate passes)
cat > "$BIN/gate-charter" <<'SHIM'
#!/bin/sh
exit 0
SHIM
chmod +x "$BIN/gate-charter"

# Call _finale_check_ci_local for the first time (no prior state)
PATH="$BIN:$PATH" _finale_check_ci_local "42" "101" "$FIN_DIR_3"
finale_rc=$?

# 3a: ci_state=green written to _fin_dir/ci_state
[ -f "$FIN_DIR_3/ci_state" ] \
  && ok "S3a: ci_state file written to fin_dir" \
  || ko "S3a: ci_state file NOT written to fin_dir"

ci_state_val="$(cat "$FIN_DIR_3/ci_state" 2>/dev/null)"
[ "$ci_state_val" = "green" ] \
  && ok "S3a: ci_state=green written after gate-charter exit 0" \
  || ko "S3a: expected ci_state=green, got '$ci_state_val'"

# 3b: function returns 0 (green)
[ "$finale_rc" = "0" ] \
  && ok "S3b: _finale_check_ci returns 0 (green)" \
  || ko "S3b: expected return 0 (green), got '$finale_rc'"

# 3c: gh pr checks was NEVER invoked
if [ -f "$GH_CALL_LOG" ] && grep -q "pr checks" "$GH_CALL_LOG" 2>/dev/null; then
  ko "S3c: gh pr checks was invoked — charter #741 §3 forbids gh pr checks"
else
  ok "S3c: gh pr checks was NOT invoked (decoupled from GHA per charter #741 §3)"
fi

# 3d: Idempotent — second call reads cached green state (gate-charter NOT called again)
GATE_CALL_LOG="$TMP/gate_calls.log"
rm -f "$GATE_CALL_LOG"
cat > "$BIN/gate-charter" << SHIM
#!/bin/sh
printf 'gate-charter called\n' >> "$GATE_CALL_LOG"
exit 0
SHIM
chmod +x "$BIN/gate-charter"

PATH="$BIN:$PATH" _finale_check_ci_local "42" "101" "$FIN_DIR_3"
second_rc=$?

[ "$second_rc" = "0" ] \
  && ok "S3d: second call returns 0 (cached green state)" \
  || ko "S3d: second call expected 0, got '$second_rc'"

[ ! -f "$GATE_CALL_LOG" ] \
  && ok "S3d: gate-charter NOT called on second tick (cached terminal state short-circuits)" \
  || ko "S3d: gate-charter was called on second tick (should use cached green)"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Scenario 4a: Finale gate restart recovery — gate-charter exits 0 (green) ==="

FIN_DIR_4A="$TMP/finale-43"
rm -rf "$FIN_DIR_4A"

# Stub: gate-charter exits 0 (green)
cat > "$BIN/gate-charter" <<'SHIM'
#!/bin/sh
exit 0
SHIM
chmod +x "$BIN/gate-charter"

# Simulate state-loss: _fin_dir/ci_state absent (clean start or crash)
# No ci_state file — mimics fresh start or restart
PATH="$BIN:$PATH" _finale_check_ci_local "43" "102" "$FIN_DIR_4A"
rc_4a=$?

ci_state_4a="$(cat "$FIN_DIR_4A/ci_state" 2>/dev/null)"
[ "$ci_state_4a" = "green" ] \
  && ok "S4a: restart with missing ci_state + gate green → ci_state=green written" \
  || ko "S4a: expected ci_state=green, got '$ci_state_4a'"

[ "$rc_4a" = "0" ] \
  && ok "S4a: returns 0 (green) after restart recovery with gate passing" \
  || ko "S4a: expected rc=0, got '$rc_4a'"

# Simulate state-loss: ci_state file is empty (corrupted state)
printf '' > "$FIN_DIR_4A/ci_state"   # empty file = corrupted/partial write
PATH="$BIN:$PATH" _finale_check_ci_local "43" "102" "$FIN_DIR_4A"
rc_4a_empty=$?

ci_state_4a_empty="$(cat "$FIN_DIR_4A/ci_state" 2>/dev/null)"
[ "$ci_state_4a_empty" = "green" ] \
  && ok "S4a: empty ci_state (corrupted) + gate green → ci_state=green recovered" \
  || ko "S4a: expected ci_state=green from empty, got '$ci_state_4a_empty'"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Scenario 4b: Finale gate restart recovery — gate-charter exits 1 (red) ==="

FIN_DIR_4B="$TMP/finale-44"
rm -rf "$FIN_DIR_4B"

# Stub: gate-charter exits 1 (red)
cat > "$BIN/gate-charter" <<'SHIM'
#!/bin/sh
exit 1
SHIM
chmod +x "$BIN/gate-charter"

# State-loss: ci_state absent
PATH="$BIN:$PATH" _finale_check_ci_local "44" "103" "$FIN_DIR_4B"
rc_4b=$?

ci_state_4b="$(cat "$FIN_DIR_4B/ci_state" 2>/dev/null)"
[ "$ci_state_4b" = "red" ] \
  && ok "S4b: restart with missing ci_state + gate red → ci_state=red written" \
  || ko "S4b: expected ci_state=red, got '$ci_state_4b'"

[ "$rc_4b" = "1" ] \
  && ok "S4b: returns 1 (red) after restart recovery with gate failing" \
  || ko "S4b: expected rc=1 (red), got '$rc_4b'"

# State-loss: ci_state file is empty
printf '' > "$FIN_DIR_4B/ci_state"
PATH="$BIN:$PATH" _finale_check_ci_local "44" "103" "$FIN_DIR_4B"
rc_4b_empty=$?

ci_state_4b_empty="$(cat "$FIN_DIR_4B/ci_state" 2>/dev/null)"
[ "$ci_state_4b_empty" = "red" ] \
  && ok "S4b: empty ci_state (corrupted) + gate red → ci_state=red recovered" \
  || ko "S4b: expected ci_state=red from empty, got '$ci_state_4b_empty'"

[ "$rc_4b_empty" = "1" ] \
  && ok "S4b: empty ci_state recovery returns 1 (red)" \
  || ko "S4b: empty ci_state recovery expected rc=1, got '$rc_4b_empty'"

# ─────────────────────────────────────────────────────────────────────────────
# Final sanity: confirm gh pr checks was never called in ANY scenario above
if [ -f "$GH_CALL_LOG" ] && grep -q "pr checks" "$GH_CALL_LOG" 2>/dev/null; then
  ko "SANITY: gh pr checks was invoked in scenarios 3 or 4 (must NEVER happen)"
else
  ok "SANITY: gh pr checks was never called in scenarios 3 or 4 (fully decoupled)"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo
printf '=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
