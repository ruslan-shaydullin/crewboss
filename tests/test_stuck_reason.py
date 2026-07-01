"""test_stuck_reason.py — 7 pytest test cases for _compute_stuck (charter #485, issue #1211).

Guards the stuck-charter detection logic that the backend executor leaf adds to
ui/server/crewboss-api.py.  All tests skip gracefully (exit 0) when the function
is not yet present, so this leaf can merge before the implementation leaf.

Function signature (what the backend will implement):
    _compute_stuck(n, labels, issues, plan_convergence_active, finale_pr)
        -> {"is_stuck": bool, "reason": str | None}

  n                        -- charter issue number (int)
  labels                   -- list of label dicts for the charter, e.g. [{"name": "type:charter"}]
  issues                   -- raw GitHub REST issues list; each has
                             labels: [{"name": "..."}], state: "open"|"closed", body: str
  plan_convergence_active  -- bool
  finale_pr                -- PR number string or "" (empty = no finale PR)

Detection order (first match wins):
  1. Open type:human-decision issue whose body references this charter
  2. Charter labels include status:blocked
  3. No leaf children (issues only contain type:charter / type:milestone items)
  4. finale_pr is set and the PR is open + non-draft
  5. plan_convergence_active is True
  6. (none of the above) -> not stuck
"""
import pytest, sys

sys.path.insert(0, "ui/server")
try:
    from crewboss_api import _compute_stuck
except ImportError:
    pytest.skip("_compute_stuck not yet implemented", allow_module_level=True)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def make_label(*names):
    """Return a list-of-dicts as GitHub REST labels."""
    return [{"name": n} for n in names]


def make_issue(labels, state="open", body=""):
    """Minimal GitHub REST issue dict."""
    return {"labels": labels, "state": state, "body": body}


# ---------------------------------------------------------------------------
# Test 1: Open type:human-decision issue whose body references this charter
#         -> is_stuck=True, reason="human decision pending"
# ---------------------------------------------------------------------------
def test_open_human_decision_fires():
    n = 42
    charter_labels = make_label("type:charter")
    issues = [
        make_issue(
            make_label("type:human-decision"),
            state="open",
            body="Charter: #42\nPlease decide something.",
        ),
    ]
    result = _compute_stuck(n, charter_labels, issues, False, "")
    assert result["is_stuck"] is True
    assert result["reason"] == "human decision pending"


# ---------------------------------------------------------------------------
# Test 2: CLOSED type:human-decision issue with same body
#         -> is_stuck=False, reason=None  (closed HD must NOT fire)
# ---------------------------------------------------------------------------
def test_closed_human_decision_does_not_fire():
    n = 42
    charter_labels = make_label("type:charter")
    issues = [
        make_issue(
            make_label("type:human-decision"),
            state="closed",
            body="Charter: #42\nSome resolved decision.",
        ),
    ]
    result = _compute_stuck(n, charter_labels, issues, False, "")
    assert result["is_stuck"] is False
    assert result["reason"] is None


# ---------------------------------------------------------------------------
# Test 3: Charter labels include status:blocked, no HD issues
#         -> is_stuck=True, reason starts with "blocked"
# ---------------------------------------------------------------------------
def test_status_blocked_label():
    n = 99
    charter_labels = make_label("type:charter", "status:blocked")
    # No issues at all -- only the status:blocked label should fire.
    issues = []
    result = _compute_stuck(n, charter_labels, issues, False, "")
    assert result["is_stuck"] is True
    assert result["reason"].startswith("blocked")


# ---------------------------------------------------------------------------
# Test 4: issues list contains only type:charter / type:milestone items
#         -> is_stuck=True, reason="no leaves"
# (A raw issue is a leaf if it does NOT have type:charter or type:milestone.
#  We must NOT use item.get("kind") == "leaf"; that field does not exist on
#  raw GitHub REST dicts.)
# ---------------------------------------------------------------------------
def test_no_leaf_children():
    n = 55
    charter_labels = make_label("type:charter")
    # Both items are non-leaf (charter / milestone)
    issues = [
        make_issue(make_label("type:charter"),   state="open", body=""),
        make_issue(make_label("type:milestone"),  state="open", body=""),
    ]
    result = _compute_stuck(n, charter_labels, issues, False, "")
    assert result["is_stuck"] is True
    assert result["reason"] == "no leaves"


# ---------------------------------------------------------------------------
# Test 5: finale_pr="42", monkeypatched gh pr view returns isDraft=False, state=OPEN
#         -> is_stuck=True, reason="finale PR awaiting merge"
# ---------------------------------------------------------------------------
def test_finale_pr_open_and_non_draft(monkeypatch):
    import subprocess
    import json

    n = 7
    charter_labels = make_label("type:charter")
    # Provide a leaf so "no leaves" check does not fire first
    issues = [
        make_issue(make_label("type:leaf"), state="open", body="Charter: #7"),
    ]

    pr_payload = json.dumps({"isDraft": False, "state": "OPEN"})

    class _MockResult:
        stdout = pr_payload
        returncode = 0
        stderr = ""

    monkeypatch.setattr(subprocess, "run", lambda *a, **kw: _MockResult())

    result = _compute_stuck(n, charter_labels, issues, False, "42")
    assert result["is_stuck"] is True
    assert result["reason"] == "finale PR awaiting merge"


# ---------------------------------------------------------------------------
# Test 6: plan_convergence_active=True, no other signals
#         -> is_stuck=True, reason="plan cap: awaiting review"
# ---------------------------------------------------------------------------
def test_plan_convergence_active():
    n = 13
    charter_labels = make_label("type:charter")
    # Leaf exists so "no leaves" does not fire; no finale_pr
    issues = [
        make_issue(make_label("type:leaf"), state="open", body="Charter: #13"),
    ]
    result = _compute_stuck(n, charter_labels, issues, True, "")
    assert result["is_stuck"] is True
    assert result["reason"] == "plan cap: awaiting review"


# ---------------------------------------------------------------------------
# Test 7: Clean charter -- no signals present
#         -> is_stuck=False, reason=None
# ---------------------------------------------------------------------------
def test_clean_charter_not_stuck():
    n = 100
    charter_labels = make_label("type:charter")
    # Has a leaf child, no blocked label, no HD issues, no finale_pr
    issues = [
        make_issue(make_label("type:leaf"), state="open", body="Charter: #100"),
    ]
    result = _compute_stuck(n, charter_labels, issues, False, "")
    assert result["is_stuck"] is False
    assert result["reason"] is None
