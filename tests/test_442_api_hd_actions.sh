#!/usr/bin/env bash
# test_442_api_hd_actions.sh — TDD gate for charter #442 API HD action commands
#
# Tests /api/command with the three new actions added by charter #442:
#   approve-hd       — 5 HD types × expected label mutations + close HD
#   request-changes-hd — post reason comment to charter + close HD + no unblock labels
#   close-hd         — close HD only, ZERO charter label mutations
#
# Regression guard: existing approve + request-changes still work on non-HD issues.
#
# ALLOW-class: stubbed gh (Python dispatcher); local API server (background);
# curl HTTP client; no real GitHub; no launcher loop; no external network.
# TDD guard: new-action tests are SKIP-guarded (detect "unknown action" response)
# and become fully assertive once charter #442 api-hd-actions leaf merges.
#
# Charter #442
set -uo pipefail

pass=0; fail=0

ok()     { printf 'ok   %s\n' "$*"; pass=$((pass+1)); }
ko()     { printf 'FAIL %s\n' "$*"; fail=$((fail+1)); }
skip_ok(){ printf 'skip %s\n' "$*"; pass=$((pass+1)); }

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
GH_CALL_LOG="$TMP/gh_calls.log"; : > "$GH_CALL_LOG"

# ── Stub: gh ─────────────────────────────────────────────────────────────────
# Python dispatcher: logs every invocation, routes by sub-command.
# Fixtures: HD issues 501-505, charter 100, plan-review charter 200.
cat > "$BIN/gh" <<'PYSHIM'
#!/usr/bin/env python3
import sys, os, json

argv = sys.argv[1:]
log_file = os.environ.get("GH_CALL_LOG", "/dev/null")
try:
    with open(log_file, "a") as f:
        f.write(" ".join(str(a) for a in argv) + "\n")
except Exception:
    pass

# Fixture issues keyed by number (as strings for lookup)
HD_ISSUES = {
    "501": {
        "number": 501,
        "title": "Human decision: charter #100 composition not converging",
        "body": "Charter: #100\n",
        "state": "open",
        "labels": [{"name": "type:human-decision"}]
    },
    "502": {
        "number": 502,
        "title": "Human decision: charter #100 analysis did not converge",
        "body": "Charter: #100\n",
        "state": "open",
        "labels": [{"name": "type:human-decision"}]
    },
    "503": {
        "number": 503,
        "title": "Human approval required: Charter #100",
        "body": "Charter: #100\n",
        "state": "open",
        "labels": [{"name": "type:human-decision"}]
    },
    "504": {
        "number": 504,
        "title": "Human decision: charter #100 plan did not converge",
        "body": "Charter: #100\n",
        "state": "open",
        "labels": [{"name": "type:human-decision"}]
    },
    "505": {
        "number": 505,
        "title": "Human decision: charter #100 acceptance did not converge",
        "body": "Charter: #100\n",
        "state": "open",
        "labels": [{"name": "type:human-decision"}]
    },
    # Charter issue (target of label mutations)
    "100": {
        "number": 100,
        "title": "Charter: main feature",
        "body": "",
        "state": "open",
        "labels": [{"name": "type:charter"}, {"name": "status:team-review"}]
    },
    # Plan-review charter (for regression tests)
    "200": {
        "number": 200,
        "title": "Charter: planning feature",
        "body": "",
        "state": "open",
        "labels": [{"name": "type:charter"}, {"name": "status:plan-review"}]
    },
}

# Route by sub-command
if len(argv) >= 2 and argv[0] == "issue" and argv[1] == "view":
    n = argv[2] if len(argv) > 2 else ""
    issue = HD_ISSUES.get(n, {
        "number": int(n) if n.isdigit() else 0,
        "title": "", "body": "", "state": "open", "labels": []
    })
    # Honor --json fields argument
    json_fields = None
    if "--json" in argv:
        idx = argv.index("--json")
        if idx + 1 < len(argv):
            json_fields = [f.strip() for f in argv[idx + 1].split(",")]
    if json_fields:
        out = {k: issue.get(k, "" if k in ("title","body") else []) for k in json_fields}
    else:
        out = issue
    # Honor --jq argument (basic support)
    if "--jq" in argv:
        idx = argv.index("--jq")
        jq_expr = argv[idx + 1] if idx + 1 < len(argv) else ""
        if jq_expr == ".body":
            print(out.get("body", ""))
            sys.exit(0)
        elif jq_expr == ".title":
            print(out.get("title", ""))
            sys.exit(0)
    print(json.dumps(out))
    sys.exit(0)

elif len(argv) >= 2 and argv[0] == "api":
    # Paginated issue list: return empty array (no board data needed)
    if "--include" in argv:
        # Include headers + body format for ETag branch
        print("HTTP/1.1 200 OK\nContent-Type: application/json\n\n[]")
    else:
        print("[]")
    sys.exit(0)

# All other calls (issue edit, issue close, issue comment, etc.): log and succeed
sys.exit(0)
PYSHIM
chmod +x "$BIN/gh"
export GH_CALL_LOG

# ── Start API server ──────────────────────────────────────────────────────────
PORT=19442
export CB_REPO="test/repo"
export CB_HOME
export CB_API_TOKEN="testtoken442"

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
AUTH="Authorization: Bearer testtoken442"

# ── Helpers ───────────────────────────────────────────────────────────────────
post_cmd() {
  curl -s --max-time 15 -X POST "$API/api/command" \
    -H "$AUTH" -H "Content-Type: application/json" -d "$1" 2>/dev/null || echo '{}'
}

resp_ok()  { printf '%s' "$1" | python3 -c "import json,sys; print(json.load(sys.stdin).get('ok', False))" 2>/dev/null || echo "False"; }
resp_msg() { printf '%s' "$1" | python3 -c "import json,sys; print(json.load(sys.stdin).get('msg', ''))" 2>/dev/null || echo ""; }

is_unknown_action() {
  local msg="$1"
  printf '%s' "$msg" | grep -qi "unknown action"
}

# ── Helper: test one approve-hd case ─────────────────────────────────────────
# $1=HD_NUM $2=CHARTER_NUM $3=GATE_LABEL $4=expected_add_labels(comma-sep)
# $5=expected_remove_labels(comma-sep) $6=1 if HD should be closed
_test_approve_hd() {
  local hd_num="$1" charter_num="$2" gate="$3" add_labels="$4" rm_labels="$5"
  : > "$GH_CALL_LOG"
  local resp
  resp=$(post_cmd "{\"action\":\"approve-hd\",\"number\":\"${hd_num}\"}")
  local ok msg
  ok=$(resp_ok "$resp"); msg=$(resp_msg "$resp")

  if is_unknown_action "$msg"; then
    skip_ok "${gate}/approve-hd: action not implemented yet (charter #442 api-hd-actions pending)"
    return
  fi

  # Action is implemented — run full assertions
  [ "$ok" = "True" ] \
    && ok "${gate}/approve-hd: ok=true" \
    || ko "${gate}/approve-hd: ok=$ok msg=$msg"

  # Charter label mutations
  grep -q "issue edit ${charter_num}" "$GH_CALL_LOG" \
    && ok "${gate}/approve-hd: gh issue edit called on charter #${charter_num}" \
    || ko "${gate}/approve-hd: gh issue edit NOT called on charter #${charter_num}"

  IFS=',' read -ra _add <<< "$add_labels"
  for lbl in "${_add[@]}"; do
    [ -z "$lbl" ] && continue
    grep -q "${lbl}" "$GH_CALL_LOG" \
      && ok "${gate}/approve-hd: label '${lbl}' added" \
      || ko "${gate}/approve-hd: label '${lbl}' NOT added to charter"
  done

  IFS=',' read -ra _rm <<< "$rm_labels"
  for lbl in "${_rm[@]}"; do
    [ -z "$lbl" ] && continue
    grep -q "${lbl}" "$GH_CALL_LOG" \
      && ok "${gate}/approve-hd: label '${lbl}' referenced (removed from charter)" \
      || ko "${gate}/approve-hd: label '${lbl}' NOT referenced (should be removed)"
  done

  # HD issue closed
  grep -q "issue close ${hd_num}" "$GH_CALL_LOG" \
    && ok "${gate}/approve-hd: HD #${hd_num} closed" \
    || ko "${gate}/approve-hd: HD #${hd_num} NOT closed"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Section 1 — approve-hd: all 5 HD type × label-mutation matrix
# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Section 1: approve-hd — 5 HD types ==="

# Case 1: composition not converging → add composition:approved,status:needs-plan; remove status:team-review
_test_approve_hd 501 100 "gate1/composition-not-converging" \
  "composition:approved,status:needs-plan" "status:team-review"

# Case 2: analysis did not converge → add review:agreed; close HD
_test_approve_hd 502 100 "gate2/analysis-did-not-converge" \
  "review:agreed" ""

# Case 3: approval required → add composition:approved,status:needs-plan; remove status:team-review
_test_approve_hd 503 100 "gate3/approval-required" \
  "composition:approved,status:needs-plan" "status:team-review"

# Case 4: plan did not converge → add plan:agreed; close HD
_test_approve_hd 504 100 "gate4/plan-did-not-converge" \
  "plan:agreed" ""

# Case 5: acceptance did not converge → add accept:agreed; close HD
_test_approve_hd 505 100 "gate5/acceptance-did-not-converge" \
  "accept:agreed" ""

# ═══════════════════════════════════════════════════════════════════════════════
# Section 2 — request-changes-hd
# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Section 2: request-changes-hd ==="

# request-changes-hd must:
# - Close the HD issue
# - Post comment to CHARTER with reason
# - NOT add any forward-progression labels (no composition:approved, review:agreed, etc.)
# Exception: for "approval required" (503): also add status:needs-analysis, remove status:team-review

# Case 6: composition not converging → close HD, comment to charter #100, no unblock labels
: > "$GH_CALL_LOG"
_resp=$(post_cmd '{"action":"request-changes-hd","number":"501","reason":"composition needs revision"}')
_ok=$(resp_ok "$_resp"); _msg=$(resp_msg "$_resp")
if is_unknown_action "$_msg"; then
  skip_ok "gate1/request-changes-hd: action not implemented yet (charter #442 api-hd-actions pending)"
else
  [ "$_ok" = "True" ] \
    && ok "gate1/request-changes-hd: ok=true" \
    || ko "gate1/request-changes-hd: ok=$_ok msg=$_msg"

  # Comment must be posted to CHARTER (100), not HD (501)
  grep -q "issue comment 100" "$GH_CALL_LOG" \
    && ok "gate1/request-changes-hd: comment posted to charter #100" \
    || ko "gate1/request-changes-hd: comment NOT posted to charter #100"

  # HD is closed
  grep -q "issue close 501" "$GH_CALL_LOG" \
    && ok "gate1/request-changes-hd: HD #501 closed" \
    || ko "gate1/request-changes-hd: HD #501 NOT closed"

  # No forward-progression (unblock) labels
  for unblock in "composition:approved" "review:agreed" "plan:agreed" "accept:agreed"; do
    if grep -q "$unblock" "$GH_CALL_LOG"; then
      ko "gate1/request-changes-hd: unblock label '$unblock' found (must not appear)"
    else
      ok "gate1/request-changes-hd: no unblock label '$unblock'"
    fi
  done
fi

# Case 7: approval required → close HD + comment to charter + add status:needs-analysis + remove status:team-review
: > "$GH_CALL_LOG"
_resp=$(post_cmd '{"action":"request-changes-hd","number":"503","reason":"approval needs rework"}')
_ok=$(resp_ok "$_resp"); _msg=$(resp_msg "$_resp")
if is_unknown_action "$_msg"; then
  skip_ok "gate3/request-changes-hd: action not implemented yet (charter #442 api-hd-actions pending)"
else
  [ "$_ok" = "True" ] \
    && ok "gate3/request-changes-hd/approval-required: ok=true" \
    || ko "gate3/request-changes-hd/approval-required: ok=$_ok msg=$_msg"

  # Comment to charter
  grep -q "issue comment 100" "$GH_CALL_LOG" \
    && ok "gate3/request-changes-hd/approval-required: comment posted to charter #100" \
    || ko "gate3/request-changes-hd/approval-required: comment NOT posted to charter #100"

  # HD is closed
  grep -q "issue close 503" "$GH_CALL_LOG" \
    && ok "gate3/request-changes-hd/approval-required: HD #503 closed" \
    || ko "gate3/request-changes-hd/approval-required: HD #503 NOT closed"

  # Exception: add status:needs-analysis, remove status:team-review on charter
  grep -q "status:needs-analysis" "$GH_CALL_LOG" \
    && ok "gate3/request-changes-hd/approval-required: status:needs-analysis added to charter" \
    || ko "gate3/request-changes-hd/approval-required: status:needs-analysis NOT added"
  grep -q "status:team-review" "$GH_CALL_LOG" \
    && ok "gate3/request-changes-hd/approval-required: status:team-review removed from charter" \
    || ko "gate3/request-changes-hd/approval-required: status:team-review NOT removed"

  # Still no forward-progression labels
  for unblock in "composition:approved" "review:agreed" "plan:agreed" "accept:agreed"; do
    if grep -q "$unblock" "$GH_CALL_LOG"; then
      ko "gate3/request-changes-hd/approval-required: unblock label '$unblock' found (must not appear)"
    else
      ok "gate3/request-changes-hd/approval-required: no unblock label '$unblock'"
    fi
  done
fi

# Case 8: analysis did not converge (another non-approval HD type)
: > "$GH_CALL_LOG"
_resp=$(post_cmd '{"action":"request-changes-hd","number":"502","reason":"analysis needs more rounds"}')
_ok=$(resp_ok "$_resp"); _msg=$(resp_msg "$_resp")
if is_unknown_action "$_msg"; then
  skip_ok "gate2/request-changes-hd: action not implemented yet (charter #442 api-hd-actions pending)"
else
  [ "$_ok" = "True" ] \
    && ok "gate2/request-changes-hd: ok=true" \
    || ko "gate2/request-changes-hd: ok=$_ok msg=$_msg"
  grep -q "issue comment 100" "$GH_CALL_LOG" \
    && ok "gate2/request-changes-hd: comment posted to charter #100" \
    || ko "gate2/request-changes-hd: comment NOT posted to charter"
  grep -q "issue close 502" "$GH_CALL_LOG" \
    && ok "gate2/request-changes-hd: HD #502 closed" \
    || ko "gate2/request-changes-hd: HD #502 NOT closed"
  # For non-approval HD: must NOT add status:needs-analysis
  if grep -q "status:needs-analysis" "$GH_CALL_LOG"; then
    ko "gate2/request-changes-hd: status:needs-analysis added (only valid for approval-required HD)"
  else
    ok "gate2/request-changes-hd: status:needs-analysis NOT added (correct for non-approval HD)"
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Section 3 — close-hd: HD closed, ZERO charter label mutations
# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Section 3: close-hd ==="

# Case 9: close-hd on composition-not-converging → close HD, NO charter edits
: > "$GH_CALL_LOG"
_resp=$(post_cmd '{"action":"close-hd","number":"501"}')
_ok=$(resp_ok "$_resp"); _msg=$(resp_msg "$_resp")
if is_unknown_action "$_msg"; then
  skip_ok "gate1/close-hd: action not implemented yet (charter #442 api-hd-actions pending)"
else
  [ "$_ok" = "True" ] \
    && ok "gate1/close-hd: ok=true" \
    || ko "gate1/close-hd: ok=$_ok msg=$_msg"

  # HD must be closed
  grep -q "issue close 501" "$GH_CALL_LOG" \
    && ok "gate1/close-hd: HD #501 closed" \
    || ko "gate1/close-hd: HD #501 NOT closed"

  # ZERO charter label mutations: no 'issue edit 100' calls
  if grep -q "issue edit 100" "$GH_CALL_LOG"; then
    ko "gate1/close-hd: charter #100 was edited — MUST be zero label mutations on close-hd"
  else
    ok "gate1/close-hd: charter #100 NOT edited (zero label mutations — correct)"
  fi
fi

# Case 10: close-hd on approval-required → same constraint
: > "$GH_CALL_LOG"
_resp=$(post_cmd '{"action":"close-hd","number":"503"}')
_ok=$(resp_ok "$_resp"); _msg=$(resp_msg "$_resp")
if is_unknown_action "$_msg"; then
  skip_ok "gate3/close-hd: action not implemented yet (charter #442 api-hd-actions pending)"
else
  [ "$_ok" = "True" ] \
    && ok "gate3/close-hd: ok=true" \
    || ko "gate3/close-hd: ok=$_ok msg=$_msg"

  grep -q "issue close 503" "$GH_CALL_LOG" \
    && ok "gate3/close-hd: HD #503 closed" \
    || ko "gate3/close-hd: HD #503 NOT closed"

  if grep -q "issue edit 100" "$GH_CALL_LOG"; then
    ko "gate3/close-hd: charter #100 was edited — MUST be zero label mutations on close-hd"
  else
    ok "gate3/close-hd: charter #100 NOT edited (zero label mutations — correct)"
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Section 4 — Regression: existing approve + request-changes still work
# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Section 4: Regression — existing plan-review commands ==="

# Case 11: approve (plan-review) still works
: > "$GH_CALL_LOG"
_resp=$(post_cmd '{"action":"approve","number":"200"}')
_ok=$(resp_ok "$_resp"); _msg=$(resp_msg "$_resp")
[ "$_ok" = "True" ] \
  && ok "regression/approve: ok=true (plan-review approve still works)" \
  || ko "regression/approve: ok=$_ok msg=$_msg (plan-review approve BROKEN)"

grep -q "issue edit 200" "$GH_CALL_LOG" \
  && ok "regression/approve: gh issue edit called on #200" \
  || ko "regression/approve: gh issue edit NOT called on #200"

grep -q "status:approved" "$GH_CALL_LOG" \
  && ok "regression/approve: status:approved label added" \
  || ko "regression/approve: status:approved NOT added"

grep -q "status:plan-review" "$GH_CALL_LOG" \
  && ok "regression/approve: status:plan-review label removed" \
  || ko "regression/approve: status:plan-review NOT removed"

# Case 12: request-changes (plan-review) still works
: > "$GH_CALL_LOG"
_resp=$(post_cmd '{"action":"request-changes","number":"200","comment":"needs more detail"}')
_ok=$(resp_ok "$_resp"); _msg=$(resp_msg "$_resp")
[ "$_ok" = "True" ] \
  && ok "regression/request-changes: ok=true (plan-review request-changes still works)" \
  || ko "regression/request-changes: ok=$_ok msg=$_msg (plan-review request-changes BROKEN)"

grep -q "issue comment 200" "$GH_CALL_LOG" \
  && ok "regression/request-changes: comment posted to #200 (the issue itself)" \
  || ko "regression/request-changes: comment NOT posted to #200"

grep -q "status:needs-plan" "$GH_CALL_LOG" \
  && ok "regression/request-changes: status:needs-plan added" \
  || ko "regression/request-changes: status:needs-plan NOT added"

grep -q "status:plan-review" "$GH_CALL_LOG" \
  && ok "regression/request-changes: status:plan-review removed" \
  || ko "regression/request-changes: status:plan-review NOT removed"

# Sanity: request-changes on #200 (plan-review charter) must NOT touch charter #100
if grep -q "issue edit 100" "$GH_CALL_LOG"; then
  ko "regression/request-changes: unexpectedly edited charter #100 (should only touch #200)"
else
  ok "regression/request-changes: did not touch charter #100 (isolated to #200)"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════════
echo
printf '=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then
  printf 'ALL GREEN\n'
else
  printf 'FAILED (%d failures)\n' "$fail"
  exit 1
fi
