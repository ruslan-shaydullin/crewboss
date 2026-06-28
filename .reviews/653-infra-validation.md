# Infra Validation: Issue #653 — ITA Bash-path guard (charter #593)

**Issue:** #653 (infra-engineer for charter #593)
**Validating:** PR #655 — `feat(#650): add ITA Bash-path guard to crewboss-gate.sh`
**Validation Date:** 2026-06-24
**Validator:** leaf/653-1782308930
**Charter:** #593

---

## Summary

**ALL CHECKS PASS.** Bootstrap caveat #193 is satisfied, both gate copies are identical, and all three test suites exit 0 with zero failures.

---

## (a) Bootstrap caveat #193 compliance — PASS

The new ITA Bash-path block (`.claude/hooks/crewboss-gate.sh` lines 47–51):

```bash
# ITA Bash-path: block executor from writing test files via shell redirect/tee
if printf '%s' "$cmd" | grep -Eq '(>|>>)[[:space:]]*(tests/|\S*(\.test\.(sh|ts|js|py)|/tests/))' \
   || printf '%s' "$cmd" | grep -Eq 'tee([[:space:]]+-[a-zA-Z]+)*[[:space:]]+(tests/|\S*(\.test\.(sh|ts|js|py)|/tests/))'; then
  [ "$role" = "executor" ] && { printf 'crewboss BLOCK [%s]: test-file writes via Bash are test-author-only (independent test authorship, charter #523)\n' "$role" >&2; exit 2; }
fi
```

**Pure stdin JSON → binary function:** ✓
- Reads `$cmd` and `$role` which are extracted earlier in the gate from stdin JSON via `jqr`.
- Uses only `printf` + `grep -Eq` — both are subprocesses of the gate itself, not external services.
- No network calls whatsoever.
- No additional process spawns beyond `grep`/`printf`.

**Same ALLOW class as existing ITA tests:** ✓
- For non-executor roles and non-test-write commands, the block falls through (no exit).
- Only `executor` role attempting a write to a test path hits `exit 2`.
- No existing ALLOW cases are promoted to EXCLUDED or EXCLUDED-or-LAUNCHER class.
- The per-leaf-manifest ALLOW count is unchanged.

---

## (b) Both gate copies updated identically — PASS

```
$ diff .claude/hooks/crewboss-gate.sh reference/.claude/hooks/crewboss-gate.sh
(empty — no output)
```

The deployed copy (`.claude/hooks/crewboss-gate.sh`) and the reference copy (`reference/.claude/hooks/crewboss-gate.sh`) are byte-for-byte identical. No P0 divergence.

---

## (c) All three test suites green — PASS

### gate-layer-a.test.sh

```
$ bash reference/tests/gate-layer-a.test.sh
...
passed=46 failed=0
```

Exit 0. All 46 Layer-A assertions pass.

### gate-layer-b.test.sh

```
$ bash reference/tests/gate-layer-b.test.sh
...
passed=20 failed=0
```

Exit 0. All 20 Layer-B assertions pass.

### independent-test-authorship.test.sh

```
$ bash reference/tests/independent-test-authorship.test.sh
== (a) executor denied: Edit to protected test paths ==
ok   exit=2 [Edit/role=executor] foo.test.sh
ok   exit=2 [Edit/role=executor] foo.test.ts
ok   exit=2 [Edit/role=executor] src/tests/bar.sh
ok   exit=2 [Edit/role=executor] reference/tests/baz.test.sh
== (a) executor denied: Write to protected test paths ==
ok   exit=2 [Write/role=executor] foo.test.sh
...
== (bash-a) executor denied: redirect to test file via Bash ==
ok   exit=2 [Bash/role=executor] echo x > foo.test.sh
== (bash-b) executor denied: tee to test file via Bash ==
ok   exit=2 [Bash/role=executor] echo x | tee foo.test.sh
== (bash-c) qa-engineer allowed: redirect to test file via Bash ==
ok   exit=0 [Bash/role=qa-engineer] echo x > foo.test.sh
== (bash-d) executor allowed: redirect to non-test file via Bash ==
ok   exit=0 [Bash/role=executor] echo x > README.md
== (bash-e) executor allowed: running test file via Bash (no false-deny on test-runner) ==
ok   exit=0 [Bash/role=executor] bash reference/tests/independent-test-authorship.test.sh
== (bash-f) executor allowed: catting test file via Bash (no false-deny on reads) ==
ok   exit=0 [Bash/role=executor] cat foo.test.sh
== (bash-g) executor denied: redirect to tests/ subdir via Bash ==
ok   exit=2 [Bash/role=executor] echo x > tests/foo.sh
== (bash-h) executor denied: tee to tests/ subdir via Bash ==
ok   exit=2 [Bash/role=executor] echo x | tee tests/foo.sh
== (bash-i) executor denied: tee -a to test file via Bash (flag-skipping bypass) ==
ok   exit=2 [Bash/role=executor] echo x | tee -a foo.test.sh
== (c) verify-merged presence check ==
ok   presence: reference/tests/independent-test-authorship.test.sh exists on disk

passed=30 failed=0
```

Exit 0. All 30 assertions pass (21 pre-existing + 9 new Bash-path assertions from #649).
The 9 new bash-a through bash-i assertions cover: redirect `>`, tee, qa-engineer allow, non-test allow, test-runner false-deny guard, read false-deny guard, `tests/` subdir, tee to `tests/` subdir, and `tee -a` flag-skipping bypass.

---

## Verdict

**APPROVED — infra constraints satisfied.**

- (a) Bootstrap caveat #193: satisfied — pure stdin JSON → binary, no network, no extra spawns, ALLOW class unchanged.
- (b) Gate copies: identical — zero diff between deployed and reference copies.
- (c) Test suites: all green — gate-layer-a (46/46), gate-layer-b (20/20), ITA (30/30).
