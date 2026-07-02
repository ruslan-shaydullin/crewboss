#!/usr/bin/env bash
# 1220-cli-approve-guard.test.sh — plan-convergence guard for the CLI approve path.
# Charter: #1220 (P1 of milestone #1219 / docs/design/plan-oversight-strategy.md).
#
# Defect (site 3 of 3): reference/bin/crewboss cmd_approve is UNGUARDED — it flips
#   status:plan-review -> status:approved with a bare `gh issue edit`, even when the
#   org policy sets plan_review_role and the live issue has NOT yet earned plan:agreed.
#   This bypasses the convergence gate #690 closed only for the cockpit — a real risk
#   on the live board in convergence mode.
#
# Correct CLI guard (same three-site condition):
#   `crewboss approve <N>` must DIE (non-zero) when plan_review_role (read from org.json
#   POLICY sub-dict) is non-empty AND the live labels lack plan:agreed; it must SUCCEED
#   on a role-empty (human-park) charter — no deadlock.
#
# Modes (self-provability — mirrors tests/690-...test.py and tests/969-api-pagination.test.py):
#   CB_1220_MODE=fixture (default): bundled pre-fix (UNGUARDED) vs post-fix (GUARDED)
#       reference impls. Prove the unguarded impl is a hole (RED) and the guarded impl
#       blocks (GREEN). No real CLI, no gh, no network — green at this leaf's merge point.
#   CB_1220_MODE=source : run the REAL reference/bin/crewboss approve with a `gh` PATH-shim
#       (auth ok, `gh issue view` labels, `gh issue edit` no-op) and a POLICY-NESTED
#       org.json under CB_TEAM. RED against current origin/main (unguarded) — the #1220
#       implementation leaf turns it GREEN. No dependency on a running server.
#
# Fix 2 (policy-nested fixture): every org.json here uses {"policy":{"plan_review_role":...}},
# NOT the flat {"plan_review_role":...} shape that was the root cause of the #690 false-green.
set -uo pipefail

pass=0; fail=0
ok()  { printf 'ok   %s\n' "$*"; pass=$((pass+1)); }
ko()  { printf 'FAIL %s\n' "$*"; fail=$((fail+1)); }

MODE="${CB_1220_MODE:-fixture}"
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd -P "$HERE/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Read the role the production way: (org.policy or {}).plan_review_role
role_of() {
  python3 -c 'import json,sys
try:
    d=json.load(open(sys.argv[1]))
except Exception:
    d={}
print((d.get("policy") or {}).get("plan_review_role",""))' "$1"
}

# ---------------------------------------------------------------------------
# Reference impls of cmd_approve (fixture mode)
#   prefix  = UNGUARDED (mirrors current reference/bin/crewboss cmd_approve)
#   postfix = GUARDED   (the #1220 fix)
# Args: <role> <labels_csv>.  Returns 0 = approved, 1 = blocked/die.
# ---------------------------------------------------------------------------
ref_approve_prefix() {
  # unguarded — always approves regardless of role / plan:agreed
  printf 'approved\n'; return 0
}
ref_approve_postfix() {
  local role="$1" labels="$2"
  if [ -n "$role" ] && ! printf '%s' "$labels" | grep -q 'plan:agreed'; then
    printf 'crewboss: plan-convergence in progress — %s must agree before approve\n' "$role" >&2
    return 1
  fi
  printf 'approved\n'; return 0
}

# ===========================================================================
# fixture mode
# ===========================================================================
echo "=== Fix 2: policy-nested org.json role extraction ==="
printf '{"policy":{"plan_review_role":"analyst"}}' > "$TMP/org-role.json"
printf '{"policy":{}}'                              > "$TMP/org-empty.json"
printf '{"plan_review_role":"analyst"}'             > "$TMP/org-flat.json"
R_NESTED="$(role_of "$TMP/org-role.json")"
R_EMPTY="$(role_of "$TMP/org-empty.json")"
R_FLAT="$(role_of "$TMP/org-flat.json")"
if [ "$R_NESTED" = "analyst" ] && [ -z "$R_FLAT" ]; then
  ok "Fix2: nested policy.plan_review_role='analyst'; FLAT top-level yields '' (false-green root cause)"
else
  ko "Fix2: nested/flat extraction wrong: nested='$R_NESTED' flat='$R_FLAT'"
fi
[ -z "$R_EMPTY" ] && ok "Fix2: empty policy resolves role to '' (human-park / manual mode)" \
                  || ko "Fix2: empty policy role should be '', got '$R_EMPTY'"

echo "=== CLI approve guard: pre-fix (unguarded) vs post-fix (guarded) ==="
LBL_NO_AGREED="type:charter,status:plan-review"
LBL_WITH_AGREED="type:charter,status:plan-review,plan:agreed"

# convergence hole: unguarded approves (RED), guarded dies (GREEN)
if ref_approve_prefix "analyst" "$LBL_NO_AGREED" >/dev/null 2>&1; then
  if ref_approve_postfix "analyst" "$LBL_NO_AGREED" >/dev/null 2>&1; then
    ko "convergence: guarded impl WRONGLY approved (should die)"
  else
    ok "convergence (role set, no plan:agreed): pre-fix approves (HOLE), post-fix DIES (fixed)"
  fi
else
  ko "convergence: unguarded impl did not model the hole (should approve rc0)"
fi

# role-empty human-park: guarded MUST still approve (no deadlock)
if ref_approve_postfix "$R_EMPTY" "$LBL_NO_AGREED" >/dev/null 2>&1; then
  ok "role-empty: guarded impl approves (human-park charter — no deadlock)"
else
  ko "role-empty: guarded impl wrongly blocked (deadlock)"
fi

# convergence complete (role set + plan:agreed): guarded approves
if ref_approve_postfix "analyst" "$LBL_WITH_AGREED" >/dev/null 2>&1; then
  ok "role set + plan:agreed: guarded impl approves (convergence complete)"
else
  ko "role set + plan:agreed: guarded impl wrongly blocked"
fi

# ===========================================================================
# CB_1220_MODE=source — run the REAL reference/bin/crewboss approve
# ===========================================================================
if [ "$MODE" = "source" ]; then
  echo "=== source: real reference/bin/crewboss approve (gh-shimmed) ==="
  CLI="$REPO_ROOT/reference/bin/crewboss"
  if [ ! -x "$CLI" ] && [ ! -f "$CLI" ]; then
    ko "source: reference/bin/crewboss not found at $CLI"
  else
    # gh PATH shim: auth ok, `issue view` returns injected labels, `issue edit` no-op.
    SHIM="$TMP/bin"; mkdir -p "$SHIM"
    cat > "$SHIM/gh" <<'GHSHIM'
#!/usr/bin/env bash
# minimal gh shim for the 1220 CLI approve-guard test
if [ "$1" = "auth" ]; then exit 0; fi
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  printf '%s\n' "${CB_TEST_LABELS_JSON:-{\"labels\":[]}}"; exit 0
fi
if [ "$1" = "issue" ] && [ "$2" = "edit" ]; then exit 0; fi
exit 0
GHSHIM
    chmod +x "$SHIM/gh"

    # org.json fixture dir — cover both CB_TEAM/org.json and CB_HOME/team/org.json
    FIX="$TMP/fix"; mkdir -p "$FIX/team"

    run_cli_approve() { # <org_json_body> <labels_json> ; echoes nothing, returns cli rc
      printf '%s' "$1" > "$FIX/team/org.json"
      cp "$FIX/team/org.json" "$FIX/org.json"
      CB_TEST_LABELS_JSON="$2" \
      CB_HOME="$FIX" CB_TEAM="$FIX/team" CB_REPO="x/y" \
      PATH="$SHIM:$PATH" \
        bash "$CLI" approve 42 >/dev/null 2>&1
      return $?
    }

    LBL_JSON_NO_AGREED='{"labels":[{"name":"status:plan-review"}]}'
    LBL_JSON_WITH_AGREED='{"labels":[{"name":"status:plan-review"},{"name":"plan:agreed"}]}'

    # (b) convergence charter -> approve MUST die
    if run_cli_approve '{"policy":{"plan_review_role":"analyst"}}' "$LBL_JSON_NO_AGREED"; then
      ko "source (b): CLI approve SUCCEEDED for convergence charter (unguarded hole)"
    else
      ok "source (b): CLI approve DIES for convergence charter (role set, no plan:agreed)"
    fi

    # (a) role-empty human-park charter -> approve MUST succeed
    if run_cli_approve '{"policy":{}}' "$LBL_JSON_NO_AGREED"; then
      ok "source (a): CLI approve SUCCEEDS for role-empty human-park charter (no deadlock)"
    else
      ko "source (a): CLI approve wrongly DIED for role-empty charter (deadlock)"
    fi

    # (b') role set + plan:agreed -> approve MUST succeed
    if run_cli_approve '{"policy":{"plan_review_role":"analyst"}}' "$LBL_JSON_WITH_AGREED"; then
      ok "source (b'): CLI approve SUCCEEDS once plan:agreed present (convergence complete)"
    else
      ko "source (b'): CLI approve wrongly DIED with plan:agreed present"
    fi
  fi
fi

echo
printf '=== SUMMARY (mode=%s): %d passed, %d failed ===\n' "$MODE" "$pass" "$fail"
[ "$fail" -eq 0 ]
