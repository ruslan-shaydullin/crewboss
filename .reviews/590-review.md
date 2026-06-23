# Verification Review: Issue #590 — Acceptance-Convergence Gate Review

**Issue:** #590 (Reviewer for charter #522)
**Reviewed:** leaf #589 (gate-impl PR), leaf #588 (tests PR)
**Review Date:** 2026-06-23
**Reviewer:** leaf/590-1782225151
**Charter:** #522

---

## Acceptance Checks Run

| Check | Result |
|---|---|
| `gh pr list -R stratch1989/crewboss --state open --json number --jq length` | `3` |
| `grep -q sset.*term reference/runtime/crewboss-launcher-gh.sh` | PASS |
| `grep -q _q_accept_head reference/runtime/crewboss-launcher-gh.sh` | PASS |
| `bash reference/tests/acceptance-convergence.test.sh` | FAIL (7 passed, 6 failed) |
| `bash reference/tests/queue-acceptance-convergence.test.sh` | FAIL (5 passed, 7 failed) |

---

## Change A (leaf #589): _finale_check_ci acceptance gate — PASS

- **`sset "$cid" term ""`** is present at launcher line 506, immediately after `gh issue edit "$cid" --add-label status:acceptance-review`. ✓
- Guard is placed **before** `gh pr merge` (line 516). ✓
- When `_acc_agreed = "true"`, the block is skipped and execution falls through to `gh pr merge "$pr_num"`. ✓
- `last_comment` guard (`if [ "$last_comment" != "acceptance-pending" ]`) prevents duplicate comments. ✓
- Entire Change A block is guarded by `if [ -n "$_acc_review_role" ]` — absent `acceptance_review_role` leaves flow unchanged. ✓

## Change B (leaf #589): acceptance-convergence loop — PASS

- Insertion point is after the `fi` closing the tech-lead/`plannable_scoped` loop (line 1432) and before `for id in $(board launchable)` (line 1534). ✓ (lines 1481–1533)
- Structurally mirrors plan-convergence gate (lines 1436–1480). ✓
- `aound` counter is isolated per-charter via `sget "$cid" aound` / `sset "$cid" aound`. ✓
- Convergence path (`accept:agreed = "true"`) writes `"pending"` to `ci_state` file (line 1506), does **not** `sset term 1`. ✓
- `status:acceptance-review` removed (line 1503) **before** writing `pending` to `ci_state`. ✓
- Human-decision idempotency check: `_ex_hd` body-matches `"Charter:\\s*#?" + ($c|tostring)` (line 1515) before creating. ✓

## Change C (leaf #589): `_q_accept_head` queue head — PASS

- Terminal list is `done|blocked` only (line 1158: `case "$_qst" in done|blocked) continue ;; esac`). `accept:agreed` is **not** in the terminal list. ✓
- Loop iterates `$_q_order` and breaks at first non-terminal charter. ✓
- `_q_accept_head` guard applied at line 1495: `[ -z "$_q_accept_head" ] && break; [ "$cid" = "$_q_accept_head" ] || continue`. ✓
- `_q_accept_head` declared and cleared in the same `local`/reset statement as `_q_plan_head` (lines 866 and 1130). ✓

## Change D (leaf #589): acceptance-review task reaper — PASS

- Routing branch inserted after the plan-review kind block (line 978 `fi`) at line 979–992. ✓
- `continue` is the unconditional last statement in the block (line 991). ✓
- `sset "$id" pid ""` fires unconditionally before the `accept:agreed` check (line 984). ✓
- When `accept:agreed = "true"`: `sset "$id" term ""` (line 988) and `sset "$id" aound 0` (line 989). ✓
- Does not call `board route blocked`. ✓
- Does not fall through to status.json reader (line 991 `continue` exits the loop body). ✓

---

## Test Correctness (leaf #588): FAIL — Two bugs found

### Bug 1: `"$BIN/gh"` in acceptance-review stubs — CRITICAL

Both `acceptance-convergence.test.sh` and `queue-acceptance-convergence.test.sh` write an `ACCEPT_STUB` file using a heredoc guarded with single quotes (`<< 'ACCSTUB'`), preventing expansion at write time. Inside the stub, `"$BIN/gh"` is used to call the `gh` stub:

```bash
"$BIN/gh" issue comment "$CID" -R "test/repo" --body "ACCEPT-REVIEW: agreed"
"$BIN/gh" issue edit "$CID" -R "test/repo" --add-label "accept:agreed"
```

However, `BIN` is **not exported** in either test file (line 61 in both: `BIN="$ROOT/bin"; mkdir -p "$BIN"`). The acceptance-review stub is spawned as a child process of the launcher; it inherits `PATH` (which contains `$BIN`) but not the `BIN` shell variable. At runtime `"$BIN/gh"` expands to `"/gh"` (not found), causing:
- `accept:agreed` label never added to `BOARD_STATE`
- Convergence path in Change B never triggered
- Reviewer spawned in a loop until `aound` hits cap (ACCEPT-CONVERGE) or `CB_MAX_TICKS` (HAPPY-PATH)

**Contrast with plan-convergence tests** (which pass): the `PLAN_REVIEW_STUB` uses `gh` (resolved via PATH) instead of `"$BIN/gh"`.

**Fix**: Replace `"$BIN/gh"` with `gh` in both ACCEPT_STUB heredocs, or add `export BIN` after line 61 in both test files.

### Bug 2: `grep -c ... || echo 0` produces `"0\n0"` for zero-match cases

`grep -c` **always** writes the match count to stdout (including `"0"` for zero matches) but exits with code 1 when count is 0. The pattern `$(grep -c 'pattern' file 2>/dev/null || echo 0)` captures grep's `"0"` AND then appends echo's `"0"`, yielding the string `"0\n0"`. Subsequent `[ "${var:-0}" -eq 0 ]` fails with *integer expression expected*.

Affected lines:

| File | Line | Scenario |
|---|---|---|
| `acceptance-convergence.test.sh` | 456 | DEFAULT-OFF `_spawn_d` |
| `queue-acceptance-convergence.test.sh` | 403 | CONTROL `_spawn_c50` |
| `queue-acceptance-convergence.test.sh` | 404 | CONTROL `_spawn_c100` |

**Fix**: Remove `|| echo 0` (grep -c always produces a count on stdout regardless of exit code), or change to `|| true` inside the subshell.

### Bug 3: CB_CONVERGE_CAP leaks from production environment

The test runner inherits `CB_CONVERGE_CAP=15` from the production crewboss environment. When `CB_ACCEPT_CONVERGE_CAP` is not explicitly set (ACCEPT-CONVERGE scenario), `_acap="${CB_ACCEPT_CONVERGE_CAP:-${CB_CONVERGE_CAP:-4}}"` evaluates to `15` instead of `4`. Combined with Bug 1 (accept:agreed never set), this causes 15 reviewer spawns before cap is hit, rather than the expected 2.

**Fix**: The test should explicitly set `CB_ACCEPT_CONVERGE_CAP` in the ACCEPT-CONVERGE scenario (as ACCEPT-ESCALATE already does with `CB_ACCEPT_CONVERGE_CAP=3`), or unset `CB_CONVERGE_CAP` at the top of each test run.

### Bug 4: Test files not registered in SHA-lock manifest

Neither `reference/tests/acceptance-convergence.test.sh` nor `reference/tests/queue-acceptance-convergence.test.sh` appears in `reference/runtime-manifest.tsv`. The spec (§ Test correctness) requires: *"Both test files registered in SHA-lock manifest."*

---

## Root Cause Summary

| Bug | Root Cause | Affected Scenarios |
|---|---|---|
| `"$BIN/gh"` in stubs (BIN not exported) | `BIN` set but not exported; child process can't use `"$BIN/gh"` | ACCEPT-CONVERGE, HAPPY-PATH |
| `grep -c ... \|\| echo 0` yields `"0\n0"` | grep -c exits 1 for 0 matches while still printing "0"; `\|\| echo 0` fires | DEFAULT-OFF, CONTROL |
| `CB_CONVERGE_CAP=15` from production env | Test doesn't isolate `CB_CONVERGE_CAP`; cap=15 instead of 4 | ACCEPT-CONVERGE (exacerbates Bug 1) |
| Test files absent from manifest | Leaf #588 didn't add entries to `runtime-manifest.tsv` | Manifest correctness check |

---

## Backward Compatibility — PASS

- `acceptance_review_role` absent → `_acc_review_role=""` → all Change A/B/C/D blocks guarded by `if [ -n "$_acc_review_role" ]` are skipped. Existing flows unchanged. ✓
- `CB_AUTO_MERGE=0` (human-merge) → Change A only executes inside the `if [ "${CB_AUTO_MERGE:-0}" = "1" ] || [ "$_charter_auto_merge" = "true" ]` block. Human-merge path unaffected. ✓

---

## Overall Verdict

**Implementation (leaf #589): APPROVED** — all four Changes (A/B/C/D) are structurally correct and match the round-5 specification.

**Tests (leaf #588): CHANGES REQUIRED** — two blocking bugs prevent the acceptance scenarios from converging:
1. `"$BIN/gh"` in stubs (BIN not exported) → `accept:agreed` never set → ACCEPT-CONVERGE and HAPPY-PATH fail
2. `grep -c ... || echo 0` → `"0\n0"` string in zero-match arithmetic → DEFAULT-OFF and CONTROL fail

Additionally, the test files are absent from the SHA-lock manifest.

Leaf #588 must be reworked to fix these two bugs and register both test files in `reference/runtime-manifest.tsv`.
