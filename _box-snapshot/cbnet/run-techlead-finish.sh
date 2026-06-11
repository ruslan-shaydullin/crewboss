#!/usr/bin/env bash
# Continue the existing run: charter #49 is approved, leaf #51 still open -> the launcher
# (with the idle-debounce fix) should pick it up and drive it to a PR.
set -u
source /home/ec2-user/.crewboss.env; export CLAUDE_CODE_OAUTH_TOKEN
export CB_REPO=stratch1989/crewboss-proto CB_HOME=/tmp/cbnet
export CB_SPAWN=/tmp/cbnet/crewboss-prep-spawn-gh.sh CB_GOVERNED=1
export CB_RETRY_CAP=2 CB_MAX_PARALLEL=2 CB_POLL=3 CB_LAUNCHER_ID=cbtl CB_MAX_TICKS=80 CB_IDLE_CONFIRM=3
GH_TOKEN=$(gh auth token); export GH_TOKEN
L=/tmp/cbnet/crewboss-launcher-gh.sh; BG=/tmp/cbnet/board-gh.sh; RUN=$CB_HOME/run
rm -rf "$RUN/state" "$RUN/launcher.lock"; mkdir -p "$RUN/state"
echo ">> launcher run (should pick up straggler #51):"
bash "$L" run 2>&1 | sed 's/^/   /; s/sk-ant-oat[A-Za-z0-9_-]*/REDACTED/g; s#x-access-token:[^@]*@#REDACTED@#g'
echo ">> result:"
for n in 50 51; do echo "   leaf #$n: state=$(bash "$BG" get "$n" state)  pr=$(jq -r '.pr//""' "$RUN/work/$n/status.json" 2>/dev/null)"; done
echo "   pool spent: \$$(jq -r .spent_usd "$RUN/budget.json")"
echo "=== done ==="
