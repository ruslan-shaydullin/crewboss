"""fixtures/969/prefix/pagination_fns.py — PRE-FIX crewboss-api pagination + classification.

Reproduces two live-observed #969 defects on the ui/server/crewboss-api.py surface:

  defect #2  unbounded `while True:` client pagination (build_state/search_board) —
             never terminates against a feed that does not return an empty page.
  defect #3  `state == "CLOSED"` case-mismatch — `gh api` returns state="closed"
             (lowercase), so the equality never matches and closed leaves misclassify.

`fetch_page(page)` is injected by the test (the gh-api stub).
"""
import json


def paginate(fetch_page):
    """Client-side pagination over fetch_page(page) -> raw JSON string."""
    all_issues = []
    page = 1
    while True:                      # defect #2: NO page/time bound
        raw = fetch_page(page)
        try:
            batch = json.loads(raw)
        except Exception:
            break
        if not batch:
            break
        all_issues.extend(batch)
        page += 1
    return all_issues


def classify_state(item):
    """Map a raw gh issue object -> board state string."""
    labels = [l["name"] for l in item.get("labels", [])]
    if item.get("state") == "CLOSED":            # defect #3: case-sensitive compare
        return "done"
    if "hold" in labels:                          return "held"
    if "status:blocked" in labels:                return "blocked"
    if "status:review" in labels:                 return "review"
    if "status:in-progress" in labels:            return "in-progress"
    if "status:approved" in labels:               return "approved"
    return "open"
