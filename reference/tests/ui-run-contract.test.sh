#!/usr/bin/env bash
# ui-run-contract.test.sh — UI action=run env contract test (issue #148, class T2)
#
# Verifies that POST /api/command {action:run} delivers the full run-env.sh loop contract
# to the launcher even when crewboss-api.py is started with an empty/minimal env (model
# of post-deploy restart via deploy-runtime.sh).
#
# Setup:
#   - Isolated HOME with fake ~/.crewboss.env (fixed fake values)
#   - Stub gh on PATH (auth token → FAKETOKEN)
#   - Stub launcher $HOME/cbnet/crewboss-launcher-gh.sh (dumps actual env to file)
#   - Actual run-env.sh from reference/runtime/ deployed to $HOME/cbnet/
#   - API started with env -i (model post-deploy restart); CB_API_TOKEN from .crewboss.env
#
# RED (before fix):
#   env dump lacks CB_GIT_REMOTE, CB_MAX_TICKS=120, no CLAUDE_CODE_OAUTH_TOKEN; auth=OFF
#   (api.py uses env=os.environ; daemon restarted without env; finding #1+#2 for path C)
#
# GREEN (after fix):
#   Full env contract present in dump + auth=on (CB_API_TOKEN delivered by restart model)

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
RUNTIME="$HERE/../runtime"
API_PY="$REPO_ROOT/ui/server/crewboss-api.py"

pass=0; fail=0
ok(){ printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

ROOT="$(mktemp -d)"; API_PID=""
cleanup(){ [ -n "$API_PID" ] && kill "$API_PID" 2>/dev/null || true; rm -rf "$ROOT"; }
trap 'cleanup' EXIT

FAKE_HOME="$ROOT/home"
CBNET="$FAKE_HOME/cbnet"
DUMP_FILE="$ROOT/env-dump"
BIN="$ROOT/bin"
API_OUT="$ROOT/api.out"
API_PORT=8851   # unique port for this test suite

mkdir -p "$CBNET/run" "$BIN"

# ── Verify api.py exists ──────────────────────────────────────────────────────
if [ ! -f "$API_PY" ]; then
  no "crewboss-api.py not found: $API_PY"
  printf '\n=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"; exit 1
fi

# ── Fake ~/.crewboss.env with fixed fake values ───────────────────────────────
cat > "$FAKE_HOME/.crewboss.env" <<'ENVEOF'
GH_TOKEN=FAKETOKEN
CB_API_TOKEN=FAKEAPITOKEN
CLAUDE_CODE_OAUTH_TOKEN=FAKEOAUTH
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

# ── Stub launcher: dumps actual inherited env to DUMP_FILE ────────────────────
# Path to DUMP_FILE is baked in at creation time (not a literal $DUMP_FILE in the script)
cat > "$CBNET/crewboss-launcher-gh.sh" <<LAEOF
#!/usr/bin/env bash
env > "$DUMP_FILE"
echo "[stub-launcher] env dumped to $DUMP_FILE"
LAEOF
chmod +x "$CBNET/crewboss-launcher-gh.sh"

# ── Deploy run-env.sh from reference/runtime/ ─────────────────────────────────
if [ ! -f "$RUNTIME/run-env.sh" ]; then
  no "run-env.sh not found at $RUNTIME/run-env.sh (issue #147 dependency)"
  printf '\n=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"; exit 1
fi
cp "$RUNTIME/run-env.sh" "$CBNET/run-env.sh"

# ── Start api.py with clean env (model post-deploy-runtime.sh restart) ────────
# The fixed deploy-runtime.sh sources ~/.crewboss.env on the box and passes
# CB_HOME / CB_REPO / CB_API_TOKEN explicitly to the daemon.  We replicate that
# here with env -i so inherited env from the test runner cannot pollute results.
env -i \
  HOME="$FAKE_HOME" \
  PATH="$BIN:/usr/bin:/bin:/usr/local/bin" \
  CB_API_TOKEN=FAKEAPITOKEN \
  CB_HOME="$CBNET" \
  CB_REPO=stratch1989/crewboss \
  python3 "$API_PY" --port "$API_PORT" \
  > "$API_OUT" 2>&1 &
API_PID=$!

# ── Wait for api to be ready (poll, no fixed sleep) ───────────────────────────
B="http://127.0.0.1:$API_PORT"
api_ready=0
deadline=$(( $(date +%s) + 25 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  code=$(curl -s -m1 -o /dev/null -w '%{http_code}' "$B/api/health" 2>/dev/null)
  if [ "$code" = "200" ]; then api_ready=1; break; fi
  sleep 0.2
done

if [ "$api_ready" -eq 0 ]; then
  no "api did not become ready within deadline"
  printf 'api output:\n'; head -10 "$API_OUT" 2>/dev/null || true
  printf '\n=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"; exit 1
fi

# ── T2-A: auth=on in api startup line ────────────────────────────────────────
# api.py:592: print("...auth={'on' if TOKEN else 'OFF'}...") — CB_API_TOKEN must reach daemon
if grep -q "auth=on" "$API_OUT" 2>/dev/null; then
  ok "T2-A: api startup contains 'auth=on' (CB_API_TOKEN delivered by restart model)"
else
  no "T2-A: 'auth=on' missing from api startup — CB_API_TOKEN did not reach daemon"
  printf '  api output: %s\n' "$(head -3 "$API_OUT" 2>/dev/null)"
fi

# ── POST action=run with Bearer ───────────────────────────────────────────────
rc_json=$(curl -s -m15 -X POST \
  -H "Authorization: Bearer FAKEAPITOKEN" \
  -H "Content-Type: application/json" \
  -d '{"action":"run"}' \
  "$B/api/command" 2>/dev/null)

if echo "$rc_json" | grep -qE '"ok"[[:space:]]*:[[:space:]]*true'; then
  ok "T2-B: POST /api/command action=run → ok"
else
  no "T2-B: POST /api/command action=run failed: $rc_json"
  printf '\n=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"; exit 1
fi

# ── Poll for env dump (NOT fixed sleep) ───────────────────────────────────────
dump_ok=0
deadline=$(( $(date +%s) + 20 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  if [ -f "$DUMP_FILE" ] && [ -s "$DUMP_FILE" ]; then dump_ok=1; break; fi
  sleep 0.1
done

if [ "$dump_ok" -eq 0 ]; then
  no "T2-C: env dump never appeared within deadline (stub launcher not called or env-build failed)"
  printf '\n=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"; exit 1
fi
ok "T2-C: env dump written by stub launcher"

dump_val(){ grep "^${1}=" "$DUMP_FILE" 2>/dev/null | head -1 | cut -d= -f2-; }

# ── T2-1: CB_GIT_REMOTE non-empty ────────────────────────────────────────────
v="$(dump_val CB_GIT_REMOTE)"
if [ -n "$v" ]; then
  ok "T2-1: CB_GIT_REMOTE=$v (integration enabled)"
else
  no "T2-1: CB_GIT_REMOTE empty — loop would run without git integration (finding #1 path C)"
fi

# ── T2-2: CB_MAX_TICKS ≥ 1800 ────────────────────────────────────────────────
v="$(dump_val CB_MAX_TICKS)"
if [ -n "$v" ] && [ "$v" -ge 1800 ] 2>/dev/null; then
  ok "T2-2: CB_MAX_TICKS=$v (≥1800 — T6 tick budget)"
else
  no "T2-2: CB_MAX_TICKS not ≥1800 (got: '$v') — loop would cap at 120 ticks (finding #2)"
fi

# ── T2-3: CB_SPAWN ends with charter-leaf-prep.sh ────────────────────────────
v="$(dump_val CB_SPAWN)"
if printf '%s' "$v" | grep -q "charter-leaf-prep\.sh$"; then
  ok "T2-3: CB_SPAWN=$v (ends with charter-leaf-prep.sh)"
else
  no "T2-3: CB_SPAWN wrong (got: '$v') — spawn would not use charter-leaf dispatch"
fi

# ── T2-4: CB_MAX_PARALLEL set ────────────────────────────────────────────────
v="$(dump_val CB_MAX_PARALLEL)"
if [ -n "$v" ]; then
  ok "T2-4: CB_MAX_PARALLEL=$v (set; default MAXP=2 in launcher would apply without fix)"
else
  no "T2-4: CB_MAX_PARALLEL not set — launcher default MAXP=2 applies (finding #2/#142)"
fi

# ── T2-5: CLAUDE_CODE_OAUTH_TOKEN=FAKEOAUTH ──────────────────────────────────
v="$(dump_val CLAUDE_CODE_OAUTH_TOKEN)"
if [ "$v" = "FAKEOAUTH" ]; then
  ok "T2-5: CLAUDE_CODE_OAUTH_TOKEN=FAKEOAUTH (flows from ~/.crewboss.env via run-env.sh)"
else
  no "T2-5: CLAUDE_CODE_OAUTH_TOKEN wrong (got: '$v') — spawn would be dead without oauth token"
fi

# ── T2-6: CB_HOME consistency (api CB_HOME == launcher env CB_HOME) ───────────
# api.py uses RUN=$CB_HOME/run for kill_switch/pause paths; launcher must see the same CB_HOME
# so UI pause/kill commands target the correct flag-files.
api_cb_home="$CBNET"
dump_cb_home="$(dump_val CB_HOME)"
if [ "$dump_cb_home" = "$api_cb_home" ]; then
  ok "T2-6: CB_HOME consistent (api=$api_cb_home, launcher env=$dump_cb_home) — kill_switch/pause paths align"
else
  no "T2-6: CB_HOME mismatch: api=$api_cb_home vs launcher env=$dump_cb_home — UI pause/kill would miss loop"
fi

echo
printf '=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
