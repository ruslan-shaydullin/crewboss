#!/usr/bin/env bash
# run-charter.sh — start the crewboss charter-integration run loop.
# Env contract: sourced from run-env.sh (single canonical source — see run-env.sh).
. "$(dirname "$0")/run-env.sh"
# ── pid-guard: one launcher per host ─────────────────────────────────────────
PIDFILE="$CB_HOME/run/launcher.pid"
LOGFILE="$CB_HOME/run/launcher.log"
if [ -f "$PIDFILE" ] && pid=$(cat "$PIDFILE") && kill -0 "$pid" 2>/dev/null; then
  echo "launcher already running (pid $pid)"; exit 0
fi
mkdir -p "$CB_HOME/run"
nohup bash "$CB_HOME/crewboss-launcher-gh.sh" run >"$LOGFILE" 2>&1 &
echo "$!" > "$PIDFILE"
echo "launcher started (pid $!)"
