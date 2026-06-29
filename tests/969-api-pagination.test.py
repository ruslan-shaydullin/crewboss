#!/usr/bin/env python3
"""969-api-pagination.test.py — regression guard for the #969 PYTHON surface
(ui/server/crewboss-api.py: build_state() / search_board()).
Charter: #969 · qa-engineer leaf (MERGES FIRST, before any implementation).

Guards two live-observed #969 defects:

  defect #2  unbounded `while True:` client pagination — `/api/state` and `/api/search`
             hang (HTTP 000, 40s+ timeout) -> cockpit OFFLINE / search dead. The guard
             feeds an ENDLESS page source (every page non-empty) and asserts the paginator
             TERMINATES under a hard page bound instead of spinning forever.
  defect #3  `state == "CLOSED"` case-mismatch — moving from `gh issue list` (state=CLOSED)
             to `gh api` (state=closed) breaks classification: closed leaves with a residual
             status:review label classify as `review` -> phantom integrators. The guard asserts
             a `closed` issue classifies `done` REGARDLESS of the case the source returns.

Modes (self-provability — this leaf merges before any impl exists):
  CB_969_MODE=fixture (default) — RED on bundled pre-fix fixtures, GREEN on bundled post-fix
      fixtures. CB_969_FIXTURE=prefix selects the pre-fix set directly (-> non-zero).
  CB_969_MODE=source — assert against the REAL crewboss-api.py (impl leaves).

NOTE: the 1007 `while True` in crewboss-api.py is the SSE keepalive — NOT covered here.
"""
import importlib.util
import json
import os
import sys
import threading

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(HERE)
FIX = os.path.join(HERE, "fixtures", "969")

MODE = os.environ.get("CB_969_MODE", "fixture")
SEL = os.environ.get("CB_969_FIXTURE", "postfix")

_pass = 0
_fail = 0


def ok(msg):
    global _pass
    _pass += 1
    print("ok   " + msg)


def ko(msg):
    global _fail
    _fail += 1
    print("FAIL " + msg)


# ── pagination/classification provider abstraction ──────────────────────────────
# A "provider" exposes:
#   paginate(fetch_page) -> list         (fetch_page(page) -> raw JSON string)
#   classify_state(item) -> state string
# We get one from a bundled fixture module (fixture mode) or from the real
# crewboss-api.py via thin adapters (source mode).

def load_fixture_provider(variant):
    # NB: fixture module is pagination_fns.py (NOT *api.py) so the #993 smoke gate's
    # `*api.py` detector never imports/runs the deliberately-unbounded pre-fix fixture.
    path = os.path.join(FIX, variant, "pagination_fns.py")
    spec = importlib.util.spec_from_file_location("api_fns_" + variant, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod  # has paginate(fetch_page), classify_state(item)


def load_source_provider():
    """Adapt the REAL crewboss-api.py build_state/search_board to the provider API."""
    path = os.path.join(REPO_ROOT, "ui", "server", "crewboss-api.py")
    os.environ["CB_REPO"] = "test/repo969"
    spec = importlib.util.spec_from_file_location("crewboss_api_under_test", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    mod.REPO = "test/repo969"

    class _SourceProvider:
        def paginate(self, fetch_page):
            # Route the module's sh() through fetch_page keyed on the page=N field.
            def fake_sh(args, timeout=30):
                page = 1
                for a in args:
                    a = str(a)
                    if a.startswith("page="):
                        try:
                            page = int(a.split("=", 1)[1])
                        except ValueError:
                            page = 1
                return fetch_page(page)
            mod.sh = fake_sh
            return mod.search_board("__cb969_probe__").get("results", [])

        def classify_state(self, item):
            # search_board() applies the exact build_state() classification; drive one item.
            def one_sh(args, timeout=30):
                for a in args:
                    if str(a).startswith("page="):
                        if str(a) != "page=1":
                            return "[]"
                title = item.get("title", "")
                if "__cb969_one__" not in title:
                    item["title"] = (title + " __cb969_one__").strip()
                return json.dumps([item])
            mod.sh = one_sh
            res = mod.search_board("__cb969_one__").get("results", [])
            return res[0]["state"] if res else "<no-result>"

    return _SourceProvider()


# ── the two assertions ───────────────────────────────────────────────────────────
def assert_bounded(provider):
    """Pagination must terminate under a hard bound against an ENDLESS page source."""
    HARD_SAFETY = 5000   # if the paginator asks for this many pages it is effectively hung
    calls = {"n": 0}

    def endless(page):
        calls["n"] += 1
        if calls["n"] > HARD_SAFETY:
            raise RuntimeError("paginator-unbounded")  # trip-wire so the TEST can't hang
        # every page is non-empty -> an unbounded `while True` never stops
        return json.dumps([{"number": 100000 + page, "state": "OPEN", "labels": []}])

    try:
        provider.paginate(endless)
    except RuntimeError as e:
        if "paginator-unbounded" in str(e):
            return False  # regression: never terminated within the safety bound
        raise
    # terminated on its own before the safety trip-wire -> bounded
    return calls["n"] <= HARD_SAFETY


def assert_case_insensitive_closed(provider):
    """A `closed` (lowercase, as `gh api` returns) issue must classify `done`."""
    item = {
        "number": 248,
        "state": "closed",                       # lowercase — the gh-api shape
        "labels": [{"name": "status:review"}],   # residual label that mis-pulls to `review`
        "title": "merged leaf",
        "body": "",
    }
    return provider.classify_state(item) == "done"


def run_regression_assertions(provider):
    """Return True when the surface is CLEAN (post-fix), False when the regression is present."""
    clean = True
    if not assert_bounded(provider):
        print("    [regress] pagination is UNBOUNDED (while True hang)")
        clean = False
    if not assert_case_insensitive_closed(provider):
        print("    [regress] classification is case-SENSITIVE ('closed' != 'CLOSED' -> not done)")
        clean = False
    return clean


# ── driver ───────────────────────────────────────────────────────────────────────
def main():
    if MODE == "fixture":
        if SEL == "prefix":
            print("=== fixture mode: PRE-FIX fixtures (expected RED) ===")
            clean = run_regression_assertions(load_fixture_provider("prefix"))
            if clean:
                print("pre-fix fixtures unexpectedly GREEN — guard is too weak")
                sys.exit(1)
            print("pre-fix fixtures are RED (regression detected) — exiting non-zero by design")
            sys.exit(1)
        print("=== fixture mode: red-before-green self-proof ===")
        post_clean = run_regression_assertions(load_fixture_provider("postfix"))
        pre_clean = run_regression_assertions(load_fixture_provider("prefix"))
        if post_clean:
            ok("post-fix fixtures GREEN")
        else:
            ko("post-fix fixtures NOT green — guard false-reds the fix")
        if not pre_clean:
            ok("pre-fix fixtures RED — guard detects the #969 api regression")
        else:
            ko("pre-fix fixtures GREEN — guard is too weak / false-green")
    elif MODE == "source":
        print("=== source mode: assertions against the REAL crewboss-api.py ===")
        # Guard the TEST against the unbounded-source hang with a watchdog.
        result = {}

        def worker():
            try:
                result["clean"] = run_regression_assertions(load_source_provider())
            except Exception as e:  # noqa: BLE001
                result["err"] = repr(e)
        t = threading.Thread(target=worker, daemon=True)
        t.start()
        t.join(timeout=60)
        if t.is_alive():
            ko("real crewboss-api.py RED — pagination did not terminate within 60s (while True hang)")
        elif "err" in result:
            ko("real crewboss-api.py errored: " + result["err"])
        elif result.get("clean"):
            ok("real crewboss-api.py GREEN — no #969 api-surface regression")
        else:
            ko("real crewboss-api.py RED — #969 api-surface regression present (see [regress] lines)")
    else:
        ko("unknown CB_969_MODE=%r (want fixture|source)" % MODE)

    print()
    print("=== SUMMARY: %d passed, %d failed ===" % (_pass, _fail))
    sys.exit(0 if _fail == 0 else 1)


if __name__ == "__main__":
    main()
