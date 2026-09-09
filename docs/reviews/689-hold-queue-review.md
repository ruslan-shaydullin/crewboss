# Integration Review: Issue #689 — Charter #686 Q-hold Fix Review

**Reviewed leaves:** #687 (qa-engineer/tests) · #688 (executor/impl)  
**Head commit reviewed:** `0aa4d3b` (merge of #693 / leaf/688 into `charter/686`)  
**Reviewer:** leaf/689-1782369576 (reviewer, charter #686)  
**Review date:** 2026-06-25  
**Charter:** #686

---

## Verdict: ✅ APPROVED — all acceptance checks green, all review items pass

### Machine acceptance checks

```
check: grep -n 'hold' proto/r6/board-gh.sh | grep -q 'then "hold"'
  → line 60: elif ([.labels[].name]|any(.=="hold")) then "hold"
  → PASS ✅

check: bash reference/tests/launcher-queue.test.sh 2>&1 | grep -q 'ok.*Q-hold'
  → ok   Q-hold: board get 50 state returns 'hold' (board-gh.sh hold-branch patch verified)
  → ok   Q-hold: charter A (50) remains in queue order (not purged by launcher)
  → ok   Q-hold: leaf 101 (charter B=100) IS spawned — queue advanced past held A=50
  → ok   Q-hold: leaf 51 (charter A=50, held) correctly NOT spawned
  → PASS ✅

check: grep -c 'hold) continue' reference/runtime/crewboss-launcher-gh.sh | grep -qE '^[4-9]|^[1-9][0-9]'
  → 4 occurrences (lines 952, 1287, 1302, 1310)
  → PASS ✅
```

### Live test run

`bash reference/tests/launcher-queue.test.sh` → **passed=8 failed=0** ✅

---

## Checklist verification

### 1. board-gh.sh priority: `hold` before `status:blocked` ✅

`proto/r6/board-gh.sh` lines 60–61:
```bash
elif ([.labels[].name]|any(.=="hold")) then "hold"
elif ([.labels[].name]|any(.=="status:blocked")) then "blocked"
```
The `hold` branch is inserted BEFORE `status:blocked`. A charter with both labels returns
`"hold"`, not `"blocked"`. Correct priority order confirmed. ✅

### 2. All four launcher sites patched ✅

`reference/runtime/crewboss-launcher-gh.sh`:
- Line 952  — `cmd_cycle` `_q_head`:      `done|blocked|hold) continue ;;` ✅
- Line 1287 — `cmd_run`   `_q_head`:      `done|blocked|hold) continue ;;` ✅
- Line 1302 — `cmd_run`   `_q_plan_head`: `case "$_qst" in approved|done|blocked|hold) continue ;; esac` ✅
- Line 1310 — `cmd_run`   `_q_accept_head`: `case "$_qst" in done|blocked|hold) continue ;; esac` ✅

No site left with `done|blocked) continue` without `|hold`. ✅

### 3. No regression in plan-review skip logic ✅

The `_q_head` loop's `plan-review` branch (with `_prr_q` / `_plag_q` checks) is
untouched by either #687 or #688. Only the skip-pattern arms were modified; the
plan-review conditional path is structurally identical to pre-patch. ✅

### 4. Test covers the failure mode ✅

`reference/tests/launcher-queue.test.sh` Q-hold scenario:
- Two-charter queue: A (id=50, hold-labelled) at position 1, B (id=100) at position 2.
- Assert `board get 50 state` returns `"hold"` (unit check of board-gh.sh patch).
- Assert charter A (50) remains in queue order (not purged by launcher).
- Assert leaf 101 (charter B=100) IS spawned — queue advances past held A.
- Assert leaf 51 (charter A=50, held) is NOT spawned.

Covers the exact failure mode described in #686: held charter at head blocking all
subsequent charters. Board mock returns `hold` label for issue 50; launcher reads
state and skips rather than attempting to run. ✅

### 5. "deferred" correctly out of scope ✅

Neither #687 nor #688 modifies any `deferred` or `status:deferred` handling.
Searched both changed files — zero references to `deferred` added or removed. ✅

### 6. Both files land atomically ✅

`proto/r6/board-gh.sh` and `reference/runtime/crewboss-launcher-gh.sh` are both
modified in a single commit (`3673ee9`) from leaf/688. The test (#687, commit `3af0be6`)
was merged first (PR #692) and the impl (#688, commit `3673ee9`) was merged second
(PR #693). The test PR's Q-hold assertions fail until the impl is present; the
impl satisfies all four assertions. The two PRs are in the same `charter/686` branch
so atomicity from the charter perspective is preserved. ✅

---

## Summary

Both leaves (#687 test, #688 impl) fully satisfy the acceptance criteria for
charter #686's queue-freeze fix. The board-gh.sh `hold` priority is correct,
all four launcher skip sites are patched, the regression test covers the exact
failure mode, and no unintended changes were introduced to deferred or
plan-review paths.
