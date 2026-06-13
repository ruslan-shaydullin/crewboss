#!/usr/bin/env bash
# run-env-contract.test.sh — env-contract tests for run-env.sh (issue #147)
# Classes T1+T6: env is correctly exported by both bash entrypoints.
#
# Case A: run-charter.sh — full contract visible to stub launcher
# Case B: start-stack.sh with-loop — same full contract visible to stub launcher
# Case C: CB_NO_INTEGRATE=1 → CB_GIT_REMOTE empty (D2 explicit opt-out)
#
# RED-0: run-env.sh absent → source fails → dump never written → timeout → FAIL
# Стаб моделирует реальность (урок P1): изолированный HOME, стаб-gh (auth token→FAKETOKEN),
# фейковый ~/.crewboss.env, стаб-лаунчер $HOME/cbnet/crewboss-launcher-gh.sh сбрасывающий
# ФАКТИЧЕСКИЙ полученный env в файл. Ожидание dump-файла — poll-циклом с дедлайном.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RUNTIME="$HERE/../runtime"

pass=0; fail=0
ok(){ printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
FAKE_HOME="$ROOT/home"
DUMP_FILE="$ROOT/env-dump"
BIN="$ROOT/bin"

mkdir -p "$FAKE_HOME/cbnet/run" "$BIN"

# ── Fake ~/.crewboss.env ──────────────────────────────────────────────────────
cat > "$FAKE_HOME/.crewboss.env" <<'ENVEOF'
CB_REPO=stratch1989/crewboss
ENVEOF

# ── Stub gh: auth token → FAKETOKEN ──────────────────────────────────────────
cat > "$BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "auth" ] && [ "${2:-}" = "token" ]; then
  printf 'FAKETOKEN\n'
fi
exit 0
GHEOF
chmod +x "$BIN/gh"

# ── Stub launcher: dumps inherited env to DUMP_FILE ──────────────────────────
# Path substituted at stub-creation time (not a literal $DUMP_FILE in the script)
cat > "$FAKE_HOME/cbnet/crewboss-launcher-gh.sh" <<LAEOF
#!/usr/bin/env bash
env > "$DUMP_FILE"
echo "[launcher-gh-stub] env dumped"
LAEOF
chmod +x "$FAKE_HOME/cbnet/crewboss-launcher-gh.sh"

# ── helpers ───────────────────────────────────────────────────────────────────

reset_state(){
  rm -f "$DUMP_FILE"
  rm -f "$FAKE_HOME/cbnet/run/launcher.pid"
  rm -f "$FAKE_HOME/cbnet/run/api.pid"
}

# Poll for dump file with deadline in seconds (poll interval 0.1s — NOT fixed sleep N)
wait_dump(){
  local limit="${1:-15}"
  local deadline=$(( $(date +%s) + limit ))
  while [ ! -f "$DUMP_FILE" ]; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      return 1
    fi
    sleep 0.1
  done
  return 0
}

dump_val(){ grep "^${1}=" "$DUMP_FILE" 2>/dev/null | head -1 | cut -d= -f2-; }

# assert_contract: common assertions against the dump; label is prefix for ok/no messages
assert_contract(){
  local label="$1"

  local v
  v="$(dump_val CB_GIT_REMOTE)"
  if printf '%s' "$v" | grep -q "github.com/stratch1989/crewboss"; then
    ok "$label: CB_GIT_REMOTE contains github.com/stratch1989/crewboss"
  else
    no "$label: CB_GIT_REMOTE missing or wrong (got: '$v')"
  fi

  v="$(dump_val CB_MAX_TICKS)"
  if [ -n "$v" ] && [ "$v" -ge 1800 ] 2>/dev/null; then
    ok "$label: CB_MAX_TICKS=$v (≥1800, T6 budget)"
  else
    no "$label: CB_MAX_TICKS not ≥1800 (got: '$v')"
  fi

  v="$(dump_val CB_MAX_PARALLEL)"
  if [ -n "$v" ]; then
    ok "$label: CB_MAX_PARALLEL=$v (set, contract=4)"
  else
    no "$label: CB_MAX_PARALLEL not set (launcher default MAXP=2 would apply — finding #2/#142)"
  fi

  v="$(dump_val CB_SPAWN)"
  if printf '%s' "$v" | grep -q "charter-leaf-prep.sh"; then
    ok "$label: CB_SPAWN ends with charter-leaf-prep.sh"
  else
    no "$label: CB_SPAWN missing or wrong (got: '$v')"
  fi

  v="$(dump_val CB_PLAN_SPAWN)"
  if [ -n "$v" ]; then
    ok "$label: CB_PLAN_SPAWN set (=$v)"
  else
    no "$label: CB_PLAN_SPAWN not set"
  fi

  v="$(dump_val CB_HOME)"
  local want_home="$FAKE_HOME/cbnet"
  if [ "$v" = "$want_home" ]; then
    ok "$label: CB_HOME=$v (=\$HOME/cbnet, not launcher default /tmp/cbnet)"
  else
    no "$label: CB_HOME wrong (got: '$v', want: '$want_home')"
  fi

  # Leaf green-before-merge verifier env (#177: box-native, NOT GHA, no freshness gate)
  v="$(dump_val CB_VERIFY_CACHE)"
  if [ -n "$v" ]; then
    ok "$label: CB_VERIFY_CACHE set (=$v)"
  else
    no "$label: CB_VERIFY_CACHE not set (leaf verifier prod-env missing)"
  fi

  v="$(dump_val CB_VERIFY_TIMEOUT)"
  if [ -n "$v" ]; then
    ok "$label: CB_VERIFY_TIMEOUT set (=$v)"
  else
    no "$label: CB_VERIFY_TIMEOUT not set (leaf verifier prod-env missing)"
  fi
}

# =============================================================================
# Case A: run-charter.sh
# =============================================================================
echo "=== Case A: run-charter.sh env contract ==="
reset_state

HOME="$FAKE_HOME" PATH="$BIN:$PATH" bash "$RUNTIME/run-charter.sh" >/dev/null 2>&1 &
A_PID=$!

if wait_dump 15; then
  ok "Case A: dump written by stub launcher"
else
  no "Case A: dump file never appeared within deadline (run-charter.sh failed to start launcher)"
  wait "$A_PID" 2>/dev/null || true
  echo; printf '=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]; exit
fi
wait "$A_PID" 2>/dev/null || true

assert_contract "Case A"

# =============================================================================
# Case B: start-stack.sh with-loop
# =============================================================================
echo "=== Case B: start-stack.sh with-loop env contract ==="
reset_state

HOME="$FAKE_HOME" PATH="$BIN:$PATH" bash "$RUNTIME/start-stack.sh" with-loop >/dev/null 2>&1 &
B_PID=$!

if wait_dump 20; then
  ok "Case B: dump written by stub launcher"
else
  no "Case B: dump file never appeared within deadline (start-stack.sh with-loop failed to start launcher)"
  wait "$B_PID" 2>/dev/null || true
  echo; printf '=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]; exit
fi
wait "$B_PID" 2>/dev/null || true

assert_contract "Case B"

# =============================================================================
# Case C: CB_NO_INTEGRATE=1 → CB_GIT_REMOTE empty (D2 explicit opt-out)
# =============================================================================
echo "=== Case C: CB_NO_INTEGRATE=1 → CB_GIT_REMOTE empty (D2) ==="
reset_state

HOME="$FAKE_HOME" CB_NO_INTEGRATE=1 PATH="$BIN:$PATH" bash "$RUNTIME/run-charter.sh" >/dev/null 2>&1 &
C_PID=$!

if wait_dump 15; then
  ok "Case C: dump written"
else
  no "Case C: dump file never appeared within deadline"
  wait "$C_PID" 2>/dev/null || true
  echo; printf '=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]; exit
fi
wait "$C_PID" 2>/dev/null || true

v="$(dump_val CB_GIT_REMOTE)"
if [ -z "$v" ]; then
  ok "Case C: CB_GIT_REMOTE is empty with CB_NO_INTEGRATE=1 (D2 opt-out; launcher will log DISABLED)"
else
  no "Case C: CB_GIT_REMOTE should be empty with CB_NO_INTEGRATE=1 (got: '$v')"
fi

# =============================================================================
echo
printf '=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
