#!/usr/bin/env bash
# Start a deployed API, or use --foreground under a process supervisor.
# Optional CB_ENV_FILE is a trusted shell file; its assignments override the
# inherited environment. See api.env.example for the required configuration.
set -euo pipefail
umask 077

fail() { printf 'start-api: %s\n' "$*" >&2; exit 1; }
case "${1:-}" in
  '') foreground=0 ;;
  --foreground) foreground=1 ;;
  *) fail 'usage: start-api.sh [--foreground]' ;;
esac
[ "$#" -le 1 ] || fail 'usage: start-api.sh [--foreground]'

# shellcheck source=run-env.sh
. "$(dirname "${BASH_SOURCE[0]}")/run-env.sh" || fail 'runtime configuration is invalid'
[[ "${CB_API_TOKEN:-}" =~ [^[:space:]] ]] \
  || fail 'set CB_API_TOKEN to a private, randomly generated bearer token'

export CB_REPO CB_API_TOKEN
export CB_HOME="${CB_HOME:-$HOME/cbnet}"
export CB_API_HOST="${CB_API_HOST:-127.0.0.1}"
export CB_API_PORT="${CB_API_PORT:-8787}"
export CB_API_SCRIPT="${CB_API_SCRIPT:-$CB_HOME/crewboss-api.py}"
export CB_GOVERNED="${CB_GOVERNED:-1}"
[[ "$CB_API_PORT" =~ ^[0-9]+$ ]] && [ "${#CB_API_PORT}" -le 5 ] \
  && (( 10#$CB_API_PORT >= 1 && 10#$CB_API_PORT <= 65535 )) \
  || fail 'CB_API_PORT must be an integer from 1 to 65535'
[ -f "$CB_API_SCRIPT" ] || fail "API script not found: $CB_API_SCRIPT (set CB_API_SCRIPT or deploy the runtime to CB_HOME)"
command -v python3 >/dev/null || fail 'python3 is required'
mkdir -p "$CB_HOME/run"

if [ "$foreground" -eq 1 ]; then
  exec python3 "$CB_API_SCRIPT" --port "$CB_API_PORT"
fi

command -v curl >/dev/null || fail 'curl is required for the startup health check'
api_pid_file="$CB_HOME/run/api.pid"
if [ -f "$api_pid_file" ]; then
  old_pid="$(cat "$api_pid_file")"
  if [[ "$old_pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$old_pid" 2>/dev/null; then
    fail "a process already uses $api_pid_file; stop that API before starting another"
  fi
  rm -f "$api_pid_file"
fi

nohup python3 "$CB_API_SCRIPT" --port "$CB_API_PORT" >"$CB_HOME/run/api.out" 2>&1 < /dev/null &
api_pid=$!
printf '%s\n' "$api_pid" > "$api_pid_file"
# Only stop the process started by this invocation if readiness fails.
cleanup() {
  kill "$api_pid" 2>/dev/null || true
  wait "$api_pid" 2>/dev/null || true
  rm -f "$api_pid_file"
}
trap cleanup EXIT

check_host="$CB_API_HOST"
case "$check_host" in
  0.0.0.0) check_host=127.0.0.1 ;;
  ::) check_host='[::1]' ;;
  *:*) check_host="[$check_host]" ;;
esac
health_url="http://$check_host:$CB_API_PORT/api/health"
for (( attempt=0; attempt<30; attempt++ )); do
  sleep 0.2
  kill -0 "$api_pid" 2>/dev/null || fail "API exited during startup; see $CB_HOME/run/api.out"
  if curl --noproxy '*' --fail --silent --max-time 1 "$health_url" >/dev/null 2>&1; then
    trap - EXIT
    disown "$api_pid" 2>/dev/null || true
    printf 'API started (PID %s): %s\nLog: %s/run/api.out\n' "$api_pid" "$health_url" "$CB_HOME"
    exit 0
  fi
done
fail "API did not become healthy; see $CB_HOME/run/api.out"
