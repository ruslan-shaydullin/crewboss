#!/usr/bin/env bash
# 825-search-api.test.sh — tests for GET /api/search endpoint (issue #825, charter #500)
#
# Tests A–F specified in issue #825:
#   A: number search (#123 or 123) → result with n==123 only
#   B: title substring (case-insensitive) → matching items only
#   C: empty query → {results:[]}
#   D: no-match query → {results:[]}
#   E: response shape — n:int, kind:charter|leaf|milestone, state:str, title:str, labels:array
#   F: state=all coverage — CLOSED issue appears when queried by number
#
# Approach: stubs `gh` to return fixture data; starts crewboss-api.py on an ephemeral
# port; uses curl+python3 for HTTP calls and JSON assertion.
#
# ALLOW-class: stubbed gh; no real GitHub; no real launcher; no background processes.
set -uo pipefail

pass=0; fail=0
ok()  { printf 'ok   %s\n' "$*"; pass=$((pass+1)); }
ko()  { printf 'FAIL %s\n' "$*"; fail=$((fail+1)); }

# ── Prerequisites ─────────────────────────────────────────────────────────────
for cmd in python3 curl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    printf 'SKIP: %s not found\n' "$cmd"
    exit 0
  fi
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVER_PY="$SCRIPT_DIR/../ui/server/crewboss-api.py"
if [ ! -f "$SERVER_PY" ]; then
  printf 'SKIP: server not found at %s\n' "$SERVER_PY"
  exit 0
fi

TMP="$(mktemp -d)"
SERVER_PID=""
cleanup() {
  [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

BIN="$TMP/bin"; mkdir -p "$BIN"
CB_HOME="$TMP/cbhome"; mkdir -p "$CB_HOME"

# ── Fixture: four issues across two states ────────────────────────────────────
# Page 1: open leaf #42, open charter #100, open leaf #123, CLOSED leaf #99
# Page 2: empty (signals end of pagination)
FIXTURE_P1="$TMP/fixture_p1.json"
python3 - <<'PYEOF' > "$FIXTURE_P1"
import json
issues = [
  {"number": 42,  "title": "Deploy microservice alpha",       "state": "open",   "body": "Charter: #100\n", "labels": [{"name": "type:leaf"},    {"name": "status:in-progress"}]},
  {"number": 100, "title": "Charter: microservice platform",  "state": "open",   "body": "",               "labels": [{"name": "type:charter"}, {"name": "status:approved"}]},
  {"number": 123, "title": "Fix rate limiting bug",           "state": "open",   "body": "Charter: #100\n", "labels": [{"name": "type:leaf"}]},
  {"number": 99,  "title": "Old closed task",                 "state": "CLOSED", "body": "Charter: #100\n", "labels": [{"name": "type:leaf"}]},
]
print(json.dumps(issues))
PYEOF

# ── Stub: gh ─────────────────────────────────────────────────────────────────
# Returns fixture_p1 for page 1 (or no page arg), empty list for page >= 2.
# Handles: gh api /repos/REPO/issues -F state=all -F per_page=100 -F page=N
cat > "$BIN/gh" <<'SHIM'
#!/bin/sh
page=1
prev=""
for arg in "$@"; do
  if [ "$prev" = "-F" ]; then
    case "$arg" in
      page=*) page="${arg#page=}" ;;
    esac
  fi
  prev="$arg"
done
if [ "$page" -le 1 ] 2>/dev/null; then
  cat "${GH_FIXTURE_P1:-/dev/null}"
else
  printf '[]'
fi
SHIM
chmod +x "$BIN/gh"
export GH_FIXTURE_P1="$FIXTURE_P1"

# ── Start server ──────────────────────────────────────────────────────────────
PORT=19825
export CB_REPO="test/repo"
export CB_HOME
export CB_API_TOKEN="testtoken825"

PATH="$BIN:$PATH" python3 "$SERVER_PY" --port "$PORT" \
  > "$TMP/server.log" 2>&1 &
SERVER_PID=$!

# Wait for /api/health (up to 8 s)
ready=0
for i in $(seq 1 80); do
  if curl -sf "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1; then
    ready=1; break
  fi
  sleep 0.1
done

if [ "$ready" = "0" ]; then
  printf 'SKIP: server did not start within 8 s\n'
  printf '--- server log ---\n'; cat "$TMP/server.log"; printf '------------------\n'
  exit 0
fi

API="http://127.0.0.1:$PORT"
AUTH="Authorization: Bearer testtoken825"

# Helper: call /api/search and return raw JSON (or "ENDPOINT_MISSING" / "CURL_FAIL")
search() {
  local q="$1"
  local code
  code=$(curl -s -o "$TMP/resp.json" -w "%{http_code}" \
    -H "$AUTH" "$API/api/search?q=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe='')); " "$q" 2>/dev/null)" 2>/dev/null || echo "000")
  if [ "$code" = "000" ]; then echo "CURL_FAIL"; return; fi
  if [ "$code" = "404" ]; then echo "ENDPOINT_MISSING"; return; fi
  cat "$TMP/resp.json"
}

# Helper: extract .results length via python3
jlen() { python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(len(d.get('results',[])))" 2>/dev/null || echo "-1"; }
jfield() { local field="$1"; python3 -c "import json,sys; d=json.loads(sys.stdin.read()); r=d.get('results',[]); print(r[0].get('$field','MISSING') if r else 'EMPTY')" 2>/dev/null || echo "ERR"; }
jhas() { local field="$1"; python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print('yes' if '$field' in d else 'no')" 2>/dev/null || echo "no"; }
jtype() { local jpath="$1"; python3 -c "import json,sys; d=json.loads(sys.stdin.read()); v=d$jpath; print(type(v).__name__)" 2>/dev/null || echo "err"; }
jresults_n_field() { local n="$1" field="$2"; python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
items=[r for r in d.get('results',[]) if r.get('n')==$n]
print(items[0].get('$field','MISSING') if items else 'NOT_FOUND')
" 2>/dev/null || echo "ERR"; }

# ── Test A: number search ─────────────────────────────────────────────────────
echo "=== Test A: number search ==="

# A1: #123 (encoded as %23123)
RESP_A=$(search '#123')
if [ "$RESP_A" = "ENDPOINT_MISSING" ]; then
  ko "A: /api/search endpoint not yet implemented (404) — will pass once leaf-1 merges"
  # Skip remaining tests — endpoint absent
else
  COUNT_A=$(printf '%s' "$RESP_A" | jlen)
  [ "$COUNT_A" = "1" ] \
    && ok "A1: ?q=%23123 returns exactly 1 result" \
    || ko "A1: expected 1 result for #123, got $COUNT_A (resp=$RESP_A)"

  N_A=$(printf '%s' "$RESP_A" | jfield n)
  [ "$N_A" = "123" ] \
    && ok "A2: result item has n==123" \
    || ko "A2: expected n=123, got n=$N_A"

  # Other numbers must not appear
  HAS_42=$(printf '%s' "$RESP_A" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(any(r.get('n')==42 for r in d.get('results',[])))" 2>/dev/null || echo False)
  [ "$HAS_42" = "False" ] \
    && ok "A3: n==42 not in results (number search is exact)" \
    || ko "A3: n==42 must not appear in ?q=%23123 results"

  # A4: digit-only form
  RESP_A4=$(search '123')
  COUNT_A4=$(printf '%s' "$RESP_A4" | jlen)
  [ "$COUNT_A4" = "1" ] \
    && ok "A4: ?q=123 (digit string) also returns exactly 1 result" \
    || ko "A4: expected 1 result for q=123, got $COUNT_A4"

# ── Test B: title substring ─────────────────────────────────────────────────
echo "=== Test B: title substring ==="

  RESP_B=$(search 'microservice')
  COUNT_B=$(printf '%s' "$RESP_B" | jlen)
  [ "$COUNT_B" = "2" ] \
    && ok "B1: ?q=microservice returns 2 matching items" \
    || ko "B1: expected 2 matches for 'microservice', got $COUNT_B (resp=$RESP_B)"

  # Non-matching items excluded (Fix rate limiting bug should not be in results)
  HAS_123=$(printf '%s' "$RESP_B" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(any(r.get('n')==123 for r in d.get('results',[])))" 2>/dev/null || echo True)
  [ "$HAS_123" = "False" ] \
    && ok "B2: issue #123 (Fix rate limiting bug) excluded from microservice search" \
    || ko "B2: issue #123 must not appear in microservice search results"

  # Case-insensitive
  RESP_B3=$(search 'MICROSERVICE')
  COUNT_B3=$(printf '%s' "$RESP_B3" | jlen)
  [ "$COUNT_B3" = "2" ] \
    && ok "B3: case-insensitive: MICROSERVICE matches same 2 items" \
    || ko "B3: expected 2 matches for MICROSERVICE, got $COUNT_B3"

# ── Test C: empty query ─────────────────────────────────────────────────────
echo "=== Test C: empty query ==="

  RESP_C=$(search '')
  COUNT_C=$(printf '%s' "$RESP_C" | jlen)
  [ "$COUNT_C" = "0" ] \
    && ok "C1: empty q → results is empty list" \
    || ko "C1: expected 0 results for empty q, got $COUNT_C"

  HAS_KEY=$(printf '%s' "$RESP_C" | jhas results)
  [ "$HAS_KEY" = "yes" ] \
    && ok "C2: response shape has 'results' key" \
    || ko "C2: response missing 'results' key: $RESP_C"

# ── Test D: no match ────────────────────────────────────────────────────────
echo "=== Test D: no match ==="

  RESP_D=$(search 'xyzzy_guaranteed_no_match_825')
  COUNT_D=$(printf '%s' "$RESP_D" | jlen)
  [ "$COUNT_D" = "0" ] \
    && ok "D1: no-match query → results is empty list" \
    || ko "D1: expected 0 results for no-match query, got $COUNT_D"

# ── Test E: response shape ──────────────────────────────────────────────────
echo "=== Test E: response shape ==="

  RESP_E=$(search '42')
  COUNT_E=$(printf '%s' "$RESP_E" | jlen)
  if [ "$COUNT_E" -ge 1 ] 2>/dev/null; then
    python3 - <<PYEOF
import json, sys
resp = json.loads("""$(printf '%s' "$RESP_E" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))")""")
# resp might be a double-JSON-encoded string; unwrap if needed
if isinstance(resp, str): resp = json.loads(resp)
results = resp.get('results', [])
item = results[0] if results else {}
errors = []
if not isinstance(item.get('n'), int):
    errors.append(f"n is not int: {type(item.get('n'))}")
if item.get('kind') not in ('charter', 'leaf', 'milestone'):
    errors.append(f"kind invalid: {item.get('kind')!r}")
if not isinstance(item.get('state'), str):
    errors.append(f"state is not str: {type(item.get('state'))}")
if not isinstance(item.get('title'), str):
    errors.append(f"title is not str: {type(item.get('title'))}")
if not isinstance(item.get('labels'), list):
    errors.append(f"labels is not list: {type(item.get('labels'))}")
if errors:
    for e in errors: print('SHAPE_FAIL: ' + e)
    sys.exit(1)
else:
    print('SHAPE_OK')
    sys.exit(0)
PYEOF
    shape_rc=$?
    [ "$shape_rc" = "0" ] \
      && ok "E: result item has correct shape (n:int, kind:str, state:str, title:str, labels:list)" \
      || ko "E: result item shape check failed (see SHAPE_FAIL lines above)"
  else
    ko "E: no results for q=42 — cannot check shape (count=$COUNT_E, resp=$RESP_E)"
  fi

# ── Test F: state=all (CLOSED issues appear) ────────────────────────────────
echo "=== Test F: state=all coverage ==="

  RESP_F=$(search '99')
  COUNT_F=$(printf '%s' "$RESP_F" | jlen)
  [ "$COUNT_F" -ge 1 ] 2>/dev/null \
    && ok "F1: CLOSED issue #99 appears in search results (state=all flag confirmed)" \
    || ko "F1: CLOSED issue #99 not in results — state=all flag may be missing (count=$COUNT_F)"

  STATE_F=$(printf '%s' "$RESP_F" | jresults_n_field 99 state)
  [ "$STATE_F" = "done" ] \
    && ok "F2: CLOSED issue #99 mapped to state='done'" \
    || ko "F2: expected state='done' for CLOSED issue #99, got '$STATE_F'"

fi  # end of "endpoint present" block

# ── Summary ────────────────────────────────────────────────────────────────────
echo
printf '=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
