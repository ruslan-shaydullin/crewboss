# Integration Review: Issue #679 — Charter #597 Test-Quality Gate Cross-Cutting Review

**Reviewed leaves:** #676 (infra-engineer/wire) · #677 (qa-engineer/tests) · #678 (executor/impl)  
**Head commit reviewed:** `891cb0a` (merge of #682 / leaf/678 into `charter/597`)  
**Reviewer:** leaf/679-1782334822 (reviewer, charter #597)  
**Review date:** 2026-06-24  
**Charter:** #597

---

## Verdict: ✅ APPROVED — all acceptance checks green, all review items pass

### Machine acceptance checks

```
check: test -f reference/bin/test-lint.sh                              → PASS ✅
check: grep -q "EXCLUDED webhook-security" reference/runtime/per-leaf-manifest  → PASS ✅
check: grep -q "EXCLUDED test-quality-gate" reference/runtime/per-leaf-manifest → PASS ✅
check: grep -q "_excl_count -eq 58" reference/tests/leaf-verifier.test.sh       → PASS ✅
check: grep -q "_actual_count -eq 80" reference/tests/leaf-verifier.test.sh     → PASS ✅
check: grep -q "SKIP: gate script not yet merged" reference/tests/test-quality-gate.test.sh → PASS ✅
check: bash -n reference/bin/test-lint.sh                              → PASS ✅
```

### Live test runs

`bash reference/tests/test-quality-gate.test.sh` → **passed=21 failed=0** ✅  
`bash reference/tests/leaf-verifier.test.sh` (Test 7) → **ALLOW=22 EXCLUDED=58 actual=80, all 5 sub-checks pass** ✅

---

## Stage logic — does it actually catch #522 failure modes?

### Stage 1 (reference-correctness / anti-pattern lint)

`run-test-quality-gate.sh` lines 79–105: scans all `*.test.sh` files under `$REPO_DIR/reference/tests`
for anti-patterns A and B.

**Anti-pattern A** (`grep -c ... || echo 0`): regex `'grep -c .* \|\| echo 0'` — fires correctly
in S2 scenario (verified by test-quality-gate.test.sh passed=21).

**Anti-pattern B** (BIN used in PATH but not exported): dual-grep pattern checks for
`PATH=.*\$BIN` present AND `export BIN` absent — fires correctly in S1 scenario (verified by
test-quality-gate.test.sh passed=21, S1 assertions all `ok`).

**Routing**: on lint hit → `_route_test_broken` → `status:test-broken` applied to `$QA_LEAF`,
NOT `$IMPL_LEAF`. `status:impl-broken` withheld. This is the correct routing for #522's
failure mode (buggy test, not buggy impl). ✅

**Reference tree**: `$REPO_DIR` is the charter branch tree passed via `--repo-dir`; the
`_tqg_cycle` in the launcher does NOT pass `--repo-dir` (local checkout path), so Stage 1
lint runs against the merged charter tree that contains both qa-engineer and impl leaves. The
impl leaf (#678) is present before the gate fires (guard: all leaves closed). ✅

### Stage 2 (determinism / harness run)

Lines 113–133: runs all ALLOW-class tests in `$REPO_DIR/reference/tests` against the charter
tree. S5 scenario demonstrates correct routing: lint-clean test that exits 1 → `_route_impl_broken`.
S3 (flaky test) is an acknowledged known-gap (N-run determinism not yet wired; scenario passes
with the acceptable "known gap" outcome per test harness design). ✅

### Stage 3 (anti-pattern lint — standalone binary)

`reference/bin/test-lint.sh` detects:
- Anti-pattern A: `grep -qE 'grep[[:space:]]+-c[[:space:]].*\|\|[[:space:]]*echo[[:space:]]+0'` — tested manually: correct.
- Anti-pattern B: PATH uses `$BIN` without `export BIN` — dual-grep pattern. ✅
- Anti-pattern C (flock) as bonus catch. ✅

`bash -n reference/bin/test-lint.sh` → exit 0 (syntax clean). ✅

---

## Gate timing and reference (Fix #1)

`_tqg_cycle` (launcher line 1260) is called after `_integrator_cycle` (which merges leaves)
and before `_charter_finale_cycle`. The guard at line 684:

```bash
[ "${_tqg_open:-1}" = "0" ] || return 0   # leaves still open — not ready
```

ensures the gate fires only when ALL leaves for the charter are closed — i.e., BOTH qa-engineer
(#677) and impl (#678) leaves are in the charter tree. Gate does NOT fire after only qa-engineer
merges. ✅

Reference for Stage 1 is `--repo-dir` (charter merge tree with impl present). No reference to
`main`. A TDD test of new functionality cannot receive false `test-broken` because the impl leaf
must be closed before the gate fires. ✅

---

## Tooling separation (Fix #4)

`reference/bin/test-lint.sh` — NEW file (not present before leaf #678). Content: anti-pattern
linter for `*.test.sh` files; Stage 3 of the gate. ✅

`reference/bin/leaf-lint.sh` — unmodified. Still validates only `Charter:` / `Depends-on:`
issue body fields (grep patterns for `^Charter: #[0-9]+$` and `^Depends-on:`). No test-file
analysis added. 49 lines, same as pre-charter/597 baseline. ✅

---

## Routing signal (Fix #3)

Exact label names in `run-test-quality-gate.sh`:
```bash
gh issue edit "$QA_LEAF"   -R "$REPO" --add-label "status:test-broken"   # line 63
gh issue edit "$IMPL_LEAF" -R "$REPO" --add-label "status:impl-broken"   # line 71
```

- `status:test-broken` applied to `$QA_LEAF` (qa-engineer leaf issue number). ✅
- `status:impl-broken` applied to `$IMPL_LEAF` (executor leaf issue number). ✅
- No variant label names (no `test_broken`, `testbroken`, etc.). ✅

Re-dispatch path: `_tqg_cycle` sub-step A (lines 646–665) detects open type:agent leaves that
already carry `status:test-broken` or `status:impl-broken` and adds `status:needs-rework` so
the launcher's existing rework path (run-rework.sh / `board route requeue`) picks them up. ✅

---

## per-leaf-manifest + leaf-verifier.test.sh (Fixes #2, #7, #8)

### per-leaf-manifest

```
EXCLUDED webhook-security   # comment: background Python server + network
EXCLUDED test-quality-gate  # comment: subprocess + gh stub
```
Both entries present at lines 175–177. Justification comments are present. ✅

Header line (line 17):
```
# Counts: ALLOW=22, EXCLUDED=58, union=80  (verify with: leaf-verifier.test.sh Test 7)
```
✅ Correct counts.

Actual counts verified:
```bash
grep -c '^ALLOW '    reference/runtime/per-leaf-manifest  → 22
grep -c '^EXCLUDED ' reference/runtime/per-leaf-manifest  → 58
ls reference/tests/*.test.sh | wc -l                      → 80
```

### leaf-verifier.test.sh

Line 244: `echo "=== Test 7: Composition/guard fail-closed (manifest completeness, ALLOW=22 EXCLUDED=58) ==="` ✅  
Line 266: `[ $_excl_count -eq 58 ]` ✅  
Line 270: `[ $_actual_count -eq 80 ]` ✅  

Test 7 live run output:
```
ok   guard: ALLOW count=22
ok   guard: EXCLUDED count=58
ok   guard: actual *.test.sh count=80
ok   guard: ALLOW∩EXCLUDED=∅ (disjoint)
ok   guard: ALLOW∪EXCLUDED == actual reference/tests/*.test.sh (no unclassified, no phantom)
```
All 5 sub-checks pass. ✅

---

## Existence guard (Fix #5)

`reference/tests/test-quality-gate.test.sh` lines 37–41:

```bash
if [ ! -f "$GATE_SCRIPT" ]; then
  printf 'SKIP: gate script not yet merged\n'
  printf 'passed=0 failed=0\n'
  exit 0
fi
```

Pattern matches `acceptance-convergence.test.sh` lines 28–33:
- Condition guard
- `printf 'SKIP…\n'`
- `printf 'passed=0 failed=0\n'`
- `exit 0`

Guard fires correctly: if `run-test-quality-gate.sh` is absent, the test exits 0 immediately.
Charter/597 CI does not red when qa leaf (#677) lands before impl leaf (#678). ✅

---

## EXCLUDED-class correctness (Fix #6)

`test-quality-gate.test.sh` classified as `EXCLUDED test-quality-gate` in per-leaf-manifest
(line 177). NOT in ALLOW list. ✅

All variables used in background subshells are exported:
```bash
export BIN ROOT          # line 50
export GH_LOG GATE_SCRIPT  # line 52
export _flaky_flag        # line 179 (used in flaky subshell test)
```
✅

No `sleep` or timing asserts in the test file. ✅  
Test is deterministic given fixed inputs (all I/O through `$GH_LOG` file; no real network;
flaky subshell behavior is reproducible given the flag file state). ✅

---

## Bootstrap / scoped execution (#193)

`_tqg_cycle` line 637:
```bash
[ "$CHARTER_SCOPE" = "0" ] && return 0
```
Gate returns immediately (no-op) in unscoped/multi-charter mode. Gate does NOT route through
the multi-charter queue. ✅

Gate is invocable in SCOPED mode via:
```bash
bash run-test-quality-gate.sh --charter CID --qa-leaf QID --impl-leaf IID [--repo-dir DIR]
```
✅

---

## New anti-pattern risks

Checked `run-test-quality-gate.sh` for the patterns it is designed to detect:

- `grep -c ... || echo 0`: NOT present in the gate script. Only appears in comments and in
  grep-qE detection patterns (which detect the pattern, not use it). ✅
- Unexported BIN in PATH: gate does NOT use `$BIN` in PATH at all. ✅
- `flock`: NOT present in the gate script. ✅

Gate is self-consistent: it does not exhibit the anti-patterns it detects. ✅

---

## Summary

All 8 categories from the review checklist pass. All 7 machine acceptance checks are green.
Live test runs (test-quality-gate.test.sh: 21/21 pass; leaf-verifier.test.sh Test 7: 5/5 pass)
confirm correct behavior, not merely structural presence.

The implementation correctly catches the #522 failure modes (BIN not exported in background
subshell; `grep -c ... || echo 0` integer-context error), applies the correct routing signals
to the correct leaf issues, fires post-all (after both qa and impl leaves merge), and does not
introduce new instances of the anti-patterns it detects.
