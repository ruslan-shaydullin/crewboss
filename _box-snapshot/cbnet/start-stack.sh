#!/usr/bin/env bash
source ~/.crewboss.env
export CB_REPO=stratch1989/crewboss CB_HOME=$HOME/cbnet
export CB_MAX_TICKS=1800 CB_MAX_PARALLEL=${CB_MAX_PARALLEL:-4} CB_TASK_TIMEOUT=3600
pgrep -f "cbnet/crewboss-api.py" >/dev/null || { nohup python3 ~/cbnet/crewboss-api.py --port 8787 > ~/cbnet/run/api.out 2>&1 & }
sleep 2; curl -s http://127.0.0.1:8787/api/health; echo
if [ "${1:-}" = "with-loop" ]; then
  pgrep -f "crewboss-launcher-gh.sh run" >/dev/null && { echo "loop already running"; exit 0; }
  nohup bash ~/cbnet/crewboss-launcher-gh.sh run >> ~/cbnet/run/launcher.out 2>&1 &
  sleep 2; tail -1 ~/cbnet/run/launcher.out
fi
