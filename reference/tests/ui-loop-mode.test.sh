#!/usr/bin/env bash
# ui-loop-mode.test.sh — GET /api/state loop block (issue #152, class T2)
#
# Verifies that /api/state includes a `loop` block with integration mode,
# max_ticks, max_parallel, and launcher running status.
#
# Setup:
#   - Isolated HOME with run-env.sh (from reference/runtime/, issue #147)
#   - Fake ~/.crewboss.env (FAKETOKEN / FAKEAPITOKEN)
#   - Stub gh (auth token → FAKETOKEN)
#   - crewboss-api.py started with minimal env (model post-deploy restart)
#   - GET /api/state with Bearer auth; response polled (NOT sleep N)
#
# Case A: default → loop.integrate=true, loop.max_ticks ≥ 1800, loop.max_parallel set
# Case B: CB_NO_INTEGRATE=1 → loop.integrate=false
#
# GENUINELY RED before fix: /api/state has no `loop` field at all.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
RUNTIME="$HERE/../runtime"
API_PY="$REPO_ROOT/ui/server/crewboss-api.py"

pass=0; fail=0
ok(){ printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

API_PID=""
ROOT="$(mktemp -d)"
cleanup(){
  [ -n "${API_PID:-}" ] && kill "$API_PID" 2>/dev/null || true
  [ -n "${API_PID_B:-}" ] && kill "$API_PID_B" 2>/dev/null || true
  rm -rf "$ROOT"
}
trap 'cleanup' EXIT

FAKE_HOME="$ROOT/home"
CBNET="$FAKE_HOME/cbnet"
BIN="$ROOT/bin"
API_OUT_A="$ROOT/api-a.out"
API_OUT_B="$ROOT/api-b.out"
API_PORT_A=8852
API_PORT_B=8853

mkdir -p "$CBNET/run" "$BIN"

# ── Verify prerequisites ──────────────────────────────────────────────────────
if [ ! -f "$API_PY" ]; then
  no "crewboss-api.py not found: $API_PY"
  printf '\n=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"; exit 1
fi
if [ ! -f "$RUNTIME/run-env.sh" ]; then
  no "run-env.sh not found at $RUNTIME/run-env.sh (dependency on #147)"
  printf '\n=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"; exit 1
fi

# ── Fake ~/.crewboss.env ──────────────────────────────────────────────────────
cat > "$FAKE_HOME/.crewboss.env" <<'ENVEOF'
GH_TOKEN=FAKETOKEN
CB_API_TOKEN=FAKEAPITOKEN
CB_REPO=stratch1989/crewboss
ENVEOF

# ── Stub gh: auth token → FAKETOKEN ──────────────────────────────────────────
cat > "$BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "auth" ] && [ "${2:-}" = "token" ]; then
  printf 'FAKETOKEN\n'
fi
exit 0
GHEOF
chmod +x "$BIN/gh"

# ── Deploy run-env.sh ─────────────────────────────────────────────────────────
cp "$RUNTIME/run-env.sh" "$CBNET/run-env.sh"

# ── Helper: json field extractor (stdlib python3 only) ────────────────────────
json_field(){
  # Usage: json_field <json_string> <dotted.path>
  python3 -c "
import json, sys
d=json.loads(sys.argv[1])
parts=sys.argv[2].split('.')
for p in parts:
    if isinstance(d, dict): d=d.get(p,'')
    else: d=''; break
print(d)
" "$1" "$2" 2>/dev/null
}

# ── Helper: wait for API ready (poll, NO fixed sleep) ────────────────────────
wait_api_ready(){
  local port="$1" limit="${2:-25}"
  local deadline=$(( $(date +%s) + limit ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    code=$(curl -s -m1 -o /dev/null -w '%{http_code}' \
      "http://127.0.0.1:${port}/api/health" 2>/dev/null)
    if [ "$code" = "200" ]; then return 0; fi
    sleep 0.2
  done
  return 1
}

# ── Helper: GET /api/state poll with deadline ────────────────────────────────
poll_state(){
  local port="$1" token="$2" limit="${3:-20}"
  local deadline=$(( $(date +%s) + limit ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    resp=$(curl -s -m5 \
      -H "Authorization: Bearer $token" \
      "http://127.0.0.1:${port}/api/state" 2>/dev/null)
    if echo "$resp" | python3 -c "import json,sys; d=json.load(sys.stdin); exit(0 if 'loop' in d else 1)" 2>/dev/null; then
      echo "$resp"; return 0
    fi
    sleep 0.2
  done
  return 1
}

# =============================================================================
# Case A: default (no CB_NO_INTEGRATE) → loop.integrate=true, max_ticks≥1800
# =============================================================================
echo "=== Case A: default → loop.integrate=true, max_ticks≥1800, max_parallel set ==="

env -i \
  HOME="$FAKE_HOME" \
  PATH="$BIN:/usr/bin:/bin:/usr/local/bin" \
  CB_API_TOKEN=FAKEAPITOKEN \
  CB_HOME="$CBNET" \
  CB_REPO=stratch1989/crewboss \
  python3 "$API_PY" --port "$API_PORT_A" \
  > "$API_OUT_A" 2>&1 &
API_PID=$!

if ! wait_api_ready "$API_PORT_A" 25; then
  no "Case A: API did not become ready within deadline"
  printf '  api output:\n'; head -5 "$API_OUT_A" 2>/dev/null || true
  printf '\n=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"; exit 1
fi
ok "Case A: API ready on port $API_PORT_A"

# Poll for state with loop field
STATE_A=$(poll_state "$API_PORT_A" "FAKEAPITOKEN" 20)
if [ -z "$STATE_A" ]; then
  no "Case A: GET /api/state did not return loop field within deadline"
  printf '\n=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"; exit 1
fi
ok "Case A: /api/state returned loop block"

# Check loop.integrate = true
v=$(json_field "$STATE_A" "loop.integrate")
if [ "$v" = "True" ] || [ "$v" = "true" ]; then
  ok "Case A: loop.integrate=true (integration ON by default)"
else
  no "Case A: loop.integrate should be true (got: '$v') — CB_GIT_REMOTE should be set"
fi

# Check loop.max_ticks >= 1800
v=$(json_field "$STATE_A" "loop.max_ticks")
if [ -n "$v" ] && [ "$v" -ge 1800 ] 2>/dev/null; then
  ok "Case A: loop.max_ticks=$v (≥1800, T6 tick budget)"
else
  no "Case A: loop.max_ticks not ≥1800 (got: '$v')"
fi

# Check loop.max_parallel set
v=$(json_field "$STATE_A" "loop.max_parallel")
if [ -n "$v" ] && [ "$v" -gt 0 ] 2>/dev/null; then
  ok "Case A: loop.max_parallel=$v (set)"
else
  no "Case A: loop.max_parallel not set or zero (got: '$v')"
fi

# Check loop.running is present (bool, may be false — no launcher started)
v=$(json_field "$STATE_A" "loop.running")
if [ "$v" = "True" ] || [ "$v" = "true" ] || [ "$v" = "False" ] || [ "$v" = "false" ]; then
  ok "Case A: loop.running present (got: '$v')"
else
  no "Case A: loop.running missing or not bool (got: '$v')"
fi

# Kill Case A API
kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null || true; API_PID=""

# =============================================================================
# Case B: CB_NO_INTEGRATE=1 → loop.integrate=false
# =============================================================================
echo "=== Case B: CB_NO_INTEGRATE=1 → loop.integrate=false ==="

env -i \
  HOME="$FAKE_HOME" \
  PATH="$BIN:/usr/bin:/bin:/usr/local/bin" \
  CB_API_TOKEN=FAKEAPITOKEN \
  CB_HOME="$CBNET" \
  CB_REPO=stratch1989/crewboss \
  CB_NO_INTEGRATE=1 \
  python3 "$API_PY" --port "$API_PORT_B" \
  > "$API_OUT_B" 2>&1 &
API_PID_B=$!

if ! wait_api_ready "$API_PORT_B" 25; then
  no "Case B: API did not become ready within deadline"
  printf '  api output:\n'; head -5 "$API_OUT_B" 2>/dev/null || true
  printf '\n=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"; exit 1
fi
ok "Case B: API ready on port $API_PORT_B"

STATE_B=$(poll_state "$API_PORT_B" "FAKEAPITOKEN" 20)
if [ -z "$STATE_B" ]; then
  no "Case B: GET /api/state did not return loop field within deadline"
  printf '\n=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"; exit 1
fi
ok "Case B: /api/state returned loop block"

v=$(json_field "$STATE_B" "loop.integrate")
if [ "$v" = "False" ] || [ "$v" = "false" ]; then
  ok "Case B: loop.integrate=false (CB_NO_INTEGRATE=1 → D2 opt-out)"
else
  no "Case B: loop.integrate should be false with CB_NO_INTEGRATE=1 (got: '$v')"
fi

kill "$API_PID_B" 2>/dev/null; wait "$API_PID_B" 2>/dev/null || true; API_PID_B=""

# =============================================================================
echo
printf '=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
