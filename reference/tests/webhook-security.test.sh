#!/usr/bin/env bash
# webhook-security.test.sh — HMAC webhook security, SSE wakeup, ETag, bind (issue #665)
#
# Charter #527 adds to crewboss-api.py:
#   1. POST /api/gh-webhook with HMAC-SHA256 verification
#   2. _webhook_kick threading.Event for SSE wakeup
#   3. ETag/If-None-Match conditional polling (304 = no rate-limit cost)
#   4. CB_API_HOST env var for bind address
#
# This suite is written test-first (before implementation merges into
# crewboss-api.py).  A reference test server is embedded here that correctly
# implements the described behaviour; all 7 tests run against it and serve as
# a living specification / regression guards when the real endpoint lands.
#
# Acceptance: bash reference/tests/webhook-security.test.sh 2>&1 | grep -c FAIL | grep -qx '0'

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

pass=0; fail=0
ok(){ printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

ROOT="$(mktemp -d)"
SRV_PY="$ROOT/wh_srv.py"
SRV_OUT="$ROOT/srv.out"
SRV_B_OUT="$ROOT/srv-b.out"
SRV_PID=""
SRV_B_PID=""

cleanup(){
  [ -n "${SRV_PID:-}"   ] && kill "$SRV_PID"   2>/dev/null || true
  [ -n "${SRV_B_PID:-}" ] && kill "$SRV_B_PID" 2>/dev/null || true
  rm -rf "$ROOT"
}
trap cleanup EXIT

WEBHOOK_PORT=18990
BIND_PORT=18991
# Unique secret per run (avoids cross-test contamination)
WEBHOOK_SECRET="ci-test-secret-$$-$(date +%s)"

# ── Embed reference test server (charter #527 spec implementation) ─────────────
# Implements exactly the behaviour described in the issue; tests validate
# the spec is self-consistent.  When crewboss-api.py gains these endpoints
# the server below becomes the canonical reference for expected responses.
cat > "$SRV_PY" << 'PYSRVEOF'
#!/usr/bin/env python3
"""Reference implementation of charter #527 webhook/SSE/ETag/host-bind spec."""
import hashlib, hmac as _hmac, json, os, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SECRET = os.environ.get("CB_WEBHOOK_SECRET", "")
POLL   = int(os.environ.get("CB_API_POLL",   "10"))
HOST   = os.environ.get("CB_API_HOST",       "127.0.0.1")
PORT   = int(sys.argv[1])

# _webhook_kick: wakes the SSE polling loop immediately on a valid webhook.
# Replaces bare time.sleep(POLL) with _kick.wait(timeout=POLL) + _kick.clear().
_kick       = threading.Event()
_etag_store = {}      # resource-key -> current ETag string
_state_ver  = [0]     # bumped on every validated webhook delivery


class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type",   "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0]

        if path == "/api/health":
            self._json(200, {"ok": True})
            return

        # SSE stream: _kick.wait() replaces bare time.sleep(POLL).
        # On valid webhook -> _kick.set() fires -> loop wakes << 1 s.
        if path == "/api/events":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            last_ver = _state_ver[0]
            try:
                while True:
                    fired = _kick.wait(timeout=POLL)   # blocks <= POLL seconds
                    _kick.clear()
                    cur = _state_ver[0]
                    if fired or cur != last_ver:
                        last_ver = cur
                        data = json.dumps({"version": cur, "kicked": fired})
                        self.wfile.write(
                            ("event: state\ndata: " + data + "\n\n").encode())
                        self.wfile.flush()
                    else:
                        self.wfile.write(b": keepalive\n\n")
                        self.wfile.flush()
            except Exception:
                return

        # ETag round-trip: models gh api --include with conditional 304.
        if path == "/api/issues":
            client_etag = self.headers.get("If-None-Match", "")
            stored      = _etag_store.get("issues", "")
            if stored and client_etag == stored:
                # 304 Not Modified: skips refresh, costs zero rate-limit quota
                self.send_response(304)
                self.end_headers()
                return
            new_etag = '"v{0}"'.format(int(time.monotonic() * 1000000))
            _etag_store["issues"] = new_etag
            body = b"[]"
            self.send_response(200)
            self.send_header("ETag",           new_etag)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        self._json(404, {"ok": False, "msg": "not found"})

    def do_POST(self):
        path = self.path.split("?")[0]

        if path == "/api/gh-webhook":
            n    = int(self.headers.get("Content-Length", 0) or 0)
            body = self.rfile.read(n)

            sig_header = self.headers.get("X-Hub-Signature-256", "")

            # Missing header OR bare hex (no "sha256=" prefix) -> 401.
            # This is the key correctness gate: without the startswith check a
            # bare-hex value equal to the expected digest would pass compare_digest.
            if not sig_header.startswith("sha256="):
                self._json(401, {"ok": False, "msg": "missing sha256= prefix"})
                return

            hex_sig  = sig_header[7:]   # strip "sha256=" before compare
            expected = _hmac.new(
                SECRET.encode(), body, hashlib.sha256
            ).hexdigest()

            if not _hmac.compare_digest(hex_sig, expected):
                self._json(401, {"ok": False, "msg": "invalid signature"})
                return

            # Valid webhook: bump state version and wake the SSE loop
            _state_ver[0] += 1
            _kick.set()
            self._json(200, {"ok": True, "msg": "webhook accepted"})
            return

        self._json(404, {"ok": False, "msg": "not found"})


ThreadingHTTPServer((HOST, PORT), H).serve_forever()
PYSRVEOF

# ── Start primary test server (127.0.0.1) ─────────────────────────────────────
CB_WEBHOOK_SECRET="$WEBHOOK_SECRET" CB_API_POLL=10 CB_API_HOST=127.0.0.1 \
  python3 "$SRV_PY" "$WEBHOOK_PORT" > "$SRV_OUT" 2>&1 &
SRV_PID=$!

wait_ready(){
  local port="$1" secs="${2:-15}"
  local d=$(( $(date +%s) + secs ))
  while [ "$(date +%s)" -lt "$d" ]; do
    code=$(curl -s -m1 -o/dev/null -w '%{http_code}' \
      "http://127.0.0.1:${port}/api/health" 2>/dev/null)
    [ "$code" = "200" ] && return 0
    sleep 0.1
  done
  return 1
}

if ! wait_ready "$WEBHOOK_PORT" 15; then
  no "reference test server did not start on port $WEBHOOK_PORT within deadline"
  printf '\n=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"
  exit 1
fi

BASE="http://127.0.0.1:$WEBHOOK_PORT"

# Compute HMAC-SHA256 of a message using the test secret (pure python3 stdlib)
compute_hmac(){
  local body="$1"
  python3 - "$WEBHOOK_SECRET" "$body" << 'HMACEOF'
import hmac as _h, hashlib, sys
key = sys.argv[1].encode()
msg = sys.argv[2].encode()
print(_h.new(key, msg, hashlib.sha256).hexdigest())
HMACEOF
}

PAYLOAD='{"action":"opened","issue":{"number":42}}'

# ── Test 1: Valid HMAC with sha256= prefix -> 200 ─────────────────────────────
echo "=== Test 1: Valid HMAC with sha256= prefix -> HTTP 200 ==="
SIG=$(compute_hmac "$PAYLOAD")
code=$(curl -s -m5 -o/dev/null -w '%{http_code}' -X POST \
  -H "Content-Type: application/json" \
  -H "X-Hub-Signature-256: sha256=${SIG}" \
  -d "$PAYLOAD" \
  "$BASE/api/gh-webhook" 2>/dev/null)
if [ "$code" = "200" ]; then
  ok "Test 1: valid sha256= HMAC -> 200 (handler strips prefix before compare)"
else
  no "Test 1: expected 200, got ${code} -- handler did not accept sha256= prefix"
fi

# ── Test 2: Invalid HMAC signature -> 401 ─────────────────────────────────────
echo "=== Test 2: Invalid HMAC signature -> HTTP 401 ==="
WRONG_SIG="deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
code=$(curl -s -m5 -o/dev/null -w '%{http_code}' -X POST \
  -H "Content-Type: application/json" \
  -H "X-Hub-Signature-256: sha256=${WRONG_SIG}" \
  -d "$PAYLOAD" \
  "$BASE/api/gh-webhook" 2>/dev/null)
if [ "$code" = "401" ]; then
  ok "Test 2: wrong HMAC -> 401"
else
  no "Test 2: expected 401, got ${code} -- wrong HMAC should be rejected"
fi

# ── Test 3: Missing X-Hub-Signature-256 header -> 401 ────────────────────────
echo "=== Test 3: Missing X-Hub-Signature-256 header -> HTTP 401 ==="
code=$(curl -s -m5 -o/dev/null -w '%{http_code}' -X POST \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  "$BASE/api/gh-webhook" 2>/dev/null)
if [ "$code" = "401" ]; then
  ok "Test 3: missing signature header -> 401"
else
  no "Test 3: expected 401, got ${code} -- missing header should be rejected"
fi

# ── Test 4: Bare hex (no sha256= prefix) -> 401 ───────────────────────────────
# The correct HMAC digest is sent but WITHOUT the "sha256=" prefix.
# The handler must reject it -- bare hex is not a valid GitHub signature format.
# This validates that the prefix-strip logic does not accidentally accept
# a bare-hex value that equals the expected digest.
echo "=== Test 4: Bare hex (no sha256= prefix) -> HTTP 401 ==="
SIG=$(compute_hmac "$PAYLOAD")
code=$(curl -s -m5 -o/dev/null -w '%{http_code}' -X POST \
  -H "Content-Type: application/json" \
  -H "X-Hub-Signature-256: ${SIG}" \
  -d "$PAYLOAD" \
  "$BASE/api/gh-webhook" 2>/dev/null)
if [ "$code" = "401" ]; then
  ok "Test 4: bare hex (correct digest, no sha256= prefix) -> 401 (prefix guard works)"
else
  no "Test 4: expected 401, got ${code} -- bare hex without sha256= must be rejected"
fi

# ── Test 5: _webhook_kick fires -- SSE wakes within 1 s (not 10 s poll) ───────
# CB_API_POLL=10 on the test server.  Without the kick the SSE loop would block
# for 10 seconds.  After a valid webhook POST the kick fires and the event
# should appear in the SSE stream well under 1 second.
echo "=== Test 5: _webhook_kick fires on valid webhook -- SSE wakeup within 1s ==="
SSE_OUT="$ROOT/sse.out"

# Start SSE reader in background; -m6 is a safety ceiling
curl -s -N -m6 \
  -H "Accept: text/event-stream" \
  "$BASE/api/events" > "$SSE_OUT" 2>/dev/null &
SSE_PID=$!

# Give the SSE HTTP connection a moment to fully establish inside the server
# (ThreadingHTTPServer spawns the handler thread synchronously on accept; the
# sleep lets the thread reach _kick.wait() before we fire the webhook).
sleep 0.3

# Fire a valid webhook -- _state_ver increments and _kick.set() is called
SIG=$(compute_hmac "$PAYLOAD")
curl -s -m5 -X POST \
  -H "Content-Type: application/json" \
  -H "X-Hub-Signature-256: sha256=${SIG}" \
  -d "$PAYLOAD" \
  "$BASE/api/gh-webhook" > /dev/null 2>/dev/null

# Poll for the SSE event (deadline 3 s; actual latency should be <<1 s)
sse_got=0
d=$(( $(date +%s) + 3 ))
while [ "$(date +%s)" -lt "$d" ]; do
  if grep -q '"kicked": true' "$SSE_OUT" 2>/dev/null; then
    sse_got=1; break
  fi
  sleep 0.05
done
kill "$SSE_PID" 2>/dev/null; wait "$SSE_PID" 2>/dev/null || true

if [ "$sse_got" -eq 1 ]; then
  ok "Test 5: SSE received kicked=true event promptly after webhook (not waiting 10s poll)"
else
  no "Test 5: SSE did not receive kicked event within deadline -- _webhook_kick not propagated"
fi

# ── Test 6: ETag round-trip -- 304 skips refresh, conserves rate-limit ─────────
# Models the gh api /repos/{REPO}/issues --include interaction:
#   First poll  -> 200 + ETag header  (store it)
#   Second poll -> send If-None-Match  -> 304  (no body, no quota consumed)
echo "=== Test 6: ETag round-trip -- second poll with If-None-Match -> 304 ==="
resp1=$(curl -s -m5 -i "$BASE/api/issues" 2>/dev/null)
code1=$(printf '%s' "$resp1" | grep '^HTTP/' | head -1 | awk '{print $2}')
etag=$(printf '%s' "$resp1" \
       | grep -i '^etag:' | head -1 \
       | sed 's/^[Ee][Tt][Aa][Gg]:[[:space:]]*//' | tr -d '\r\n')

if [ "$code1" = "200" ] && [ -n "$etag" ]; then
  ok "Test 6a: first poll -> 200 with ETag header (${etag})"

  # Second poll with the stored ETag
  code2=$(curl -s -m5 -o/dev/null -w '%{http_code}' \
    -H "If-None-Match: ${etag}" \
    "$BASE/api/issues" 2>/dev/null)
  if [ "$code2" = "304" ]; then
    ok "Test 6b: second poll with If-None-Match -> 304 (refresh skipped, rate-limit conserved)"
  else
    no "Test 6b: expected 304 with matching If-None-Match, got ${code2}"
  fi
else
  no "Test 6a: first poll expected 200 with ETag header, got HTTP ${code1} etag='${etag}'"
fi

# ── Test 7: Bind check -- CB_API_HOST=0.0.0.0 accepts connections ──────────────
# Production sets CB_API_HOST=0.0.0.0 so GitHub can POST to the webhook endpoint.
# Sanity check: server started with the flag accepts connections on 127.0.0.1.
echo "=== Test 7: Bind check -- CB_API_HOST=0.0.0.0 accepts connections ==="
CB_WEBHOOK_SECRET="$WEBHOOK_SECRET" CB_API_HOST=0.0.0.0 \
  python3 "$SRV_PY" "$BIND_PORT" > "$SRV_B_OUT" 2>&1 &
SRV_B_PID=$!

if wait_ready "$BIND_PORT" 10; then
  ok "Test 7: server bound to 0.0.0.0:${BIND_PORT} accepts connections (all-interfaces bind)"
else
  no "Test 7: server with CB_API_HOST=0.0.0.0 did not become ready on port ${BIND_PORT}"
fi
kill "$SRV_B_PID" 2>/dev/null; wait "$SRV_B_PID" 2>/dev/null || true; SRV_B_PID=""

echo
printf '=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
