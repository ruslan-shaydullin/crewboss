# Review: Issue #1262 — Charter #1143 finale auto-merge permanent-stuck bugs

**Issue:** #1262 (Reviewer for charter #1143)
**Reviewed leaves:**
- #1260 (leaf-A, tests): RED-h / RED-i regression tests in `reference/tests/charter-finale.test.sh` — PR #1263
- #1261 (leaf-B, impl): `_finale_check_ci` fix in `reference/runtime/crewboss-launcher-gh.sh` — PR #1264

**Review Date:** 2026-07-02
**Reviewer:** leaf/1262-1782950401
**Charter:** #1143

---

## Summary

**APPROVED — both leaves are correct, minimal, and mutually consistent.**

The two permanent-stuck bugs in `_finale_check_ci` are fixed with a surgical, three-part
change and covered by two new deterministic regression tests that mirror the existing
RED-f / RED-g structure. Both new tests (RED-h off→on transition, RED-i failed-merge retry)
are RED against the pre-fix runtime and GREEN against the fixed runtime — verified by
bisecting the merge history:

| head | passed | failed | RED-h/RED-i |
|------|--------|--------|-------------|
| base `charter/1143` (pre-charter, 3809208) | 19 | 3 | n/a (tests absent) |
| after tests merged (#1263, 5980e4e)        | 21 | 7 | **RED** (impl absent) |
| after impl merged (#1264, 533d01d)         | 25 | 3 | **GREEN** |

All 6 RED-h/RED-i assertions pass on the current charter head. The residual 3 failures
(RED-b ×2, RED-f queue-prune ×1) are **pre-existing on the base branch** (present at
3809208 before charter #1143 began) and are **out of scope** for this charter — see the
note at the end.

---

## Leaf-B (#1261) — `_finale_check_ci` implementation fix (PR #1264)

Reviewed against `reference/runtime/crewboss-launcher-gh.sh` lines 817–937.

### Checklist

- [x] **Green early-exit guard checks BOTH flags** (line 840):
  `green) [ "${CB_AUTO_MERGE:-0}" != "1" ] && [ "$_charter_auto_merge" != "true" ] && return 0`.
  Early-exit fires only when NEITHER `CB_AUTO_MERGE` env NOR the per-charter `auto:merge`
  label is set — matching the OR that independently enables auto-merge at line 844.
  Neither flag alone short-circuits the merge path. ✓
- [x] **`_charter_auto_merge` loaded BEFORE the early-exit** (lines 835–837, before the
  `case "$ci_state"` at 839). The guard is therefore not vacuously false on the off→on
  transition. Single `gh issue view … labels` call — the second `gh issue view` at line 854
  fetches the distinct `accept:agreed` label (acceptance-convergence gate), not a duplicate
  of the auto-merge flag. ✓
- [x] **`ci_state=green` written ONLY inside the successful-merge branch** (line 884, inside
  the `if gh pr merge … --admin` success block). It is NOT written before the merge attempt.
  The only other `green` write (line 930) is the legitimate pure-no-auto-merge "parked for
  human" cache, which is now unreachable from the auto-merge failure path (see next item). ✓
- [x] **`return 1` after failed admin-merge** (line 899, after the
  "admin-merge failed — left ready for human" log) makes the No-auto-merge section
  (lines 926–937, including line 930's `green` write) unreachable from the auto-merge
  failure path. A failed admin-merge now returns 1 → the finale retries next tick with no
  cached green blocking it. ✓
- [x] **No new state keys / transition-detection files / extra early-exit paths.** Only
  `ci_state` and `last_comment` persistent files remain; the `case "$ci_state"` still has
  exactly the `green`/`timeout` arms. No new sset/sget keys. ✓
- [x] **Pure no-auto-merge mode still short-circuits** (line 840 `return 0` when both flags
  off). The parked-for-human green cache at line 930 keeps working; no extra API churn per
  tick — the single added `gh issue view` (labels) at line 836 is the same call the
  auto-merge branch already needed, hoisted above the early-exit rather than duplicated. ✓

### Correctness analysis

The fix is the minimal correct edit. Hoisting the `_charter_auto_merge` load above the
`case` (line 835) is what makes the conditional early-exit sound: without it the off→on
transition would read a stale/unset flag. The green write is now exactly co-located with
the single success sink (admin-merge OK), and every failure/retry arm (`vm_exit` 1/3/*, and
the admin-merge failure) returns non-zero with no `ci_state` mutation, so no path can leave
a green cache that strands the charter. The queue-prune block (lines 886–894) and the
acceptance-convergence gate (lines 845–867) are untouched by this change.

**Verdict: PASS — approve.**

---

## Leaf-A (#1260) — RED-h / RED-i regression tests (PR #1263)

Reviewed against `reference/tests/charter-finale.test.sh` lines 520–645.

### Checklist

- [x] **RED-h exercises the off→on transition specifically** (lines 520–573): two
  `run_finale` calls on the SAME state dir `$CBHOME_H` / `finale-5`. Run 1 with
  `CB_AUTO_MERGE=0` (lines 552–553), asserting no admin-merge yet (556–558) and
  `ci_state=green` cached (560–562). Run 2 with `CB_AUTO_MERGE=1` (565), asserting the
  admin-merge now happens (567–569) and charter #5 CLOSES (571–573). Uses the REAL launcher
  (not the stub) so the `ci_state` cache is actually modeled. ✓
- [x] **RED-i uses a fail-once-then-succeed admin-merge stub** (lines 604–627): a `gh`
  wrapper with a counter file fails the 1st `pr merge --admin` (exit 1, lines 619–621) and
  delegates to the real stub on the 2nd. Asserts charter #5 CLOSES after the SECOND run
  (lines 631–645) — proving the retry path, not a stuck cached green. Original `gh` stub is
  backed up and restored (607, 637) so later tests are unaffected. ✓
- [x] **Both mirror the existing RED-f / RED-g structure**: same `reset_sandbox` +
  `FINALE_BOARD` + pre-created `charter-pr-5` + seeded `ci_state=pending` setup, same
  `run_finale` / `charter_pr_merged_admin` / `issue_state` helpers, same integrator-wrap
  verify-merged→exit-0 stubbing. ✓
- [x] **Changes touch only the test file** — PR #1263 modifies only
  `reference/tests/charter-finale.test.sh`. ✓
- [x] Seeding `ci_state=pending` (lines 541, 593) correctly forces the first call through
  the real branches rather than the early-exit; RED-h additionally verifies the green cache
  is written by run 1 before flipping the flag, which is precisely the Bug-1 precondition. ✓

### Correctness analysis

RED-h is a true reproduction of Bug 1: without the conditional early-exit, run 2 reads the
cached green and returns 0 before the `CB_AUTO_MERGE` branch, so the charter would never
merge — the assertion at 567–569 would fail. RED-i is a true reproduction of Bug 2: with
green written before the merge attempt and no `return 1`, run 1 would cache green after the
failed merge and run 2's early-exit would strand the charter — the assertion at 639–645
would fail. Both are deterministic (counter files, no timing/network) and self-contained.

**Verdict: PASS — approve.**

---

## Acceptance check

```
$ bash reference/tests/charter-finale.test.sh
ok   RED-h: CB_AUTO_MERGE=0 run parked ready (no admin merge yet)
ok   RED-h: ci_state=green cached after CB_AUTO_MERGE=0 run (ready for human)
ok   RED-h: off→on transition auto-merged (cached green did NOT block merge)
ok   RED-h: charter #5 CLOSED after off→on auto-merge
ok   RED-i: admin merge retried and succeeded after an initial failure
ok   RED-i: charter #5 CLOSED after admin-merge retry
passed=25 failed=3
```

All 6 assertions belonging to this charter (RED-h ×4, RED-i ×2) are GREEN.

### Note on the 3 residual failures (out of scope)

RED-b (×2: draft-promotion + human-review comment) and RED-f (×1: queue-prune of charter
300) fail identically on the **pre-charter base** `charter/1143` @ 3809208, before any of
#1260 / #1261 landed. RED-f fails because the launcher hits an environmental
`autorebase infra error (rc=1)` before ever reaching the merge/prune path, and RED-b for a
similarly pre-existing reason — neither is touched by, nor related to, the `_finale_check_ci`
green-cache fix under review. They belong to other charters (#484 queue-prune, and the
draft-promotion leaf) and are explicitly outside the scope of charter #1143. This review
does not modify them.

---

## Overall verdict

**APPROVED — both leaves are correct and the charter #1143 deliverable (RED-h / RED-i) is
fully covered and green.** The two permanent-stuck auto-merge bugs are fixed with a minimal,
correct change; the regression tests deterministically pin both failure modes. Charter #1143
is ready for finale merge.
