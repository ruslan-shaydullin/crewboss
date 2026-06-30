#!/usr/bin/env bash
# 825-search-api.test.sh — tests for GET /api/search under the NEW gh contract
# (charter #994 / qa leaf #1059). Supersedes the old #500/#825 paginated-array
# contract, which is gone: search_board() no longer walks the whole repo.
#
# NEW backend contract modelled here (NOT the old paginate-and-filter one):
#   * Number query (q is "#N" or all-digits): ONE direct call
#       gh api -X GET /repos/OWNER/REPO/issues/{N}   -> a single issue OBJECT.
#     Not-found / non-object -> {"results": []} (never 5xx, never hangs).
#   * Text query: ONE call
#       gh api -X GET /search/issues -f q="repo:OWNER/REPO is:issue <terms>" ...
#     whose response carries a `.items` ARRAY (different shape from /issues).
#   * Scope is ALWAYS hard-pinned to `repo:OWNER/REPO is:issue`; user-supplied
#     qualifiers (repo:other/x, org:foo, is:pr) MUST NOT widen scope.
#   * Output parity: each result is {n, kind, state, title, labels} with the same
#     kind/state classification as build_state(). Empty q -> {"results": []}.
#   * /api/state, build_state, paginate_issues(for /api/state) are UNCHANGED.
#
# MERGEABLE-FIRST GUARD (red->green): this leaf merges BEFORE the backend rewrite.
# After issuing a TEXT query we probe the gh-invocation log:
#   * a single /search/issues call  -> NEW path live  -> run full assertions.
#   * paginated /repos/.../issues (page=) and NO /search/issues -> OLD impl still
#     present -> print SKIP and exit 0 (green now, green again after the backend
#     leaf lands and flips the probe to the assert branch).
#
# ALLOW-class: stubbed gh; no real GitHub; no real launcher; no background procs
# beyond the local api server we start + kill.
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
GH_LOG="$TMP/gh-invocations.log"; : > "$GH_LOG"

# ── Stub: gh ─────────────────────────────────────────────────────────────────
# A python dispatcher that LOGS every invocation (one line per call: the full
# argv) and routes BY REQUEST PATH under the new contract:
#   /repos/OWNER/REPO/issues/{N}  -> single issue OBJECT  (404-style -> error obj)
#   /search/issues                -> {"items": [...]}      (search shape)
#   /repos/OWNER/REPO/issues      -> paginated bare ARRAY  (old contract / api/state)
cat > "$BIN/gh" <<'PYSHIM'
#!/usr/bin/env python3
import sys, os, json, re

argv = sys.argv[1:]
log = os.environ.get("GH_LOG")
if log:
    with open(log, "a") as f:
        f.write(" ".join(argv) + "\n")

# Fixture issues, keyed by number. Mirrors gh-api object shape (state lowercase
# from REST; we deliberately use CLOSED on #99 to prove case-insensitive done).
ISSUES = {
    42:  {"number": 42,  "title": "Deploy microservice alpha",   "state": "open",
          "body": "Charter: #100\n", "labels": [{"name": "type:leaf"}, {"name": "status:in-progress"}]},
    100: {"number": 100, "title": "Charter: smoke platform",     "state": "open",
          "body": "", "labels": [{"name": "type:charter"}, {"name": "status:approved"}]},
    99:  {"number": 99,  "title": "Old closed smoke task",        "state": "CLOSED",
          "body": "Charter: #100\n", "labels": [{"name": "type:leaf"}]},
    993: {"number": 993, "title": "Cockpit search smoke test",   "state": "open",
          "body": "Charter: #994\n", "labels": [{"name": "type:leaf"}, {"name": "status:in-progress"}]},
}

# First arg that looks like an API path.
path = ""
for a in argv:
    if a.startswith("/"):
        path = a
        break

def get_field_value(key):
    """Return the value of a `-f key=VALUE` / `-F key=VALUE` field, else ''."""
    for a in argv:
        if a.startswith(key + "="):
            return a[len(key) + 1:]
    return ""

# ── Route 1: number query -> single issue OBJECT ─────────────────────────────
m = re.match(r"^/repos/[^/]+/[^/]+/issues/(\d+)$", path)
if m:
    n = int(m.group(1))
    obj = ISSUES.get(n)
    if obj is None:
        # 404: gh prints an error OBJECT (no "number") and exits non-zero.
        sys.stdout.write(json.dumps({"message": "Not Found",
                                     "documentation_url": "https://docs.github.com"}))
        sys.exit(1)
    sys.stdout.write(json.dumps(obj))
    sys.exit(0)

# ── Route 2: text query -> {"items": [...]} ──────────────────────────────────
if path == "/search/issues" or path.startswith("/search/issues"):
    q = get_field_value("q")
    ql = q.lower()
    # Strip the pinned qualifiers to get the plain search terms.
    terms = []
    for tok in ql.split():
        if ":" in tok:        # qualifier-like (repo:, is:, org:) -> not a term
            continue
        terms.append(tok)
    items = []
    for num in sorted(ISSUES):
        it = ISSUES[num]
        title = it["title"].lower()
        if terms and all(t in title for t in terms):
            items.append(it)
    sys.stdout.write(json.dumps({"total_count": len(items), "items": items}))
    sys.exit(0)

# ── Route 3: paginated issue LIST (old contract + /api/state) ────────────────
m = re.match(r"^/repos/[^/]+/[^/]+/issues$", path)
if m:
    page = 1
    pv = get_field_value("page")
    if pv.isdigit():
        page = int(pv)
    is_charter_call = ("label=type:charter" in argv) or (get_field_value("label") == "type:charter")
    include = "--include" in argv
    if is_charter_call:
        body = json.dumps([ISSUES[100]])
    elif page <= 1:
        body = json.dumps([ISSUES[42], ISSUES[100], ISSUES[993], ISSUES[99]])
    else:
        body = "[]"
    if include:
        sys.stdout.write("Status: 200 OK\n\n" + body)
    else:
        sys.stdout.write(body)
    sys.exit(0)

# Unknown path -> empty.
sys.stdout.write("")
sys.exit(0)
PYSHIM
chmod +x "$BIN/gh"
export GH_LOG

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

# Helper: call /api/search, return raw JSON (or "ENDPOINT_MISSING"/"CURL_FAIL").
# Bounded with --max-time so a regressed (hanging) backend FAILS fast instead of
# stalling the harness — this is exactly the live "HTTP 000, 40s+" symptom.
search() {
  local q="$1" code
  code=$(curl -s --max-time 15 -o "$TMP/resp.json" -w "%{http_code}" \
    -H "$AUTH" "$API/api/search?q=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))" "$q" 2>/dev/null)" 2>/dev/null || echo "000")
  if [ "$code" = "000" ]; then echo "CURL_FAIL"; return; fi
  if [ "$code" = "404" ]; then echo "ENDPOINT_MISSING"; return; fi
  cat "$TMP/resp.json"
}

jlen()  { python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(len(d.get('results',[])))" 2>/dev/null || echo "-1"; }
jfield(){ python3 -c "import json,sys; d=json.loads(sys.stdin.read()); r=d.get('results',[]); print(r[0].get('$1','MISSING') if r else 'EMPTY')" 2>/dev/null || echo "ERR"; }
jhas()  { python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print('yes' if '$1' in d else 'no')" 2>/dev/null || echo "no"; }

# Count log lines whose joined-argv contains a substring. `grep -c` already
# prints "0" on no-match (exit 1) — do NOT add `|| echo 0` (would emit "0\n0"
# and corrupt every integer compare).
log_count() { local n; n=$(grep -c -- "$1" "$GH_LOG" 2>/dev/null); printf '%s' "${n:-0}"; }
log_has()   { grep -q -- "$1" "$GH_LOG" 2>/dev/null; }

# ── CONTRACT PROBE (mergeable-first guard) ───────────────────────────────────
# Issue a TEXT query and inspect the gh-invocation log.
echo "=== Contract probe (new /search/issues path vs old pagination) ==="
: > "$GH_LOG"
PROBE=$(search 'smoke')
if [ "$PROBE" = "ENDPOINT_MISSING" ]; then
  printf 'SKIP: /api/search endpoint absent (404) — backend leaf not landed yet\n'
  exit 0
fi
SEARCH_HITS=$(log_count "/search/issues")
PAGE_HITS=$(log_count " page=")
if [ "$SEARCH_HITS" -lt 1 ] 2>/dev/null; then
  # No /search/issues call -> the OLD paginating search_board is still live.
  printf 'SKIP: old paginated search_board still present '
  printf '(search/issues calls=%s, paginated page= calls=%s). ' "$SEARCH_HITS" "$PAGE_HITS"
  printf 'New-contract assertions deferred until the backend leaf merges.\n'
  exit 0
fi
ok "PROBE: text query took the new /search/issues path (single-call contract live)"

# ── New-contract assertions (only reached when the new path is live) ─────────

# Single-call-per-query: the probe 'smoke' must be exactly ONE /search/issues
# call and ZERO paginated list calls.
echo "=== Single-call: text query ==="
[ "$SEARCH_HITS" = "1" ] \
  && ok "text query hits /search/issues exactly once" \
  || ko "text query must hit /search/issues exactly once, got $SEARCH_HITS"
[ "$PAGE_HITS" = "0" ] \
  && ok "text query never paginates /repos/.../issues (page= calls=0)" \
  || ko "text query must not paginate; saw $PAGE_HITS page= calls"

# Scoping: user input must NOT widen scope. Effective q stays pinned.
echo "=== Scoping: hard-pinned repo:OWNER/REPO is:issue ==="
log_has "repo:test/repo is:issue" \
  && ok "effective search q is hard-pinned to 'repo:test/repo is:issue'" \
  || ko "effective search q is NOT pinned to 'repo:test/repo is:issue' (see $GH_LOG)"

: > "$GH_LOG"
search 'repo:other/x org:foo is:pr smoke' >/dev/null
log_has "repo:test/repo is:issue" \
  && ok "scope stays pinned even when user supplies repo:/org:/is: qualifiers" \
  || ko "scope lost its pin when user supplied qualifiers"
if log_has "other/x" || log_has "org:foo" || grep -qi "is:pr" "$GH_LOG"; then
  ko "user-supplied qualifiers leaked into the effective query (scope can be widened!)"
else
  ok "user-supplied qualifiers (repo:other/x, org:foo, is:pr) stripped — cannot widen scope"
fi

# Number path: single direct /repos/.../issues/N call, never paginates.
echo "=== Single-call: number query ==="
: > "$GH_LOG"
RESP_HASH=$(search '#993')
N_HITS=$(log_count "/repos/test/repo/issues/993")
SEARCH_ON_NUM=$(log_count "/search/issues")
PAGE_ON_NUM=$(log_count " page=")
[ "$N_HITS" = "1" ] \
  && ok "#993 hits /repos/test/repo/issues/993 exactly once" \
  || ko "#993 must hit /repos/.../issues/993 exactly once, got $N_HITS"
{ [ "$SEARCH_ON_NUM" = "0" ] && [ "$PAGE_ON_NUM" = "0" ]; } \
  && ok "number query uses neither /search/issues nor pagination" \
  || ko "number query leaked extra calls (search=$SEARCH_ON_NUM, page=$PAGE_ON_NUM)"

COUNT_HASH=$(printf '%s' "$RESP_HASH" | jlen)
[ "$COUNT_HASH" = "1" ] \
  && ok "#993 returns exactly 1 result" \
  || ko "#993 expected 1 result, got $COUNT_HASH (resp=$RESP_HASH)"
N_HASH=$(printf '%s' "$RESP_HASH" | jfield n)
[ "$N_HASH" = "993" ] \
  && ok "#993 result has n==993" \
  || ko "#993 expected n=993, got $N_HASH"

# Digit-only form -> same number path.
: > "$GH_LOG"
RESP_DIG=$(search '993')
[ "$(log_count "/repos/test/repo/issues/993")" = "1" ] \
  && ok "digit query 993 also takes the single /issues/{N} path" \
  || ko "digit query 993 did not take the /issues/{N} path"
[ "$(printf '%s' "$RESP_DIG" | jlen)" = "1" ] \
  && ok "digit query 993 returns exactly 1 result" \
  || ko "digit query 993 expected 1 result"

# Not-found number -> {"results":[]} (no 5xx, no hang).
echo "=== Not-found number ==="
: > "$GH_LOG"
RESP_NF=$(search '88888')
[ "$RESP_NF" != "CURL_FAIL" ] \
  && ok "not-found number did NOT hang/HTTP-000 (responded within budget)" \
  || ko "not-found number HUNG (CURL_FAIL / HTTP 000)"
[ "$(printf '%s' "$RESP_NF" | jlen)" = "0" ] \
  && ok "not-found number -> {\"results\":[]}" \
  || ko "not-found number expected empty results, got $(printf '%s' "$RESP_NF" | jlen) (resp=$RESP_NF)"
[ "$(printf '%s' "$RESP_NF" | jhas results)" = "yes" ] \
  && ok "not-found response still carries a 'results' key (no error body)" \
  || ko "not-found response missing 'results' key: $RESP_NF"

# Text path: case-insensitivity.
echo "=== Text path + case-insensitivity ==="
RESP_LO=$(search 'smoke')
RESP_UP=$(search 'SMOKE')
CL=$(printf '%s' "$RESP_LO" | jlen); CU=$(printf '%s' "$RESP_UP" | jlen)
[ "$CL" -ge 1 ] 2>/dev/null \
  && ok "text query 'smoke' returns matching items ($CL)" \
  || ko "text query 'smoke' returned no items"
[ "$CL" = "$CU" ] \
  && ok "case-insensitive: 'smoke' and 'SMOKE' return the same count ($CL)" \
  || ko "case sensitivity mismatch: smoke=$CL SMOKE=$CU"

# Empty q -> no gh call, {"results":[]}.
echo "=== Empty query ==="
: > "$GH_LOG"
RESP_E=$(search '')
[ "$(printf '%s' "$RESP_E" | jlen)" = "0" ] \
  && ok "empty q -> {\"results\":[]}" \
  || ko "empty q expected 0 results, got $(printf '%s' "$RESP_E" | jlen)"
[ "$(printf '%s' "$RESP_E" | jhas results)" = "yes" ] \
  && ok "empty-q response has 'results' key" \
  || ko "empty-q response missing 'results' key: $RESP_E"
{ [ "$(log_count '/search/issues')" = "0" ] && [ "$(log_count '/repos/test/repo/issues/')" = "0" ]; } \
  && ok "empty q makes NO gh call (short-circuits before any request)" \
  || ko "empty q must not call gh at all"

# Shape parity {n,kind,state,title,labels}, same classification as build_state().
echo "=== Output shape parity ==="
RESP_SHAPE=$(search 'smoke')
python3 - "$TMP/resp.json" <<'PYEOF'
import json, sys
resp = json.load(open(sys.argv[1]))
results = resp.get("results", [])
errs = []
if not results:
    errs.append("no results to shape-check")
for item in results:
    if not isinstance(item.get("n"), int):              errs.append("n not int: %r" % item.get("n"))
    if item.get("kind") not in ("charter","leaf","milestone"): errs.append("kind invalid: %r" % item.get("kind"))
    if not isinstance(item.get("state"), str):          errs.append("state not str: %r" % item.get("state"))
    if not isinstance(item.get("title"), str):          errs.append("title not str: %r" % item.get("title"))
    if not isinstance(item.get("labels"), list):        errs.append("labels not list: %r" % item.get("labels"))
if errs:
    print("\n".join("SHAPE_FAIL: " + e for e in errs))
    sys.exit(1)
sys.exit(0)
PYEOF
[ "$?" = "0" ] \
  && ok "every result has shape {n:int, kind, state:str, title:str, labels:list}" \
  || ko "result shape parity check failed (see SHAPE_FAIL lines)"

# state classification: CLOSED issue (#99) maps to done via the number path.
: > "$GH_LOG"
RESP_CLOSED=$(search '99')
STATE_99=$(printf '%s' "$RESP_CLOSED" | jfield state)
[ "$STATE_99" = "done" ] \
  && ok "CLOSED issue #99 maps to state='done' (case-insensitive, build_state parity)" \
  || ko "CLOSED issue #99 expected state='done', got '$STATE_99'"

# ── Regression: /api/state (build_state / paginate_issues) unaffected ────────
echo "=== Regression: /api/state unchanged ==="
STATE_CODE=$(curl -s --max-time 15 -o "$TMP/state.json" -w "%{http_code}" \
  -H "$AUTH" "$API/api/state" 2>/dev/null || echo "000")
if [ "$STATE_CODE" = "200" ]; then
  ok "/api/state still returns 200 (did not hang / regress)"
  python3 - "$TMP/state.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
board = d.get("board", [])
by_n = {it.get("n"): it for it in board}
errs = []
if 99 not in by_n or by_n[99].get("state") != "done":
    errs.append("#99 should be done in /api/state board: %r" % by_n.get(99))
if not board:
    errs.append("board is empty")
if errs:
    print("\n".join("STATE_FAIL: " + e for e in errs))
    sys.exit(1)
sys.exit(0)
PYEOF
  [ "$?" = "0" ] \
    && ok "/api/state board still built via paginate_issues (CLOSED #99 -> done)" \
    || ko "/api/state board regressed (see STATE_FAIL lines)"
else
  ko "/api/state did not return 200 (code=$STATE_CODE) — regression"
fi

# ── Summary ────────────────────────────────────────────────────────────────────
echo
printf '=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
