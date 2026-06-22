#!/usr/bin/env bash
# merge-action.test.sh — deterministic integration tests for POST {action:merge}
# in crewboss-api.py (charter #400, issue #475).
#
# Starts crewboss-api.py as a background process (same pattern as ui-run-contract.test.sh).
# Fake gh binary is prepended to PATH; all calls are logged to GH_LOG; PR/CI state is
# served from temp control files in GH_STATE.
#
# (A) Happy path   — pr_num exists, CI green, merge succeeds → ok:true; log has pr ready/merge/close
# (B) No PR        — pr_num file absent → ok:false; no pr merge / issue close in log
# (C) Red CI gate  — CI check returns FAILURE → ok:false; no pr merge / issue close in log
# (D) Merge fails  — CI green but pr merge exits non-zero → ok:false; NO issue close (no silent close)
#
# Acceptance: bash reference/tests/merge-action.test.sh 2>&1 | grep ^failed= | head -1 → failed=0

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
API_PY="$REPO_ROOT/ui/server/crewboss-api.py"

failed=0; passed=0
ok()  { printf '  ok   %s\n' "$1"; passed=$((passed+1)); }
FAIL(){ printf '  FAIL %s\n' "$1"; failed=$((failed+1)); }

ROOT="$(mktemp -d)"; API_PID=""
cleanup(){ [ -n "$API_PID" ] && kill "$API_PID" 2>/dev/null || true; rm -rf "$ROOT"; }
trap 'cleanup' EXIT

# Directories
BIN="$ROOT/bin"
CBHOME="$ROOT/cbhome"
RUN="$CBHOME/run"
GH_LOG="$ROOT/gh.log"
GH_STATE="$ROOT/ghstate"   # control files: pr-<NUM>-checks (FAILURE) / pr-<NUM>-merge-fail

mkdir -p "$BIN" "$CBHOME" "$RUN" "$GH_STATE"
: > "$GH_LOG"
export GH_LOG GH_STATE

API_TOKEN="MERGETESTAPITOKEN"
CB_REPO_VAL="test/repo"
API_PORT=8872
BASE_URL="http://127.0.0.1:$API_PORT"
API_OUT="$ROOT/api.out"

# ── gh stub ────────────────────────────────────────────────────────────────────
# Handles: gh pr view --json statusCheckRollup --jq (CI gate)
#           gh pr ready, gh pr merge, gh issue close
# GH_LOG and GH_STATE are inherited from the API process environment.
#
# Control files:
#   $GH_STATE/pr-<NUM>-checks     — contains "FAILURE" to simulate red CI; absent = green
#   $GH_STATE/pr-<NUM>-merge-fail — exists to make gh pr merge exit non-zero
cat > "$BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
obj="${1:-}"; verb="${2:-}"
[ $# -ge 2 ] && shift 2

# Strip -R/--repo flags (and their values)
_args=()
while [ $# -gt 0 ]; do
  case "$1" in -R|--repo) shift ;; *) _args+=("$1") ;; esac; shift
done
set -- "${_args[@]+"${_args[@]}"}"

# Log this call (obj verb arg1 arg2 ...)
{ printf '%s %s' "$obj" "$verb"
  for a in "$@"; do printf ' %s' "$a"; done
  printf '\n'; } >> "$GH_LOG"

case "$obj $verb" in
  "pr view")
    pr_num="${1:-}"
    # Read CI state from control file; absent or non-FAILURE → green
    ci_state="$(cat "$GH_STATE/pr-${pr_num}-checks" 2>/dev/null || printf 'SUCCESS')"
    if [ "$ci_state" = "FAILURE" ]; then
      printf 'false\n'
    else
      printf 'true\n'
    fi
    ;;

  "pr ready")
    pr_num="${1:-}"
    if [ -f "$GH_STATE/pr-${pr_num}-ready-fail" ]; then
      printf 'pr ready failed\n' >&2; exit 1
    fi
    ;;

  "pr merge")
    pr_num="${1:-}"
    if [ -f "$GH_STATE/pr-${pr_num}-merge-fail" ]; then
      printf 'merge failed\n' >&2; exit 1
    fi
    ;;

  "issue close") ;;   # success no-op

  *) ;;
esac
exit 0
GHEOF
chmod +x "$BIN/gh"

# ── Verify api.py exists ──────────────────────────────────────────────────────
if [ ! -f "$API_PY" ]; then
  FAIL "crewboss-api.py not found: $API_PY"
  printf '\nfailed=%d\n' "$failed"; exit 1
fi

# ── Start crewboss-api.py as a background process ─────────────────────────────
# Pass GH_LOG and GH_STATE explicitly so the gh stub inherits them from the
# API server process (subprocess.run inherits parent env by default).
PATH="$BIN:/usr/local/bin:/usr/bin:/bin" \
  CB_API_TOKEN="$API_TOKEN" \
  CB_HOME="$CBHOME" \
  CB_REPO="$CB_REPO_VAL" \
  GH_LOG="$GH_LOG" \
  GH_STATE="$GH_STATE" \
  python3 "$API_PY" --port "$API_PORT" \
  > "$API_OUT" 2>&1 &
API_PID=$!

# ── Wait for api to be ready (poll, no fixed sleep) ───────────────────────────
api_ready=0
deadline=$(( $(date +%s) + 25 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  code=$(curl -s -m1 -o /dev/null -w '%{http_code}' "$BASE_URL/api/health" 2>/dev/null)
  if [ "$code" = "200" ]; then api_ready=1; break; fi
  sleep 0.2
done

if [ "$api_ready" -eq 0 ]; then
  FAIL "API did not become ready within deadline"
  printf 'api output:\n'; head -10 "$API_OUT" 2>/dev/null || true
  printf '\nfailed=%d\n' "$failed"; exit 1
fi

# Helper: POST action=merge for issue N and capture response body
post_merge() {
  local n="$1"
  curl -s -m15 -X POST \
    -H "Authorization: Bearer $API_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"action\":\"merge\",\"number\":$n}" \
    "$BASE_URL/api/command" 2>/dev/null
}

# =============================================================================
# (A) Happy path: pr_num=42, CI green, merge succeeds
# =============================================================================
echo "== (A) Happy path: CI green, merge succeeds =="
N_A=100; PR_A=42
mkdir -p "$RUN/state/finale-$N_A"
printf '%s' "$PR_A" > "$RUN/state/finale-$N_A/pr_num"
# No GH_STATE/pr-42-checks → green by default; no merge-fail → merge succeeds
: > "$GH_LOG"

resp_a=$(post_merge "$N_A")

if printf '%s' "$resp_a" | grep -qE '"ok"\s*:\s*true'; then
  ok "(A) response ok:true (happy path)"
else
  FAIL "(A) expected ok:true, got: $resp_a"
fi

if grep -q "pr ready" "$GH_LOG"; then
  ok "(A) GH_LOG contains pr ready"
else
  FAIL "(A) GH_LOG missing pr ready"
fi

if grep -q "pr merge" "$GH_LOG"; then
  ok "(A) GH_LOG contains pr merge"
else
  FAIL "(A) GH_LOG missing pr merge"
fi

if grep -q "issue close" "$GH_LOG"; then
  ok "(A) GH_LOG contains issue close"
else
  FAIL "(A) GH_LOG missing issue close"
fi

# =============================================================================
# (B) No PR: pr_num file does not exist
# =============================================================================
echo "== (B) No PR: pr_num file absent =="
N_B=101
# Do NOT create RUN/state/finale-101/pr_num
: > "$GH_LOG"

resp_b=$(post_merge "$N_B")

if ! printf '%s' "$resp_b" | grep -qE '"ok"\s*:\s*true'; then
  ok "(B) response is error (not ok:true) — no PR found"
else
  FAIL "(B) expected error response for missing PR, got: $resp_b"
fi

if ! grep -q "pr merge" "$GH_LOG"; then
  ok "(B) GH_LOG does NOT contain pr merge"
else
  FAIL "(B) GH_LOG unexpectedly contains pr merge"
fi

if ! grep -q "issue close" "$GH_LOG"; then
  ok "(B) GH_LOG does NOT contain issue close"
else
  FAIL "(B) GH_LOG unexpectedly contains issue close"
fi

# =============================================================================
# (C) Red CI gate: pr_num exists but gh pr view returns FAILURE
# =============================================================================
echo "== (C) Red CI gate: one FAILURE check =="
N_C=102; PR_C=43
mkdir -p "$RUN/state/finale-$N_C"
printf '%s' "$PR_C" > "$RUN/state/finale-$N_C/pr_num"
printf 'FAILURE' > "$GH_STATE/pr-${PR_C}-checks"
: > "$GH_LOG"

resp_c=$(post_merge "$N_C")

if ! printf '%s' "$resp_c" | grep -qE '"ok"\s*:\s*true'; then
  ok "(C) response is error (CI gate blocked)"
else
  FAIL "(C) expected error response for red CI gate, got: $resp_c"
fi

if ! grep -q "pr merge" "$GH_LOG"; then
  ok "(C) GH_LOG does NOT contain pr merge (blocked at CI gate)"
else
  FAIL "(C) GH_LOG unexpectedly contains pr merge after CI failure"
fi

if ! grep -q "issue close" "$GH_LOG"; then
  ok "(C) GH_LOG does NOT contain issue close (blocked at CI gate)"
else
  FAIL "(C) GH_LOG unexpectedly contains issue close after CI failure"
fi

# =============================================================================
# (D) Merge fails: CI green but gh pr merge exits non-zero → no silent issue close
# =============================================================================
echo "== (D) Merge fails: no silent issue close =="
N_D=103; PR_D=44
mkdir -p "$RUN/state/finale-$N_D"
printf '%s' "$PR_D" > "$RUN/state/finale-$N_D/pr_num"
touch "$GH_STATE/pr-${PR_D}-merge-fail"   # makes gh pr merge exit non-zero
: > "$GH_LOG"

resp_d=$(post_merge "$N_D")

if printf '%s' "$resp_d" | grep -qE '"ok"\s*:\s*false'; then
  ok "(D) response has ok:false after failed merge"
else
  FAIL "(D) expected ok:false after failed merge, got: $resp_d"
fi

if ! grep -q "issue close" "$GH_LOG"; then
  ok "(D) GH_LOG does NOT contain issue close (no silent close after failed merge)"
else
  FAIL "(D) GH_LOG contains issue close despite failed merge (silent close must not happen)"
fi

# =============================================================================
echo
printf 'passed=%d\n' "$passed"
printf 'failed=%d\n' "$failed"
[ "$failed" -eq 0 ]
