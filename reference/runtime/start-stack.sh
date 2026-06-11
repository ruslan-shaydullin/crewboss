#!/usr/bin/env bash
source ~/.crewboss.env
export CB_REPO=stratch1989/crewboss CB_HOME=$HOME/cbnet
export CB_MAX_TICKS=1800 CB_MAX_PARALLEL=${CB_MAX_PARALLEL:-4} CB_TASK_TIMEOUT=3600
API_PID="$HOME/cbnet/run/api.pid"
mkdir -p "$HOME/cbnet/run"
if [ ! -f "$API_PID" ] || ! kill -0 "$(cat "$API_PID" 2>/dev/null)" 2>/dev/null; then
  nohup python3 ~/cbnet/crewboss-api.py --port 8787 > ~/cbnet/run/api.out 2>&1 &
  echo $! > "$API_PID"
fi
sleep 2; curl -s http://127.0.0.1:8787/api/health; echo
if [ "${1:-}" = "with-loop" ]; then
  LAUNCHER_PID="$HOME/cbnet/run/launcher.pid"
  if [ -f "$LAUNCHER_PID" ] && kill -0 "$(cat "$LAUNCHER_PID" 2>/dev/null)" 2>/dev/null; then
    echo "loop already running"; exit 0
  fi
  nohup bash ~/cbnet/crewboss-launcher-gh.sh run >> ~/cbnet/run/launcher.out 2>&1 &
  echo $! > "$LAUNCHER_PID"
  sleep 2; tail -1 ~/cbnet/run/launcher.out
fi
