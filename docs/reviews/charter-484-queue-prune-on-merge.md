# Review: queue.json pruning on charter merge (charter #484, issue #931)

**Status:** APPROVED (with one non-blocking test-infra note)
**Date:** 2026-06-30
**Scope:** `ui/server/crewboss-api.py` `do_command merge` (Step 5D, #927) +
`reference/runtime/crewboss-launcher-gh.sh` `_finale_check_ci` (auto-merge prune, #930)

This leaf reviews the two implementation leaves of charter #484 together and
confirms the charter is ready to close. Charter #484 makes a merged charter
self-evict from `run/queue.json` in both code paths that complete a charter
merge, so the queue head advances without manual editing.

---

## 1. Python patch — `do_command merge` Step 5D (#927)

```python
# Step 5C: Only unlink pr_num_path after confirmed close (preserves retry invariant)
os.unlink(pr_num_path)
# Step 5D: Prune merged charter from queue (best-effort, non-blocking)
try:
    _qdata = read_json(os.path.join(RUN, "queue.json"), {"order": []})
    _qorder = [x for x in _qdata.get("order", []) if x != int(n)]
    save_queue(_qorder)
except Exception:
    pass  # best-effort — never block a successful merge
return {"ok": True, "verify_verdict": "green", "verify_output": result.stdout, "merged": True}
```

| Checklist item | Verdict |
|---|---|
| Inserted after `os.unlink(pr_num_path)`, before `return {"ok": True, ...}` | ✅ |
| Loads via `read_json(os.path.join(RUN, "queue.json"), {"order": []})` | ✅ |
| Filters `[x for x in ... if x != int(n)]` (`int(n)` cast) | ✅ — `n` is a str; the `int(n)` cast is required so the comparison matches the integer queue entries |
| Atomic write via `save_queue(order)` | ✅ |
| Wrapped in `try/except Exception: pass` (best-effort, non-blocking) | ✅ — a queue-prune failure can never roll back an already-completed merge+close |

**Verdict: correct.** The placement after Step 5C keeps the retry invariant
intact (pr_num_path is only removed after a confirmed close), and the prune is a
strictly post-success, non-blocking step.

---

## 2. Bash patch — `_finale_check_ci` auto-merge prune (#930)

```sh
gh issue close "$cid" -R "$CB_REPO" --reason completed 2>/dev/null || true
    # Prune merged charter from queue.json (non-blocking, atomic)
    { _qf="$RUN/queue.json"
      [ -f "$_qf" ] && \
        _qt=$(mktemp -p "$RUN" q.XXXXXX.tmp 2>/dev/null) && \
        jq --argjson c "$cid" \
          'if .order then .order |= map(select(. != $c)) else . end' \
          "$_qf" > "$_qt" 2>/dev/null && \
        mv "$_qt" "$_qf" 2>/dev/null || \
        rm -f "$_qt" 2>/dev/null; } || true
printf '%s' "merged" > "$_fin_dir/last_comment"
```

| Checklist item | Verdict |
|---|---|
| Inserted after the charter-close line, before `printf ..merged.. > last_comment` | ✅ |
| `mktemp -p "$RUN"` + `jq` + `mv` for atomic write | ✅ — temp file lives on the same filesystem as the target, so `mv` is an atomic rename; the `rm -f` cleans the temp on any failure |
| `jq --argjson c "$cid"` converts `$cid` to a JSON number for comparison | ✅ — required so `select(. != $c)` compares numbers, not strings |
| Whole block wrapped with `|| true` (non-blocking) | ✅ |
| `bash -n` passes on the patched file | ✅ |

**Verdict: correct.** Mirrors the Python semantics (drop the merged charter,
retain the rest) and is fully fail-open: any failure leaves the queue untouched
and never blocks the finale cycle.

---

## 3. Sha-lock

- `reference/runtime-manifest.tsv` is consistent with both changed canonical
  files: `bash reference/bin/regen-manifest.sh && git diff --exit-code
  reference/runtime-manifest.tsv` is clean (no drift).
- `reference/tests/runtime-manifest.test.sh` passes (sha-lock Test 3 green).

**Verdict: sha-lock green.**

---

## 4. Tests

- `reference/tests/merge-action.test.sh` — **passes.** The `Q-queue-prune`
  scenario seeds `{"order":[150,999]}`, drives the real Python `do_command
  merge`, and asserts 150 is pruned while 999 is retained. This is the
  authoritative end-to-end check of the #927 path and it is green.
- `reference/tests/runtime-manifest.test.sh` — **passes.**
- `reference/tests/charter-finale.test.sh` — the new `RED-f` queue-prune
  scenario asserts the #930 launcher path. See the note below.

### Note: charter-finale.test.sh (non-blocking, pre-existing, out of scope)

`charter-finale.test.sh` does not currently pass in full, but the failures are
**pre-existing and unrelated to charter #484**. They reproduce identically on the
pre-charter base commit and affect the entire family of launcher-finale tests
(`finale-nonblocking.test.sh`, `finale-autorebase.test.sh`, …), not just the new
`RED-f` prune scenario.

Root cause: the launcher now fetches the board via `gh api --paginate
/repos/.../issues` (`_cb_issue_fetch`, one-fetch-per-tick cache, charter #1004),
but the in-test `gh` stub only implements `gh issue list`. With no `gh api`
handler the per-tick snapshot is empty, so `_charter_finale_cycle` iterates zero
charters and never reaches the auto-merge/prune path. The `RED-f` prune scenario
additionally drives the real `verify-merged` against a throwaway remote that has
no `reference/` tree, which classifies as infra (no merge attempted) regardless
of the prune code.

Both are **test-harness** concerns owned by the test-author (the executor role is
hard-blocked from editing `*.test.sh` / `tests/` by the independent-test-authorship
gate, charter #523) and are independent of the queue-prune feature. The #930
launcher prune code itself is verified correct by inspection and `bash -n`, and
the equivalent Python path is proven green by `merge-action.test.sh`.
**Recommended follow-up (separate issue, test-author):** add a `gh api`
issue-list handler to the finale-test stub so the launcher-finale tests exercise
the real fetch path again.

---

## Summary

| Area | Verdict |
|---|---|
| Python Step 5D (#927) | ✅ Correct, non-blocking, retry-safe |
| Bash prune block (#930) | ✅ Correct, atomic, fail-open; `bash -n` clean |
| Sha-lock manifest | ✅ Green (no drift) |
| `merge-action.test.sh` | ✅ Green (Q-queue-prune) |
| `runtime-manifest.test.sh` | ✅ Green |
| `charter-finale.test.sh` | ⚠️ Pre-existing, out-of-scope test-harness regression (gh-api stub) — not a charter-#484 defect |

**Overall: APPROVED.** The queue-prune feature is correctly implemented in both
the Python and Bash merge paths, atomic and non-blocking in each, sha-locked, and
covered by a green end-to-end test on the Python path. Charter #484 is ready to
close. The one outstanding test failure is a pre-existing, charter-independent
test-harness issue that should be tracked as a separate test-author follow-up.
