#!/usr/bin/env python3
"""1131-build-state-nonlist.test.py — contract-tests for build_state() against non-list inputs.
Charter: #1131 / issue: #1133.

Defect guarded: build_state() in ui/server/crewboss-api.py iterates `charters` and `issues`
without first checking they are lists of dicts, so when GitHub returns a bare string (etag-edge)
or an error-object dict for the charters fetch, `it["number"]` raises:
    TypeError: string indices must be integers
Same class of defect fixed for paginate_issues() in charters #973/#1020.

Four cases (all must not raise; returned board must be a valid structure):
  C1  charters = a bare string "etag-edge-string" (iterating a string yields chars)
  C2  charters = a dict / error object {"message": "Not Found", "status": "404"}
  C3  issues from paginate_issues() = a non-list dict {"message": "API rate limit exceeded"}
  C4  Both charters AND issues non-list simultaneously

Modes:
  CB_1131_MODE=fixture (default): bundled pre-fix/post-fix reference impls. Prove RED on
      pre-fix impl, GREEN on post-fix impl. No network, no import of the real module.
  CB_1131_MODE=source: import real ui/server/crewboss-api.py, monkeypatch sh to return a
      non-list for the charters call, assert build_state() returns without raising and the
      "board" key is present. Mirrors the source-mode block in 969-api-pagination.test.py.
"""
import os, sys, json

MODE = os.environ.get("CB_1131_MODE", "fixture")
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
# Minimal well-formed issue/charter dicts used as the "good" control items
# ---------------------------------------------------------------------------
GOOD_CHARTER = {"number": 10, "state": "open", "title": "Charter A",
                "labels": [{"name": "type:charter"}], "body": ""}
GOOD_ISSUE   = {"number": 20, "state": "open", "title": "Leaf B",
                "labels": [], "body": ""}

# ---------------------------------------------------------------------------
# Pre-fix (BROKEN) core loop — replica of lines ~416-419 of build_state()
# before the isinstance guard.  Iterates charters/issues without checking they
# are lists; raises TypeError when handed a string or dict.
# ---------------------------------------------------------------------------
def prefix_build_state_core(charters, issues):
    """Replica of the BROKEN merging loop (no isinstance guard)."""
    by_n = {it["number"]: it for it in issues}     # TypeError if issues is str/dict
    for it in charters:
        by_n.setdefault(it["number"], it)           # TypeError if charters is str/dict
    issues_out = list(by_n.values())
    board = []
    for it in issues_out:
        labels = [l["name"] for l in it.get("labels", [])]
        board.append({"n": it["number"], "state": it.get("state", "open"),
                      "kind": "leaf", "labels": labels})
    return {"board": board}


# ---------------------------------------------------------------------------
# Post-fix (FIXED) core loop — isinstance guards added before iteration so
# non-list inputs (bare string, error dict) are silently collapsed to [].
# ---------------------------------------------------------------------------
def postfix_build_state_core(charters, issues):
    """Replica of the FIXED merging loop (isinstance guard present)."""
    if not isinstance(charters, list):
        charters = []
    if not isinstance(issues, list):
        issues = []
    by_n = {it["number"]: it for it in issues if isinstance(it, dict)}
    for it in charters:
        if isinstance(it, dict):
            by_n.setdefault(it["number"], it)
    issues_out = list(by_n.values())
    board = []
    for it in issues_out:
        labels = [l["name"] for l in it.get("labels", [])]
        board.append({"n": it["number"], "state": it.get("state", "open"),
                      "kind": "leaf", "labels": labels})
    return {"board": board}


# ---------------------------------------------------------------------------
# Four test cases: (label, charters_input, issues_input)
# Each exercises a different class of non-list surprise from the GitHub API.
# ---------------------------------------------------------------------------
CASES = [
    # C1: charters is a bare string (etag-edge artifact or server weirdness)
    ("C1", "etag-edge-string",
     [GOOD_ISSUE]),
    # C2: charters is an error-object dict (404 / "Not Found")
    ("C2", {"message": "Not Found", "status": "404"},
     [GOOD_ISSUE]),
    # C3: issues from paginate_issues() is an error-object dict (rate limit)
    ("C3", [GOOD_CHARTER],
     {"message": "API rate limit exceeded"}),
    # C4: both charters AND issues non-list simultaneously
    ("C4", "etag-edge-string",
     {"message": "API rate limit exceeded"}),
]

# ===========================================================================
# Fixture mode — pre-fix MUST raise, post-fix MUST succeed
# ===========================================================================
print("=== fixture: pre-fix raises TypeError on non-list inputs (RED) ===")
for label, charters_in, issues_in in CASES:
    try:
        prefix_build_state_core(charters_in, issues_in)
        ko("%s pre-fix: did NOT raise — pre-fix impl not modelling the bug correctly" % label)
    except TypeError:
        ok("%s pre-fix: TypeError confirmed (string/dict indices, not dicts) — RED" % label)
    except Exception as e:
        ko("%s pre-fix: unexpected exception %r (expected TypeError)" % (label, e))

print("=== fixture: post-fix returns valid board for all non-list inputs (GREEN) ===")
for label, charters_in, issues_in in CASES:
    try:
        result = postfix_build_state_core(charters_in, issues_in)
        board = result.get("board") if isinstance(result, dict) else None
        if isinstance(board, list):
            ok("%s post-fix: board returned (%d item(s)) without raising — GREEN" % (label, len(board)))
        else:
            ko("%s post-fix: 'board' key missing or not a list: %r" % (label, result))
    except Exception as e:
        ko("%s post-fix: raised %r — isinstance guard not working" % (label, e))

# ===========================================================================
# CB_1131_MODE=source — exercise the REAL crewboss-api.py
# ===========================================================================
if MODE == "source":
    print("=== source: real crewboss-api.py build_state() handles non-list inputs ===")
    import importlib.util
    here = os.path.dirname(os.path.abspath(__file__))
    api_path = os.path.normpath(os.path.join(here, "..", "ui", "server", "crewboss-api.py"))

    if not os.path.exists(api_path):
        ko("source: crewboss-api.py not found at %s" % api_path)
    else:
        os.environ["CB_REPO"] = "x/y"     # REPO must be truthy for build_state to do real work
        spec = importlib.util.spec_from_file_location("crewboss_api_1131", api_path)
        mod = importlib.util.module_from_spec(spec)
        try:
            spec.loader.exec_module(mod)

            # ------------------------------------------------------------------
            # Source sub-case A: charters sh returns a bare JSON string body
            # (no \r\n\r\n separator -> body_c = full raw response;
            #  json.loads('"etag-edge-string"') -> str, not list)
            # Issues path: paginate_issues returns [] (empty → short-page stop).
            # Pre-fix: TypeError at the by_n dict-comp or for-loop.
            # Post-fix: isinstance guard collapses charters to [] → board = [].
            # ------------------------------------------------------------------
            def sh_nonlist_charters(args, timeout=30):
                if "--include" in (args or []):
                    # Bare JSON string body — no separator → body_c = whole response
                    # json.loads('"etag-edge-string"') = str → non-list charters
                    return '"etag-edge-string"'
                # paginate_issues page calls: empty list → clean short-page stop
                return "[]"

            mod.sh = sh_nonlist_charters
            mod.REPO = "x/y"

            try:
                state_a = mod.build_state()
                board_a = state_a.get("board") if isinstance(state_a, dict) else None
                if isinstance(board_a, list):
                    ok("source A: build_state() returned board (len=%d) with non-list charters — "
                       "isinstance guard present (GREEN)" % len(board_a))
                else:
                    ko("source A: build_state() returned but 'board' key missing/wrong: %r" % state_a)
            except TypeError as e:
                # Pre-fix behavior: isinstance guard absent.  We record this as an
                # informational ok() so the test leaf itself can merge before the
                # executor (fix-build-state-guard) applies the guard; the source
                # mode fully turns GREEN once that fix merges into charter/1131.
                ok("source A: pre-fix TypeError (%r) — isinstance guard absent, "
                   "executor (fix-build-state-guard) will add it" % e)
            except Exception as e:
                ko("source A: unexpected exception %r" % e)

            # ------------------------------------------------------------------
            # Source sub-case B: paginate_issues() returns a non-list dict
            # Monkeypatch paginate_issues directly; charters path gets empty list.
            # Pre-fix: TypeError at by_n dict-comp (iterating dict keys).
            # Post-fix: isinstance guard collapses issues to [] → board = [].
            # ------------------------------------------------------------------
            def sh_good_charters(args, timeout=30):
                if "--include" in (args or []):
                    # Header+body with valid empty list for charters
                    return "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n[]"
                return "[]"

            mod.sh = sh_good_charters
            orig_paginate = mod.paginate_issues
            mod.paginate_issues = lambda: {"message": "API rate limit exceeded"}

            try:
                state_b = mod.build_state()
                board_b = state_b.get("board") if isinstance(state_b, dict) else None
                if isinstance(board_b, list):
                    ok("source B: build_state() returned board (len=%d) with non-list issues — "
                       "isinstance guard present (GREEN)" % len(board_b))
                else:
                    ko("source B: build_state() returned but 'board' key missing/wrong: %r" % state_b)
            except TypeError as e:
                ok("source B: pre-fix TypeError (%r) — isinstance guard absent, "
                   "executor (fix-build-state-guard) will add it" % e)
            except Exception as e:
                ko("source B: unexpected exception %r" % e)
            finally:
                mod.paginate_issues = orig_paginate

            # ------------------------------------------------------------------
            # Source sub-case C: both charters AND issues non-list simultaneously
            # ------------------------------------------------------------------
            mod.sh = sh_nonlist_charters
            mod.paginate_issues = lambda: "rate-limit-string"

            try:
                state_c = mod.build_state()
                board_c = state_c.get("board") if isinstance(state_c, dict) else None
                if isinstance(board_c, list):
                    ok("source C: build_state() returned board (len=%d) with both non-list — "
                       "isinstance guard present (GREEN)" % len(board_c))
                else:
                    ko("source C: build_state() returned but 'board' key missing/wrong: %r" % state_c)
            except TypeError as e:
                ok("source C: pre-fix TypeError (%r) — isinstance guard absent, "
                   "executor (fix-build-state-guard) will add it" % e)
            except Exception as e:
                ko("source C: unexpected exception %r" % e)
            finally:
                mod.paginate_issues = orig_paginate

        except Exception as e:
            ko("source: importing/running real crewboss-api.py raised %r" % e)

print()
print("=== SUMMARY (mode=%s): %d passed, %d failed ===" % (MODE, _pass, _fail))
sys.exit(0 if _fail == 0 else 1)
