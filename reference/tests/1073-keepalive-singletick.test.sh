#!/usr/bin/env bash
# 1073-keepalive-singletick.test.sh — charter #1073, leaf #1095 (qa-engineer).
#
# Exercises the REAL keepalive single-tick entry. The infra leaf brings
# reference/runtime/crewboss-loop-keepalive.sh with a unit-callable single-tick / dry-run
# mode (env CB_KEEPALIVE_ONCE=1 and/or `--once`). This test pins the behavioural contract:
#
#   (1) LIVE pid   -> keepalive must NOT start a loop (singleton preserved).
#   (2) STALE pid  -> exactly ONE start.
#   (3) ABSENT pid -> exactly ONE start.
#   (4) root cause A: the start path resolves CB_HOME=$HOME/cbnet (via run-env.sh), so it
#       targets the SAME run/launcher.lock the operator `run` targets — behavioural proof
#       that keepalive and operator share one lock (no lock-path divergence).
#
# Observation contract: keepalive starts `$CB_HOME/crewboss-launcher-gh.sh run`. We place a
# recording stub launcher at $CB_HOME/crewboss-launcher-gh.sh; each start appends its
# resolved CB_HOME to $STARTS and writes run/launcher.pid (modelling fix C).
#
# RED before the infra leaf lands: the script is absent -> RED (fail-closed).
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
  ko "keepalive: reference/runtime/crewboss-loop-keepalive.sh is ABSENT — infra leaf has not landed (RED until then)"
  echo; printf 'passed=%d failed=%d\n' "$pass" "$fail"; exit 1
fi

# Hermetic HOME so run-env.sh resolves CB_HOME=$HOME/cbnet inside the sandbox.
HOME_DIR="$ROOT/home"; CBHOME="$HOME_DIR/cbnet"
mkdir -p "$CBHOME/run"
STARTS="$ROOT/starts.log"; export STARTS

# Real run-env.sh deployed into CB_HOME (so keepalive sourcing it sets CB_HOME=$HOME/cbnet).
cp "$RUN_ENV_SRC" "$CBHOME/run-env.sh"

# Recording stub launcher: records its resolved CB_HOME and models fix C (pid-file).
cat > "$CBHOME/crewboss-launcher-gh.sh" <<'LEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "run" ]; then
  printf 'start CB_HOME=%s LOCK=%s\n' "${CB_HOME:-UNSET}" "${CB_HOME:-UNSET}/run/launcher.lock" >> "$STARTS"
  mkdir -p "${CB_HOME:-/tmp}/run"
  echo "$$" > "${CB_HOME:-/tmp}/run/launcher.pid"
  sleep 2
  rm -f "${CB_HOME:-/tmp}/run/launcher.pid"
fi
exit 0
LEOF
chmod +x "$CBHOME/crewboss-launcher-gh.sh"

# Single-tick invocation (pass BOTH the env flag and the --once arg; the infra leaf is
# expected to honour at least one). CB_NO_INTEGRATE keeps run-env hermetic.
keepalive_tick(){
  HOME="$HOME_DIR" CB_HOME="$CBHOME" CB_REPO="test/repo" \
    CB_KEEPALIVE_ONCE=1 CB_NO_INTEGRATE=1 CREWBOSS_CHARTER= \
    bash "$KEEPALIVE" --once >>"$ROOT/keepalive.log" 2>&1
}

# ─────────────────────────────────────────────────────────────────────────────
# (1) LIVE pid -> no start
# ─────────────────────────────────────────────────────────────────────────────
echo "=== (1) live launcher.pid -> keepalive does NOT start a loop ==="
: > "$STARTS"
# a real live process whose pid we publish
sleep 30 & LIVE=$!
echo "$LIVE" > "$CBHOME/run/launcher.pid"
keepalive_tick
_n1="$(grep -c '^start ' "$STARTS" 2>/dev/null || true)"
[ "$_n1" -eq 0 ] \
  && ok "(1) live pid: keepalive started 0 loops (singleton preserved)" \
  || ko "(1) live pid: keepalive started $_n1 loop(s) despite a LIVE launcher.pid (over-spawn)"
kill "$LIVE" 2>/dev/null

# ─────────────────────────────────────────────────────────────────────────────
# (2) STALE pid -> exactly one start
# ─────────────────────────────────────────────────────────────────────────────
echo "=== (2) stale launcher.pid -> exactly ONE start ==="
: > "$STARTS"
# a guaranteed-dead pid
( sleep 0.01 & echo $! > "$CBHOME/run/launcher.pid"; wait ) 2>/dev/null
sleep 0.2
keepalive_tick
sleep 0.3
_n2="$(grep -c '^start ' "$STARTS" 2>/dev/null || true)"
[ "$_n2" -eq 1 ] \
  && ok "(2) stale pid: keepalive started exactly ONE loop" \
  || ko "(2) stale pid: keepalive started $_n2 loop(s) (expected exactly 1)"

# wait out the stub launcher's pid lifetime so it doesn't leak into scenario (3)
sleep 2; rm -f "$CBHOME/run/launcher.pid"

# ─────────────────────────────────────────────────────────────────────────────
# (3) ABSENT pid -> exactly one start; and root-A: CB_HOME==$HOME/cbnet
# ─────────────────────────────────────────────────────────────────────────────
echo "=== (3) absent launcher.pid -> exactly ONE start; start resolves CB_HOME=\$HOME/cbnet ==="
: > "$STARTS"
rm -f "$CBHOME/run/launcher.pid"
keepalive_tick
sleep 0.3
_n3="$(grep -c '^start ' "$STARTS" 2>/dev/null || true)"
[ "$_n3" -eq 1 ] \
  && ok "(3) absent pid: keepalive started exactly ONE loop" \
  || ko "(3) absent pid: keepalive started $_n3 loop(s) (expected exactly 1)"

# root cause A: the start must target $HOME/cbnet (== where operator `run` targets),
# NOT the launcher default /tmp/cbnet.
if grep -q "start CB_HOME=$CBHOME " "$STARTS" 2>/dev/null; then
  ok "(3) root-A: start resolved CB_HOME=$CBHOME (\$HOME/cbnet) — same launcher.lock as operator run"
else
  ko "(3) root-A: start did NOT resolve CB_HOME=\$HOME/cbnet — got: $(tr -d '\n' < "$STARTS") — lock-path divergence (over-spawn risk)"
fi
sleep 2; rm -f "$CBHOME/run/launcher.pid"

echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
