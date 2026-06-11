#!/usr/bin/env bash
# doctor-process.test.sh — smoke tests for crewboss-doctor.sh (issue #68, class d)
#
# Uses stub processes (sleep) + stubbed lsof to simulate multi-process / port scenarios
# without requiring SO_REUSEPORT or network bind.
#
# Test 1: two stub-processes "on port" → doctor detects/fixes to one
# Test 2: pgrep trap — failing pgrep stub does NOT break port-kill (kill-by-port only)
# Test 3: dead tunnel stub → doctor detects the problem (reports FAIL + non-zero exit)
#
# Tests 1+2 are combined: lsof stub returns two stub PIDs; pgrep stub always fails.
# Doctor must kill the duplicate WITHOUT calling pgrep — proves kill-by-port path.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DOCTOR="$HERE/../runtime/crewboss-doctor.sh"
TMP="$(mktemp -d)"
PROCS=()
cleanup(){
  for _p in "${PROCS[@]:-}"; do kill "$_p" 2>/dev/null || true; done
  rm -rf "$TMP"
}
trap cleanup EXIT

pass=0; fail=0
ok(){ printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

if [ ! -f "$DOCTOR" ]; then
  echo "FAIL: doctor not found at $DOCTOR"
  exit 1
fi

BIN="$TMP/bin"; mkdir -p "$BIN"

# ── Tests 1+2: two stub processes, lsof stub returns both, pgrep stub fails ──
echo "=== Test 1: two processes on port → doctor detects/fixes to one ==="
echo "=== Test 2: pgrep trap — port-kill succeeds despite failing pgrep stub ==="

# Start two stub "API" processes (sleep 60 = long-lived stand-ins)
sleep 60 & P1=$!; PROCS+=("$P1")
sleep 60 & P2=$!; PROCS+=("$P2")

PORT1="43210"

# lsof stub: returns P1 and P2 when asked about PORT1 (simulates two processes on port)
cat > "$BIN/lsof" <<LSTUB
#!/usr/bin/env bash
# lsof stub: return stub PIDs for port query
for arg; do
  [ "\$arg" = "tcp:$PORT1" ] && { printf '%s\n%s\n' $P1 $P2; exit 0; }
done
exit 1
LSTUB
chmod +x "$BIN/lsof"

# pgrep stub: always fail and mark invocation (the pgrep anti-self-match trap)
PGREP_LOG="$TMP/pgrep_called"
cat > "$BIN/pgrep" <<'STUB'
#!/usr/bin/env bash
# pgrep trap: always fail and record invocation
echo "pgrep-trap: called" >&2
exit 127
STUB
chmod +x "$BIN/pgrep"
# Export so the stub can write the log
export PGREP_LOG

# Set up CB_HOME with P1 as keeper
CBHOME1="$TMP/cbhome1"; mkdir -p "$CBHOME1/run"
echo "$P1" > "$CBHOME1/run/api.pid"

# Run doctor --fix with stub lsof+pgrep in PATH
out1=$(CB_HOME="$CBHOME1" CB_API_PORT="$PORT1" PATH="$BIN:$PATH" \
       bash "$DOCTOR" --fix 2>&1) || true

# Small pause for kill to propagate
sleep 0.3

# Assert: doctor detected duplicates
if echo "$out1" | grep -qi "duplicate\|multiple"; then
  ok "test 1: doctor detected duplicate processes on port $PORT1"
else
  no "test 1: doctor output does not mention 'duplicate'/'multiple'"
  echo "  (out: $(echo "$out1" | head -5))"
fi

# Assert: keeper (P1) still alive
if kill -0 "$P1" 2>/dev/null; then
  ok "test 1: keeper process (P1=$P1) still alive after doctor fix"
else
  no "test 1: keeper process (P1=$P1) was unexpectedly killed"
fi

# Assert: duplicate (P2) was killed
if kill -0 "$P2" 2>/dev/null; then
  no "test 1: duplicate process (P2=$P2) still alive — doctor failed to kill it"
else
  ok "test 1: duplicate process (P2=$P2) killed by doctor (fix applied)"
  PROCS=("$P1")
fi

# Assert: pgrep was NOT called (proves kill-by-port, not pgrep -f)
if echo "$out1" | grep -q "pgrep-trap"; then
  no "test 2: pgrep was called by doctor — self-match risk! Must use port-kill only"
else
  ok "test 2: pgrep NOT called — doctor uses kill-by-port only (no self-match risk)"
fi

# ── Test 3: dead tunnel → doctor detects ──────────────────────────────────────
echo "=== Test 3: dead tunnel stub → doctor detects ==="

# Start one stub process for a healthy port
sleep 60 & P3=$!; PROCS+=("$P3")
PORT2="43211"

# lsof stub for PORT2: returns just P3 (healthy, one process)
cat > "$BIN/lsof2" <<LSTUB2
#!/usr/bin/env bash
for arg; do
  [ "\$arg" = "tcp:$PORT2" ] && { printf '%s\n' $P3; exit 0; }
done
exit 1
LSTUB2
chmod +x "$BIN/lsof2"

# Wrap lsof to handle both ports
cat > "$BIN/lsof" <<LSTUB3
#!/usr/bin/env bash
for arg; do
  [ "\$arg" = "tcp:$PORT1" ] && { printf '%s\n%s\n' $P1 $P2; exit 0; }
  [ "\$arg" = "tcp:$PORT2" ] && { printf '%s\n' $P3; exit 0; }
done
exit 1
LSTUB3
chmod +x "$BIN/lsof"

CBHOME2="$TMP/cbhome2"; mkdir -p "$CBHOME2/run"
echo "$P3" > "$CBHOME2/run/api.pid"

# Tunnel check that always fails (dead tunnel simulation)
DEAD_CHECK="exit 1"
out3=$(CB_HOME="$CBHOME2" CB_API_PORT="$PORT2" \
       CB_TUNNEL_CHECK="$DEAD_CHECK" PATH="$BIN:$PATH" \
       bash "$DOCTOR" 2>&1) || rc3=$?
: "${rc3:=0}"

if [ "${rc3:-0}" -ne 0 ]; then
  ok "test 3: doctor exits non-zero when tunnel is dead"
else
  no "test 3: doctor exits 0 despite dead tunnel (should report problem)"
fi

if echo "$out3" | grep -qi "tunnel"; then
  ok "test 3: doctor output mentions 'tunnel' when tunnel check fails"
else
  no "test 3: doctor output does not mention 'tunnel' — detection unclear"
  echo "  (out: $(echo "$out3" | tail -5))"
fi

echo
printf '=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
