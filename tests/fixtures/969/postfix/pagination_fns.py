"""fixtures/969/postfix/pagination_fns.py — POST-FIX crewboss-api pagination + classification.

Fixes the two #969 defects on the ui/server/crewboss-api.py surface:

  defect #2  pagination is now BOUNDED by a hard page cap (MAX_PAGES) — it terminates
             even against a feed that never returns an empty page.
  defect #3  classification is CASE-INSENSITIVE — state "closed" / "CLOSED" both -> "done".

`fetch_page(page)` is injected by the test (the gh-api stub).
"""
import json

MAX_PAGES = 50   # hard upper bound: 50 * 100/page == 5000 issues — far past any real board


def paginate(fetch_page):
    """Client-side pagination over fetch_page(page) -> raw JSON string. BOUNDED."""
    all_issues = []
    page = 1
    while page <= MAX_PAGES:         # fix #2: bounded — never hangs
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
    """Map a raw gh issue object -> board state string (case-insensitive on state)."""
    labels = [l["name"] for l in item.get("labels", [])]
    if str(item.get("state", "")).lower() == "closed":   # fix #3: case-insensitive
        return "done"
    if "hold" in labels:                          return "held"
    if "status:blocked" in labels:                return "blocked"
    if "status:review" in labels:                 return "review"
    if "status:in-progress" in labels:            return "in-progress"
    if "status:approved" in labels:               return "approved"
    return "open"
