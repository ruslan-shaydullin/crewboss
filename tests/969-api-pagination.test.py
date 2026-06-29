#!/usr/bin/env python3
"""969-api-pagination.test.py — python/api-surface regression for the #969
pagination/state-window class.  Charter: #995 / issue: #1015.

Surface covered: ui/server/crewboss-api.py  (build_state() / search_board()).

Defects guarded (live-only breakages #969 shipped green):
  D2  client pagination MUST terminate under a hard page/time bound.  The old
      `while True:` + `if not batch: break` spun forever the moment gh returned a
      non-empty error OBJECT (HTTP 422/403 rate-limit) instead of an empty list —
      `if not batch` is False on a dict, so /api/state hung (HTTP 000, 40s+).
  D3  closed->done classification MUST be case-insensitive.  gh REST returns
      lowercase "closed" (the migrated-from `gh issue list` returned "CLOSED");
      `state == "CLOSED"` then misclassified a merged/closed leaf carrying a
      residual `status:review` label as "review" (phantom awaiting integrators).

Modes (self-provability — see issue #1015 "## Self-provability"):
  CB_969_MODE=fixture (default): bundled pre-fix/post-fix reference impls.  Prove
      RED on the pre-fix impl, GREEN on the post-fix impl.  No network, no import
      of the real module — runnable at this leaf's own merge point.
  CB_969_MODE=source : import the REAL crewboss-api.py, monkeypatch its `sh`, and
      assert build_state() terminates + classifies case-insensitively.  Owned by
      the impl leaves at merge (the real tree on this branch already satisfies it).
"""
import os, sys, json, time

MODE = os.environ.get("CB_969_MODE", "fixture")
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
# A fake gh `sh` whose PAST-THE-END response is a non-empty error OBJECT (not an
# empty list) — the exact #969 trap that defeated `if not batch:`.
# ---------------------------------------------------------------------------
def make_sh(real_pages):
    state = {"calls": 0}

    def sh(args, timeout=30):
        state["calls"] += 1
        page = 1
        for a in args:
            if isinstance(a, str) and a.startswith("page="):
                page = int(a.split("=", 1)[1])
        if page <= real_pages:
            # a full page of 100 CLOSED issues carrying a residual review label
            return json.dumps([
                {"number": 1000 + page * 100 + i,
                 "state": "closed",
                 "labels": [{"name": "status:review"}],
                 "title": "leaf", "body": ""}
                for i in range(100)
            ])
        # past the end: a 403/422 returns a non-empty JSON OBJECT (the trap)
        return json.dumps({"message": "API rate limit exceeded"})

    return sh, state


# --- pre-fix paginator (BROKEN): unbounded, no list-guard --------------------
def prefix_paginate(sh, safety=5000):
    all_issues = []
    page = 1
    spins = 0
    while True:
        spins += 1
        if spins > safety:          # test-only guard so we never hang the harness
            return all_issues, spins, False   # did NOT terminate on its own
        raw = sh(["gh", "api", "/repos/x/y/issues", "-F", "state=all",
                  "-F", "per_page=100", "-F", "page=%d" % page])
        try:
            batch = json.loads(raw)
        except Exception:
            break
        if not batch:               # empty list -> stop (an error OBJECT is truthy!)
            break
        all_issues.extend(batch)
        page += 1
    return all_issues, spins, True


# --- post-fix paginator (FIXED): bounded + list-guard + short-page -----------
def postfix_paginate(sh, max_pages=100):
    all_issues = []
    page = 1
    while page <= max_pages:
        raw = sh(["gh", "api", "-X", "GET", "/repos/x/y/issues", "-F", "state=all",
                  "-F", "per_page=100", "-F", "page=%d" % page])
        try:
            batch = json.loads(raw)
        except Exception:
            break
        if not isinstance(batch, list) or not batch:
            break
        all_issues.extend(batch)
        if len(batch) < 100:
            break
        page += 1
    return all_issues


# --- classification fixtures -------------------------------------------------
def prefix_classify(state, labels):
    if state == "CLOSED":
        return "done"
    if "status:review" in labels:
        return "review"
    return "open"


def postfix_classify(state, labels):
    if (state or "").upper() == "CLOSED":
        return "done"
    if "status:review" in labels:
        return "review"
    return "open"


# ===========================================================================
# D2 — bounded pagination
# ===========================================================================
print("=== D2: bounded pagination terminates (no while-True hang) ===")
sh_a, _ = make_sh(3)
_, spins, terminated = prefix_paginate(sh_a)
if not terminated:
    ok("D2 pre-fix paginator does NOT self-terminate (hits safety cap, spins=%d) — RED" % spins)
else:
    ko("D2 pre-fix paginator unexpectedly self-terminated (trap not modelled)")

sh_b, st_b = make_sh(3)
t0 = time.time()
res = postfix_paginate(sh_b)
dt = time.time() - t0
if st_b["calls"] <= 100 and dt < 5:
    ok("D2 post-fix paginator terminates in %d calls, %.3fs (bounded) — GREEN" % (st_b["calls"], dt))
else:
    ko("D2 post-fix paginator did not bound cleanly: calls=%d dt=%.3fs" % (st_b["calls"], dt))

# ===========================================================================
# D3 — case-insensitive closed->done classification
# ===========================================================================
print("=== D3: case-insensitive 'closed' -> 'done' classification ===")
pre = prefix_classify("closed", ["status:review"])
post = postfix_classify("closed", ["status:review"])
if pre == "review" and post == "done":
    ok("D3 closed+review: pre-fix='review' (BUG), post-fix='done' (FIXED)")
else:
    ko("D3 discrimination failed: pre-fix=%r post-fix=%r" % (pre, post))
if postfix_classify("CLOSED", []) == "done" and postfix_classify("closed", []) == "done":
    ok("D3 post-fix classifies BOTH 'CLOSED' and 'closed' as done (case-insensitive)")
else:
    ko("D3 post-fix not case-insensitive for the bare-closed case")

# ===========================================================================
# CB_969_MODE=source — exercise the REAL crewboss-api.py
# ===========================================================================
if MODE == "source":
    print("=== source: real crewboss-api.py build_state() terminates + classifies ===")
    import importlib.util
    here = os.path.dirname(os.path.abspath(__file__))
    api_path = os.path.join(here, "..", "ui", "server", "crewboss-api.py")
    api_path = os.path.normpath(api_path)
    if not os.path.exists(api_path):
        ko("source: crewboss-api.py not found at %s" % api_path)
    else:
        os.environ["CB_REPO"] = "x/y"          # REPO must be truthy for build_state
        spec = importlib.util.spec_from_file_location("crewboss_api_under_test", api_path)
        mod = importlib.util.module_from_spec(spec)
        try:
            spec.loader.exec_module(mod)
            # monkeypatch the real module's gh shell so no network is touched and the
            # #969 trap (non-empty error object past the end) is in play.
            sh_src, st_src = make_sh(2)
            mod.sh = sh_src
            mod.REPO = "x/y"
            t0 = time.time()
            state = mod.build_state()
            dt = time.time() - t0
            if dt < 10:
                ok("source: build_state() terminated in %.3fs (bounded — no #969 hang)" % dt)
            else:
                ko("source: build_state() took %.3fs (suspected hang)" % dt)
            board = state.get("board", [])
            closed_items = [b for b in board if b.get("state") == "done"]
            misclassified = [b for b in board
                             if b.get("state") == "review"
                             and "status:review" in b.get("labels", [])]
            if closed_items and not misclassified:
                ok("source: closed+review leaves classify as 'done' (%d done, 0 misclassified)"
                   % len(closed_items))
            else:
                ko("source: classification wrong — done=%d misclassified-as-review=%d"
                   % (len(closed_items), len(misclassified)))
        except Exception as e:
            ko("source: importing/running real crewboss-api.py raised %r" % e)

print()
print("=== SUMMARY (mode=%s): %d passed, %d failed ===" % (MODE, _pass, _fail))
sys.exit(0 if _fail == 0 else 1)
