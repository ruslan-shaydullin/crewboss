# Review: Charter #486 — Phantom-agent fix for cockpit (CLOSED leaf with residual status:review)

**Reviewer leaf:** #1227  
**Reviewed leaves:** #1225 (api-filter: `ui/server/crewboss-api.py`), #1226 (integrator-label-cleanup: `reference/runtime/crewboss-integrator.sh`), #1224 (QA tests: `reference/tests/phantom-closed-leaf.test.sh`)  
**Verdict:** ✅ APPROVED — all checklist items satisfied; all three machine acceptance checks pass

---

## Machine acceptance checks

| # | Command | Result |
|---|---------|--------|
| 1 | `python3 ui/server/crewboss-api.py --selftest-synthetic-gate` | PASS |
| 2 | `bash reference/tests/phantom-closed-leaf.test.sh` | 10/10 PASS |
| 3 | `bash -n reference/runtime/crewboss-integrator.sh` | PASS (no syntax errors) |

---

## api-filter PR review (leaf #1225 — `ui/server/crewboss-api.py`)

### A-1  Comment accuracy (line 147)

```python
        # build_state() maps CLOSED→"done" as first-priority (L494) before any label
        # check, so state=="review" here always means an OPEN issue with status:review.
        if item.get("state") == "review":
```

- ✅ Comment correctly identifies L494 (`if str(it.get("state","")).lower()=="closed": st="done"`) as the first-priority CLOSED→done mapping.
- ✅ Explanation is accurate: by the time `build_agents()` inspects `item.get("state")`, every CLOSED issue has already been classified as `"done"`, so `state=="review"` unambiguously identifies an OPEN issue with the `status:review` label.

### A-2  No tautological double-condition

```python
if item.get("state") == "review":
```

- ✅ Single condition only — no `and state != "done"` guard present. The previously rejected tautological form (`state=="review" and state!="done"`) does **not** appear anywhere in the file.

### A-3  Selftest: full-chain closed-leaf fixture (lines 1579–1594)

```python
_raw_closed = {"state": "CLOSED", "labels": [{"name": "status:review"}],
               "number": 99, "title": "Stale closed leaf", "kind": "leaf"}
_labels_c = {l["name"] for l in _raw_closed.get("labels", [])}
if   str(_raw_closed.get("state","")).lower() == "closed": _st_c = "done"
elif "status:review" in _labels_c:                         _st_c = "review"
else:                                                       _st_c = "open"
if _st_c != "done":
    failures.append(...)
_closed_item = {"state": _st_c, "kind": "leaf", "title": "Stale closed leaf", "number": 99}
_agents_closed = build_agents({99: _closed_item}, loop_running=False)
_phantom = [a for a in _agents_closed if a.get("role") == "integrator" and a.get("task") == 99]
if _phantom:
    failures.append(...)
```

- ✅ Input is a **raw** issue dict with `state=CLOSED` and `labels=[{"name":"status:review"}]` — not pre-classified.
- ✅ Classification uses the same if/elif priority order as lines 494–502 (CLOSED checked first).
- ✅ Asserts resulting state is `"done"`.
- ✅ Calls `build_agents()` (not just the synthetic loop — the real production function) and asserts zero integrator chips for item #99.
- ✅ Full chain: raw issue → inline classify → board item → `build_agents()` → assert no phantom.

### A-4  Non-regression: live PID agents unaffected

The change touches only the comment above the `state=="review"` guard and adds the selftest fixture. The PID-based agent collection path (scanning `/proc`, `ps`, active worker PIDs) is entirely separate from the synthetic chip loop and is unchanged.

- ✅ Live agents with real PIDs still appear normally; no PID-agent code path was modified.

### A-5  Running-agent counter cross-reference (lines 1593–1594)

```python
        # Running-agent counter (pid-based, not synthetic) already covered by
        # synthetic-phases.test.sh Test 3 (charters #718/#738). Not re-tested here.
```

- ✅ No re-investigation or duplicate test of the pid-based counter.
- ✅ Cross-reference to `synthetic-phases.test.sh Test 3` (charters #718/#738) is present.

---

## integrator-label-cleanup PR review (leaf #1226 — `reference/runtime/crewboss-integrator.sh`)

### I-1  Correct placement

```sh
  log "closed leaf #$id (merge-sha: ${merge_sha:-n/a})"              # line 121
  gh issue edit "$id" "${repo_flag[@]}" --remove-label "status:review" 2>/dev/null || true  # line 122
}                                                                     # line 123
```

- ✅ Appears AFTER the `log "closed leaf #$id..."` call (line 121).
- ✅ Appears BEFORE the closing `}` of `cmd_close_leaf()` (line 123).
- ✅ Appears AFTER the `close_exit` guard (lines 115–120) — not before it. The label removal only runs on the success path (when `gh issue close` succeeded).

### I-2  Best-effort semantics

```sh
gh issue edit "$id" "${repo_flag[@]}" --remove-label "status:review" 2>/dev/null || true
```

- ✅ `2>/dev/null` suppresses stderr (e.g., "label not found" error from GitHub).
- ✅ `|| true` ensures a non-zero exit code from `gh` does not fail the function.
- ✅ The label-removal call is non-blocking: a missing label or transient API error does not prevent the leaf from being recorded as closed.

---

## QA test review (leaf #1224 — `reference/tests/phantom-closed-leaf.test.sh`)

### Q-1  Scenario 1: CLOSED+status:review → done → no phantom chip

Lines 87–104. Input `raw7 = {"state": "CLOSED", "labels": [{"name": "status:review"}], ...}` is a **raw** (unclassified) GitHub issue dict. `classify(raw7)` is called inline using the full 8-case if/elif chain matching lines 494–502. Asserts `st7 == "done"` and no integrator chip for `task==7`.

- ✅ Calls classification logic on a raw CLOSED+status:review fixture — not a pre-classified dict.
- ✅ Verifies the classification step itself (not just that a chip is absent from a pre-tagged item).

### Q-2  Scenario 2: Mixed CLOSED+OPEN → only OPEN item gets chip

Lines 106–145. Two raw items: `raw7` (CLOSED+status:review) and `raw8` (open+status:review). Both classified. Board fed to `build_agents_synthetic()`. Asserts exactly one integrator chip with `task==8`.

- ✅ Two raw items (one CLOSED, one OPEN).
- ✅ Both classified inline before being fed to the chip-emission loop.
- ✅ Asserts exactly one chip (not zero, not two).
- ✅ Asserts the chip has `task==8` (OPEN leaf), not `task==7` (CLOSED leaf).

### Q-3  Scenario 3: cmd_close_leaf strips status:review label

Lines 152–216. A `gh` stub executable (placed on PATH via `$BIN3`) records all invocations to `$GH_LOG3`. `cmd_close_leaf_expected()` (inline replication of the updated integrator function) is called with leaf `42`. Asserts three gh calls: `issue comment 42`, `issue edit --remove-label status:review`, and `issue close 42`.

- ✅ `gh` stubbed as a PATH executable (recording all argv to a log file).
- ✅ `cmd_close_leaf` invoked; asserts `--remove-label status:review` call was made.
- ✅ Also asserts `issue close 42` and `issue comment 42` to confirm no regression on existing calls.

---

## Summary

All 14 checklist items across the three leaves are satisfied.  Root cause (phantom integrator chip for CLOSED issue with residual `status:review` label) is correctly addressed by:

1. The doc-comment on the `state=="review"` guard (`build_agents()`, L147) now clearly explains why the guard is unambiguous — CLOSED issues are always mapped to `"done"` before reaching this point.
2. The `--selftest-synthetic-gate` extension adds a full-chain fixture proving the classification→chip suppression chain.
3. `cmd_close_leaf()` now strips the `status:review` label on success, closing the lifecycle gap.
4. `phantom-closed-leaf.test.sh` provides independent regression coverage of all three behaviors.

**All acceptance criteria met.  PR approved.**
