#!/usr/bin/env bash
# shellcheck source=run-env.sh
. "$(dirname "$0")/run-env.sh"
LAUNCHER_PID="$HOME/cbnet/run/launcher.pid"
if [ -f "$LAUNCHER_PID" ] && kill -0 "$(cat "$LAUNCHER_PID" 2>/dev/null)" 2>/dev/null; then
  echo "loop already running"; exit 0
fi
nohup bash ~/cbnet/crewboss-launcher-gh.sh run >> ~/cbnet/run/launcher.out 2>&1 &
echo $! > "$LAUNCHER_PID"
sleep 2; tail -1 ~/cbnet/run/launcher.out
