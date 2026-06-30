#!/usr/bin/env bash
# 1073-pid-lifecycle.test.sh — charter #1073, leaf #1095 (qa-engineer).
#
# CONTRACT (root cause C): the launcher writes run/launcher.pid UNDER the flock at loop
# start, and removes it on loop exit (EXIT trap). The pid-file is the single atomic
# liveness source the keepalive timer and the API both read (os.kill(pid,0)).
#
#   T1  during a live run:  run/launcher.pid EXISTS and points at a LIVE process.
#   T2  after the loop exits: run/launcher.pid is REMOVED (EXIT trap fired).
#   T3  write is UNDER the lock: if a foreign holder already owns launcher.lock, a new
#       `run` loses the flock and exits WITHOUT writing launcher.pid (it is not written
#       before lock acquisition, and it does not clobber the foreign holder's view).
#
# RED before fix C (launcher never writes launcher.pid): T1 RED (file absent during run).
# GREEN after fix:  T1/T2/T3 all hold.
#
# Pure flock/process stubs, no real agents. EXCLUDED (real launcher loop + timing).
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
: > "$GH_LOG"; : > "$SPAWN_MARK"

cp "$BOARD_GH_SRC"   "$CBHOME/board-gh.sh"
cp "$LAUNCHABLE_SRC" "$CBHOME/launchable.sh"
chmod +x "$CBHOME/board-gh.sh" "$CBHOME/launchable.sh"

BIN="$ROOT/bin"; mkdir -p "$BIN"
export BIN
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
  "auth token") echo "fake-token" ;;
  *) : ;;
esac
exit 0
GHEOF
chmod +x "$BIN/gh"

PLAN_STUB="$ROOT/plan-stub.sh"
cat > "$PLAN_STUB" <<'PSEOF'
#!/usr/bin/env bash
printf 'spawn %s\n' "$1" >> "$SPAWN_MARK"
sleep "${CB_TEST_HOLD:-4}"
exit 0
PSEOF
chmod +x "$PLAN_STUB"

cat > "$BOARD_STATE" <<'JSON'
[
  {"number":5,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:needs-plan"}],
   "body":"charter goal","comments":[]}
]
JSON

launcher_env(){
  PATH="$BIN:$PATH" CB_REPO="test/repo" CB_HOME="$CBHOME" \
  CB_SPAWN="$PLAN_STUB" CB_PLAN_SPAWN="$PLAN_STUB" \
  CB_POLL=0 CB_MAX_TICKS=40 CB_MAX_PARALLEL=2 CREWBOSS_CHARTER= "$@"
}

PIDF="$CBHOME/run/launcher.pid"

# =============================================================================
# T1: during a live run, launcher.pid exists + alive
# =============================================================================
echo "=== T1: run/launcher.pid present + alive during a live loop ==="
rm -f "$PIDF"
launcher_env env CB_TEST_HOLD=5 bash "$LAUNCHER" run >"$ROOT/run.log" 2>&1 &
LOOP=$!

# wait for the loop to spawn (proves it acquired the lock and entered the loop body)
_w=0; while :; do [ -s "$SPAWN_MARK" ] && break; _w=$((_w+1)); [ "$_w" -ge 100 ] && break; sleep 0.1; done

_seen_pid=""; _seen_alive=0; _w=0
while [ "$_w" -lt 50 ]; do
  if [ -f "$PIDF" ]; then
    _seen_pid="$(cat "$PIDF" 2>/dev/null)"
    if [ -n "$_seen_pid" ] && kill -0 "$_seen_pid" 2>/dev/null; then _seen_alive=1; break; fi
  fi
  _w=$((_w+1)); sleep 0.1
done

[ -n "$_seen_pid" ] \
  && ok "T1: run/launcher.pid was written during the live loop (pid=$_seen_pid)" \
  || ko "T1: run/launcher.pid never appeared during a live loop — fix C (write pid under flock) missing"
[ "$_seen_alive" -eq 1 ] \
  && ok "T1: launcher.pid points at a LIVE process (kill -0 ok)" \
  || ko "T1: launcher.pid did not point at a live process"

# =============================================================================
# T2: after the loop exits, launcher.pid removed (EXIT trap)
# =============================================================================
echo "=== T2: run/launcher.pid removed on loop exit (EXIT trap) ==="
wait "$LOOP" 2>/dev/null
# small settle window for the EXIT trap
_w=0; while [ "$_w" -lt 30 ] && [ -f "$PIDF" ]; do _w=$((_w+1)); sleep 0.1; done
[ ! -f "$PIDF" ] \
  && ok "T2: run/launcher.pid removed after the loop exited (EXIT trap fired)" \
  || ko "T2: run/launcher.pid still present after loop exit (pid=$(cat "$PIDF" 2>/dev/null)) — EXIT-trap cleanup missing (zombie pid-file)"

# =============================================================================
# T3: pid-file write is UNDER the lock — a foreign holder blocks it
# =============================================================================
echo "=== T3: launcher.pid is written only AFTER acquiring the flock ==="
rm -f "$PIDF"; : > "$SPAWN_MARK"
LOCK="$CBHOME/run/launcher.lock"
mkdir -p "$CBHOME/run"
# Foreign process holds the flock for the whole window.
( exec 9>"$LOCK"; flock -n 9 && sleep 4 ) &
HOLDER=$!
sleep 0.4
launcher_env env CB_TEST_HOLD=1 bash "$LAUNCHER" run >"$ROOT/blocked.log" 2>&1
grep -q "another launcher holds the lock" "$ROOT/blocked.log" \
  && ok "T3: a second run racing a foreign lock-holder lost the flock and exited" \
  || ko "T3: the second run did NOT report losing the lock (flock not enforced)"
[ ! -f "$PIDF" ] \
  && ok "T3: launcher.pid was NOT written while the lock was foreign-held (write is gated by the flock)" \
  || ko "T3: launcher.pid written despite losing the flock (pid=$(cat "$PIDF" 2>/dev/null)) — pid write is not under the lock"
kill "$HOLDER" 2>/dev/null; wait 2>/dev/null

echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
