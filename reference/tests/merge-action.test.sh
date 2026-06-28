#!/usr/bin/env bash
# merge-action.test.sh — deterministic integration tests for POST {action:merge}
# in crewboss-api.py (charter #400, issue #475 / charter #625).
#
# Starts crewboss-api.py as a background process (same pattern as ui-run-contract.test.sh).
# Fake gh binary is prepended to PATH; all calls are logged to GH_LOG; PR/CI state is
# served from temp control files in GH_STATE.
#
# (A)          Happy path        — pr_num exists, not draft, integrator green -> ok:true, verify_verdict:green
# (A-draft)    Draft promoted    — draft file present -> stub promoted before merge
# (B-no-pr)    No PR             — pr_num file absent -> ok:false; no pr merge / issue close
# (B)          verify-merged green — integrator exits 0 -> ok:true, verify_verdict:green, merged:true
# (C-new)      verify-merged red   — integrator exits 1 -> ok:false, verify_verdict:red, verify_output check-failed
# (D)          Infra failure       — integrator exits 2 -> ok:false; no pr merge
# (D-merge-fails) Merge fails    — integrator green but pr merge exits non-zero -> ok:false; NO issue close
# (X)          CB_INTEGRATOR missing — second server w/o CB_INTEGRATOR -> ok:false, CB_INTEGRATOR not found
#
# Acceptance: bash reference/tests/merge-action.test.sh 2>&1 | grep ^failed= | head -1 -> failed=0

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
API_PY="$REPO_ROOT/ui/server/crewboss-api.py"

failed=0; passed=0
ok()  { printf '  ok   %s\n' "$1"; passed=$((passed+1)); }
FAIL(){ printf '  FAIL %s\n' "$1"; failed=$((failed+1)); }

ROOT="$(mktemp -d)"; API_PID=""; API_PID_X=""
cleanup(){
  [ -n "$API_PID"   ] && kill "$API_PID"   2>/dev/null || true
  [ -n "$API_PID_X" ] && kill "$API_PID_X" 2>/dev/null || true
  rm -rf "$ROOT"
}
trap 'cleanup' EXIT

# Directories
BIN="$ROOT/bin"
CBHOME="$ROOT/cbhome"
RUN="$CBHOME/run"
GH_LOG="$ROOT/gh.log"
GH_STATE="$ROOT/ghstate"   # control files:
                            #   pr-<NUM>-draft        -> isDraft=true
                            #   pr-<NUM>-merge-fail   -> gh pr merge exits non-zero
                            #   verify-merged-exit    -> exit code for STUB_INTEGRATOR (default 0)
                            #   verify-merged-out     -> stdout for STUB_INTEGRATOR (default empty)

mkdir -p "$BIN" "$CBHOME" "$RUN" "$GH_STATE"
: > "$GH_LOG"
export GH_LOG GH_STATE

API_TOKEN="MERGETESTAPITOKEN"
CB_REPO_VAL="test/repo"
API_PORT=8872
API_PORT_X=8873
BASE_URL="http://127.0.0.1:$API_PORT"
BASE_URL_X="http://127.0.0.1:$API_PORT_X"
API_OUT="$ROOT/api.out"

# -- STUB_INTEGRATOR -----------------------------------------------------------
# Simulates CB_INTEGRATOR. Accepts subcommand: verify-merged charter/$n main --remote <url>
# Logs its invocation to GH_LOG (inherited from API process env).
# Control files (in GH_STATE):
#   verify-merged-exit  -- exit code to use (default 0 if absent)
#   verify-merged-out   -- stdout to emit (default empty if absent)
STUB_INTEGRATOR="$ROOT/stub-integrator.sh"
cat > "$STUB_INTEGRATOR" <<'SIEOF'
#!/usr/bin/env bash
printf 'integrator %s\n' "$*" >> "$GH_LOG"
exit_code=$(cat "$GH_STATE/verify-merged-exit" 2>/dev/null | tr -d '[:space:]')
exit_code=${exit_code:-0}
out=$(cat "$GH_STATE/verify-merged-out" 2>/dev/null || true)
[ -n "$out" ] && printf '%s\n' "$out"
exit "$exit_code"
SIEOF
chmod +x "$STUB_INTEGRATOR"

# -- gh stub -------------------------------------------------------------------
# Handles: gh pr view <NUM> --json isDraft --jq .isDraft (draft gate)
#           gh pr ready, gh pr merge, gh issue close
# GH_LOG and GH_STATE are inherited from the API process environment.
#
# Control files:
#   $GH_STATE/pr-<NUM>-draft      -- exists to simulate a draft PR
#   $GH_STATE/pr-<NUM>-merge-fail -- exists to make gh pr merge exit non-zero
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
    # Handle --json isDraft --jq .isDraft: return true if draft file exists, else false
    if [ -f "$GH_STATE/pr-${pr_num}-draft" ]; then
      printf 'true\n'
    else
      printf 'false\n'
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

# -- Verify api.py exists ------------------------------------------------------
if [ ! -f "$API_PY" ]; then
  FAIL "crewboss-api.py not found: $API_PY"
  printf '\nfailed=%d\n' "$failed"; exit 1
fi

# -- Start crewboss-api.py as a background process -----------------------------
# Pass GH_LOG and GH_STATE explicitly so the gh stub and STUB_INTEGRATOR
# inherit them from the API server process (subprocess.run inherits parent env).
PATH="$BIN:/usr/local/bin:/usr/bin:/bin" \
  CB_API_TOKEN="$API_TOKEN" \
  CB_HOME="$CBHOME" \
  CB_REPO="$CB_REPO_VAL" \
  CB_INTEGRATOR="$STUB_INTEGRATOR" \
  GH_LOG="$GH_LOG" \
  GH_STATE="$GH_STATE" \
  python3 "$API_PY" --port "$API_PORT" \
  > "$API_OUT" 2>&1 &
API_PID=$!

# -- Wait for api to be ready (poll, no fixed sleep) ---------------------------
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

# Helper: POST action=merge for issue N to the primary server
post_merge() {
  local n="$1"
  curl -s -m15 -X POST \
    -H "Authorization: Bearer $API_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"action\":\"merge\",\"number\":$n}" \
    "$BASE_URL/api/command" 2>/dev/null
}

# =============================================================================
# (A) Happy path: pr_num=42, not draft, integrator green (exit 0), merge succeeds
# =============================================================================
echo "== (A) Happy path: not draft, integrator green, merge succeeds =="
N_A=100; PR_A=42
mkdir -p "$RUN/state/finale-$N_A"
printf '%s' "$PR_A" > "$RUN/state/finale-$N_A/pr_num"
# No GH_STATE/pr-42-draft -> isDraft=false
# No verify-merged-exit -> STUB_INTEGRATOR defaults to exit 0 (green)
# No merge-fail -> merge succeeds
rm -f "$GH_STATE/verify-merged-exit" "$GH_STATE/verify-merged-out"
: > "$GH_LOG"

resp_a=$(post_merge "$N_A")

if printf '%s' "$resp_a" | grep -qE '"ok"\s*:\s*true'; then
  ok "(A) response ok:true (happy path)"
else
  FAIL "(A) expected ok:true, got: $resp_a"
fi

if grep -q "verify-merged" "$GH_LOG"; then
  ok "(A) GH_LOG contains verify-merged invocation"
else
  FAIL "(A) GH_LOG missing verify-merged invocation"
fi

if printf '%s' "$resp_a" | grep -qE '"verify_verdict"\s*:\s*"green"'; then
  ok "(A) response contains verify_verdict:green"
else
  FAIL "(A) expected verify_verdict:green in response, got: $resp_a"
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
# (A-draft) Draft PR promoted: draft file present -> stub promoted before merge
# =============================================================================
echo "== (A-draft) Draft PR promoted: stub promoted before merge =="
N_AD=110; PR_AD=50
mkdir -p "$RUN/state/finale-$N_AD"
printf '%s' "$PR_AD" > "$RUN/state/finale-$N_AD/pr_num"
touch "$GH_STATE/pr-${PR_AD}-draft"   # isDraft=true -> API must call gh pr ready first
rm -f "$GH_STATE/verify-merged-exit" "$GH_STATE/verify-merged-out"
: > "$GH_LOG"

resp_ad=$(post_merge "$N_AD")

if printf '%s' "$resp_ad" | grep -qE '"ok"\s*:\s*true'; then
  ok "(A-draft) response ok:true"
else
  FAIL "(A-draft) expected ok:true, got: $resp_ad"
fi

ready_line=$(grep -n "pr ready" "$GH_LOG" | head -1 | cut -d: -f1)
merge_line=$(grep -n "pr merge" "$GH_LOG" | head -1 | cut -d: -f1)
if [ -n "$ready_line" ] && [ -n "$merge_line" ] && [ "$ready_line" -lt "$merge_line" ]; then
  ok "(A-draft) gh pr ready appears in GH_LOG before gh pr merge"
else
  FAIL "(A-draft) gh pr ready should appear before gh pr merge (ready_line=${ready_line:-none} merge_line=${merge_line:-none})"
fi

# =============================================================================
# (B-no-pr) No PR: pr_num file does not exist
# =============================================================================
echo "== (B-no-pr) No PR: pr_num file absent =="
N_BNP=101
# Do NOT create RUN/state/finale-101/pr_num
: > "$GH_LOG"

resp_bnp=$(post_merge "$N_BNP")

if ! printf '%s' "$resp_bnp" | grep -qE '"ok"\s*:\s*true'; then
  ok "(B-no-pr) response is error (not ok:true) -- no PR found"
else
  FAIL "(B-no-pr) expected error response for missing PR, got: $resp_bnp"
fi

if ! grep -q "pr merge" "$GH_LOG"; then
  ok "(B-no-pr) GH_LOG does NOT contain pr merge"
else
  FAIL "(B-no-pr) GH_LOG unexpectedly contains pr merge"
fi

if ! grep -q "issue close" "$GH_LOG"; then
  ok "(B-no-pr) GH_LOG does NOT contain issue close"
else
  FAIL "(B-no-pr) GH_LOG unexpectedly contains issue close"
fi

# =============================================================================
# (B) verify-merged green: integrator exits 0 -> ok:true, verify_verdict:green, merged:true
# =============================================================================
echo "== (B) verify-merged green: integrator exits 0 =="
N_B=111; PR_B=51
mkdir -p "$RUN/state/finale-$N_B"
printf '%s' "$PR_B" > "$RUN/state/finale-$N_B/pr_num"
printf '0' > "$GH_STATE/verify-merged-exit"
rm -f "$GH_STATE/verify-merged-out" "$GH_STATE/pr-${PR_B}-draft"
: > "$GH_LOG"

resp_b=$(post_merge "$N_B")

if printf '%s' "$resp_b" | grep -qE '"ok"\s*:\s*true'; then
  ok "(B) response ok:true (verify-merged green)"
else
  FAIL "(B) expected ok:true, got: $resp_b"
fi

if printf '%s' "$resp_b" | grep -qE '"verify_verdict"\s*:\s*"green"'; then
  ok "(B) response contains verify_verdict:green"
else
  FAIL "(B) expected verify_verdict:green in response, got: $resp_b"
fi

if printf '%s' "$resp_b" | grep -qE '"merged"\s*:\s*true'; then
  ok "(B) response contains merged:true"
else
  FAIL "(B) expected merged:true in response, got: $resp_b"
fi

if grep -q "pr merge" "$GH_LOG"; then
  ok "(B) GH_LOG contains pr merge"
else
  FAIL "(B) GH_LOG missing pr merge"
fi

# =============================================================================
# (C-new) verify-merged red: integrator exits 1 -> ok:false, verify_verdict:red,
#         verify_output contains check-failed; no pr merge in GH_LOG
# =============================================================================
echo "== (C-new) verify-merged red: integrator exits 1, output=check-failed =="
N_CN=112; PR_CN=52
mkdir -p "$RUN/state/finale-$N_CN"
printf '%s' "$PR_CN" > "$RUN/state/finale-$N_CN/pr_num"
printf '1'            > "$GH_STATE/verify-merged-exit"
printf 'check-failed' > "$GH_STATE/verify-merged-out"
rm -f "$GH_STATE/pr-${PR_CN}-draft"
: > "$GH_LOG"

resp_cn=$(post_merge "$N_CN")

if printf '%s' "$resp_cn" | grep -qE '"ok"\s*:\s*false'; then
  ok "(C-new) response ok:false (integrator red)"
else
  FAIL "(C-new) expected ok:false, got: $resp_cn"
fi

if printf '%s' "$resp_cn" | grep -qE '"verify_verdict"\s*:\s*"red"'; then
  ok "(C-new) response contains verify_verdict:red"
else
  FAIL "(C-new) expected verify_verdict:red in response, got: $resp_cn"
fi

if printf '%s' "$resp_cn" | grep -q 'check-failed'; then
  ok "(C-new) response verify_output contains check-failed"
else
  FAIL "(C-new) expected verify_output to contain check-failed, got: $resp_cn"
fi

if ! grep -q "pr merge" "$GH_LOG"; then
  ok "(C-new) GH_LOG does NOT contain pr merge (blocked at integrator red)"
else
  FAIL "(C-new) GH_LOG unexpectedly contains pr merge after integrator red"
fi

# =============================================================================
# (D) Infra failure: integrator exits 2 -> ok:false; no pr merge in GH_LOG
# =============================================================================
echo "== (D) Infra failure: integrator exits 2 =="
N_D=113; PR_D=53
mkdir -p "$RUN/state/finale-$N_D"
printf '%s' "$PR_D" > "$RUN/state/finale-$N_D/pr_num"
printf '2' > "$GH_STATE/verify-merged-exit"
rm -f "$GH_STATE/verify-merged-out" "$GH_STATE/pr-${PR_D}-draft"
: > "$GH_LOG"

resp_d=$(post_merge "$N_D")

if printf '%s' "$resp_d" | grep -qE '"ok"\s*:\s*false'; then
  ok "(D) response ok:false (infra failure, integrator exit 2)"
else
  FAIL "(D) expected ok:false after infra failure, got: $resp_d"
fi

if ! grep -q "pr merge" "$GH_LOG"; then
  ok "(D) GH_LOG does NOT contain pr merge (blocked at infra failure)"
else
  FAIL "(D) GH_LOG unexpectedly contains pr merge after infra failure"
fi

# =============================================================================
# (D-merge-fails) Merge fails: not draft, integrator green but merge exits non-zero
# =============================================================================
echo "== (D-merge-fails) Merge fails: no silent issue close =="
N_DMF=103; PR_DMF=44
mkdir -p "$RUN/state/finale-$N_DMF"
printf '%s' "$PR_DMF" > "$RUN/state/finale-$N_DMF/pr_num"
touch "$GH_STATE/pr-${PR_DMF}-merge-fail"   # makes gh pr merge exit non-zero
rm -f "$GH_STATE/verify-merged-exit" "$GH_STATE/verify-merged-out" "$GH_STATE/pr-${PR_DMF}-draft"
: > "$GH_LOG"

resp_dmf=$(post_merge "$N_DMF")

if printf '%s' "$resp_dmf" | grep -qE '"ok"\s*:\s*false'; then
  ok "(D-merge-fails) response has ok:false after failed merge"
else
  FAIL "(D-merge-fails) expected ok:false after failed merge, got: $resp_dmf"
fi

if ! grep -q "issue close" "$GH_LOG"; then
  ok "(D-merge-fails) GH_LOG does NOT contain issue close (no silent close after failed merge)"
else
  FAIL "(D-merge-fails) GH_LOG contains issue close despite failed merge (silent close must not happen)"
fi

# =============================================================================
# (X) CB_INTEGRATOR unset/missing: start a second short-lived server on API_PORT_X=8873
#     without CB_INTEGRATOR in env and without $CB_HOME/crewboss-integrator.sh present.
#     CB_INTEGRATOR is a module-level constant resolved at import time -- do NOT reuse
#     the main server instance.
# =============================================================================
echo "== (X) CB_INTEGRATOR unset/missing: second server on port $API_PORT_X =="
CBHOME_X="$ROOT/cbhome-x"
RUN_X="$CBHOME_X/run"
API_OUT_X="$ROOT/api.out.x"
mkdir -p "$CBHOME_X" "$RUN_X"
# Neither CB_INTEGRATOR env nor $CBHOME_X/crewboss-integrator.sh present

PATH="$BIN:/usr/local/bin:/usr/bin:/bin" \
  CB_API_TOKEN="$API_TOKEN" \
  CB_HOME="$CBHOME_X" \
  CB_REPO="$CB_REPO_VAL" \
  GH_LOG="$GH_LOG" \
  GH_STATE="$GH_STATE" \
  python3 "$API_PY" --port "$API_PORT_X" \
  > "$API_OUT_X" 2>&1 &
API_PID_X=$!

api_ready_x=0
deadline_x=$(( $(date +%s) + 25 ))
while [ "$(date +%s)" -lt "$deadline_x" ]; do
  code=$(curl -s -m1 -o /dev/null -w '%{http_code}' "$BASE_URL_X/api/health" 2>/dev/null)
  if [ "$code" = "200" ]; then api_ready_x=1; break; fi
  sleep 0.2
done

if [ "$api_ready_x" -eq 0 ]; then
  FAIL "(X) secondary API did not become ready within deadline"
  printf 'api-x output:\n'; head -10 "$API_OUT_X" 2>/dev/null || true
else
  N_X=114; PR_X=54
  mkdir -p "$RUN_X/state/finale-$N_X"
  printf '%s' "$PR_X" > "$RUN_X/state/finale-$N_X/pr_num"
  rm -f "$GH_STATE/verify-merged-exit" "$GH_STATE/verify-merged-out" "$GH_STATE/pr-${PR_X}-draft"
  : > "$GH_LOG"

  resp_x=$(curl -s -m15 -X POST \
    -H "Authorization: Bearer $API_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"action\":\"merge\",\"number\":$N_X}" \
    "$BASE_URL_X/api/command" 2>/dev/null)

  if printf '%s' "$resp_x" | grep -qE '"ok"\s*:\s*false'; then
    ok "(X) response ok:false (CB_INTEGRATOR missing)"
  else
    FAIL "(X) expected ok:false when CB_INTEGRATOR missing, got: $resp_x"
  fi

  if printf '%s' "$resp_x" | grep -q 'CB_INTEGRATOR not found'; then
    ok "(X) response msg contains 'CB_INTEGRATOR not found'"
  else
    FAIL "(X) expected msg to contain 'CB_INTEGRATOR not found', got: $resp_x"
  fi

  if ! grep -q "pr merge" "$GH_LOG"; then
    ok "(X) GH_LOG does NOT contain pr merge"
  else
    FAIL "(X) GH_LOG unexpectedly contains pr merge"
  fi
fi

# Stop the secondary server after (X) assertions
kill "$API_PID_X" 2>/dev/null || true
API_PID_X=""

# =============================================================================
echo
printf 'passed=%d\n' "$passed"
printf 'failed=%d\n' "$failed"
[ "$failed" -eq 0 ]
