#!/usr/bin/env bash
# boss-chat-endpoint.test.sh — POST /api/boss endpoint contract (issue #313, charter #291)
#
# Verifies the /api/boss endpoint using stubs — no real claude, no real gh.
# Pattern: follows ui-run-contract.test.sh and ui-loop-mode.test.sh.
#
# Cases:
#   1  POST with valid message → {ok:true, session_id, message} + history.json created
#   2  Second POST with same session_id → history.json has 4 entries
#   3  Charter detection — stub returns GitHub issues URL → charter_number in response
#   4  Missing auth → HTTP 401
#   5  Empty message → {ok:false}

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
API_PY="$REPO_ROOT/ui/server/crewboss-api.py"

pass=0; fail=0
ok(){ printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

ROOT="$(mktemp -d)"; API_PID=""
cleanup(){ [ -n "${API_PID:-}" ] && kill "$API_PID" 2>/dev/null || true; rm -rf "$ROOT"; }
trap 'cleanup' EXIT

FAKE_HOME="$ROOT/home"
CBNET="$FAKE_HOME/cbnet"
BIN="$ROOT/bin"
API_OUT="$ROOT/api.out"
API_PORT=8856   # unique port for this test suite

mkdir -p "$CBNET/run" "$BIN"

# ── Verify api.py exists ──────────────────────────────────────────────────────
if [ ! -f "$API_PY" ]; then
  no "crewboss-api.py not found: $API_PY"
  printf '\n=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"; exit 1
fi

# ── Fake ~/.crewboss.env ──────────────────────────────────────────────────────
mkdir -p "$FAKE_HOME"
cat > "$FAKE_HOME/.crewboss.env" <<'ENVEOF'
CB_API_TOKEN=FAKEAPITOKEN
CLAUDE_CODE_OAUTH_TOKEN=FAKEOAUTH
ENVEOF

# ── Stub gh: no-op (boss reads board via gh; stubs suffice for unit test) ─────
cat > "$BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
exit 0
GHEOF
chmod +x "$BIN/gh"

# ── Stub claude: normal canned response ──────────────────────────────────────
cat > "$BIN/claude" <<'CLAUDEOF'
#!/usr/bin/env bash
printf '{"result":"Tell me more about the goal.","is_error":false}\n'
CLAUDEOF
chmod +x "$BIN/claude"

# ── Start api.py (model post-deploy restart: env -i, CB_HOME/CB_REPO explicit) ─
env -i \
  HOME="$FAKE_HOME" \
  PATH="$BIN:/usr/bin:/bin:/usr/local/bin" \
  CB_API_TOKEN=FAKEAPITOKEN \
  CB_HOME="$CBNET" \
  CB_REPO=owner/repo \
  python3 "$API_PY" --port "$API_PORT" \
  > "$API_OUT" 2>&1 &
API_PID=$!

# ── Wait for API ready (poll, no fixed sleep) ─────────────────────────────────
B="http://127.0.0.1:$API_PORT"
api_ready=0
deadline=$(( $(date +%s) + 25 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  code=$(curl -s -m1 -o /dev/null -w '%{http_code}' "$B/api/health" 2>/dev/null)
  if [ "$code" = "200" ]; then api_ready=1; break; fi
  sleep 0.2
done

if [ "$api_ready" -eq 0 ]; then
  no "API did not become ready within deadline"
  printf 'api output:\n'; head -10 "$API_OUT" 2>/dev/null || true
  printf '\n=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"; exit 1
fi

# ── Helper: json field extractor (stdlib python3 only) ────────────────────────
json_field(){
  python3 -c "
import json, sys
try:
    d=json.loads(sys.argv[1])
    parts=sys.argv[2].split('.')
    for p in parts:
        if isinstance(d, dict): d=d.get(p,'')
        else: d=''; break
    print(d)
except Exception:
    print('')
" "$1" "$2" 2>/dev/null
}

# =============================================================================
# Case 1: POST /api/boss with valid message returns {ok:true, session_id, message}
# =============================================================================
echo "=== Case 1: POST /api/boss with valid message ==="

resp1=$(curl -s -m30 -X POST \
  -H "Authorization: Bearer FAKEAPITOKEN" \
  -H "Content-Type: application/json" \
  -d '{"message":"Hello"}' \
  "$B/api/boss" 2>/dev/null)

ok_val1=$(json_field "$resp1" "ok")
session_id=$(json_field "$resp1" "session_id")
msg_val1=$(json_field "$resp1" "message")

if [ "$ok_val1" = "True" ] || [ "$ok_val1" = "true" ]; then
  ok "Case 1: response .ok == true"
else
  no "Case 1: response .ok != true (got: '$ok_val1'); resp=$resp1"
fi

if [ -n "$session_id" ]; then
  ok "Case 1: response .session_id is non-empty"
else
  no "Case 1: response .session_id is empty; resp=$resp1"
fi

if [ -n "$msg_val1" ]; then
  ok "Case 1: response .message is non-empty"
else
  no "Case 1: response .message is empty; resp=$resp1"
fi

# Check session history file exists
hist_path="$CBNET/run/boss-sessions/$session_id/history.json"
if [ -n "$session_id" ] && [ -f "$hist_path" ]; then
  ok "Case 1: history.json exists at \$CBNET/run/boss-sessions/<session_id>/history.json"
else
  no "Case 1: history.json not found at $hist_path"
fi

# =============================================================================
# Case 2: Second POST with same session_id appends to history (4 entries total)
# =============================================================================
echo "=== Case 2: Second POST with same session_id appends to history ==="

if [ -z "$session_id" ]; then
  no "Case 2: skipped — session_id from Case 1 was empty"
else
  resp2=$(curl -s -m30 -X POST \
    -H "Authorization: Bearer FAKEAPITOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"message\":\"Tell me more\",\"session_id\":\"$session_id\"}" \
    "$B/api/boss" 2>/dev/null)

  ok_val2=$(json_field "$resp2" "ok")
  if [ "$ok_val2" = "True" ] || [ "$ok_val2" = "true" ]; then
    ok "Case 2: second POST succeeded (ok=true)"
  else
    no "Case 2: second POST failed (got ok='$ok_val2'); resp=$resp2"
  fi

  entry_count=$(python3 -c "
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    print(len(data))
except Exception:
    print(0)
" "$hist_path" 2>/dev/null)

  if [ "$entry_count" = "4" ]; then
    ok "Case 2: history.json contains 4 entries (2 user + 2 boss)"
  else
    no "Case 2: history.json has $entry_count entries (expected 4)"
  fi
fi

# =============================================================================
# Case 3: Charter detection — stub returns URL → charter_number in response
# =============================================================================
echo "=== Case 3: Charter detection — stub returns GitHub issues URL ==="

# Replace claude stub with charter-detection version
cat > "$BIN/claude" <<'CLAUDEOF'
#!/usr/bin/env bash
printf '{"result":"Created charter at https://github.com/owner/repo/issues/42","is_error":false}\n'
CLAUDEOF
chmod +x "$BIN/claude"

resp3=$(curl -s -m30 -X POST \
  -H "Authorization: Bearer FAKEAPITOKEN" \
  -H "Content-Type: application/json" \
  -d '{"message":"Create a charter for me"}' \
  "$B/api/boss" 2>/dev/null)

charter_num=$(json_field "$resp3" "charter_number")
if [ "$charter_num" = "42" ]; then
  ok "Case 3: response .charter_number == 42"
else
  no "Case 3: response .charter_number != 42 (got: '$charter_num'); resp=$resp3"
fi

# =============================================================================
# Case 4: Missing auth token returns 401
# =============================================================================
echo "=== Case 4: Missing auth token returns 401 ==="

status4=$(curl -s -m30 -X POST \
  -H "Content-Type: application/json" \
  -d '{"message":"Hello"}' \
  -o /dev/null \
  -w '%{http_code}' \
  "$B/api/boss" 2>/dev/null)

if [ "$status4" = "401" ]; then
  ok "Case 4: missing auth → HTTP 401"
else
  no "Case 4: missing auth → HTTP $status4 (expected 401)"
fi

# =============================================================================
# Case 5: Empty message returns {ok:false}
# =============================================================================
echo "=== Case 5: Empty message returns {ok:false} ==="

resp5=$(curl -s -m30 -X POST \
  -H "Authorization: Bearer FAKEAPITOKEN" \
  -H "Content-Type: application/json" \
  -d '{"message":""}' \
  "$B/api/boss" 2>/dev/null)

ok_val5=$(json_field "$resp5" "ok")
if [ "$ok_val5" = "False" ] || [ "$ok_val5" = "false" ]; then
  ok "Case 5: empty message → ok=false"
else
  no "Case 5: empty message → ok=$ok_val5 (expected false); resp=$resp5"
fi

# =============================================================================
echo
printf '=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
