#!/usr/bin/env bash
# Validate kill-switch + pause flag-files (free, stub spawn, real gh board).
set -u
export CB_REPO=stratch1989/crewboss-proto CB_HOME=/tmp/cbnet
export CB_SPAWN=/tmp/cbnet/stub-spawn-bg.sh CB_RETRY_CAP=2 CB_MAX_PARALLEL=2 CB_POLL=1 CB_LAUNCHER_ID=cbflag STUB_SLEEP=1
L=/tmp/cbnet/crewboss-launcher-gh.sh; BG=/tmp/cbnet/board-gh.sh; RUN=$CB_HOME/run
pass=0; fail=0; created=()
ok(){ echo "  PASS $1"; pass=$((pass+1)); }; no(){ echo "  FAIL $1"; fail=$((fail+1)); }
reset_run(){ rm -rf "$RUN/state" "$RUN/work" "$RUN/launcher.lock" "$RUN/kill_switch" "$RUN/pause" "$RUN/parallel-calls.log"; mkdir -p "$RUN/state"; : > "$RUN/parallel-calls.log"; }
cleanup(){ for n in "${created[@]}"; do gh issue close "$n" -R $CB_REPO >/dev/null 2>&1; done; }
trap cleanup EXIT
for l in type:charter status:approved status:in-progress status:review status:blocked hold; do gh label create "$l" -R $CB_REPO --color ededed 2>/dev/null||true; done
CH=$(gh issue create -R $CB_REPO -t "CHARTER flags $(date +%s)" -b root -l type:charter -l status:approved|grep -oE '[0-9]+$'|tail -1); created+=("$CH")
A=$(gh issue create -R $CB_REPO -t "flag-A $(date +%s)" -b "Charter: #$CH"|grep -oE '[0-9]+$'|tail -1); created+=("$A")
echo "charter=#$CH leaf=#$A"

echo "=== T1: kill-switch -> stop immediately, nothing claimed ==="
reset_run; touch "$RUN/kill_switch"
out=$(CB_MAX_TICKS=5 bash "$L" run 2>&1)
echo "$out" | grep -q "kill-switch" && ok "kill-switch logged" || no "no kill-switch log"
[ ! -s "$RUN/parallel-calls.log" ] && ok "nothing spawned under kill-switch" || no "spawned: $(cat $RUN/parallel-calls.log)"
[ "$(bash "$BG" get "$A" state)" = "open" ] && ok "leaf still open" || no "leaf state=$(bash "$BG" get "$A" state)"

echo "=== T2: pause -> no new claims (in-flight still managed) ==="
reset_run; touch "$RUN/pause"
out=$(CB_MAX_TICKS=3 bash "$L" run 2>&1)
echo "$out" | grep -q "paused" && ok "pause logged" || no "no pause log"
[ ! -s "$RUN/parallel-calls.log" ] && ok "nothing spawned while paused" || no "spawned while paused"
[ "$(bash "$BG" get "$A" state)" = "open" ] && ok "leaf still open while paused" || no "leaf claimed while paused"

echo "=== T3: no flags -> resumes, leaf runs to review ==="
reset_run
CB_MAX_TICKS=20 bash "$L" run >/dev/null 2>&1
[ "$(grep -c START "$RUN/parallel-calls.log")" -ge 1 ] && ok "spawned after flags removed" || no "not spawned"
[ "$(bash "$BG" get "$A" state)" = "review" ] && ok "leaf -> review" || no "leaf state=$(bash "$BG" get "$A" state)"

echo "=== SUMMARY: $pass passed, $fail failed ==="
echo "=== done ==="
