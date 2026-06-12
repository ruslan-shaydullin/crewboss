#!/usr/bin/env bash
source ~/.crewboss.env
export CB_REPO=stratch1989/crewboss CB_HOME=$HOME/cbnet
export CB_MAX_TICKS=1800 CB_MAX_PARALLEL=4 CB_TASK_TIMEOUT=3600
export CB_SPAWN=$HOME/cbnet/charter-leaf-prep.sh
# gate / integrator env (F8 contract — soft link, just pass through)
GH_TOKEN="${GH_TOKEN:-$(gh auth token 2>/dev/null)}"
export CB_GIT_REMOTE="https://x-access-token:${GH_TOKEN}@github.com/${CB_REPO}.git"
export CB_PLAN_SPAWN="${CB_PLAN_SPAWN:-$HOME/cbnet/crewboss-prep-spawn-gh.sh}"
export CB_HARNESS="${CB_HARNESS:-}"
export CB_GATE_REPO_DIR="${CB_GATE_REPO_DIR:-.}"
LAUNCHER_PID="$HOME/cbnet/run/launcher.pid"
if [ -f "$LAUNCHER_PID" ] && kill -0 "$(cat "$LAUNCHER_PID" 2>/dev/null)" 2>/dev/null; then
  echo "loop already running"; exit 0
fi
nohup bash ~/cbnet/crewboss-launcher-gh.sh run >> ~/cbnet/run/launcher.out 2>&1 &
echo $! > "$LAUNCHER_PID"
sleep 2; tail -1 ~/cbnet/run/launcher.out
