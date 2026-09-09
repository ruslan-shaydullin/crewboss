#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=run-env.sh
. "$(dirname "$0")/run-env.sh"
case "${1:-}" in ''|--foreground) ;; *) echo 'usage: run-charter.sh [--foreground]' >&2; exit 2 ;; esac
mkdir -p "$CB_HOME/run"
bash "$CB_HOME/crewboss-doctor.sh" --preflight
LAUNCHER_PID="$CB_HOME/run/launcher.pid"
if [ -f "$LAUNCHER_PID" ] && kill -0 "$(cat "$LAUNCHER_PID" 2>/dev/null)" 2>/dev/null; then
  echo "loop already running"; exit 0
fi
# board-init: ensure orchestration labels exist (idempotent) before the loop starts (#205)
bash "$CB_HOME/labels-setup.sh" >/dev/null 2>&1 || true
if [ "${1:-}" = --foreground ]; then
  exec bash "$CB_HOME/crewboss-launcher-gh.sh" run
fi
# Belt-and-braces: pipe launcher stdout+stderr through redact.pl so launcher.out
# never accumulates raw tokens (e.g. from set -x or stray echo).
# Graceful degradation: falls back to cat if redact.pl is absent (dev/test envs).
nohup bash -c 'bash "$1" run 2>&1 | ( [ -f "$2" ] && exec perl "$2" || exec cat )' -- \
  "$CB_HOME/crewboss-launcher-gh.sh" "$CB_HOME/redact.pl" \
  >> "$CB_HOME/run/launcher.out" 2>/dev/null &
echo $! > "$LAUNCHER_PID"
sleep 2; tail -1 "$CB_HOME/run/launcher.out"
