# Security Review: Issue #652 — ITA Bash-path Guard (charter #593)

**Reviewed PR:** issue #650 (`feat(#650): add ITA Bash-path guard to crewboss-gate.sh`)  
**Head commit reviewed:** `2a0a1a5`  
**Reviewer:** leaf/652 (security-reviewer, charter #593)  
**Review date:** 2026-06-24  
**Rubric:** "lazy/dishonest" reliability tier (per gate header SCOPE); adversarial evasion explicitly carved out.

---

## Gate extension under review

```bash
# ITA Bash-path: block executor from writing test files via shell redirect/tee
if printf '%s' "$cmd" | grep -Eq '(>|>>)[[:space:]]*(tests/|\S*(\.test\.(sh|ts|js|py)|/tests/))' \
   || printf '%s' "$cmd" | grep -Eq '(^[[:space:]]*|[|;][[:space:]]*)tee([[:space:]]+-[a-zA-Z]+)*[[:space:]]+(tests/|\S*(\.test\.(sh|ts|js|py)|/tests/))'; then
  [ "$role" = "executor" ] && { printf 'crewboss BLOCK [%s]: test-file writes via Bash are test-author-only ...\n' "$role" >&2; exit 2; }
fi
```

---

## Section 1 — Bypass vectors

### Finding F-1 · tee --append bypass · **P1**

**Description:**  
The tee flag-skip pattern `([[:space:]]+-[a-zA-Z]+)*` only matches single-dash flags (e.g. `-a`, `-i`).
The POSIX long-form `--append` uses a double-dash prefix and is NOT matched by `-[a-zA-Z]+`.
When `--append` appears, the regex cannot consume it as a flag token, so the subsequent
file-path position check fails to reach `foo.test.sh`.

**Proof-of-concept:**
```bash
echo x | tee --append foo.test.sh       # exit 0 (allowed — gate miss)
echo x | tee --append tests/new.sh      # exit 0 (allowed — gate miss)
```
Verified: `exit 0` observed on commit `2a0a1a5` (should be `exit 2`).

**In-scope classification:**  
`--append` is standard `tee(1)` usage — not adversarial, not in the header carve-out list.
A lazy/honest executor reaching for `tee --append` to extend a test helper would bypass the gate
silently. Severity: **P1** (reliable bypass via natural usage pattern).

**Recommended fix:**  
Extend the flag-skip alternation from single-dash only to both dash forms, and allow `key=value`
values embedded in the flag token (used by GNU tee `--output-error=warn`):

```bash
# Before:
([[:space:]]+-[a-zA-Z]+)*
# After:
([[:space:]]+--?[a-zA-Z][a-zA-Z=_-]*)*
```

Regex proof that `-a`, `--append`, and `--output-error=warn` all match, and that
`grep tee tests/foo.sh` still does NOT match (false-positive guard preserved):
```
printf 'tee --append foo.test.sh'      | grep -Eq '...(pattern)...'  => MATCH  ✓
printf 'tee -a foo.test.sh'            | grep -Eq '...(pattern)...'  => MATCH  ✓
printf 'tee --output-error=warn f.t.sh'| grep -Eq '...(pattern)...'  => MATCH  ✓
printf 'grep tee tests/foo.sh'         | grep -Eq '...(pattern)...'  => NO-MATCH ✓
```

---

### Finding F-2 · Process substitution redirect · **P2**

**Description:**  
`echo x > >(tee foo.test.sh)` uses bash process substitution as the redirect target.
The redirect arm `(>|>>)[[:space:]]*` matches the leading `>`, then `\S*` attempts to match
`>(tee` and stops at the space; `.test.sh` is not immediately adjacent to the non-whitespace
prefix, so the overall match fails. The tee arm also fails: `tee` is preceded by `(`, not
`^`, `|`, or `;`.

**Proof-of-concept:**
```bash
echo x > >(tee foo.test.sh)     # exit 0 (allowed — gate miss)
```
Verified: `exit 0` observed on commit `2a0a1a5` (should be `exit 2`).

**Classification:**  
Process substitution is not listed in the gate header's explicit carve-out (which names:
param-expansion, variable indirection, `eval`, aliases, backslash-continuation). However,
using `>(...)` as a redirect target requires deliberate syntactic choice; it is closer to
the adversarial tier than natural usage. Severity: **P2** (borderline; document and monitor).

**Recommended fix:**  
Add a third arm to detect `> >(` process-substitution redirects targeting test files:

```bash
|| printf '%s' "$cmd" | grep -Eq '>\s*>\([[:space:]]*(tee[[:space:]]+)?(tests/|\S*(\.test\.(sh|ts|js|py)|/tests/))'
```

Or equivalently, pre-normalise `>(tee FOO)` → `| tee FOO` before the existing pattern runs,
since process substitution in this context is semantically identical to a pipe.

---

### Out-of-scope items (verified, no action required)

| Vector | PoC | Slips? | Scope ruling |
|---|---|---|---|
| Variable indirection | `f=foo.test.sh; echo x > $f` | Yes (exit 0) | **OOS** — explicitly in header carve-out ("variable indirection") |
| Command substitution | `echo x > $(echo foo.test.sh)` | Yes (exit 0) | **OOS** — related to variable indirection / param-expansion carve-out |

---

## Section 2 — False-positive analysis (benign executor commands)

All three checked. No false-denials observed.

| Command | Expected | Got | Verdict |
|---|---|---|---|
| `bash reference/tests/independent-test-authorship.test.sh` | exit 0 | exit 0 | ✓ PASS |
| `cat foo.test.sh` | exit 0 | exit 0 | ✓ PASS |
| `grep "pattern" reference/tests/gate-layer-a.test.sh` | exit 0 | exit 0 | ✓ PASS |

The redirect arm correctly requires `>` or `>>` before a test path, so pure reads
(`cat`, `bash`, `grep`) are not matched. The tee arm correctly requires `^`, `|`, or `;`
before `tee`, so `grep tee tests/foo.sh` is not matched (no false-positive on grep of "tee").

---

## Section 3 — Confirmed-caught vectors (gate is correct)

| Vector | PoC | Gate result | Verdict |
|---|---|---|---|
| Simple redirect | `echo x > foo.test.sh` | exit 2 | ✓ CAUGHT |
| Append redirect | `echo x >> foo.test.sh` | exit 2 | ✓ CAUGHT |
| Heredoc redirect | `cat > foo.test.sh << 'EOF'` | exit 2 | ✓ CAUGHT |
| tee (pipe) | `echo x \| tee foo.test.sh` | exit 2 | ✓ CAUGHT |
| tee -a (pipe) | `echo x \| tee -a foo.test.sh` | exit 2 | ✓ CAUGHT |
| tee (semicolon) | `cmd; tee tests/foo.sh` | exit 2 | ✓ CAUGHT |
| redirect to tests/ | `echo x > tests/foo.sh` | exit 2 | ✓ CAUGHT |
| tee to tests/ | `echo x \| tee tests/foo.sh` | exit 2 | ✓ CAUGHT |

---

## Section 4 — qa-engineer scope

**Verdict: CORRECT — no widening.**

The guard is:
```bash
[ "$role" = "executor" ] && { ...; exit 2; }
```

If the pattern matches for a non-executor role (e.g. `qa-engineer`), the early-exit does NOT
fire. Execution continues past the `if` block into the `canon()` flow, which does not gate
`qa-engineer` writes to test files. All three qa-engineer test commands verified `exit 0`:

```bash
echo x > foo.test.sh          [qa-engineer] -> exit 0 ✓
echo x | tee foo.test.sh      [qa-engineer] -> exit 0 ✓
echo x >> tests/foo.sh        [qa-engineer] -> exit 0 ✓
```

No other role widening was introduced. `tech-lead` and other roles are unaffected by this
extension (they would also fall through, which is correct — the ITA constraint is specifically
on `executor`).

---

## Summary

| # | Severity | Description | Status |
|---|---|---|---|
| F-1 | **P1** | `tee --append` (long-form flag) bypasses the tee arm | Needs fix |
| F-2 | P2 | Process substitution `> >(tee ...)` bypasses both arms | Borderline adversarial; document |
| — | OOS | Variable indirection (`$f`), command substitution (`$(...)`) | Explicitly carved out by header |
| — | ✓ | Heredoc, append `>>`, simple redirect, tee -a | Correctly caught |
| — | ✓ | Benign reads (cat, bash, grep) — no false-deny | Verified |
| — | ✓ | qa-engineer fall-through — no role widening | Verified |

**Disposition:** Conditional approval. F-1 (P1) should be patched before this gate extension
is relied upon as a reliability control. F-2 (P2) is documented for the next hardening pass.
The existing test suite (independent-test-authorship.test.sh) does not cover `tee --append`;
a test case for that vector should be added alongside the F-1 patch.
