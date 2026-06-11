#!/usr/bin/env bash
# killswitch.test.sh — kill_switch hygiene tests for the canonical launcher (issue #68, class a)
#
# Test 1 (RED→GREEN): kill_switch present → launcher exits with distinguishable non-zero code
#   + message. RED now = silent break (exit 0). GREEN = exit 42 + "kill-switch" in output.
# Test 2 (false-deny guard): kill_switch absent → launcher runs without kill-switch block.
# Test 3 (path-hygiene): canonical launcher references ONLY run/kill_switch, never
#   .crewboss-launcher.stop (the LEGACY launcher's path — must not leak into canon).

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER="$HERE/../runtime/crewboss-launcher-gh.sh"

pass=0; fail=0
ok(){ printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Minimal board stub: returns empty for every command (no real gh needed)
make_board_stub(){
  local dir="$1"; mkdir -p "$dir"
  cat > "$dir/board-gh.sh" <<'STUB'
#!/usr/bin/env bash
# board stub: always returns empty (used in tests with no real gh)
case "$1" in
  plannable|launchable) echo "" ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$dir/board-gh.sh"
}

# ── Test 1: kill_switch present → non-zero exit + "kill-switch" in output ─────
echo "=== Test 1: kill_switch present → distinguishable exit-code + message ==="
H1="$TMP/home1"
make_board_stub "$H1"
mkdir -p "$H1/run"
touch "$H1/run/kill_switch"

out1=$(CB_HOME="$H1" CB_REPO=test/repo CB_POLL=0 CB_MAX_TICKS=2 CB_IDLE_CONFIRM=1 \
       bash "$LAUNCHER" run 2>&1) || rc1=$?
: "${rc1:=0}"   # default 0 if launcher unexpectedly succeeded

if [ "${rc1:-0}" -ne 0 ]; then
  ok "exit code is non-zero (got $rc1) when kill_switch present"
else
  no "exit code is 0 (silent break) when kill_switch present — WANT non-zero"
fi

if echo "$out1" | grep -qi "kill.switch"; then
  ok "output contains 'kill-switch' message when kill_switch present"
else
  no "output does NOT contain 'kill-switch' message when kill_switch present"
fi

# ── Test 2: kill_switch absent → no kill-switch block (false-deny guard) ──────
echo "=== Test 2: kill_switch absent → launcher runs without kill-switch block ==="
H2="$TMP/home2"
make_board_stub "$H2"

out2=$(CB_HOME="$H2" CB_REPO=test/repo CB_POLL=0 CB_MAX_TICKS=2 CB_IDLE_CONFIRM=1 \
       bash "$LAUNCHER" run 2>&1); rc2=$?

if echo "$out2" | grep -qi "kill.switch"; then
  no "kill-switch message found unexpectedly when kill_switch is absent (false-deny)"
else
  ok "no kill-switch block when kill_switch absent (false-deny guard)"
fi

if [ "${rc2:-0}" -ne 42 ]; then
  ok "launcher did NOT exit with kill-switch code 42 when kill_switch absent"
else
  no "launcher exited with code 42 even though kill_switch was absent — false-deny!"
fi

# ── Test 3: canonical launcher path = run/kill_switch only ────────────────────
echo "=== Test 3: canonical launcher references run/kill_switch, NOT .crewboss-launcher.stop ==="

if [ ! -f "$LAUNCHER" ]; then
  no "canonical launcher not found: $LAUNCHER"
else
  # Must NOT reference the legacy kill-switch path
  if grep -q '\.crewboss-launcher\.stop' "$LAUNCHER"; then
    no "canonical launcher references .crewboss-launcher.stop (legacy path leaked in)"
  else
    ok "canonical launcher has no reference to .crewboss-launcher.stop (legacy path clean)"
  fi

  # Must reference run/kill_switch (the canonical path)
  if grep -q 'kill_switch' "$LAUNCHER"; then
    ok "canonical launcher references kill_switch (canonical path confirmed)"
  else
    no "canonical launcher does not reference kill_switch — path check broken"
  fi
fi

echo
printf '=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
