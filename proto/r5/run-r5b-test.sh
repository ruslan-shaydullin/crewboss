#!/usr/bin/env bash
# Round 5b: validate the launcher loop (predicate/claim/route/retry/reconcile/lock)
# deterministically with a stub spawn — no jail, no spend.
set -u
export CB_HOME=/tmp/cbnet
CB=$CB_HOME; RUN=$CB/run; BOARD=$RUN/board
export CB_SPAWN=$CB/stub-spawn.sh CB_RETRY_CAP=2 CB_MAX_PARALLEL=5
LNCH=$CB/crewboss-launcher.sh
pass=0; fail=0
ok(){ echo "  PASS $1"; pass=$((pass+1)); }
no(){ echo "  FAIL $1"; fail=$((fail+1)); }
reset(){ rm -rf "$RUN/board" "$RUN/stub-ctl" "$RUN/stub-calls.log" "$RUN/launcher.lock"; mkdir -p "$BOARD" "$RUN/stub-ctl"; : > "$RUN/stub-calls.log"; }
mktask(){ # id kind role state charter "deps" held tries
  jq -n --argjson id "$1" --arg k "$2" --arg r "$3" --arg s "$4" --arg c "$5" \
        --arg deps "$6" --argjson held "$7" --argjson tries "$8" \
    '{id:$id,kind:$k,role:$r,state:$s,charter:($c|if .=="" then null else tonumber end),
      deps:($deps|if .=="" then [] else split(",")|map(tonumber) end),held:$held,tries:$tries,pid:"",starttime:""}' \
    > "$BOARD/$1.json"; }
state(){ jq -r '.state' "$BOARD/$1.json"; }
called(){ grep -qx "$1" "$RUN/stub-calls.log"; }

echo "=== T1: predicate — unmet dep blocks, then unblocks ==="
reset
mktask 1 leaf executor done   "" "" false 0     # dependency, already done
mktask 2 leaf executor open   "" "3" false 0     # depends on #3 (open) -> blocked
mktask 3 leaf executor open   "" "" false 0
bash "$LNCH" once >/dev/null 2>&1
called 3 && ok "#3 (no deps) launched" || no "#3 not launched"
called 2 && no "#2 launched despite open dep" || ok "#2 held back by unmet dep"
# now #3 done -> #2 becomes launchable
bash "$LNCH" once >/dev/null 2>&1
called 2 && ok "#2 launched after dep done" || no "#2 still not launched"

echo "=== T2: hold veto ==="
reset
mktask 1 leaf executor open "" "" true 0
bash "$LNCH" once >/dev/null 2>&1
called 1 && no "held task launched" || ok "held task vetoed"

echo "=== T3: charter must be approved ==="
reset
mktask 10 charter techlead plan-review "" "" false 0
mktask 11 leaf executor open 10 "" false 0       # under unapproved charter
bash "$LNCH" once >/dev/null 2>&1
called 11 && no "leaf under unapproved charter launched" || ok "unapproved-charter leaf blocked"
jq '.state="approved"' "$BOARD/10.json" > "$BOARD/10.json.t" && mv "$BOARD/10.json.t" "$BOARD/10.json"
bash "$LNCH" once >/dev/null 2>&1
called 11 && ok "leaf launched once charter approved" || no "leaf still blocked after approve"

echo "=== T4: success routing + idempotency ==="
reset
mktask 1 leaf executor open "" "" false 0
bash "$LNCH" once >/dev/null 2>&1
[ "$(state 1)" = "done" ] && ok "success -> state=done" || no "state=$(state 1)"
: > "$RUN/stub-calls.log"
bash "$LNCH" once >/dev/null 2>&1
called 1 && no "done task re-spawned" || ok "done task not re-spawned (idempotent)"

echo "=== T5: retry then blocked at cap ==="
reset
mktask 1 leaf executor open "" "" false 0
echo 2 > "$RUN/stub-ctl/1"     # always fail
bash "$LNCH" once >/dev/null 2>&1
[ "$(state 1)" = "open" ] && ok "1st fail -> requeued (open)" || no "state=$(state 1)"
bash "$LNCH" once >/dev/null 2>&1
[ "$(state 1)" = "blocked" ] && ok "2nd fail -> blocked at cap=2" || no "state=$(state 1)"
: > "$RUN/stub-calls.log"
bash "$LNCH" once >/dev/null 2>&1
called 1 && no "blocked task re-spawned" || ok "blocked task not re-spawned"

echo "=== T6: budget hard-stop ends the cycle, leaves task open ==="
reset
mktask 1 leaf executor open "" "" false 0
mktask 2 leaf executor open "" "" false 0
echo 3 > "$RUN/stub-ctl/1"     # #1 returns budget-stop
bash "$LNCH" once >/dev/null 2>&1
[ "$(state 1)" = "open" ] && ok "budget-stopped task left open (claim reverted)" || no "state=$(state 1)"
called 2 && no "#2 spawned after budget stop" || ok "cycle stopped — #2 not spawned"

echo "=== T7: reconcile requeues orphaned in-progress (dead pid) ==="
reset
mktask 1 leaf executor in-progress "" "" false 0
jq '.pid="999999"' "$BOARD/1.json" > "$BOARD/1.json.t" && mv "$BOARD/1.json.t" "$BOARD/1.json"  # dead pid
bash "$LNCH" reconcile >/dev/null 2>&1
[ "$(state 1)" = "open" ] && ok "orphaned in-progress -> requeued" || no "state=$(state 1)"

echo "=== T8: single-instance lock ==="
reset
mktask 1 leaf executor open "" "" false 0
exec 8>"$RUN/launcher.lock"; flock -n 8   # hold the lock
OUT=$(bash "$LNCH" once 2>&1); flock -u 8; exec 8>&-
echo "$OUT" | grep -q "holds the lock" && ok "second launcher refused under held lock" || no "lock not enforced: $OUT"
called 1 && no "task spawned despite held lock" || ok "no spawn under held lock"

echo "=== SUMMARY: $pass passed, $fail failed ==="
echo "=== done ==="
