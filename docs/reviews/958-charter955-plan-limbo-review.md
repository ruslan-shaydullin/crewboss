# Review: Issue #958 — Charter #955 PLAN-Limbo Reconcile Cross-Review

**Issue:** #958 (Reviewer for charter #955)
**Reviewed leaves:**
- #957 — infra-engineer: idempotent PLAN-limbo reconcile block added after line 1773 of `reference/runtime/crewboss-launcher-gh.sh`
- #956 — qa-engineer: regression tests LIMBO-RECOVER, NORMAL-FLOW-INTACT, NO-PREMATURE-APPROVE added to `reference/tests/plan-convergence.test.sh`

**Review Date:** 2026-06-29
**Reviewer:** leaf/958-1782718514
**Charter:** #955

---

## Summary

**APPROVED.** All five invariants verified. Both machine acceptance checks GREEN (22/22 tests pass, `bash -n` syntax clean). Implementation is correct, minimal, and idempotent. No regressions to the CB_AUTO_PLAN_APPROVE path or the leaf-count guard.

---

## Invariant 1: Idempotency — PASS

**Location:** `reference/runtime/crewboss-launcher-gh.sh` lines 1790–1809.

The reconcile block uses two guards to ensure repeated ticks do not re-fire:

1. **`sget term` guard (line 1804):**
   ```bash
   [ -n "$(sget "$cid" term)" ] && continue
   ```
   On the first execution, `sset "$cid" term 1` (line 1806) is written immediately after the
   label edit. On any subsequent tick, `sget "$cid" term` returns `1` (non-empty) and the
   `continue` skips the charter. This is the primary re-entry guard.

2. **`--remove-label status:plan-review` no-op (line 1805):**
   ```bash
   gh issue edit "$cid" -R "$CB_REPO" --remove-label status:plan-review --add-label status:approved 2>/dev/null || true
   ```
   The `status:plan-review` label is absent in the limbo state (by definition — the reconcile
   block only fires when `status:plan-review` is NOT present and `status:approved` is NOT
   present). The GitHub CLI silently ignores `--remove-label` for labels not on the issue
   (`2>/dev/null || true` suppresses any error). The `--add-label status:approved` is the
   idempotent label set: if already present, it is a no-op.

   Additionally, the jq filter at line 1795 explicitly excludes charters that already carry
   `status:approved`, so the outer `for` loop body is never reached for already-approved
   charters. The `sget term` guard provides an in-process guard; the jq filter provides a
   cross-restart guard.

**Verdict: PASS** — repeated ticks are safely gated; no label thrashing possible.

---

## Invariant 2: Leaf-count guard preserved — PASS

**Location:** `reference/runtime/crewboss-launcher-gh.sh` lines 1214–1236 (tech-lead
completion path, `require_decomp_leaves` gate) vs. lines 1790–1809 (reconcile block).

The reconcile block filters on `plan:agreed` being present (line 1793). The `plan:agreed`
label can **only** be set by the plan-reviewer AGREE path (via `CB_PLAN_REVIEW_SPAWN`).
The plan-reviewer is only spawned from the PLAN-convergence gate (lines 1736–1772), which
is gated on `status:plan-review`. A charter only reaches `status:plan-review` via the
tech-lead spawn completion path (lines 1200–1251), which runs the `require_decomp_leaves`
gate **before** releasing to `status:plan-review`:

```
tech-lead spawn completes
  → require_decomp_leaves check (lines 1215–1236)
      → 0 leaves: route to needs-plan OR blocked (does NOT set status:plan-review)
      → ≥1 leaves: proceeds to sset term 1 (plan-review is already set by the spawn stub)
  → plan-reviewer spawned only when status:plan-review is present
  → plan-reviewer AGREE sets plan:agreed
```

Therefore, `plan:agreed` is structurally unreachable for a charter with 0 leaves. The
reconcile block cannot bypass the leaf-count gate.

**Verdict: PASS** — no charter with 0 leaves can satisfy the reconcile block's entry condition.

---

## Invariant 3: Non-manifest flow untouched — PASS

**CB_AUTO_PLAN_APPROVE path (line 1241):**
```bash
if ([ "${CB_AUTO_PLAN_APPROVE:-0}" = "1" ] || [ "$_auto_plan_approve_label" = "true" ]) && [ "$cst" = "plan-review" ] && [ -z "$_plrr" ]; then
```
This line is unchanged from the pre-patch state. The `[ -z "$_plrr" ]` guard remains intact,
ensuring auto-approval only fires when `plan_review_role` is NOT configured in the manifest.

**`if [ -n "$_plan_review_role" ]` guard on the reconcile block (line 1790):**
The reconcile block is wrapped in the same guard as the main PLAN-convergence gate
(line 1730: `if [ -n "$_plan_review_role" ]`). When `plan_review_role` is absent from
the manifest, `_plan_review_role` is empty, and the entire reconcile block is skipped.
There is zero interaction with the CB_AUTO_PLAN_APPROVE path, which lives in a completely
different code section (tech-lead completion at line 1241 vs. charter list processing
at line 1790).

**Verdict: PASS** — CB_AUTO_PLAN_APPROVE path is untouched; reconcile block is correctly
guarded by `if [ -n "$_plan_review_role" ]`.

---

## Invariant 4: Test coverage — PASS

Three new test scenarios added to `reference/tests/plan-convergence.test.sh`:

### LIMBO-RECOVER (lines 353–376)

- **Setup:** Charter #5 with `plan:agreed` + `composition:approved` but NO `status:plan-review`.
- **Assertions:**
  - Plan-reviewer spawn count = 0 ✓ (plan:agreed already present, no review needed)
  - `issue_state 5` = "approved" ✓ (reconcile block fires and transitions to status:approved)
  - Log contains both "plan:agreed" and "status:approved" ✓ (confirms reconcile gate logged the release)
- **Coverage:** Directly exercises the bug scenario described in charter #955.

### NORMAL-FLOW-INTACT (lines 379–399)

- **Setup:** Charter #5 with `status:plan-review` + `composition:approved` + `plan:agreed`.
- **Assertions:**
  - Plan-reviewer spawn count = 0 ✓ (plan:agreed short-circuits review in the existing gate)
  - `issue_state 5` = "approved" ✓ (existing gate at line 1744 still fires)
- **Coverage:** Regression guard ensuring the reconcile block doesn't interfere with the
  normal agreed→approved path (charter still in `status:plan-review` when agreed is set).

### NO-PREMATURE-APPROVE (lines 402–443)

Three sub-cases with separate sandboxes:

- **(a) plan:agreed only, no composition:approved:** `issue_state 5` ≠ "approved" ✓
- **(b) composition:approved only, no plan:agreed:** `issue_state 5` ≠ "approved" ✓
- **(c) plan:agreed + composition:approved + hold:** `issue_state 5` ≠ "approved" ✓

- **Coverage:** Guards all three partial-condition cases. The reconcile block's jq filter
  correctly requires all of: `plan:agreed`, `composition:approved`, NOT `status:approved`,
  NOT `status:blocked`, NOT `hold`. Sub-case (c) specifically verifies the `hold` label
  filter at line 1797.

**Label-state assertions:** All three scenarios assert on `issue_state` (derived from label
state in the board JSON), providing direct label-state verification. ✓

**Spawn-count assertions:** LIMBO-RECOVER and NORMAL-FLOW-INTACT both assert plan-reviewer
spawn count = 0 via `PLAN_REVIEW_LOG` grep count. ✓

**Log-line assertions:** LIMBO-RECOVER asserts `grep -q "plan:agreed"` and `"status:approved"`
in the launcher log, confirming the reconcile gate's log line at launcher line 1807. ✓

**Verdict: PASS** — coverage is sufficient and assertions are correctly scoped.

---

## Invariant 5: Shell syntax — PASS

```
$ bash -n reference/runtime/crewboss-launcher-gh.sh && echo "SYNTAX OK"
SYNTAX OK
```

No syntax errors. The reconcile block uses standard POSIX-compatible constructs: `for`/`do`/`done`,
`[ ]` tests, command substitution, and `&&`/`||` short-circuits. No bashisms beyond what was
already present in the file.

**Verdict: PASS**

---

## Machine acceptance checks

```
$ bash reference/tests/plan-convergence.test.sh
ok   PLAN-CONVERGE: plan-reviewer spawned exactly 2× (1 CRITIQUE + 1 AGREE)
ok   PLAN-CONVERGE: tech-lead RE-PLANNED (spawned 2× — the rework round happened)
ok   PLAN-CONVERGE: plan:agreed set after convergence
ok   PLAN-CONVERGE: rework round recorded (≥1 PLAN-REVIEW critique comment, got 1)
ok   PLAN-CONVERGE: charter released to status:approved (leaves unblocked)
ok   PLAN-CONVERGE: gate logged the plan:agreed → approved release
ok   PLAN-CONVERGE: tech-lead post-proc deferred to the gate (not terminal at plan-review)
ok   PLAN-ESCALATE: plan-reviewer spawned exactly cap=3 times (no runaway ping-pong)
ok   PLAN-ESCALATE: human-decision created at cap
ok   PLAN-ESCALATE: human-decision titled 'plan did not converge'
ok   PLAN-ESCALATE: charter NOT released to approved (cap held the gate shut)
ok   PLAN-ESCALATE: idempotent — no duplicate human-decision on second run
ok   AGREED-SKIP: plan-reviewer NOT spawned (already agreed)
ok   AGREED-SKIP: charter released straight to status:approved
ok   LIMBO-RECOVER: plan-reviewer NOT spawned (plan:agreed already present)
ok   LIMBO-RECOVER: charter reached status:approved (reconcile block fired)
ok   LIMBO-RECOVER: log contains 'plan:agreed' and 'status:approved' (reconcile gate logged release)
ok   NORMAL-FLOW-INTACT: plan-reviewer NOT spawned (plan:agreed short-circuits review)
ok   NORMAL-FLOW-INTACT: charter released to status:approved (existing gate still fires)
ok   NO-PREMATURE-APPROVE(a): plan:agreed-only charter NOT approved (composition:approved absent)
ok   NO-PREMATURE-APPROVE(b): composition:approved-only charter NOT approved (plan:agreed absent)
ok   NO-PREMATURE-APPROVE(c): held charter (plan:agreed + composition:approved + hold) NOT approved

passed=22 failed=0

$ bash -n reference/runtime/crewboss-launcher-gh.sh && echo "SYNTAX OK"
SYNTAX OK
```

---

## Verdict

**APPROVED — all five invariants GREEN, both machine acceptance checks GREEN.**

PRs for leaf #957 (infra-engineer) and leaf #956 (qa-engineer) are approved.
