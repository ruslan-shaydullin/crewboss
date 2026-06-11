#!/usr/bin/env bash
# Validate background-parallel spawns (§4.6): the `run` poll-loop backgrounds spawns up to
# the cap, routes each on finish, exits when idle. Real gh board + stub spawn (no claude spend).
# Concurrency is MEASURED from the stub's START/END log (max simultaneous == cap proves both
# parallelism happened AND the cap held).
set -u
export CB_REPO=stratch1989/crewboss-proto CB_HOME=/tmp/cbnet
export CB_SPAWN=/tmp/cbnet/stub-spawn-bg.sh CB_RETRY_CAP=2 CB_MAX_PARALLEL=2 CB_POLL=1 CB_LAUNCHER_ID=cbpar
export STUB_SLEEP=4
L=/tmp/cbnet/crewboss-launcher-gh.sh; BG=/tmp/cbnet/board-gh.sh
RUN=$CB_HOME/run
pass=0; fail=0; created=()
ok(){ echo "  PASS $1"; pass=$((pass+1)); }
no(){ echo "  FAIL $1"; fail=$((fail+1)); }
rm -rf "$RUN/state" "$RUN/stub-ctl" "$RUN/parallel-calls.log" "$RUN/launcher.lock" "$RUN/work"
mkdir -p "$RUN/state" "$RUN/stub-ctl"; : > "$RUN/parallel-calls.log"
cleanup(){ for n in "${created[@]}"; do gh issue close "$n" -R $CB_REPO >/dev/null 2>&1; done; }
trap cleanup EXIT

for l in type:charter status:approved status:in-progress status:review status:blocked hold; do
  gh label create "$l" -R $CB_REPO --color ededed 2>/dev/null || true; done
CH=$(gh issue create -R $CB_REPO -t "CHARTER parallel $(date +%s)" -b root -l type:charter -l status:approved | grep -oE '[0-9]+$' | tail -1); created+=("$CH")
A=$(gh issue create -R $CB_REPO -t "par-A $(date +%s)" -b "Charter: #$CH" | grep -oE '[0-9]+$'|tail -1); created+=("$A")
B=$(gh issue create -R $CB_REPO -t "par-B $(date +%s)" -b "Charter: #$CH" | grep -oE '[0-9]+$'|tail -1); created+=("$B")
C=$(gh issue create -R $CB_REPO -t "par-C $(date +%s)" -b "Charter: #$CH" | grep -oE '[0-9]+$'|tail -1); created+=("$C")
echo "charter=#$CH leaves=#$A #$B #$C  cap=$CB_MAX_PARALLEL sleep=${STUB_SLEEP}s"

echo "=== run (background-parallel poll-loop) ==="
t0=$(date +%s)
bash "$L" run 2>&1 | sed 's/^/  /'
echo "wall=$(( $(date +%s) - t0 ))s"

echo "=== verify ==="
for n in "$A" "$B" "$C"; do
  s=$(bash "$BG" get "$n" state)
  [ "$s" = "review" ] && ok "#$n -> review" || no "#$n state=$s"
done
# measure max concurrency from START/END events
maxc=$(awk '{ if($1=="START")c++; else if($1=="END")c--; if(c>m)m=c } END{print m+0}' "$RUN/parallel-calls.log")
echo "observed max concurrency = $maxc (cap=$CB_MAX_PARALLEL)"
[ "$maxc" = "$CB_MAX_PARALLEL" ] && ok "ran in parallel AND honored cap (max==$CB_MAX_PARALLEL)" || no "max concurrency=$maxc (want $CB_MAX_PARALLEL)"
[ "$(grep -c START "$RUN/parallel-calls.log")" = 3 ] && ok "all 3 spawned" || no "spawn count=$(grep -c START "$RUN/parallel-calls.log")"

echo "=== SUMMARY: $pass passed, $fail failed ==="
echo "=== done ==="
