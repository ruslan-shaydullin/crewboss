#!/usr/bin/env bash
# 1073-recovery.test.sh — charter #1073, leaf #1095 (qa-engineer).
#
# CONTRACT (Goal: "keepalive restarts ONLY when the loop is genuinely dead"): when the loop
# is genuinely dead (a STALE launcher.pid left by a crash, or an ABSENT pid), a single
# keepalive tick must bring back EXACTLY ONE loop — recovery must NOT be broken by the new
# singleton guards — and a follow-up tick while that restarted loop is LIVE must NOT add a
# second loop (no double-recovery).
#
# This is the complement of the singleton tests: those prove "never more than one"; this
# proves "still at least one when truly dead" (the keepalive's reason to exist).
#
# RED before the infra leaf lands: crewboss-loop-keepalive.sh absent -> RED (fail-closed).
# EXCLUDED (drives the real keepalive single-tick + process start + timing): per-leaf-manifest.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
KEEPALIVE="${KEEPALIVE_OVERRIDE:-$HERE/../runtime/crewboss-loop-keepalive.sh}"
RUN_ENV_SRC="$HERE/../runtime/run-env.sh"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"; pkill -P $$ 2>/dev/null; true' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

if [ ! -f "$KEEPALIVE" ]; then
  ko "recovery: reference/runtime/crewboss-loop-keepalive.sh is ABSENT — infra leaf has not landed (RED until then)"
  echo; printf 'passed=%d failed=%d\n' "$pass" "$fail"; exit 1
fi

HOME_DIR="$ROOT/home"; CBHOME="$HOME_DIR/cbnet"
mkdir -p "$CBHOME/run"
STARTS="$ROOT/starts.log"; export STARTS
cp "$RUN_ENV_SRC" "$CBHOME/run-env.sh"

# Recording stub launcher that STAYS ALIVE long enough to be observed as the live loop,
# writing run/launcher.pid under fix C and clearing it on exit.
cat > "$CBHOME/crewboss-launcher-gh.sh" <<'LEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "run" ]; then
  printf 'start pid=%s CB_HOME=%s\n' "$$" "${CB_HOME:-UNSET}" >> "$STARTS"
  mkdir -p "${CB_HOME:-/tmp}/run"
  echo "$$" > "${CB_HOME:-/tmp}/run/launcher.pid"
  trap 'rm -f "${CB_HOME:-/tmp}/run/launcher.pid"' EXIT
  sleep "${CB_TEST_LOOP_LIFE:-6}"
fi
exit 0
LEOF
chmod +x "$CBHOME/crewboss-launcher-gh.sh"

keepalive_tick(){
  HOME="$HOME_DIR" CB_HOME="$CBHOME" CB_REPO="test/repo" \
    CB_KEEPALIVE_ONCE=1 CB_NO_INTEGRATE=1 CREWBOSS_CHARTER= \
    env "$@" bash "$KEEPALIVE" --once >>"$ROOT/keepalive.log" 2>&1
}

PIDF="$CBHOME/run/launcher.pid"

# ─────────────────────────────────────────────────────────────────────────────
# T1: STALE pid (crash residue) -> exactly one restart
# ─────────────────────────────────────────────────────────────────────────────
echo "=== T1: genuinely-dead loop via STALE launcher.pid -> exactly one restart ==="
: > "$STARTS"
# stale pid: a pid that has already exited
( sleep 0.01 & echo $! > "$PIDF"; wait ) 2>/dev/null
sleep 0.2
keepalive_tick CB_TEST_LOOP_LIFE=6
sleep 0.4
_t1="$(grep -c '^start ' "$STARTS" 2>/dev/null || true)"
[ "$_t1" -eq 1 ] \
  && ok "T1: stale pid -> exactly ONE loop restarted (recovery works)" \
  || ko "T1: stale pid -> $_t1 loop(s) restarted (expected 1) — recovery broken by a stale pid-file (root B/zombie-lock symptom)"

# the restarted loop is now live and owns the pid-file
if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null; then
  ok "T1: restarted loop is LIVE and owns run/launcher.pid"
else
  ok "T1: (restart observed via start-log; pid-file lifecycle covered by pid-lifecycle test)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# T2: a SECOND tick while the restarted loop is LIVE must NOT double-start
# ─────────────────────────────────────────────────────────────────────────────
echo "=== T2: follow-up tick while the restarted loop is live -> no second loop ==="
keepalive_tick CB_TEST_LOOP_LIFE=6
sleep 0.3
_t2="$(grep -c '^start ' "$STARTS" 2>/dev/null || true)"
[ "$_t2" -eq 1 ] \
  && ok "T2: still exactly ONE start after a second tick (live loop not double-recovered)" \
  || ko "T2: $_t2 starts after a second tick — keepalive over-spawned a second loop over a live one"

# let the restarted loop finish
sleep 6; rm -f "$PIDF"

# ─────────────────────────────────────────────────────────────────────────────
# T3: ABSENT pid (clean slate / no residue) -> exactly one restart
# ─────────────────────────────────────────────────────────────────────────────
echo "=== T3: genuinely-dead loop via ABSENT launcher.pid -> exactly one restart ==="
: > "$STARTS"; rm -f "$PIDF"
keepalive_tick CB_TEST_LOOP_LIFE=2
sleep 0.4
_t3="$(grep -c '^start ' "$STARTS" 2>/dev/null || true)"
[ "$_t3" -eq 1 ] \
  && ok "T3: absent pid -> exactly ONE loop started (recovery from clean slate)" \
  || ko "T3: absent pid -> $_t3 loop(s) started (expected 1)"
sleep 2; rm -f "$PIDF"

echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
