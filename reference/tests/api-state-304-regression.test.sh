#!/usr/bin/env bash
# api-state-304-regression.test.sh — ETag/304 regression on /api/state (issue #809)
#
# Charter #707 fixes a critical regression from #527 (ETag/webhooks, merged #675).
# When /api/state gets a 304 Not Modified from GitHub on the second gh-api call
# (server sends If-None-Match from its ETag cache), the original code did:
#
#   return _cached_issues  # skip refresh
#
# …returning the RAW GitHub issue array instead of the assembled board object
# {board, agents, budget, flags, autonomy}.  Dashboard crashes on the 2nd poll.
#
# This test verifies end-to-end:
#   1. First  /api/state (cold, no ETag stored): response is a JSON object.
#   2. Second /api/state (304 path — server sends If-None-Match, stub returns 304):
#      response is STILL a JSON object, not a raw issue array.
#   3. Neither response is a JSON array at the top level.
#
# Class: EXCLUDED — starts crewboss-api.py as a background process, uses HTTP;
# per per-leaf-manifest criterion no background processes / no network.
#
# Stub strategy: gh binary replaced with a shell script that:
#   * Returns HTTP/2.0 200 OK + ETag + minimal issue list on the first gh api call.
#   * Returns HTTP/2.0 304 Not Modified (empty body) when the -H If-None-Match:
#     argument is present (i.e. on the second call, triggered by the server's
#     internal ETag cache).

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
API_PY="$REPO_ROOT/ui/server/crewboss-api.py"

pass=0; fail=0
ok(){ printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

API_PID=""
ROOT="$(mktemp -d)"
cleanup(){
  [ -n "${API_PID:-}" ] && kill "$API_PID" 2>/dev/null || true
  rm -rf "$ROOT"
}
trap 'cleanup' EXIT

export BIN="$ROOT/bin"
CBNET="$ROOT/cbhome"
API_OUT="$ROOT/api.out"
API_PORT=18809

mkdir -p "$BIN" "$CBNET/run"

# ── Verify prerequisites ──────────────────────────────────────────────────────
if [ ! -f "$API_PY" ]; then
  no "crewboss-api.py not found: $API_PY"
  printf '\n=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"; exit 1
fi

# ── Stub gh: ETag/304 simulation ─────────────────────────────────────────────
# First call to "gh api ... --include" (no If-None-Match arg):
#   => HTTP 200 + ETag header + minimal issue list body
# Subsequent calls with "-H" "If-None-Match: ...":
#   => HTTP 304 Not Modified (empty body) — triggers the 304 regression path
# auth subcommand: emit FAKETOKEN (required for API startup)
cat > "$BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "auth" ] && [ "${2:-}" = "token" ]; then
  printf 'FAKETOKEN\n'; exit 0
fi

# Detect If-None-Match header arg => return 304 (second+ call)
for arg in "$@"; do
  case "$arg" in
    If-None-Match:*)
      printf 'HTTP/2.0 304 Not Modified\r\n\r\n'
      exit 0
      ;;
  esac
done

# First call: 200 OK + ETag + minimal issue list
printf 'HTTP/2.0 200 OK\r\nETag: "test-etag-809-abc"\r\n\r\n'
printf '[{"number":1,"title":"Stub issue","labels":[],"state":"open","body":"Charter: #707"}]\n'
exit 0
GHEOF
chmod +x "$BIN/gh"

# ── Start crewboss-api.py ─────────────────────────────────────────────────────
env -i \
  PATH="${BIN}:/usr/bin:/bin:/usr/local/bin" \
  CB_API_TOKEN="FAKEAPITOKEN304" \
  CB_HOME="$CBNET" \
  CB_REPO="fakeorg/fakerepo" \
  python3 "$API_PY" --port "$API_PORT" \
  > "$API_OUT" 2>&1 &
API_PID=$!

# Poll until /api/health returns 200 (no fixed sleep)
api_ready=0
deadline=$(( $(date +%s) + 25 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  code=$(curl -s -m1 -o /dev/null -w '%{http_code}' \
    "http://127.0.0.1:${API_PORT}/api/health" 2>/dev/null)
  if [ "$code" = "200" ]; then api_ready=1; break; fi
  sleep 0.2
done

if [ "$api_ready" -eq 0 ]; then
  no "API did not become ready within deadline"
  printf 'API output (first 10 lines):\n'; head -10 "$API_OUT" 2>/dev/null || true
  printf '\n=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"; exit 1
fi
ok "API ready on port $API_PORT"

# ── Helper: assert response is a board object, not a raw issue array ──────────
# Emits ok/no and returns 0 on success, 1 on failure.
assert_board_object(){
  local label="$1" body="$2"

  # Must not start with '[' (which would indicate a raw JSON array)
  first_char=$(printf '%s' "$body" | python3 -c \
    "import sys; s=sys.stdin.read().strip(); print(s[0] if s else 'EMPTY')" 2>/dev/null)
  if [ "$first_char" = "[" ]; then
    no "$label: response is a raw JSON array — 304 regression present (expected board object)"
    return 1
  fi

  # Must be a JSON object with required board keys
  check=$(python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
    if not isinstance(d, dict):
        print('NOT_OBJECT')
        sys.exit(0)
    required = {'board', 'agents', 'budget', 'flags', 'autonomy'}
    missing = required - set(d.keys())
    if missing:
        print('MISSING:' + ','.join(sorted(missing)))
    else:
        print('OK')
except Exception as e:
    print('ERROR:' + str(e))
" "$body" 2>/dev/null)

  case "$check" in
    OK)
      ok "$label: JSON object with board/agents/budget/flags/autonomy"
      return 0
      ;;
    NOT_OBJECT)
      no "$label: parsed JSON is not an object (type mismatch)"
      return 1
      ;;
    MISSING:*)
      no "$label: missing keys: ${check#MISSING:}"
      return 1
      ;;
    *)
      no "$label: JSON parse error or empty response (${check:-empty})"
      return 1
      ;;
  esac
}

# ── Request 1: cold path (no ETag in server state yet) ───────────────────────
echo "=== Request 1: cold /api/state (gh stub returns 200 + ETag) ==="
RESP1=$(curl -s -m15 \
  -H "Authorization: Bearer FAKEAPITOKEN304" \
  "http://127.0.0.1:${API_PORT}/api/state" 2>/dev/null)

if [ -z "$RESP1" ]; then
  no "Request 1: empty response from /api/state"
  printf '\n=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"; exit 1
fi
assert_board_object "Request 1 (cold)" "$RESP1"

# ── Request 2: 304 path (server sends If-None-Match, stub returns 304) ────────
# The server now has _etag_store["issues"]="test-etag-809-abc" from request 1.
# On this second call, the server appends -H "If-None-Match: ..." to the gh cmd.
# The stub detects the If-None-Match arg and returns 304 (empty body).
# BUG (pre-fix): return _cached_issues → raw issue array → dashboard crash.
# FIX: issues = _cached_issues → board assembled from cached issues → object.
echo "=== Request 2: /api/state with ETag cached (gh stub returns 304) ==="
RESP2=$(curl -s -m15 \
  -H "Authorization: Bearer FAKEAPITOKEN304" \
  "http://127.0.0.1:${API_PORT}/api/state" 2>/dev/null)

if [ -z "$RESP2" ]; then
  no "Request 2: empty response from /api/state (304 path)"
  printf '\n=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"; exit 1
fi
assert_board_object "Request 2 (304 path — regression guard)" "$RESP2"

# ── Explicit array-guard: confirm neither response is a raw issue list ─────────
echo "=== Array guard: neither response starts with '[' ==="
for _pair in "RESP1:$RESP1" "RESP2:$RESP2"; do
  _lbl="${_pair%%:*}"
  _bdy="${_pair#*:}"
  _first=$(printf '%s' "$_bdy" | python3 -c \
    "import sys; s=sys.stdin.read().strip(); print(s[0] if s else 'EMPTY')" 2>/dev/null)
  if [ "$_first" != "[" ]; then
    ok "$_lbl: first char='$_first' (not '[') — not a raw issue array"
  else
    no "$_lbl: starts with '[' — raw issue array returned (304 regression bug active)"
  fi
done

echo
printf '=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
