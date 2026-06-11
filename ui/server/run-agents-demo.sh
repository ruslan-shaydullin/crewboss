#!/usr/bin/env bash
# Free agents-rail demo: approved charter + 3 open leaves, launcher with a SLOW stub so 3
# agents are visibly "running" (pulse + elapsed) in the UI rail for ~45s, then -> review.
set -u
export CB_REPO=stratch1989/crewboss-proto CB_HOME=/tmp/cbnet
export CB_SPAWN=/tmp/cbnet/stub-spawn-bg.sh CB_RETRY_CAP=2 CB_MAX_PARALLEL=3 CB_POLL=2 CB_LAUNCHER_ID=uidemo
export STUB_SLEEP=45 CB_MAX_TICKS=60 CB_IDLE_CONFIRM=2
L=/tmp/cbnet/crewboss-launcher-gh.sh; RUN=$CB_HOME/run
rm -rf "$RUN/state" "$RUN/launcher.lock"; mkdir -p "$RUN/state"
for l in type:charter status:approved status:in-progress status:review status:blocked hold; do gh label create "$l" -R $CB_REPO --color ededed 2>/dev/null||true; done
CH=$(gh issue create -R $CB_REPO -t "Charter: UI agents demo" -b "demo goal" -l type:charter -l status:approved | grep -oE '[0-9]+$'|tail -1)
for nm in alpha beta gamma; do gh issue create -R $CB_REPO -t "demo task $nm" -b "Charter: #$CH" >/dev/null; done
echo "charter #$CH + 3 leaves created; launching stub agents (visible ~${STUB_SLEEP}s in the rail)"
nohup bash "$L" run >"$RUN/uidemo.out" 2>&1 &
echo "launcher pid $!  — refresh the UI and watch the Agents rail"
