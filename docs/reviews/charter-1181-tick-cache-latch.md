# Review: Charter #1181 — Tick-cache latch / 304-deadlock fix

**Reviewer leaf:** #1194  
**Reviewed leaves:** #1192 (qa-engineer, tests), #1193 (executor, fix)  
**Verdict:** ✅ APPROVED — all four charter acceptance criteria met; both machine checks green

---

## Machine acceptance checks

| Check | Command | Result |
|-------|---------|--------|
| 1 | `bash reference/tests/1181-tick-cache-latch.test.sh` | 5/5 PASS |
| 2 | `grep -q "tick-cache fetch empty" reference/runtime/crewboss-launcher-gh.sh` | FOUND |

---

## Criterion 1 — Reject empty/`[]`/`null` as invalid

**File:** `reference/runtime/crewboss-launcher-gh.sh`, lines 191–196

```bash
if [ -z "$_fetched" ] || [ "$_fetched" = "[]" ] || [ "$_fetched" = "null" ]; then
    printf '%s\n' "tick-cache fetch empty/failed — forcing full refetch next tick"
    # Do NOT assign _CB_TICK_CACHE_ALL, do NOT set _CB_TICK_CACHE_OK=1,
    # do NOT update _CB_ISSUE_ETAG.  The missing/unchanged ETag ensures the
    # next tick sends no If-None-Match header → GitHub returns 200 → full re-paginate.
    return 0
fi
```

- ✅ All three variants (`""`, `"[]"`, `"null"`) checked in a single guard.
- ✅ `_CB_TICK_CACHE_OK=1` is NOT set on this path — cache stays unpopulated.
- ✅ `_CB_ISSUE_ETAG` is NOT updated — next tick gets no `If-None-Match` header → forces a 200 re-paginate.
- ✅ Log line `"tick-cache fetch empty/failed — forcing full refetch next tick"` is emitted and is the sole code path that prints this message.

---

## Criterion 2 — 304 early-return must not short-circuit on empty cache

**File:** `reference/runtime/crewboss-launcher-gh.sh`, lines 171–177

```bash
if printf '%s' "$_status" | grep -q '304' \
   && [ -n "$_CB_TICK_CACHE_OK" ] \
   && [ -n "$_CB_TICK_CACHE_ALL" ] \
   && [ "$_CB_TICK_CACHE_ALL" != "[]" ]; then
    # Unchanged list — keep the cached snapshot (no full re-fetch, no primary-RL spend).
    return 0
fi
```

- ✅ The early-return requires all four conditions simultaneously:
  - HTTP status contains `304`
  - `_CB_TICK_CACHE_OK` is set (non-empty)
  - `_CB_TICK_CACHE_ALL` is non-empty
  - `_CB_TICK_CACHE_ALL` is not `"[]"`
- ✅ A 304 with an empty or `[]` cache falls through to the full re-paginate path — the deadlock is broken.

---

## Criterion 3 — Fetch stderr no longer silenced

Inspected `_cb_issue_fetch` (lines 121–138) and `_cb_tick_cache_refresh` (lines 162–202):

- Line 124–125: `gh api --paginate -X GET ...` — **no `2>/dev/null`**. ✅
- Lines 133–135: `gh issue list -R "$CB_REPO" ...` (fallback path) — **no `2>/dev/null`**. ✅
- Line 167: `_probe="$("${_cmd[@]}")" || _probe=""` — **no `2>/dev/null`**. ✅
- The only `2>/dev/null` remaining within these functions are on `jq` filter commands (lines 129, 147, 148), which suppress jq parse warnings, not `gh` fetch errors. This is acceptable and unchanged from prior behaviour.
- No new `2>/dev/null` was introduced in `_cb_issue_fetch` or `_cb_tick_cache_refresh`. ✅

---

## Criterion 4 — Tests

**File:** `reference/tests/1181-tick-cache-latch.test.sh` (added by leaf #1192)

- ✅ File exists and is executable.
- ✅ `bash reference/tests/1181-tick-cache-latch.test.sh` exits 0 with `passed=5 failed=0`.

### Test A — empty-fetch guard (criterion 4a)

Overrides `_cb_issue_fetch` to return `""` (empty string), verifies:

- **A1:** `_CB_TICK_CACHE_OK` remains unset — guard prevented the latch. ✅
- **A2:** `_CB_ISSUE_ETAG` remains `'"before"'` — ETag not pinned to a bad fetch. ✅
- **A3:** `_CB_TICK_CACHE_ALL` is not `"[]"` — poisoned value not committed. ✅

### Test B — 304 with live non-empty cache (criterion 4b)

Overrides `gh` to return an `HTTP/1.1 304 Not Modified` response; primes the cache with a valid non-empty snapshot, verifies:

- **B1:** `_CB_TICK_CACHE_ALL` preserved at the primed non-empty value. ✅
- **B2:** `_CB_TICK_CACHE_OK` remains set (cache still valid). ✅

Both tests use shell-function overrides only — **no live GitHub access required**.

---

## Summary

The executor PR (#1193) correctly fixes the root-cause bug by:
1. Rejecting all three empty-result variants as invalid (Criterion 1).
2. Adding a three-part guard to the 304 early-return so an empty cache is never reused as "unchanged" (Criterion 2).
3. Removing `2>/dev/null` from the `gh` fetch call sites so transient failures surface in the launcher log (Criterion 3).

The qa-engineer PR (#1192) provides a hermetic regression test suite that covers both the poison-latch path and the valid 304-reuse path (Criterion 4).

**All four acceptance criteria are met. PR approved.**
