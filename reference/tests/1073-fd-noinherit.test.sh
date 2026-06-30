#!/usr/bin/env bash
# 1073-fd-noinherit.test.sh — charter #1073, leaf #1095 (qa-engineer).
#
# CONTRACT (root cause B): cmd_run holds the flock on a fd via `( ... ) 9>"$LOCK"`.
# Background spawns started INSIDE the loop subshell — `( "$X_SPAWN" ... ) &` — inherit
# that fd. A spawn (or any grandchild it detaches) that OUTLIVES the loop subshell then
# keeps launcher.lock held with NO live loop, so the next launcher's `flock -n` fails and
# recovery is blocked. The robust fix opens the lock with an auto-assigned, close-on-exec
# fd (`flock {lockfd}` / exec {lockfd}>LOCK) so NO child inherits it.
#
# This test deliberately drives a NON-claim_and_spawn site — the tech-lead PLAN_SPAWN
# background spawn `( "$PLAN_SPAWN" "$cid" tech-lead ) &` (launcher line ~1878). A single
# point-fix that only adds `9>&-` at claim_and_spawn therefore CANNOT make this pass; only
# the close-on-exec {lockfd} fix (which severs inheritance at EVERY `&` site) does.
#
# RED before fix B: the detached grandchild inherits fd 9 and keeps launcher.lock held
#                   after the loop exits -> a fresh `flock -n` FAILS -> RED.
# GREEN after fix:  the lock fd is close-on-exec -> grandchild never holds it -> lock free.
#
# EXCLUDED (real launcher loop + background spawns + flock): per-leaf-manifest.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER="${LAUNCHER_OVERRIDE:-$HERE/../runtime/crewboss-launcher-gh.sh}"
BOARD_GH_SRC="$HERE/../../proto/r6/board-gh.sh"
LAUNCHABLE_SRC="$HERE/../../proto/r6/launchable.sh"

ROOT="$(mktemp -d)"; trap 'kill "$(cat "$ROOT/holder.pid" 2>/dev/null)" 2>/dev/null; rm -rf "$ROOT"; pkill -P $$ 2>/dev/null; true' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

CBHOME="$ROOT/cbnet"
SANDBOX="$ROOT/sb"
BOARD_STATE="$SANDBOX/board.json"
FD_HOLDER="$ROOT/holder.pid"
export BOARD_STATE FD_HOLDER
mkdir -p "$CBHOME" "$SANDBOX"

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

# ── tech-lead PLAN_SPAWN stub: detach a grandchild that OUTLIVES the loop, then route
#    the charter off needs-plan so the loop goes idle and exits promptly. ──────────
PLAN_STUB="$ROOT/plan-stub.sh"
cat > "$PLAN_STUB" <<'PSEOF'
#!/usr/bin/env bash
CID="$1"
# setsid -> new session: this grandchild survives the loop subshell. If it inherited the
# launcher's flock fd, it keeps launcher.lock held after the loop is gone.
setsid bash -c 'exec sleep "${CB_TEST_FD_SLEEP:-15}"' >/dev/null 2>&1 &
echo "$!" > "$FD_HOLDER"
gh issue edit "$CID" -R test/repo --remove-label status:needs-plan --add-label status:plan-review
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

LOCK="$CBHOME/run/launcher.lock"

# probe: 0 = lock FREE (acquirable), 1 = lock HELD by someone
lock_is_free(){ ( flock -n 200 || exit 1 ) 200>"$LOCK"; }

echo "=== drive the tech-lead PLAN_SPAWN background site, detach an fd-holding grandchild ==="
PATH="$BIN:$PATH" CB_REPO="test/repo" CB_HOME="$CBHOME" \
  CB_SPAWN="$PLAN_STUB" CB_PLAN_SPAWN="$PLAN_STUB" \
  CB_POLL=0 CB_MAX_TICKS=4 CB_MAX_PARALLEL=2 CREWBOSS_CHARTER= \
  env CB_TEST_FD_SLEEP=15 bash "$LAUNCHER" run >"$ROOT/loop.log" 2>&1 &
LOOP=$!
wait "$LOOP" 2>/dev/null   # loop fully exits; its own fd 9 is now closed

# sanity: the non-claim_and_spawn site actually ran and detached a grandchild
if [ -s "$FD_HOLDER" ] && kill -0 "$(cat "$FD_HOLDER")" 2>/dev/null; then
  ok "setup: tech-lead PLAN_SPAWN site ran and detached a grandchild that outlives the loop"
else
  ko "setup: PLAN_SPAWN grandchild not running (test could not reach the non-claim_and_spawn spawn site)"
fi

# CORE assertion: with the loop gone, the lock MUST be free. If the grandchild inherited
# fd 9 (bug), it still holds launcher.lock -> probe fails.
if lock_is_free; then
  ok "fd-noinherit: launcher.lock is FREE after the loop exited — grandchild did NOT inherit the lock fd ({lockfd} close-on-exec)"
else
  ko "fd-noinherit: launcher.lock STILL HELD after the loop exited — a backgrounded spawn inherited fd 9 (root B); a fresh launcher cannot recover"
fi

# Second probe must also succeed (idempotent — no flapping)
if lock_is_free; then
  ok "fd-noinherit: launcher.lock re-acquirable (a fresh launcher could start)"
else
  ko "fd-noinherit: launcher.lock not re-acquirable on second probe"
fi

kill "$(cat "$FD_HOLDER" 2>/dev/null)" 2>/dev/null; wait 2>/dev/null

echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
