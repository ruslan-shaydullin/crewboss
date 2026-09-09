# Review: Issue #740 — Charter #718 Phantom-Agents Executor PRs

**Issue:** #740 (Reviewer for charter #718)
**Reviewed:**
- PR #738 (commit `3572776`) — `fix: use awaiting-integration phase for synthetic integrator chips` — `ui/server/crewboss-api.py`
- PR #739 (commit `673aae2`) — `fix(#739): filter agents by pid!=null in Hero running counter` — `ui/app/src/App.tsx`
**Review Date:** 2026-06-26
**Reviewer:** leaf/740-1782474591
**Charter:** #718

---

## Summary

**APPROVED.** Both executor PRs are correct, minimal, and meet all criteria. No regressions introduced. Selftest green. TypeScript build constraint satisfied. Test files untouched by either executor PR.

---

## (1) Python fix — PR #738: `awaiting-integration` phase — PASS

**Location:** `ui/server/crewboss-api.py` line 101.

```python
phase="awaiting-integration",
```

- The synthetic integrator chip previously used `"merging" if loop_running else "awaiting"`, causing phantom "merging" agents to appear in the cockpit when a charter loop was running. The fix unconditionally assigns `"awaiting-integration"`, which is semantically accurate — the synthetic chip represents an integration slot waiting for leaves, regardless of whether the loop is currently running. ✓
- The `loop_running` flag still reaches the `tech-lead` chip at line 107 (`phase="planning" if loop_running else "awaiting"`), which is correct and intentionally unchanged. ✓
- No real-agent logic (blocks that check `pid != null`) was touched. ✓

**Selftest assertions (`--selftest-synthetic-gate`, ~line 953–982):**

```python
# loop_running=False: integrator must be phase="awaiting-integration"
if a.get("phase") != "awaiting-integration":
    failures.append(...)
# loop_running=True: integrator must also be phase="awaiting-integration"
if a.get("phase") != "awaiting-integration":
    failures.append(...)
```

Both branches now assert `"awaiting-integration"` — consistent with the unconditional fix at line 101. The assertion was previously checking for `"merging"` on the live path, which is the bug being corrected. ✓

**Selftest result:** `PASS synthetic-gate: integrator→awaiting-integration, tech-lead idle→awaiting/live→planning` (exit 0). ✓

---

## (2) TypeScript fix — PR #739: `pid != null` filter — PASS

**Location:** `ui/app/src/App.tsx` line 275.

```typescript
const running = state?.agents?.filter(a => a.pid != null).length ?? 0
```

- The previous filter was `a.phase !== 'awaiting'`, which relied on the phase string to exclude synthetic chips. After the python-fix changes the integrator chip phase to `"awaiting-integration"` (not `"awaiting"`), the old filter would have started counting the synthetic integrator chip as a running agent. The pid-based filter is the correct semantic gate: synthetic chips have `pid: null/undefined`; real agents always have a numeric `pid`. ✓
- **`!= null` vs `!== null`:** The loose equality `!= null` correctly excludes **both** `null` and `undefined` in one check, which is important because the agent object type may have `pid` as `undefined` when absent, not necessarily `null`. Using `!== null` would have missed `undefined` cases and let synthetic chips through. The implementation is correct. ✓
- No other phase strings, agent fields, or component logic were modified. ✓

---

## (3) Constraint adherence — PASS

**Files touched per PR:**

| PR   | Commit    | Files Changed                    |
|------|-----------|----------------------------------|
| #738 | `3572776` | `ui/server/crewboss-api.py` only |
| #739 | `673aae2` | `ui/app/src/App.tsx` only        |

- Neither PR touched any file under `tests/` or any `*.test.*` file. The qa-engineer leaf (#737, commit `db48b5d`) owns all test files. ✓
- No unrelated changes in either PR (verified via `git show --name-only`). ✓

---

## (4) Regression analysis — PASS

- **Real agents still counted:** `a.pid != null` is truthy for any numeric `pid` (including `0`, though `pid=0` is not a valid OS pid in practice). Real agents always have a numeric pid; they continue to appear in the running count. ✓
- **`loop_running=False` behaviour preserved:** When `loop_running=False`, the synthetic integrator chip has `phase="awaiting-integration"` (unchanged from the fix path) and `pid=null`; it is excluded from the running counter. The tech-lead chip gets `phase="awaiting"` and also has `pid=null`; also excluded. Consistent with prior semantics. ✓
- **`loop_running=True` behaviour corrected:** Integrator chip no longer shows `phase="merging"`, eliminating the phantom. `phase="awaiting-integration"` is now consistent across both loop states. ✓
- **No other phase strings altered:** `"planning"`, `"awaiting"`, `"running"`, and all real-agent phase values are untouched. ✓

---

## Acceptance Checks (machine-verifiable)

| Check | Command | Result |
|-------|---------|--------|
| Selftest green | `cd /work/ui/server && python3 crewboss-api.py --selftest-synthetic-gate` | **EXIT 0** ✓ |
| pid filter present | `grep -qE 'pid\s*!=\s*null\|pid\s*!==\s*(null\|undefined)' /work/ui/app/src/App.tsx` | **MATCH** ✓ |

---

## Verdict

**APPROVED.** Both PRs meet all correctness, constraint, and regression-safety criteria. No blocking findings.
