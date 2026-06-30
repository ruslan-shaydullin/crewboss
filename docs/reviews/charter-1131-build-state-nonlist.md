# Review: Charter #1131 — build_state() non-list guard

**Reviewer leaf:** #1135  
**Reviewed PRs:** leaf/1133 (qa-engineer tests) #1136, leaf/1134 (executor fix) #1137  
**Verdict:** ✅ APPROVED — all checklist items pass

---

## Checklist results

### PR #1134 (executor fix — `ui/server/crewboss-api.py`)

1. ✅ **Guard placement** — `if not isinstance(charters, list): charters = []` appears at line 404, immediately after `_cached_charters = json.loads(body_c)` (~line 402). `if not isinstance(issues, list): issues = []` appears at line 418, immediately after `issues = paginate_issues()` (line 416).

2. ✅ **Dict comprehension filter** — `by_n = {it["number"]: it for it in issues if isinstance(it, dict) and "number" in it}` (line 420). Both conditions (`isinstance(it, dict)` and `"number" in it`) are present.

3. ✅ **Charter merge loop filter** — `for it in charters:` loop at line 421 guards each iteration with `if isinstance(it, dict) and "number" in it:` (line 422).

4. ✅ **Pattern consistency** — guards mirror the existing `return batch if isinstance(batch, list) else None` pattern in `paginate_issues()` (line 238). Style is consistent with existing defensive code.

5. ✅ **No test-file changes** — diff touches only `ui/server/crewboss-api.py`; no files under `tests/` are modified.

6. ✅ **No scope creep** — only `build_state()` lines ~402-424 are changed; no other routes or logic modified.

### PR #1133 (qa-engineer tests — `tests/1131-build-state-nonlist.test.py`)

1. ✅ **Four cases covered** — C1 (string charters), C2 (dict/error-object charters), C3 (non-list issues dict), C4 (both non-list simultaneously).

2. ✅ **RED/GREEN self-proof** — `prefix_build_state_core()` (pre-fix replica) raises `TypeError` for all four cases (RED); `postfix_build_state_core()` (post-fix replica) returns a valid `{"board": [...]}` for all four cases (GREEN).

3. ✅ **Source mode works** — `CB_1131_MODE=source` imports real `crewboss-api.py`, monkeypatches `sh` and `paginate_issues` to return non-list values, asserts `build_state()` returns without raising and the `"board"` key is present. Sub-cases A, B, C all pass GREEN.

4. ✅ **No regressions** — `python3 /work/tests/969-api-pagination.test.py` and `CB_969_MODE=source python3 /work/tests/969-api-pagination.test.py` both pass (4 and 6 assertions respectively, 0 failures).

---

## Acceptance checks

All four checks confirmed green on merge SHA:

```
python3 /work/tests/1131-build-state-nonlist.test.py
→ SUMMARY (mode=fixture): 8 passed, 0 failed

CB_1131_MODE=source python3 /work/tests/1131-build-state-nonlist.test.py
→ SUMMARY (mode=source): 11 passed, 0 failed

python3 /work/tests/969-api-pagination.test.py
→ SUMMARY (mode=fixture): 4 passed, 0 failed

CB_969_MODE=source python3 /work/tests/969-api-pagination.test.py
→ SUMMARY (mode=source): 6 passed, 0 failed
```

---

## Summary

Both PRs correctly implement the charter #1131 fix:

- The test leaf (#1133) establishes a four-case RED/GREEN contract that proves the pre-fix code raises `TypeError` on non-list inputs and the post-fix code handles them gracefully.
- The executor leaf (#1134) adds minimal, consistent `isinstance` guards immediately after each GitHub API fetch in `build_state()`, collapsing any non-list response to `[]` before the iteration/dict-comprehension steps that previously crashed.
- The dict comprehension and charter merge loop both defend against non-dict items, preventing `KeyError` on malformed entries.
- No test files are touched by the executor; no scope creep beyond the targeted lines.

**Verdict: APPROVED.**
