#!/usr/bin/env bash
# shellcheck source=run-env.sh
. "$(dirname "$0")/run-env.sh"
LAUNCHER_PID="$HOME/cbnet/run/launcher.pid"
if [ -f "$LAUNCHER_PID" ] && kill -0 "$(cat "$LAUNCHER_PID" 2>/dev/null)" 2>/dev/null; then
  echo "loop already running"; exit 0
fi
# Belt-and-braces: pipe launcher stdout+stderr through redact.pl so launcher.out
# never accumulates raw tokens (e.g. from set -x or stray echo).
# Graceful degradation: falls back to cat if redact.pl is absent (dev/test envs).
nohup bash -c 'bash "$1" run 2>&1 | ( [ -f "$2" ] && exec perl "$2" || exec cat )' -- \
  "$CB_HOME/crewboss-launcher-gh.sh" "$CB_HOME/redact.pl" \
  >> "$CB_HOME/run/launcher.out" 2>/dev/null &
echo $! > "$LAUNCHER_PID"
sleep 2; tail -1 "$CB_HOME/run/launcher.out"
