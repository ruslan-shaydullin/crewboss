#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=run-env.sh
. "$(dirname "$0")/run-env.sh"
API_PID="$CB_HOME/run/api.pid"
mkdir -p "$CB_HOME/run"
if [ ! -f "$API_PID" ] || ! kill -0 "$(cat "$API_PID" 2>/dev/null)" 2>/dev/null; then
  bash "$(dirname "$0")/start-api.sh"
fi
if [ "${1:-}" = "with-loop" ]; then
  exec bash "$(dirname "$0")/run-charter.sh"
fi
