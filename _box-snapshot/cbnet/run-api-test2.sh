#!/usr/bin/env bash
# Validate query-token auth (the path the browser EventSource uses).
set -u
export CB_REPO=stratch1989/crewboss-proto CB_HOME=/tmp/cbnet CB_API_TOKEN=testsecret CB_API_PORT=8789
B="http://127.0.0.1:8789"
pass=0; fail=0; ok(){ echo "  PASS $1"; pass=$((pass+1)); }; no(){ echo "  FAIL $1"; fail=$((fail+1)); }
pkill -f 'crewboss-api.py' 2>/dev/null; sleep 0.3
python3 /tmp/cbnet/crewboss-api.py >/tmp/cbnet/api2.out 2>&1 & API=$!
for i in $(seq 1 30); do curl -s -m1 "$B/api/health" >/dev/null 2>&1 && break; sleep 0.2; done

code=$(curl -s -m10 -o /dev/null -w '%{http_code}' "$B/api/state?token=testsecret"); [ "$code" = 200 ] && ok "GET /api/state?token -> 200" || no "state?token = $code"
code=$(curl -s -m5 -o /dev/null -w '%{http_code}' "$B/api/state?token=wrong"); [ "$code" = 401 ] && ok "wrong ?token -> 401" || no "wrong token = $code"
ev=$(curl -s -N -m5 "$B/api/events?token=testsecret" 2>/dev/null | head -c 300)
echo "$ev" | grep -q 'event: state' && ok "SSE via ?token emits state (browser path)" || no "SSE ?token (got: $(echo "$ev"|head -c60))"

kill "$API" 2>/dev/null; pkill -f 'crewboss-api.py' 2>/dev/null
echo "=== SUMMARY: $pass passed, $fail failed ==="
echo "=== done ==="
