#!/usr/bin/env bash
source ~/.crewboss.env
export CB_REPO=ruslan-shaydullin/crewboss-proto CB_HOME=/tmp/cbnet CB_API_TOKEN=secret123
export CB_WEBHOOK_SECRET="${CB_WEBHOOK_SECRET:-changeme}"
export CB_API_HOST="${CB_API_HOST:-127.0.0.1}"
export CB_SPAWN=/tmp/cbnet/crewboss-prep-spawn-gh.sh CB_GOVERNED=1
export CLAUDE_CODE_OAUTH_TOKEN GH_TOKEN="$(gh auth token)"
mkdir -p /tmp/cbnet/run
API_PID=/tmp/cbnet/run/api.pid
if [ -f "$API_PID" ]; then kill "$(cat "$API_PID")" 2>/dev/null; rm -f "$API_PID"; fi; sleep 0.4
nohup python3 /tmp/cbnet/crewboss-api.py >/tmp/cbnet/run/api.out 2>&1 &
echo $! > "$API_PID"
disown 2>/dev/null
for i in $(seq 1 30); do curl -s -m1 http://127.0.0.1:8787/api/health >/dev/null 2>&1 && break; sleep 0.2; done
echo "=== health ==="; curl -s -m3 http://127.0.0.1:8787/api/health; echo
echo "=== state (authed) ==="; curl -s -m15 -H "Authorization: Bearer secret123" http://127.0.0.1:8787/api/state | jq '{rows:(.board|length), spent:.budget.spent, cap:.budget.cap, flags:.flags}'
echo "=== api.out ==="; tail -2 /tmp/cbnet/run/api.out
