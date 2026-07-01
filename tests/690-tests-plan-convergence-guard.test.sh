#!/usr/bin/env bash
# 690-tests-plan-convergence-guard.test.sh -- ALLOW-class unit tests for
# charter #690 plan-convergence guard (backend + build_state field).
#
# Scenario 1 -- Guard rejects during convergence:
#   do_command approve when plan_review_role IS set in org.json AND
#   plan:agreed is absent from issue labels. Assert response contains
#   ok: false and msg: plan-convergence in progress — approve blocked
#   until plan:agreed.
#
# Scenario 2 -- Guard permits in manual mode:
#   do_command approve when plan_review_role is NOT set in org.json.
#   Assert response contains ok: true.
#
# Scenario 3 -- build_state() field true:
#   plan_review_role set + issue in plan-review state + no plan:agreed label.
#   Assert board item has plan_convergence_active: true.
#
# Scenario 4 -- build_state() field false:
#   plan_review_role NOT set + issue in plan-review state.
#   Assert board item has plan_convergence_active: false.
#
# ALLOW-class: pure-function reference implementations embedded here;
# no real GitHub API, no live server, no background processes.
set -uo pipefail

pass=0; fail=0
ok()  { printf 'ok   %s\n' "$*"; pass=$((pass+1)); }
ko()  { printf 'FAIL %s\n' "$*"; fail=$((fail+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# -- Reference implementation: do_command approve guard ----------------------
#
# Mirrors the intended guard in crewboss-api.py do_command at the "approve"
# branch (leaf/690-backend-guard):
#
#   if plan_review_role is set in org.json AND "plan:agreed" NOT in labels:
#       return {"ok": False, "msg": "plan-convergence in progress — approve blocked until plan:agreed"}
#   else:
#       return {"ok": True, "msg": "approved #N"}
#
# Parameters: <org_json_path> <labels_json_array>
#
_ref_do_command_approve() {
  local org_json_path="$1"
  local labels_json="$2"
  python3 - "$org_json_path" "$labels_json" <<'PYGUARD'
import json, sys

org_path   = sys.argv[1]
labels_raw = sys.argv[2]

try:
    with open(org_path) as f:
        org = json.load(f)
except Exception:
    org = {}

plan_review_role = org.get("plan_review_role", "")

if plan_review_role:
    try:
        labels = json.loads(labels_raw)
    except Exception:
        labels = []
    if "plan:agreed" not in labels:
        msg = "plan-convergence in progress — approve blocked until plan:agreed"
        print(json.dumps({"ok": False, "msg": msg}, ensure_ascii=False))
        sys.exit(0)

print(json.dumps({"ok": True, "msg": "approved"}, ensure_ascii=False))
PYGUARD
}

# -- Reference implementation: build_state() plan_convergence_active field ---
#
# Mirrors the intended logic in crewboss-api.py build_state() (leaf/690-backend-guard):
#
#   plan_convergence_active = bool(
#       org.get("plan_review_role")
#       and item_state == "plan-review"
#       and "plan:agreed" not in item_labels
#   )
#
# Parameters: <org_json_path> <issue_state> <labels_json_array>
# Prints a board-item JSON fragment.
#
_ref_build_state_item() {
  local org_json_path="$1"
  local issue_state="$2"
  local labels_json="$3"
  python3 - "$org_json_path" "$issue_state" "$labels_json" <<'PYSTATE'
import json, sys

org_path    = sys.argv[1]
issue_state = sys.argv[2]
labels_raw  = sys.argv[3]

try:
    with open(org_path) as f:
        org = json.load(f)
except Exception:
    org = {}

try:
    labels = json.loads(labels_raw)
except Exception:
    labels = []

plan_review_role = org.get("plan_review_role", "")

plan_convergence_active = bool(
    plan_review_role
    and issue_state == "plan-review"
    and "plan:agreed" not in labels
)

item = {
    "n": 42,
    "state": issue_state,
    "kind": "charter",
    "labels": labels,
    "plan_convergence_active": plan_convergence_active,
}
print(json.dumps(item))
PYSTATE
}

# ---------------------------------------------------------------------------
echo "=== Scenario 1: Guard rejects approve during plan-convergence loop ==="

# org.json WITH plan_review_role set
ORG_WITH_ROLE="$TMP/org-with-role.json"
printf '{"plan_review_role": "analyst", "repo": "test/repo"}' > "$ORG_WITH_ROLE"

# Labels: plan-review state but NO plan:agreed
LABELS_NO_AGREED='["type:charter","status:plan-review"]'

RESP1="$(_ref_do_command_approve "$ORG_WITH_ROLE" "$LABELS_NO_AGREED")"

# S1a: ok must be false
python3 -c "import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if d.get('ok') is False else 1)" "$RESP1" \
  && ok "S1a: ok=false when plan_review_role set and plan:agreed absent" \
  || ko "S1a: expected ok=false, got: $RESP1"

# S1b: msg must contain the em-dash convergence-block phrase
# The literal em dash — (U+2014) in the check below:
printf '%s' "$RESP1" | grep -q '— approve blocked' \
  && ok "S1b: msg contains 'plan-convergence in progress — approve blocked until plan:agreed'" \
  || ko "S1b: msg missing convergence-block phrase: $RESP1"

# S1c: msg contains 'plan-convergence in progress'
printf '%s' "$RESP1" | grep -q 'plan-convergence in progress' \
  && ok "S1c: msg contains 'plan-convergence in progress'" \
  || ko "S1c: msg missing 'plan-convergence in progress': $RESP1"

# S1d: msg mentions plan:agreed
printf '%s' "$RESP1" | grep -q 'plan:agreed' \
  && ok "S1d: msg references 'plan:agreed' (approve condition)" \
  || ko "S1d: msg missing 'plan:agreed' reference: $RESP1"

# ---------------------------------------------------------------------------
echo "=== Scenario 2: Guard permits approve in manual mode (no plan_review_role) ==="

# org.json WITHOUT plan_review_role
ORG_NO_ROLE="$TMP/org-no-role.json"
printf '{"repo": "test/repo"}' > "$ORG_NO_ROLE"

RESP2="$(_ref_do_command_approve "$ORG_NO_ROLE" "$LABELS_NO_AGREED")"

# S2a: ok must be true
python3 -c "import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if d.get('ok') is True else 1)" "$RESP2" \
  && ok "S2a: ok=true when plan_review_role absent (manual mode)" \
  || ko "S2a: expected ok=true, got: $RESP2"

# S2b: also true with empty string plan_review_role
ORG_EMPTY_ROLE="$TMP/org-empty-role.json"
printf '{"plan_review_role": "", "repo": "test/repo"}' > "$ORG_EMPTY_ROLE"

RESP2B="$(_ref_do_command_approve "$ORG_EMPTY_ROLE" "$LABELS_NO_AGREED")"
python3 -c "import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if d.get('ok') is True else 1)" "$RESP2B" \
  && ok "S2b: ok=true when plan_review_role is empty string (effectively manual mode)" \
  || ko "S2b: expected ok=true with empty plan_review_role, got: $RESP2B"

# S2c: guard also passes when plan:agreed IS present (even with role set)
LABELS_WITH_AGREED='["type:charter","status:plan-review","plan:agreed"]'
RESP2C="$(_ref_do_command_approve "$ORG_WITH_ROLE" "$LABELS_WITH_AGREED")"
python3 -c "import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if d.get('ok') is True else 1)" "$RESP2C" \
  && ok "S2c: ok=true when plan_review_role set AND plan:agreed present (convergence complete)" \
  || ko "S2c: expected ok=true when plan:agreed label present, got: $RESP2C"

# ---------------------------------------------------------------------------
echo "=== Scenario 3: build_state() plan_convergence_active=true ==="

# plan_review_role set + issue in plan-review + no plan:agreed
ITEM3="$(_ref_build_state_item "$ORG_WITH_ROLE" "plan-review" "$LABELS_NO_AGREED")"

# S3a: plan_convergence_active must be true
python3 -c "import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if d.get('plan_convergence_active') is True else 1)" "$ITEM3" \
  && ok "S3a: plan_convergence_active=true when plan_review_role set + plan-review + no plan:agreed" \
  || ko "S3a: expected plan_convergence_active=true, got: $ITEM3"

# S3b: item has the expected state
python3 -c "import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if d.get('state') == 'plan-review' else 1)" "$ITEM3" \
  && ok "S3b: board item state='plan-review'" \
  || ko "S3b: board item state unexpected: $ITEM3"

# S3c: field is explicitly present in board item
python3 -c "import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if 'plan_convergence_active' in d else 1)" "$ITEM3" \
  && ok "S3c: plan_convergence_active field explicitly present in board item" \
  || ko "S3c: plan_convergence_active field absent from board item: $ITEM3"

# ---------------------------------------------------------------------------
echo "=== Scenario 4: build_state() plan_convergence_active=false ==="

# plan_review_role NOT set + issue in plan-review state
ITEM4="$(_ref_build_state_item "$ORG_NO_ROLE" "plan-review" "$LABELS_NO_AGREED")"

# S4a: plan_convergence_active must be false
python3 -c "import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if d.get('plan_convergence_active') is False else 1)" "$ITEM4" \
  && ok "S4a: plan_convergence_active=false when plan_review_role absent" \
  || ko "S4a: expected plan_convergence_active=false, got: $ITEM4"

# S4b: field is present even when false (no absent-key ambiguity)
python3 -c "import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if 'plan_convergence_active' in d else 1)" "$ITEM4" \
  && ok "S4b: plan_convergence_active field present in item even when false" \
  || ko "S4b: plan_convergence_active field absent from board item: $ITEM4"

# S4c: also false when state is not plan-review (even with role set)
ITEM4C="$(_ref_build_state_item "$ORG_WITH_ROLE" "approved" "$LABELS_NO_AGREED")"
python3 -c "import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if d.get('plan_convergence_active') is False else 1)" "$ITEM4C" \
  && ok "S4c: plan_convergence_active=false when state is not plan-review (even if role is set)" \
  || ko "S4c: expected plan_convergence_active=false for non-plan-review state, got: $ITEM4C"

# ---------------------------------------------------------------------------
echo
printf '=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
