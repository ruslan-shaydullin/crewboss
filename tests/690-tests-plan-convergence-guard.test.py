#!/usr/bin/env python3
"""690-tests-plan-convergence-guard.test.py — plan-convergence approve-guard tests.
Charter: #1220 (P1 of milestone #1219 / docs/design/plan-oversight-strategy.md).

Converted from the original .sh test.  The .sh version was a FALSE-GREEN: it tested
the guard logic ONLY in an embedded reference-impl while the production bug lived on,
and it read the *flat* `plan_review_role` top-level key while production reads the
*nested* `(_org.get("policy") or {}).get("plan_review_role", "")` (crewboss-api.py ~789).

Root defect (one root, three sites):
  build_state() and the approve-guard in ui/server/crewboss-api.py, plus cmd_approve in
  reference/bin/crewboss, all compute the approve-gate WITHOUT the `plan_review_role != ""`
  check the launcher performs.  Consequences:
    (1) Deadlock — a role-empty human-park charter in status:plan-review (no plan:agreed)
        gets plan_convergence_active=True (Approve button hidden) AND approve rejected with
        an empty role name -> the charter cannot be approved from the cockpit.
    (2) CLI hole — `crewboss approve <N>` is unguarded (covered by 1220-cli-approve-guard).
    (3) False-green — the old .sh test.

Correct condition at ALL three sites:
    block / hide  <=>  plan_review_role != ""  AND  "plan:agreed" absent
  (build_state additionally scopes to state == "plan-review").
  role-empty charters must be approvable and must NOT show "convergence in progress".

Modes (self-provability — mirrors tests/969-api-pagination.test.py and
tests/1131-build-state-nonlist.test.py):
  CB_690_MODE=fixture (default): bundled pre-fix (BROKEN) / post-fix (FIXED) reference
      impls.  Prove RED on the pre-fix impl, GREEN on the post-fix impl.  No import of the
      real module, no server, no network — green at this leaf's own merge point.
  CB_690_MODE=source : import the REAL ui/server/crewboss-api.py, monkeypatch `sh` (label
      fetch) and `read_json` (org.json injection), and call the real do_command("approve")
      and build_state() directly.  Fixtures use the production POLICY-NESTED structure
      {"policy": {"plan_review_role": "analyst"}}.  These assertions are RED against current
      origin/main production code (TDD) — the charter #1220 implementation leaves turn them
      GREEN.  No dependency on a running server.
"""
import os, sys, json

MODE = os.environ.get("CB_690_MODE", "fixture")
_pass = 0
_fail = 0


def ok(m):
    global _pass
    _pass += 1
    print("ok   " + m)


def ko(m):
    global _fail
    _fail += 1
    print("FAIL " + m)


# ---------------------------------------------------------------------------
# Fix 2 — policy-nested role extraction.  Production reads the role from the
# `policy` sub-dict of org.json; the OLD .sh fixture used a flat top-level key,
# which is the root cause of its false-green (reference-impl read top-level,
# production read policy.*).  Every source-mode fixture below uses the nested form.
# ---------------------------------------------------------------------------
def role_of(org):
    """Mirror of crewboss-api.py ~789: (_org.get('policy') or {}).get('plan_review_role','')."""
    return (org.get("policy") or {}).get("plan_review_role", "")


# ---------------------------------------------------------------------------
# build_state plan_convergence_active — reference impls
#   pre-fix (BROKEN): replica of crewboss-api.py lines ~541-544 (no role check):
#       if state == "plan-review": pca = "plan:agreed" not in labels
#       else:                      pca = False
#   post-fix (FIXED): role check added.
# ---------------------------------------------------------------------------
def pca_prefix(state, labels, plan_review_role):
    if state == "plan-review":
        return "plan:agreed" not in labels
    return False


def pca_postfix(state, labels, plan_review_role):
    return bool(plan_review_role) and state == "plan-review" and "plan:agreed" not in labels


# ---------------------------------------------------------------------------
# do_command approve-guard — reference impls
#   pre-fix (BROKEN): replica of crewboss-api.py lines ~795-796 — gates on the
#       status:plan-review label + plan:agreed, but NOT on plan_review_role, so a
#       role-empty charter is wrongly rejected (the deadlock).
#   post-fix (FIXED): reject only when role set AND plan:agreed absent.
# ---------------------------------------------------------------------------
def approve_prefix(plan_review_role, labels):
    if "status:plan-review" in labels and "plan:agreed" not in labels:
        return {"ok": False, "msg": "plan-convergence in progress — %s must agree before approve" % plan_review_role}
    return {"ok": True, "msg": "approved"}


def approve_postfix(plan_review_role, labels):
    if plan_review_role and "plan:agreed" not in labels:
        return {"ok": False, "msg": "plan-convergence in progress — %s must agree before approve" % plan_review_role}
    return {"ok": True, "msg": "approved"}


LBL_NO_AGREED   = ["type:charter", "status:plan-review"]
LBL_WITH_AGREED = ["type:charter", "status:plan-review", "plan:agreed"]

# Policy-NESTED fixtures (Fix 2).  role_of() must read the nested key.
ORG_ROLE    = {"policy": {"plan_review_role": "analyst"}, "repo": "test/repo"}
ORG_NO_ROLE = {"policy": {}, "repo": "test/repo"}
ORG_EMPTY   = {"policy": {"plan_review_role": ""}, "repo": "test/repo"}
ORG_FLAT    = {"plan_review_role": "analyst"}  # the OLD .sh (wrong) shape

# ===========================================================================
# fixture mode
# ===========================================================================
print("=== Fix 2: policy-nested role extraction (root cause of the false-green) ===")
if role_of(ORG_ROLE) == "analyst" and role_of(ORG_FLAT) == "":
    ok("Fix2: role_of() reads policy.plan_review_role; a FLAT {plan_review_role} yields '' "
       "(the exact false-green the old .sh hid behind)")
else:
    ko("Fix2: nested/flat discrimination failed: nested=%r flat=%r"
       % (role_of(ORG_ROLE), role_of(ORG_FLAT)))
if role_of(ORG_NO_ROLE) == "" and role_of(ORG_EMPTY) == "":
    ok("Fix2: missing / empty policy role both resolve to '' (manual-mode / human-park)")
else:
    ko("Fix2: empty-role resolution wrong")

print("=== build_state plan_convergence_active: pre-fix vs post-fix ===")
# role-empty deadlock — the headline defect
if pca_prefix("plan-review", LBL_NO_AGREED, "") is True and \
   pca_postfix("plan-review", LBL_NO_AGREED, "") is False:
    ok("PCA role-empty: pre-fix=True (Approve button HIDDEN — deadlock), post-fix=False (FIXED)")
else:
    ko("PCA role-empty discrimination failed: pre=%r post=%r"
       % (pca_prefix("plan-review", LBL_NO_AGREED, ""), pca_postfix("plan-review", LBL_NO_AGREED, "")))

# convergence charter — both must be True (correct)
if pca_prefix("plan-review", LBL_NO_AGREED, "analyst") is True and \
   pca_postfix("plan-review", LBL_NO_AGREED, "analyst") is True:
    ok("PCA convergence (role set, no plan:agreed): active=True at both impls")
else:
    ko("PCA convergence should be True at both impls")

# plan:agreed present — convergence complete -> False
if pca_postfix("plan-review", LBL_WITH_AGREED, "analyst") is False:
    ok("PCA plan:agreed present: active=False (convergence complete)")
else:
    ko("PCA should be False once plan:agreed present")

# non plan-review state -> always False
if pca_postfix("approved", LBL_NO_AGREED, "analyst") is False:
    ok("PCA non-plan-review state: active=False even with role set")
else:
    ko("PCA should be False for non-plan-review state")

print("=== approve-guard: pre-fix vs post-fix ===")
# role-empty deadlock at the approve site
pre_a  = approve_prefix("", LBL_NO_AGREED)
post_a = approve_postfix("", LBL_NO_AGREED)
if pre_a.get("ok") is False and post_a.get("ok") is True:
    ok("approve role-empty: pre-fix ok=False (deadlock — cannot approve), post-fix ok=True (FIXED)")
else:
    ko("approve role-empty discrimination failed: pre=%r post=%r" % (pre_a, post_a))

# convergence charter — reject at both impls
if approve_prefix("analyst", LBL_NO_AGREED).get("ok") is False and \
   approve_postfix("analyst", LBL_NO_AGREED).get("ok") is False:
    ok("approve convergence (role set, no plan:agreed): REJECTED at both impls")
else:
    ko("approve convergence should be rejected")

# plan:agreed present with role set — approve permitted
resp = approve_postfix("analyst", LBL_WITH_AGREED)
if resp.get("ok") is True:
    ok("approve plan:agreed present: ok=True (convergence complete)")
else:
    ko("approve should be permitted once plan:agreed present: %r" % resp)

print("=== acceptance matrix (post-fix reference impl) ===")
# (a) role-empty charter: active=False (button visible) AND approve succeeds
if pca_postfix("plan-review", LBL_NO_AGREED, role_of(ORG_NO_ROLE)) is False and \
   approve_postfix(role_of(ORG_NO_ROLE), LBL_NO_AGREED).get("ok") is True:
    ok("(a) role-empty: plan_convergence_active=False + approve succeeds — deadlock gone")
else:
    ko("(a) role-empty acceptance failed")
# (b) convergence charter: active=True AND approve rejected
if pca_postfix("plan-review", LBL_NO_AGREED, role_of(ORG_ROLE)) is True and \
   approve_postfix(role_of(ORG_ROLE), LBL_NO_AGREED).get("ok") is False:
    ok("(b) convergence: plan_convergence_active=True + approve rejected")
else:
    ko("(b) convergence acceptance failed")
# (c) additive: a board item carries plan_review_role (string)
_item = {"n": 42, "state": "plan-review", "kind": "charter",
         "labels": LBL_NO_AGREED, "plan_convergence_active": True,
         "plan_review_role": role_of(ORG_ROLE)}
if isinstance(_item.get("plan_review_role"), str) and _item["plan_review_role"] == "analyst":
    ok("(c) additive: board item carries plan_review_role (string) = %r" % _item["plan_review_role"])
else:
    ko("(c) plan_review_role field not a proper string: %r" % _item.get("plan_review_role"))

# ===========================================================================
# CB_690_MODE=source — exercise the REAL crewboss-api.py
# ===========================================================================
if MODE == "source":
    print("=== source: real crewboss-api.py do_command('approve') + build_state() ===")
    import importlib.util
    here = os.path.dirname(os.path.abspath(__file__))
    api_path = os.path.normpath(os.path.join(here, "..", "ui", "server", "crewboss-api.py"))
    if not os.path.exists(api_path):
        ko("source: crewboss-api.py not found at %s" % api_path)
    else:
        os.environ["CB_REPO"] = "x/y"          # REPO must be truthy for build_state
        spec = importlib.util.spec_from_file_location("crewboss_api_690", api_path)
        mod = importlib.util.module_from_spec(spec)
        try:
            spec.loader.exec_module(mod)
            mod.REPO = "x/y"

            # -- real do_command('approve') under injected org.json + live labels --
            def run_approve(org, live_labels):
                def rj(path, default):
                    if str(path).endswith("org.json"):
                        return org
                    return default
                def sh_stub(args, timeout=30):
                    a = args or []
                    if "view" in a:            # gh issue view N --json labels
                        return json.dumps({"labels": [{"name": l} for l in live_labels]})
                    return ""                  # gh issue edit (approve write)
                mod.read_json = rj
                mod.sh = sh_stub
                return mod.do_command({"action": "approve", "number": 42})

            # (a) role-empty human-park charter -> approve MUST succeed (deadlock gone)
            resp_a = run_approve(ORG_NO_ROLE, LBL_NO_AGREED)
            if isinstance(resp_a, dict) and resp_a.get("ok") is True:
                ok("source (a): role-empty approve SUCCEEDS — deadlock gone (GREEN)")
            else:
                ko("source (a): role-empty approve rejected (deadlock present) -> %r" % resp_a)

            # (b) convergence charter (role set, no plan:agreed) -> approve MUST be rejected
            resp_b = run_approve(ORG_ROLE, LBL_NO_AGREED)
            if isinstance(resp_b, dict) and resp_b.get("ok") is False:
                ok("source (b): convergence approve REJECTED (role set, no plan:agreed)")
            else:
                ko("source (b): convergence approve NOT rejected -> %r" % resp_b)

            # (b') role set AND plan:agreed present -> approve permitted
            resp_bp = run_approve(ORG_ROLE, LBL_WITH_AGREED)
            if isinstance(resp_bp, dict) and resp_bp.get("ok") is True:
                ok("source (b'): role set + plan:agreed -> approve permitted (convergence complete)")
            else:
                ko("source (b'): approve should be permitted once plan:agreed present -> %r" % resp_bp)

            # -- real build_state() with one injected charter #42 in plan-review --
            def run_build_state(org):
                def rj(path, default):
                    if str(path).endswith("org.json"):
                        return org
                    return default
                def sh_stub(args, timeout=30):
                    a = args or []
                    if "--include" in a:
                        body = json.dumps([{
                            "number": 42, "state": "open", "title": "Charter",
                            "labels": [{"name": "type:charter"},
                                       {"name": "status:plan-review"}],
                            "body": "",
                        }])
                        return "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n" + body
                    return "[]"
                mod.read_json = rj
                mod.sh = sh_stub
                orig_paginate = mod.paginate_issues
                mod.paginate_issues = lambda: []
                try:
                    return mod.build_state()
                finally:
                    mod.paginate_issues = orig_paginate

            def item42(state):
                for b in (state.get("board", []) if isinstance(state, dict) else []):
                    if b.get("n") == 42:
                        return b
                return None

            # (a) build_state role-empty -> plan_convergence_active == False (button visible)
            st_a = run_build_state(ORG_NO_ROLE)
            it_a = item42(st_a)
            if it_a is not None and it_a.get("plan_convergence_active") is False:
                ok("source (a): build_state plan_convergence_active=False for role-empty charter")
            else:
                ko("source (a): plan_convergence_active not False for role-empty -> %r"
                   % (it_a and it_a.get("plan_convergence_active")))

            # (b) build_state convergence -> plan_convergence_active == True
            st_b = run_build_state(ORG_ROLE)
            it_b = item42(st_b)
            if it_b is not None and it_b.get("plan_convergence_active") is True:
                ok("source (b): build_state plan_convergence_active=True for convergence charter")
            else:
                ko("source (b): plan_convergence_active not True for convergence -> %r"
                   % (it_b and it_b.get("plan_convergence_active")))

            # (c) additive: build_state output carries plan_review_role (string)
            if it_b is not None and isinstance(it_b.get("plan_review_role"), str):
                ok("source (c): build_state item carries plan_review_role (string) = %r"
                   % it_b.get("plan_review_role"))
            else:
                ko("source (c): build_state item missing string plan_review_role -> %r"
                   % (it_b and it_b.get("plan_review_role")))

        except Exception as e:
            ko("source: importing/running real crewboss-api.py raised %r" % e)

print()
print("=== SUMMARY (mode=%s): %d passed, %d failed ===" % (MODE, _pass, _fail))
sys.exit(0 if _fail == 0 else 1)
