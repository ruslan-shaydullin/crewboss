#!/usr/bin/env bash
# api-state-304-regression.test.sh — ETag/304 regression test (issue #809, charter #707)
#
# Verifies that GET /api/state returns a proper board object
#   {board, agents, budget, flags, autonomy}
# on BOTH the cold (1st) request and the 304-cached (2nd) request.
#
# Bug (charter #707 / #527 regression, issue #809):
#   build_state() returned `_cached_issues` (raw GitHub issue array []) on 304,
#   instead of the assembled board dict — crashing the dashboard.
#
# Fix (leaf-A): restructure the 304 branch so `issues = _cached_issues` is set
#   and board assembly runs normally regardless of cache-hit vs cache-miss.
#
# This test drives the fix end-to-end using a stub `gh` command (no real network):
#   1st gh call: returns HTTP 200 + ETag + empty issues list → stored in _etag_store
#   2nd gh call (with If-None-Match): returns HTTP 304 → triggers the fixed 304 branch
#
# Classification: EXCLUDED — starts crewboss-api.py as a background process;
#   background-process criterion → EXCLUDED per per-leaf-manifest policy (fail-closed).

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
API_PY="$REPO_ROOT/ui/server/crewboss-api.py"

pass=0; fail=0
ok() { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

API_PORT=19304   # avoids conflicts with other tests (mnemonic: HTTP 304)
API_PID=""
ROOT=""

cleanup() {
  [ -n "${API_PID:-}" ] && kill "$API_PID" 2>/dev/null || true
  [ -n "${ROOT:-}"    ] && rm -rf "$ROOT"   2>/dev/null || true
}
trap cleanup EXIT

ROOT="$(mktemp -d)"
CB_HOME_DIR="$ROOT/cbhome"
mkdir -p "$CB_HOME_DIR/run"

# ── Embed stub gh (no real network) ──────────────────────────────────────────
# First call (no If-None-Match in args): HTTP 200 + ETag + empty issues array
# Second call (If-None-Match: ... present): HTTP 304 + empty body
STUB_GH="$ROOT/gh"
cat > "$STUB_GH" << 'GHEOF'
#!/usr/bin/env bash
# Stub gh: simulates GitHub issues API with ETag/304 caching for crewboss-api.py
for arg in "$@"; do
  case "$arg" in
    *If-None-Match*)
      # 304 Not Modified — body is intentionally empty (as per HTTP spec)
      printf 'HTTP/2 304 \nETag: "test-etag-v1"\n\n'
      exit 0
      ;;
  esac
done
# First call: 200 OK with ETag and empty issues list
printf 'HTTP/2 200 \nContent-Type: application/json\nETag: "test-etag-v1"\n\n[]\n'
exit 0
GHEOF
chmod +x "$STUB_GH"

# ── Start crewboss-api.py in background ──────────────────────────────────────
CB_REPO="test/repo"          \
CB_HOME="$CB_HOME_DIR"       \
CB_API_TOKEN=""               \
CB_API_PORT="$API_PORT"      \
CB_API_HOST="127.0.0.1"      \
PATH="$ROOT:$PATH"            \
python3 "$API_PY" > "$ROOT/api.out" 2>&1 &
API_PID=$!

# Wait for /api/health → 200 (deadline 15 s)
ready=0
deadline=$(( $(date +%s) + 15 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  code=$(curl -s -m1 -o/dev/null -w '%{http_code}' \
    "http://127.0.0.1:${API_PORT}/api/health" 2>/dev/null) || true
  [ "$code" = "200" ] && ready=1 && break
  sleep 0.2
done

if [ "$ready" -ne 1 ]; then
  no "API server did not start on port $API_PORT within 15 s"
  printf '\n=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"
  exit 1
fi

# ── Test 1: cold request — no ETag cached in server state ────────────────────
echo "=== Test 1: cold /api/state (no ETag in server state) ==="
resp1=$(curl -s -m10 "http://127.0.0.1:${API_PORT}/api/state" 2>/dev/null)
first1=$(printf '%s' "$resp1" | head -c1)
if [ "$first1" = "{" ]; then
  ok "Test 1a: cold response is a JSON object (starts with '{')"
else
  no "Test 1a: cold response is NOT a JSON object (first char: '${first1}') — expected '{'"
fi
for key in board agents budget flags autonomy; do
  if printf '%s' "$resp1" | \
     python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if '${key}' in d else 1)" 2>/dev/null; then
    ok "Test 1b: cold response contains key '${key}'"
  else
    no "Test 1b: cold response is missing key '${key}'"
  fi
done

# ── Test 2: 304-path request — stub gh returns 304 on If-None-Match ──────────
# After Test 1, _etag_store["issues"] = "test-etag-v1".
# The server sends If-None-Match: test-etag-v1 to gh; stub returns 304.
# Bug: returns _cached_issues (raw []) → JSON array.
# Fix: sets issues=_cached_issues, runs board assembly → JSON object.
echo "=== Test 2: 304-path /api/state (stub gh returns 304 on If-None-Match) ==="
resp2=$(curl -s -m10 "http://127.0.0.1:${API_PORT}/api/state" 2>/dev/null)
first2=$(printf '%s' "$resp2" | head -c1)
if [ "$first2" = "{" ]; then
  ok "Test 2a: 304-path response is a JSON object (not raw issue array)"
else
  no "Test 2a: 304-path response is NOT a JSON object (first char: '${first2}') — 304 regression present"
fi
for key in board agents budget flags autonomy; do
  if printf '%s' "$resp2" | \
     python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if '${key}' in d else 1)" 2>/dev/null; then
    ok "Test 2b: 304-path response contains key '${key}'"
  else
    no "Test 2b: 304-path response missing key '${key}' — board assembly not reached on 304 path"
  fi
done

# ── Test 3: neither response is a JSON array at the top level ─────────────────
echo "=== Test 3: neither response is a JSON array ==="
type1=$(printf '%s' "$resp1" | \
  python3 -c "import sys,json; print(type(json.load(sys.stdin)).__name__)" 2>/dev/null || echo "error")
type2=$(printf '%s' "$resp2" | \
  python3 -c "import sys,json; print(type(json.load(sys.stdin)).__name__)" 2>/dev/null || echo "error")
if [ "$type1" = "dict" ]; then
  ok "Test 3a: cold response type=dict (not list)"
else
  no "Test 3a: cold response type='$type1', expected dict"
fi
if [ "$type2" = "dict" ]; then
  ok "Test 3b: 304-path response type=dict (not list) — regression absent"
else
  no "Test 3b: 304-path response type='$type2', expected dict — 304 returns raw issue list (regression)"
fi

echo
printf '=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
