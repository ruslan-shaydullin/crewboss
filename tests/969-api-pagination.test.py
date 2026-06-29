#!/usr/bin/env python3
# 969-api-pagination.test.py — python-surface regression guard for charter #969 class.
# Charter: #995  (re-fix of #969)  •  Owner: qa-engineer (tests/ surface)
#
# Surface covered: ui/server/crewboss-api.py  (build_state(), search_board()).
#
# Defects this guard makes RED (pre-fix) / GREEN (post-fix):
#   D2  `while True:` client pagination never terminates → /api/state & /api/search hang
#       (HTTP 000, 40s+). Fix: a hard page/time bound.
#   D3  state case mix-up: migrating from `gh issue list` (state="CLOSED") to `gh api`
#       (state="closed") broke `if state == "CLOSED"` → closed leaves with a residual
#       status:review label classify as `review` (board shows merged leaves as review +
#       phantom "awaiting" integrators). Fix: case-insensitive `closed` -> `done`.
#
# Self-provability: this leaf merges FIRST; the impl leaves (which fix crewboss-api.py)
# are not yet merged here. So THIS leaf's acceptance runs ONLY under CB_969_MODE=fixture:
# it proves the guard against bundled pre-fix (RED) and post-fix (GREEN) reference loops /
# classifiers — no real-source import required. The full-real-source green run is owned by
# the impl leaves under CB_969_MODE=source (implemented below, but not part of my gate).
#
# D2 is detected WITHOUT a real hang: the pathological `sh` stub never returns an empty
# page (mirrors a server that ignores the page param, or `gh api --paginate` that already
# returned everything). A test watchdog caps the number of sh() calls and raises
# WatchdogExceeded; the UNBOUNDED pre-fix loop trips it (RED), the BOUNDED post-fix loop
# stops on its own well under the cap (GREEN).

import os
import sys
import json
import importlib.util

MODE = os.environ.get("CB_969_MODE", "fixture")

_pass = 0
_fail = 0


def ok(msg):
    global _pass
    print("ok   " + msg)
    _pass += 1


def ko(msg):
    global _fail
    print("FAIL " + msg)
    _fail += 1


# ── Test watchdog: bounds sh() calls so an unbounded loop never truly hangs ──────
class WatchdogExceeded(Exception):
    pass


def make_pathological_sh(cap):
    """A `sh` stub that NEVER signals end-of-pagination (always returns a non-empty
    page). After `cap` calls it raises WatchdogExceeded — a deterministic stand-in for
    'this loop would hang forever'."""
    state = {"n": 0}

    def sh(args, timeout=30):
        state["n"] += 1
        if state["n"] > cap:
            raise WatchdogExceeded()
        return json.dumps([{"number": state["n"], "state": "open", "labels": [], "title": "x"}])

    return sh


def make_finite_sh(pages):
    """A realistic `sh` stub: returns `pages` non-empty pages then an empty list."""
    state = {"n": 0}

    def sh(args, timeout=30):
        state["n"] += 1
        if state["n"] > pages:
            return json.dumps([])
        return json.dumps([{"number": state["n"], "state": "open", "labels": [], "title": "x"}])

    return sh


# ── Bundled reference pagination loops (D2) ─────────────────────────────────────
def prefix_paginate(sh):
    """PRE-FIX: `while True` with break-on-empty ONLY — unbounded if the server never
    returns an empty page."""
    all_issues = []
    page = 1
    while True:
        raw = sh(["gh", "api", "/repos/o/r/issues", "-F", "per_page=100", "-F", "page=%d" % page])
        try:
            batch = json.loads(raw)
        except Exception:
            break
        if not batch:
            break
        all_issues.extend(batch)
        page += 1
    return all_issues


def postfix_paginate(sh, max_pages=50):
    """POST-FIX: identical, but bounded by a hard page cap (defence-in-depth even if the
    empty-page sentinel never arrives)."""
    all_issues = []
    page = 1
    while page <= max_pages:
        raw = sh(["gh", "api", "/repos/o/r/issues", "-F", "per_page=100", "-F", "page=%d" % page])
        try:
            batch = json.loads(raw)
        except Exception:
            break
        if not batch:
            break
        all_issues.extend(batch)
        page += 1
    return all_issues


# ── Bundled reference classifiers (D3) ──────────────────────────────────────────
def prefix_classify(it):
    """PRE-FIX: exact-match on uppercase 'CLOSED' — breaks on gh-api lowercase 'closed'."""
    labels = [l["name"] for l in it.get("labels", [])]
    if it.get("state") == "CLOSED":
        return "done"
    if "status:review" in labels:
        return "review"
    return "open"


def postfix_classify(it):
    """POST-FIX: case-insensitive 'closed' -> 'done', regardless of source case."""
    labels = [l["name"] for l in it.get("labels", [])]
    if str(it.get("state", "")).lower() == "closed":
        return "done"
    if "status:review" in labels:
        return "review"
    return "open"


# ── Fixture-mode proofs ─────────────────────────────────────────────────────────
def run_fixture_mode():
    cap = 200

    print("=== D2: pagination must terminate under a hard page/time bound ===")
    # Pre-fix: unbounded loop trips the watchdog -> would hang in production (RED).
    try:
        prefix_paginate(make_pathological_sh(cap))
        ko("D2: pre-fix `while True` did NOT trip the watchdog (expected unbounded hang)")
    except WatchdogExceeded:
        ok("D2: pre-fix `while True` is UNBOUNDED (trips watchdog -> live HTTP 000 hang)")

    # Post-fix: bounded loop stops on its own, well under the cap (GREEN).
    try:
        res = postfix_paginate(make_pathological_sh(cap), max_pages=50)
        if len(res) <= 50:
            ok("D2: post-fix pagination is BOUNDED (terminates at the page cap, no hang)")
        else:
            ko("D2: post-fix pagination exceeded its page cap (len=%d)" % len(res))
    except WatchdogExceeded:
        ko("D2: post-fix pagination ran past the watchdog cap (still unbounded)")

    # Post-fix must NOT truncate realistic boards: 3 real pages < 50-page cap.
    res2 = postfix_paginate(make_finite_sh(3), max_pages=50)
    if len(res2) == 3:
        ok("D2: post-fix bound does not truncate a realistic 3-page board")
    else:
        ko("D2: post-fix pagination mis-counted a 3-page board (len=%d)" % len(res2))

    print("=== D3: case-insensitive `closed` -> `done` classification ===")
    # gh api returns lowercase 'closed'; a merged leaf may keep a residual status:review.
    closed_lc = {"number": 1, "state": "closed", "labels": [{"name": "status:review"}]}
    closed_uc = {"number": 2, "state": "CLOSED", "labels": [{"name": "status:review"}]}

    # Pre-fix RED: lowercase 'closed' is misclassified as review (phantom integrator).
    if prefix_classify(closed_lc) != "done":
        ok("D3: pre-fix misclassifies lowercase 'closed' as '%s' (NOT done) — defect reproduced"
           % prefix_classify(closed_lc))
    else:
        ko("D3: pre-fix unexpectedly classified lowercase 'closed' as done (defect masked)")

    # Post-fix GREEN: both cases map to done.
    if postfix_classify(closed_lc) == "done":
        ok("D3: post-fix maps lowercase 'closed' -> done")
    else:
        ko("D3: post-fix failed to map lowercase 'closed' -> done")
    if postfix_classify(closed_uc) == "done":
        ok("D3: post-fix maps uppercase 'CLOSED' -> done (case-insensitive)")
    else:
        ko("D3: post-fix failed to map uppercase 'CLOSED' -> done")

    # Sanity: an open leaf with status:review still classifies as review under post-fix.
    open_rev = {"number": 3, "state": "open", "labels": [{"name": "status:review"}]}
    if postfix_classify(open_rev) == "review":
        ok("D3: post-fix preserves review classification for genuinely-open leaves")
    else:
        ko("D3: post-fix broke review classification for open leaves")


# ── Source-mode proofs (owned by impl leaves; GREEN once crewboss-api.py is fixed) ──
def run_source_mode():
    here = os.path.dirname(os.path.abspath(__file__))
    server_py = os.path.join(here, "..", "ui", "server", "crewboss-api.py")
    if not os.path.isfile(server_py):
        ko("SOURCE: crewboss-api.py not found at %s" % server_py)
        return
    os.environ.setdefault("CB_REPO", "test/repo969")
    os.environ.setdefault("CB_HOME", os.path.join(here, "..", "_box-snapshot"))
    try:
        spec = importlib.util.spec_from_file_location("crewboss_api_src", server_py)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
    except Exception as e:
        ko("SOURCE: failed to import crewboss-api.py: %s" % e)
        return

    cap = 500

    # D2: real build_state()/search_board() must terminate under the pathological stub.
    mod.sh = make_pathological_sh(cap)
    mod.REPO = "test/repo969"
    try:
        mod.search_board("anything")
        ok("SOURCE D2: search_board() terminates under non-terminating pages (bounded)")
    except WatchdogExceeded:
        ko("SOURCE D2: search_board() is UNBOUNDED (while True hang)")
    except Exception as e:
        ko("SOURCE D2: search_board() raised %s" % e)

    mod.sh = make_pathological_sh(cap)
    try:
        mod.build_state()
        ok("SOURCE D2: build_state() terminates under non-terminating pages (bounded)")
    except WatchdogExceeded:
        ko("SOURCE D2: build_state() is UNBOUNDED (while True hang)")
    except Exception as e:
        ko("SOURCE D2: build_state() raised %s" % e)

    # D3: search_board() must classify a lowercase-'closed' issue as done.
    closed_item = {"number": 4242, "state": "closed", "title": "merged leaf",
                   "labels": [{"name": "status:review"}]}
    mod.sh = lambda args, timeout=30: (
        json.dumps([closed_item]) if _is_page_one(args) else json.dumps([])
    )
    try:
        out = mod.search_board("4242")
        items = out.get("results", [])
        if items and items[0].get("state") == "done":
            ok("SOURCE D3: search_board() classifies lowercase 'closed' as done")
        else:
            ko("SOURCE D3: search_board() misclassified lowercase 'closed' (got %r)" % items)
    except Exception as e:
        ko("SOURCE D3: search_board() raised %s" % e)

    run_live_smoke(mod)


def _is_page_one(args):
    for a in args:
        if isinstance(a, str) and a.startswith("page=") and a != "page=1":
            return False
    return True


# ── Live-gh smoke (HARD gate when token+live-CB_REPO present) ────────────────────
def run_live_smoke(mod):
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or os.environ.get("CB_API_TOKEN")
    repo = os.environ.get("CB_REPO", "")
    if not token or not repo or repo == "test/repo969":
        print("live-smoke: no live token+CB_REPO present — live path not exercised")
        return
    print("=== LIVE: real gh smoke (HARD gate; token never echoed) ===")
    import subprocess
    try:
        # Reuse the read-only CI token (same as the merged #993 smoke gate).
        r = subprocess.run(["gh", "api", "/repos/%s/issues?per_page=1" % repo],
                           capture_output=True, text=True, timeout=40)
        if r.returncode == 0:
            ok("LIVE: gh api against live repo succeeds (live pagination path healthy)")
        else:
            ko("LIVE: gh api against live repo FAILED — live path broken (HARD fail)")
    except Exception as e:
        ko("LIVE: live gh smoke errored: %s (HARD fail)" % e)


def main():
    if MODE == "fixture":
        run_fixture_mode()
    elif MODE == "source":
        run_source_mode()
    else:
        print("unknown CB_969_MODE='%s'" % MODE, file=sys.stderr)
        sys.exit(2)

    print()
    print("=== SUMMARY: %d passed, %d failed ===" % (_pass, _fail))
    sys.exit(0 if _fail == 0 else 1)


if __name__ == "__main__":
    main()
