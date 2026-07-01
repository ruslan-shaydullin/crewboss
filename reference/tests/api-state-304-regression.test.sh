#!/usr/bin/env bash
# api-state-304-regression.test.sh — charter #707, leaf #1235 (qa-engineer)
#
# Regression test for bug #527: build_state() in ui/server/crewboss-api.py
# emptied the board when GitHub responded 304 Not Modified on the charters
# ETag request.  The fix (leaf-A, _etag_store / _parsed_c pattern) ensures
# _cached_charters is preserved on 304 and the board is not emptied.
#
# Method: starts crewboss-api.py as a background server with a stub gh binary
# that returns a seeded charter on the first /api/state call (200 + ETag) and
# then 304 Not Modified on the second call.  No real network is required.
#
# Scenarios:
#   1. GET /api/state (200 path): response is JSON object with board, agents,
#      budget, flags, autonomy keys; board is non-empty (seeded charter present).
#   2. GET /api/state (304 path): response is still the same-shaped JSON object;
#      board is still non-empty (_cached_charters preserved, not poisoned).
#
# Classification: EXCLUDED — uses a background server process (per-leaf-manifest).
# Run: bash reference/tests/api-state-304-regression.test.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
API_PY="$HERE/../../ui/server/crewboss-api.py"

pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

# ── Prerequisites ──────────────────────────────────────────────────────────────
if [ ! -f "$API_PY" ]; then
    ko "crewboss-api.py not found: $API_PY"
    printf 'passed=%d failed=%d\n' "$pass" "$fail"
    exit 1
fi
command -v python3 >/dev/null 2>&1 || {
    ko "python3 required but not found"
    printf 'passed=%d failed=%d\n' "$pass" "$fail"; exit 1
}
command -v curl >/dev/null 2>&1 || {
    ko "curl required but not found"
    printf 'passed=%d failed=%d\n' "$pass" "$fail"; exit 1
}

# ── Sandbox ────────────────────────────────────────────────────────────────────
TMP="$(mktemp -d)"
SERVER_PID=""
cleanup(){
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT

CBHOME="$TMP/cbhome"
mkdir -p "$CBHOME/run"

# Pick a free port (fall back to 18787 if python3 socket binding fails).
PORT="$(python3 -c \
    "import socket; s=socket.socket(); s.bind(('',0)); p=s.getsockname()[1]; s.close(); print(p)" \
    2>/dev/null || echo 18787)"

# ── Stub gh binary ─────────────────────────────────────────────────────────────
# A Python-based stub so counter logic and argument detection are reliable.
#
# Behaviour:
#   --include in argv (charter ETag fetch):
#     call  1:  200 OK + ETag "test-etag-v1" + seeded charter JSON (list)
#     call 2+:  304 Not Modified  — no body; build_state() must use _cached_charters
#   all other calls (paginate_issues):
#     [] (empty list, terminates pagination cleanly)
COUNTER="$TMP/charter_calls"
printf '0' > "$COUNTER"
mkdir -p "$TMP/bin"

# Write the stub Python script via a Python helper to avoid shell-quoting issues.
python3 - "$COUNTER" "$TMP/bin/gh" << 'WRITE_STUB'
import sys, os

counter_path = sys.argv[1]
stub_path    = sys.argv[2]

# Template: double-braces {{ }} are escaped literal braces for .format().
# \\r\\n in this Python string produces \r\n in the written file; when the
# stub later executes, Python reads \r\n as CR+LF — exactly what build_state()
# needs for the "sep_c = '\r\n\r\n'" detection branch.
stub_src = """\
#!/usr/bin/env python3
# Stub gh binary for api-state-304-regression.test.sh (charter #707, bug #527)
import sys

counter_file = {counter!r}
args = sys.argv[1:]

if "--include" in args:
    # Charter ETag conditional fetch:
    #   gh api /repos/REPO/issues --include -X GET -F label=type:charter ...
    try:
        count = int(open(counter_file).read().strip() or "0")
    except Exception:
        count = 0
    count += 1
    open(counter_file, "w").write(str(count))

    if count <= 1:
        # First call: 200 OK with ETag header and seeded charter list.
        # \\r\\n ensures build_state() picks sep_c = "\\r\\n\\r\\n".
        sys.stdout.write(
            "HTTP/1.1 200 OK\\r\\n"
            "ETag: \\"test-etag-v1\\"\\r\\n"
            "Content-Type: application/json\\r\\n"
            "\\r\\n"
        )
        sys.stdout.write(
            '[{{"number":707,"title":"Test Charter 707",'
            '"state":"open","body":"",'
            '"labels":[{{"name":"type:charter"}}]}}]\\n'
        )
    else:
        # Second+ call: 304 Not Modified — ETag matched, no body.
        # build_state() must fall back to _cached_charters, NOT empty board.
        sys.stdout.write(
            "HTTP/1.1 304 Not Modified\\r\\n"
            "ETag: \\"test-etag-v1\\"\\r\\n"
            "\\r\\n"
        )
else:
    # paginate_issues() and all other gh calls: empty list terminates walk.
    sys.stdout.write("[]\\n")

sys.exit(0)
""".format(counter=counter_path)

with open(stub_path, "w") as f:
    f.write(stub_src)
os.chmod(stub_path, 0o755)
WRITE_STUB

if [ ! -x "$TMP/bin/gh" ]; then
    ko "failed to write stub gh binary at $TMP/bin/gh"
    printf 'passed=%d failed=%d\n' "$pass" "$fail"; exit 1
fi

# ── Start the API server ───────────────────────────────────────────────────────
# Prepend stub bin dir so sh(["gh", ...]) in crewboss-api.py resolves to stub.
export PATH="$TMP/bin:$PATH"
export CB_REPO="test/repo"
export CB_HOME="$CBHOME"
export CB_API_TOKEN=""
export CB_API_PORT="$PORT"

python3 "$API_PY" --port "$PORT" \
    > "$TMP/server.out" 2>&1 &
SERVER_PID=$!

# Poll /api/health until ready (up to 10 s).
READY=0
for _i in $(seq 1 20); do
    _code="$(curl -s -o /dev/null -w "%{http_code}" \
        "http://127.0.0.1:$PORT/api/health" 2>/dev/null || true)"
    if [ "$_code" = "200" ]; then READY=1; break; fi
    sleep 0.5
done

if [ "$READY" != "1" ]; then
    ko "server did not start on port $PORT within 10 s"
    printf '--- server stdout/stderr ---\n'; cat "$TMP/server.out"
    printf 'passed=%d failed=%d\n' "$pass" "$fail"; exit 1
fi
ok "server started on port $PORT (pid $SERVER_PID)"

# ── Request 1: GET /api/state — first call (stub returns 200 + ETag) ──────────
echo "=== Request 1: GET /api/state (charter fetch: 200 + ETag) ==="
RESP1="$(curl -s "http://127.0.0.1:$PORT/api/state")"
printf '%s' "$RESP1" > "$TMP/resp1.json"

# 1a. Response is a JSON object (not a raw list).
python3 - "$TMP/resp1.json" << 'PY' 2>/dev/null \
    && ok  "request1: /api/state returns a JSON object (not a raw list)" \
    || ko  "request1: /api/state did not return a JSON object"
import sys, json
with open(sys.argv[1]) as f:
    d = json.load(f)
assert isinstance(d, dict), "expected dict, got %s" % type(d).__name__
PY

# 1b. Required top-level keys: board, agents, budget, flags, autonomy.
for _key in board agents budget flags autonomy; do
    python3 - "$TMP/resp1.json" "$_key" << 'PY' 2>/dev/null \
        && ok  "request1: key '${_key}' present" \
        || ko  "request1: key '${_key}' missing from /api/state response"
import sys, json
with open(sys.argv[1]) as f:
    d = json.load(f)
assert sys.argv[2] in d, "key %r not in response" % sys.argv[2]
PY
done

# 1c. board is a non-empty list (seeded charter #707 must appear).
BOARD1_LEN="$(python3 - "$TMP/resp1.json" << 'PY' 2>/dev/null || echo 0
import sys, json
with open(sys.argv[1]) as f:
    d = json.load(f)
print(len(d.get("board", [])))
PY
)"
if [ "${BOARD1_LEN:-0}" -gt 0 ] 2>/dev/null; then
    ok "request1: board has ${BOARD1_LEN} item(s) — charter #707 seeded correctly"
else
    ko "request1: board is empty after first 200 fetch (expected charter #707 on board)"
fi

# ── Request 2: GET /api/state — second call (stub returns 304) ─────────────────
echo "=== Request 2: GET /api/state (charter fetch: 304 Not Modified) ==="
RESP2="$(curl -s "http://127.0.0.1:$PORT/api/state")"
printf '%s' "$RESP2" > "$TMP/resp2.json"

# 2a. Response is still a JSON object after the 304 path.
python3 - "$TMP/resp2.json" << 'PY' 2>/dev/null \
    && ok  "request2 (after 304): /api/state still returns a JSON object" \
    || ko  "request2 (after 304): /api/state did not return a JSON object"
import sys, json
with open(sys.argv[1]) as f:
    d = json.load(f)
assert isinstance(d, dict), "expected dict, got %s" % type(d).__name__
PY

# 2b. Required keys still present after the 304 path.
for _key in board agents budget flags autonomy; do
    python3 - "$TMP/resp2.json" "$_key" << 'PY' 2>/dev/null \
        && ok  "request2 (after 304): key '${_key}' still present" \
        || ko  "request2 (after 304): key '${_key}' missing after 304"
import sys, json
with open(sys.argv[1]) as f:
    d = json.load(f)
assert sys.argv[2] in d, "key %r missing after 304" % sys.argv[2]
PY
done

# 2c. board is NOT empty after the 304 path.
# Core regression assertion for bug #527:
#   BEFORE fix: on 304 body_c is empty; json.loads("") raises; _cached_charters
#               is cleared or set to None; board is emptied (bug).
#   AFTER  fix: on 304, build_state() falls back to _cached_charters; board preserved.
BOARD2_LEN="$(python3 - "$TMP/resp2.json" << 'PY' 2>/dev/null || echo 0
import sys, json
with open(sys.argv[1]) as f:
    d = json.load(f)
print(len(d.get("board", [])))
PY
)"
if [ "${BOARD2_LEN:-0}" -gt 0 ] 2>/dev/null; then
    ok "request2 (after 304): board preserved ${BOARD2_LEN} item(s) — _cached_charters not poisoned (bug #527 fixed)"
else
    ko "request2 (after 304): board is EMPTY — build_state() emptied board on 304 (bug #527 regression)"
fi

# ── Verify the stub actually exercised the 304 path ──────────────────────────
CALLS="$(cat "$COUNTER" 2>/dev/null || echo 0)"
if [ "${CALLS:-0}" -ge 2 ] 2>/dev/null; then
    ok "stub: charter ETag endpoint hit ${CALLS} times — 304 path confirmed exercised"
else
    ko "stub: charter ETag endpoint hit only ${CALLS:-0} time(s) — 304 path may not have been reached"
fi

echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
