#!/usr/bin/env bash
# 1073-race-singleton.test.sh — charter #1073, leaf #1095 (qa-engineer).
#
# CONTRACT (Goal §1073): exactly ONE `crewboss-launcher-gh.sh run` loop at any moment,
# even under concurrent keepalive ticks + operator run, and exactly one run/launcher.pid.
#
# This is the loop-singleton regression: a live loop holds launcher.lock; every other
# `run`/`once` invocation that races it MUST lose the flock and exit WITHOUT spawning, and
# the run/launcher.pid file is the single deterministic source of "who is the loop".
#
# Pure process/flock stubs — no real agents (CB_*_SPAWN are local stub scripts). Drives the
# REAL launcher so the assertions bind to the shipped flock+pid contract, not a re-model.
#
# RED before fix C (launcher never writes run/launcher.pid): pid-file count == 0 -> RED.
# GREEN after fix:  exactly one live loop, exactly one launcher.pid pointing at it, and
#                   every racing invocation logged "another launcher holds the lock".
#
# EXCLUDED (real launcher loop + background spawns + flock race + timing): per-leaf-manifest.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER="${LAUNCHER_OVERRIDE:-$HERE/../runtime/crewboss-launcher-gh.sh}"
BOARD_GH_SRC="$HERE/../../proto/r6/board-gh.sh"
LAUNCHABLE_SRC="$HERE/../../proto/r6/launchable.sh"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"; pkill -P $$ 2>/dev/null; true' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

CBHOME="$ROOT/cbnet"
SANDBOX="$ROOT/sb"
BOARD_STATE="$SANDBOX/board.json"
GH_LOG="$SANDBOX/gh.log"
SPAWN_MARK="$ROOT/spawn.marks"
export BOARD_STATE GH_LOG SPAWN_MARK
mkdir -p "$CBHOME" "$SANDBOX"
: > "$SPAWN_MARK"; : > "$GH_LOG"

cp "$BOARD_GH_SRC"   "$CBHOME/board-gh.sh"
cp "$LAUNCHABLE_SRC" "$CBHOME/launchable.sh"
chmod +x "$CBHOME/board-gh.sh" "$CBHOME/launchable.sh"

BIN="$ROOT/bin"; mkdir -p "$BIN"
export BIN

# ── gh stub (stateful label board) ────────────────────────────────────────────
cat > "$BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
obj="$1"; verb="$2"; shift 2
_args=()
while [ $# -gt 0 ]; do case "$1" in -R|--repo|-L|--limit) shift ;; *) _args+=("$1") ;; esac; shift; done
set -- "${_args[@]+"${_args[@]}"}"
case "$obj $verb" in
  "issue list") cat "$BOARD_STATE" ;;
  "issue view")
    n="$1"; shift; jqf=""
    while [ $# -gt 0 ]; do case "$1" in --jq|-q) jqf="$2"; shift ;; --json) shift ;; esac; shift; done
    o="$(jq --argjson n "$n" 'map(select(.number==$n))[0] // {}' "$BOARD_STATE")"
    if [ -n "$jqf" ]; then printf '%s' "$o" | jq -r "$jqf"; else printf '%s\n' "$o"; fi ;;
  "issue edit")
    n="$1"; shift; adds=(); rems=()
    while [ $# -gt 0 ]; do case "$1" in --add-label) adds+=("$2"); shift ;; --remove-label) rems+=("$2"); shift ;; esac; shift; done
    adds_json="$(printf '%s\n' "${adds[@]+"${adds[@]}"}" | jq -R . | jq -s .)"
    rems_json="$(printf '%s\n' "${rems[@]+"${rems[@]}"}" | jq -R . | jq -s .)"
    jq --argjson n "$n" --argjson adds "$adds_json" --argjson rems "$rems_json" '
      map(if .number == $n then
        .labels = [(.labels // [])[] | select(.name as $nm | ($rems | index($nm)) == null)]
        | reduce $adds[] as $a (.; if ([.labels[].name] | index($a)) == null then .labels += [{name: $a}] else . end)
      else . end)' "$BOARD_STATE" > "$BOARD_STATE.t" && mv "$BOARD_STATE.t" "$BOARD_STATE" ;;
  "issue comment") : ;;
  "issue close") : ;;
  "auth token") echo "fake-token" ;;
  "label create") : ;;
  *) : ;;
esac
exit 0
GHEOF
chmod +x "$BIN/gh"

# ── plan/spawn stub: marks its start then BLOCKS, so the loop that owns the lock
#    stays alive (holding flock) for the whole race window. ─────────────────────
PLAN_STUB="$ROOT/plan-stub.sh"
cat > "$PLAN_STUB" <<'PSEOF'
#!/usr/bin/env bash
printf 'spawn %s pid=%s\n' "$1" "$$" >> "$SPAWN_MARK"
sleep "${CB_TEST_HOLD:-8}"
exit 0
PSEOF
chmod +x "$PLAN_STUB"

# Board: one charter in needs-plan so the lock-owner loop spawns a (blocking) tech-lead
# and remains busy holding the flock.
cat > "$BOARD_STATE" <<'JSON'
[
  {"number":5,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:needs-plan"}],
   "body":"charter goal","comments":[]}
]
JSON

launcher_env(){
  PATH="$BIN:$PATH" \
  CB_REPO="test/repo" \
  CB_HOME="$CBHOME" \
  CB_SPAWN="$PLAN_STUB" \
  CB_PLAN_SPAWN="$PLAN_STUB" \
  CB_POLL=0 \
  CB_MAX_TICKS=40 \
  CB_MAX_PARALLEL=4 \
  CREWBOSS_CHARTER= \
  "$@"
}

# ── start the lock-OWNER loop, wait until it has acquired the lock + spawned ──
launcher_env env CB_TEST_HOLD=8 bash "$LAUNCHER" run >"$ROOT/loopA.log" 2>&1 &
LOOP_A=$!

_waited=0
while :; do
  [ -s "$SPAWN_MARK" ] && break
  _waited=$((_waited+1)); [ "$_waited" -ge 100 ] && break
  sleep 0.1
done

# ── fire the racers: 3 operator `run` + 2 keepalive-style `once`, all SAME CB_HOME ──
RACER_RC="$ROOT/racer_rc"; : > "$RACER_RC"
for i in 1 2 3; do
  ( launcher_env env CB_TEST_HOLD=1 bash "$LAUNCHER" run >"$ROOT/run_$i.log" 2>&1
    printf 'run_%s=%s\n' "$i" "$?" >> "$RACER_RC" ) &
done
for i in 1 2; do
  ( launcher_env env CB_TEST_HOLD=1 bash "$LAUNCHER" once >"$ROOT/once_$i.log" 2>&1
    printf 'once_%s=%s\n' "$i" "$?" >> "$RACER_RC" ) &
done

# let the racers attempt the lock while LOOP_A still holds it
sleep 2

# =============================================================================
# Assertion 1: every racer lost the flock (did NOT acquire the lock)
# =============================================================================
_locklost=0
for f in "$ROOT"/run_1.log "$ROOT"/run_2.log "$ROOT"/run_3.log "$ROOT"/once_1.log "$ROOT"/once_2.log; do
  grep -q "another launcher holds the lock" "$f" 2>/dev/null && _locklost=$((_locklost+1))
done
[ "$_locklost" -eq 5 ] \
  && ok "race: all 5 racing invocations lost the flock (logged 'another launcher holds the lock')" \
  || ko "race: only $_locklost/5 racing invocations lost the flock — flock is NOT serializing concurrent loops"

# =============================================================================
# Assertion 2: only the lock-owner spawned — NO over-spawn (agents <= cap)
# Exactly ONE tech-lead spawn mark recorded during the race window.
# =============================================================================
_spawns="$(grep -c '^spawn ' "$SPAWN_MARK" 2>/dev/null || true)"
[ "$_spawns" -eq 1 ] \
  && ok "race: exactly ONE loop spawned work ($_spawns spawn) — racers spawned nothing (no over-spawn)" \
  || ko "race: $_spawns spawns recorded — multiple loops ran concurrently and over-spawned"

# =============================================================================
# Assertion 3: exactly ONE run/launcher.pid, alive, == the live loop (fix C contract)
# =============================================================================
PIDF="$CBHOME/run/launcher.pid"
if [ -f "$PIDF" ]; then
  _pidcount=1
  _pid="$(cat "$PIDF" 2>/dev/null)"
  if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then
    ok "race: exactly one run/launcher.pid present and points at a LIVE loop (pid=$_pid)"
  else
    ko "race: run/launcher.pid present but stale/empty ('$_pid') while a loop is live — pid-file not maintained under the lock"
  fi
else
  ko "race: run/launcher.pid MISSING while a loop is live — fix C (write launcher.pid under flock) not present"
fi

# belt-and-suspenders: there must never be two pid files / two live loops
_pf_n="$(find "$CBHOME/run" -maxdepth 1 -name 'launcher.pid' 2>/dev/null | wc -l | tr -d ' ')"
[ "${_pf_n:-0}" -le 1 ] \
  && ok "race: at most one launcher.pid on disk ($_pf_n)" \
  || ko "race: $_pf_n launcher.pid files — multiple loops claimed singleton"

# ── teardown ──
kill "$LOOP_A" 2>/dev/null
wait 2>/dev/null

echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
