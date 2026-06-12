#!/usr/bin/env bash
# start-stack.sh — start crewboss stack components (board daemon, UI daemon).
# Pass 'with-loop' to also start the run loop (crewboss-launcher-gh.sh).
# Env contract: sourced from run-env.sh (single canonical source — see run-env.sh).
. "$(dirname "$0")/run-env.sh"

# ── argument parsing ──────────────────────────────────────────────────────────
WITH_LOOP=0
[ "${1:-}" = "with-loop" ] && WITH_LOOP=1

# ── stack components (board daemon, UI) ──────────────────────────────────────
# Placeholder: add individual component starts here as the stack grows.
# Each component follows the same pid-guard+nohup pattern used below.

# ── run loop (only when 'with-loop' is given) ─────────────────────────────────
if [ "$WITH_LOOP" = "1" ]; then
  PIDFILE="$CB_HOME/run/launcher.pid"
  LOGFILE="$CB_HOME/run/launcher.log"
  if [ -f "$PIDFILE" ] && pid=$(cat "$PIDFILE") && kill -0 "$pid" 2>/dev/null; then
    echo "launcher already running (pid $pid)"
  else
    mkdir -p "$CB_HOME/run"
    nohup bash "$CB_HOME/crewboss-launcher-gh.sh" run >"$LOGFILE" 2>&1 &
    echo "$!" > "$PIDFILE"
    echo "launcher started (pid $!)"
  fi
fi
