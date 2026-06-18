#!/usr/bin/env bash
# Validate the demon-API (phase 0): health, auth, state, command flag-toggles, SSE.
set -u
export CB_REPO=stratch1989/crewboss-proto CB_HOME=/tmp/cbnet CB_API_TOKEN=testsecret CB_API_PORT=8788
RUN=$CB_HOME/run; mkdir -p "$RUN"
B="http://127.0.0.1:8788"; H="Authorization: Bearer testsecret"
pass=0; fail=0; ok(){ echo "  PASS $1"; pass=$((pass+1)); }; no(){ echo "  FAIL $1"; fail=$((fail+1)); }
pkill -f 'crewboss-api.py' 2>/dev/null; sleep 0.3
rm -f "$RUN/pause" "$RUN/kill_switch"
python3 /tmp/cbnet/crewboss-api.py >/tmp/cbnet/api.out 2>&1 & API=$!
for i in $(seq 1 30); do curl -s -m1 "$B/api/health" >/dev/null 2>&1 && break; sleep 0.2; done

echo "=== health (no auth) ==="
curl -s -m5 "$B/api/health" | grep -q '"ok": true' && ok "health ok" || no "health"

echo "=== auth required ==="
code=$(curl -s -m5 -o /dev/null -w '%{http_code}' "$B/api/state"); [ "$code" = 401 ] && ok "state 401 without token" || no "state without token = $code"

echo "=== state (authed) ==="
st=$(curl -s -m20 -H "$H" "$B/api/state")
echo "$st" | jq -e '.board and .budget and .flags' >/dev/null 2>&1 && ok "state has board/budget/flags" || no "state shape"
echo "   board rows: $(echo "$st" | jq '.board|length' 2>/dev/null)  spent: \$$(echo "$st" | jq -r '.budget.spent' 2>/dev/null)"

echo "=== command: pause -> resume (flag toggles) ==="
curl -s -m5 -H "$H" -d '{"action":"pause"}' "$B/api/command" | grep -q '"ok": true' && [ -f "$RUN/pause" ] && ok "pause set flag" || no "pause"
curl -s -m5 -H "$H" -d '{"action":"resume"}' "$B/api/command" >/dev/null; [ ! -f "$RUN/pause" ] && ok "resume cleared flag" || no "resume"
echo "=== command: kill -> unkill ==="
curl -s -m5 -H "$H" -d '{"action":"kill"}' "$B/api/command" >/dev/null; [ -f "$RUN/kill_switch" ] && ok "kill set flag" || no "kill"
curl -s -m5 -H "$H" -d '{"action":"unkill"}' "$B/api/command" >/dev/null; [ ! -f "$RUN/kill_switch" ] && ok "unkill cleared flag" || no "unkill"
echo "=== command: unknown rejected ==="
curl -s -m5 -H "$H" -d '{"action":"nope"}' "$B/api/command" | grep -q '"ok": false' && ok "unknown action rejected" || no "unknown action"

echo "=== queue: POST /api/queue persists order (#280) ==="
curl -s -m5 -H "$H" -d '{"order":[3,1,2]}' "$B/api/queue" | grep -q '"ok": true' && ok "POST /api/queue 200 ok" || no "POST /api/queue"
[ "$(jq -r '.order|join(",")' "$RUN/queue.json" 2>/dev/null)" = "3,1,2" ] && ok "queue.json written [3,1,2]" || no "queue.json content"
curl -s -m20 -H "$H" "$B/api/state" | jq -e '.queue.order == [3,1,2]' >/dev/null 2>&1 && ok "state.queue.order == [3,1,2]" || no "state.queue"
echo "=== queue: bad input -> 400 ==="
code=$(curl -s -m5 -o /dev/null -w '%{http_code}' -H "$H" -d '{"nope":1}' "$B/api/queue"); [ "$code" = 400 ] && ok "non-list order -> 400" || no "bad queue = $code"
echo "=== queue: empty order clears (#280) ==="
curl -s -m5 -H "$H" -d '{"order":[]}' "$B/api/queue" | grep -q '"ok": true' && [ "$(jq -r '.order|length' "$RUN/queue.json" 2>/dev/null)" = 0 ] && ok "empty order clears queue" || no "clear queue"

echo "=== SSE events ==="
ev=$(curl -s -N -m5 -H "$H" "$B/api/events" 2>/dev/null | head -c 400)
echo "$ev" | grep -q 'event: state' && ok "SSE emits state event" || no "SSE (got: $(echo "$ev"|head -c80))"

kill "$API" 2>/dev/null; pkill -f 'crewboss-api.py' 2>/dev/null
echo "=== SUMMARY: $pass passed, $fail failed ==="
echo "=== done ==="
