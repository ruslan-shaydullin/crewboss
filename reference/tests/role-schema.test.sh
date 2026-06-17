#!/usr/bin/env bash
# role-schema.test.sh — role manifest model+accesses schema round-trip (issue #270)
#
# Verifies that POST /api/role with model/accesses fields:
#   (a) writes model/accesses to the frontmatter of the role .md file (only if non-empty)
#   (b) GET /api/role/<name> returns model/accesses in the frontmatter dict (round-trip)
#   (c) empty model/accesses are NOT written (files stay clean by default)
#   (d) invalid accesses CSV token format is rejected with an error
#
# Class: integration/api  (starts real crewboss-api.py + requires jq, curl)
# EXCLUDED from per-leaf verify-merged suite (heavy: starts daemon, timing-sensitive)

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
TEAM_EXAMPLE="$REPO_ROOT/team-example"
API_PY="$REPO_ROOT/ui/server/crewboss-api.py"

pass=0; fail=0
ok(){ printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

ROOT="$(mktemp -d)"; API_PID=""
cleanup(){
    [ -n "$API_PID" ] && kill "$API_PID" 2>/dev/null || true
    rm -rf "$ROOT"
}
trap 'cleanup' EXIT

API_PORT=8857
B="http://127.0.0.1:$API_PORT"
API_OUT="$ROOT/api.out"

# ── Verify prerequisites ──────────────────────────────────────────────────────
if [ ! -f "$API_PY" ]; then
    no "crewboss-api.py not found: $API_PY"
    printf '\n=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"; exit 1
fi
if [ ! -d "$TEAM_EXAMPLE" ]; then
    no "team-example not found: $TEAM_EXAMPLE"
    printf '\n=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"; exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
    no "jq not found (required for JSON assertions)"
    printf '\n=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"; exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
    no "curl not found"
    printf '\n=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"; exit 1
fi

# ── Set up isolated CB_TEAM (copy of team-example) ──────────────────────────
CB_TEAM_DIR="$ROOT/team"
cp -r "$TEAM_EXAMPLE/." "$CB_TEAM_DIR"
CB_HOME_DIR="$ROOT/cbhome"
mkdir -p "$CB_HOME_DIR/run"

# ── Start API ─────────────────────────────────────────────────────────────────
CB_TEAM="$CB_TEAM_DIR" \
CB_HOME="$CB_HOME_DIR" \
CB_API_TOKEN="" \
CB_API_PORT="$API_PORT" \
    python3 "$API_PY" --port "$API_PORT" \
    > "$API_OUT" 2>&1 &
API_PID=$!

# Poll until ready
api_ready=0
deadline=$(( $(date +%s) + 25 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    code=$(curl -s -m1 -o /dev/null -w '%{http_code}' "$B/api/health" 2>/dev/null)
    if [ "$code" = "200" ]; then api_ready=1; break; fi
    sleep 0.2
done

if [ "$api_ready" -eq 0 ]; then
    no "API did not become ready within deadline"
    printf 'API output:\n'; head -10 "$API_OUT" 2>/dev/null || true
    printf '\n=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"; exit 1
fi
ok "API started on port $API_PORT"

# =============================================================================
# T1: save role WITH model+accesses → round-trip via GET /api/role/<name>
# =============================================================================
echo "=== T1: POST /api/role with model+accesses → round-trip GET ==="
ROLE_NAME="schema-test-executor"
ROLE_PAYLOAD=$(cat <<'JSON'
{
  "name": "schema-test-executor",
  "kind": "executor",
  "domain": "test/schema",
  "tools": "Read, Edit, Write, Bash",
  "profile": "executor",
  "model": "anthropic",
  "accesses": "github:read,fs:write",
  "prompt": "Schema round-trip test role."
}
JSON
)

save_resp=$(curl -s -m15 -X POST \
    -H "Content-Type: application/json" \
    -d "$ROLE_PAYLOAD" \
    "$B/api/role" 2>/dev/null)

if echo "$save_resp" | jq -e '.ok == true' >/dev/null 2>&1; then
    ok "T1: POST /api/role ok=true"
else
    no "T1: POST /api/role failed: $save_resp"
    printf '\n=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"; exit 1
fi

# GET /api/role/<name> and check frontmatter
get_resp=$(curl -s -m10 "$B/api/role/$ROLE_NAME" 2>/dev/null)

if echo "$get_resp" | jq -e '.ok == true' >/dev/null 2>&1; then
    ok "T1: GET /api/role/$ROLE_NAME ok=true"
else
    no "T1: GET /api/role/$ROLE_NAME failed: $get_resp"
    printf '\n=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"; exit 1
fi

fm_model=$(echo "$get_resp" | jq -r '.frontmatter.model // ""' 2>/dev/null)
fm_accesses=$(echo "$get_resp" | jq -r '.frontmatter.accesses // ""' 2>/dev/null)

[ "$fm_model" = "anthropic" ] \
    && ok "T1: frontmatter.model='anthropic' round-trips correctly" \
    || no "T1: frontmatter.model expected 'anthropic', got '$fm_model'"

[ "$fm_accesses" = "github:read,fs:write" ] \
    && ok "T1: frontmatter.accesses='github:read,fs:write' round-trips correctly" \
    || no "T1: frontmatter.accesses expected 'github:read,fs:write', got '$fm_accesses'"

# =============================================================================
# T2: verify model+accesses written to actual .md file frontmatter
# =============================================================================
echo "=== T2: model+accesses written to actual role .md file ==="
ROLE_FILE="$CB_TEAM_DIR/roles/$ROLE_NAME.md"

if [ -f "$ROLE_FILE" ]; then
    ok "T2: role file exists at $ROLE_FILE"
else
    no "T2: role file NOT found at $ROLE_FILE"
    printf '\n=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"; exit 1
fi

# Check frontmatter block has model line
if grep -q '^model: anthropic$' "$ROLE_FILE"; then
    ok "T2: 'model: anthropic' in role file frontmatter"
else
    no "T2: 'model: anthropic' MISSING from role file frontmatter"
    printf '  file contents:\n'; head -15 "$ROLE_FILE" 2>/dev/null || true
fi

# Check frontmatter block has accesses line
if grep -q '^accesses: github:read,fs:write$' "$ROLE_FILE"; then
    ok "T2: 'accesses: github:read,fs:write' in role file frontmatter"
else
    no "T2: 'accesses: github:read,fs:write' MISSING from role file frontmatter"
    printf '  file contents:\n'; head -15 "$ROLE_FILE" 2>/dev/null || true
fi

# model/accesses must appear inside the frontmatter block (between --- markers)
fm_block=$(awk '/^---$/{f=!f; next} f' "$ROLE_FILE" 2>/dev/null | head -1)  # first --- block only
in_fm_model=$(awk 'BEGIN{f=0} /^---$/{f=!f;next} f && /^model:/{print;exit}' "$ROLE_FILE" 2>/dev/null)
in_fm_accesses=$(awk 'BEGIN{f=0} /^---$/{f=!f;next} f && /^accesses:/{print;exit}' "$ROLE_FILE" 2>/dev/null)

[ -n "$in_fm_model" ] \
    && ok "T2: model line is inside frontmatter block" \
    || no "T2: model line not found inside frontmatter block"
[ -n "$in_fm_accesses" ] \
    && ok "T2: accesses line is inside frontmatter block" \
    || no "T2: accesses line not found inside frontmatter block"

# =============================================================================
# T3: save role WITHOUT model/accesses → file must NOT contain model/accesses lines
# =============================================================================
echo "=== T3: empty model/accesses → NOT written to file (clean defaults) ==="
ROLE2_NAME="schema-test-clean"
ROLE2_PAYLOAD=$(cat <<'JSON'
{
  "name": "schema-test-clean",
  "kind": "executor",
  "domain": "test/clean",
  "tools": "Read, Edit, Write, Bash",
  "profile": "executor",
  "prompt": "Clean role with no model or accesses."
}
JSON
)

save2_resp=$(curl -s -m15 -X POST \
    -H "Content-Type: application/json" \
    -d "$ROLE2_PAYLOAD" \
    "$B/api/role" 2>/dev/null)

if echo "$save2_resp" | jq -e '.ok == true' >/dev/null 2>&1; then
    ok "T3: POST /api/role (no model/accesses) ok=true"
else
    no "T3: POST /api/role (no model/accesses) failed: $save2_resp"
fi

ROLE2_FILE="$CB_TEAM_DIR/roles/$ROLE2_NAME.md"
if [ -f "$ROLE2_FILE" ]; then
    if grep -q '^model:' "$ROLE2_FILE"; then
        no "T3: 'model:' line present in clean role file (should be absent for empty value)"
    else
        ok "T3: no 'model:' line in clean role file (empty = omitted, keeps files clean)"
    fi
    if grep -q '^accesses:' "$ROLE2_FILE"; then
        no "T3: 'accesses:' line present in clean role file (should be absent for empty value)"
    else
        ok "T3: no 'accesses:' line in clean role file (empty = omitted)"
    fi
else
    no "T3: clean role file not found at $ROLE2_FILE"
fi

# =============================================================================
# T4: invalid accesses CSV token format → API returns error
# =============================================================================
echo "=== T4: invalid accesses token format → rejected ==="
BAD_ACCESSES_PAYLOAD=$(cat <<'JSON'
{
  "name": "schema-test-bad-accesses",
  "kind": "executor",
  "domain": "test/bad",
  "tools": "Read, Edit, Write, Bash",
  "profile": "executor",
  "accesses": "valid-token,bad token with spaces,another",
  "prompt": "Role with bad accesses format."
}
JSON
)

bad_resp=$(curl -s -m15 -X POST \
    -H "Content-Type: application/json" \
    -d "$BAD_ACCESSES_PAYLOAD" \
    "$B/api/role" 2>/dev/null)

if echo "$bad_resp" | jq -e '.ok == false' >/dev/null 2>&1; then
    ok "T4: invalid accesses token format → rejected (ok=false)"
    msg=$(echo "$bad_resp" | jq -r '.msg // ""' 2>/dev/null)
    if printf '%s' "$msg" | grep -qi "accesses\|invalid\|token\|format"; then
        ok "T4: rejection message mentions accesses/invalid/token/format"
    else
        no "T4: rejection message missing accesses/format context (got: $msg)"
    fi
else
    no "T4: bad accesses NOT rejected (got: $bad_resp)"
fi

# =============================================================================
# T5: model=qwen (known model) saves correctly
# =============================================================================
echo "=== T5: model=qwen (known model) saves and round-trips ==="
ROLE5_PAYLOAD=$(cat <<'JSON'
{
  "name": "schema-test-qwen",
  "kind": "executor",
  "domain": "test/qwen",
  "tools": "Read, Edit, Write, Bash",
  "profile": "executor",
  "model": "qwen",
  "prompt": "Qwen model routing test."
}
JSON
)

save5_resp=$(curl -s -m15 -X POST \
    -H "Content-Type: application/json" \
    -d "$ROLE5_PAYLOAD" \
    "$B/api/role" 2>/dev/null)

if echo "$save5_resp" | jq -e '.ok == true' >/dev/null 2>&1; then
    ok "T5: POST /api/role model=qwen ok=true"
    get5_resp=$(curl -s -m10 "$B/api/role/schema-test-qwen" 2>/dev/null)
    fm5_model=$(echo "$get5_resp" | jq -r '.frontmatter.model // ""' 2>/dev/null)
    [ "$fm5_model" = "qwen" ] \
        && ok "T5: model=qwen round-trips via GET /api/role" \
        || no "T5: model expected 'qwen', got '$fm5_model'"
else
    no "T5: POST /api/role model=qwen failed: $save5_resp"
fi

# =============================================================================
# T6: unknown model id — forward-compat: NOT blocked
# =============================================================================
echo "=== T6: unknown model id → forward-compat (not blocked) ==="
ROLE6_PAYLOAD=$(cat <<'JSON'
{
  "name": "schema-test-future",
  "kind": "executor",
  "domain": "test/future",
  "tools": "Read, Edit, Write, Bash",
  "profile": "executor",
  "model": "future-model-xyz-2027",
  "prompt": "Forward-compat model test."
}
JSON
)

save6_resp=$(curl -s -m15 -X POST \
    -H "Content-Type: application/json" \
    -d "$ROLE6_PAYLOAD" \
    "$B/api/role" 2>/dev/null)

if echo "$save6_resp" | jq -e '.ok == true' >/dev/null 2>&1; then
    ok "T6: unknown model id 'future-model-xyz-2027' NOT blocked (forward-compat)"
else
    no "T6: unknown model id was blocked (forward-compat violated): $save6_resp"
fi

echo
printf '=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
