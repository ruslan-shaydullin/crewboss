# Review: Charter #707 — `build_state()` 304 regression fix

**Reviewer leaf:** #812  
**Reviewed PRs:** leaf-A #810 (crewboss-api.py), leaf-B #811 (manifest + count sync), leaf-C #809 (304 regression test)  
**Verdict:** ✅ APPROVED — all checklist items pass, all acceptance checks green

---

## Leaf-A checklist (`crewboss-api.py` fix — PR #810)

- ✅ **if/else structure**: `issues = _cached_issues` is in the `if "304" in ...` branch; the
  ETag extraction loop, `json.loads(body)`, and `_cached_issues = ...` assignments are all in the
  `else` branch. The two paths are mutually exclusive.
- ✅ **No bare `return _cached_issues`**: the 304 path sets `issues` and falls through to board
  assembly — no early return bypassing the dict construction.
- ✅ **Exception handler cannot fire on 304**: `except Exception: issues = []` is outside the
  if/else block; `json.loads(body)` only executes in the `else` branch (non-304 path), so an
  empty body from a 304 response can never reach `json.loads`.
- ✅ **Board assembly runs on cached data**: when a 304 is received, `issues = _cached_issues`
  (the previously stored list), and `for it in issues:` builds the board dict normally — the
  board is never assembled from `[]` on the 304 path.
- ✅ **Python syntax valid**: `python3 -m py_compile ui/server/crewboss-api.py` exits 0.

## Leaf-B checklist (manifest + count sync — PR #811)

- ✅ **`ALLOW ui-api-contract`** is present at line 98 with inline justification:
  > "static grep/awk analysis of .ts/.tsx and crewboss-api.py source files; no background
  > process, no network, no timing; verdict = pure function of merged content"
- ✅ **All 3 previously-unclassified tests classified** with documented reasoning:
  - `recovery-cap`: drives REAL launcher through completion ticks → EXCLUDED (fail-closed)
  - `triage`: drives REAL launcher; Test 8B creates sleep-30 stub — violates background-process
    and timing criteria → EXCLUDED (fail-closed)
  - `triage-bounce-evidence`: drives REAL launcher with stateful gh stub → EXCLUDED (fail-closed)
- ✅ **`EXCLUDED api-state-304-regression`** entry is present (lines 197–200) with criterion
  justification: "starts crewboss-api.py + stub gh as background processes, exercises the
  ETag/304 path end-to-end — Background/process-bound → EXCLUDED (fail-closed)."
- ✅ **Count literals in leaf-verifier.test.sh Test 7** match actual post-change manifest:
  ALLOW=23, EXCLUDED=62, actual=85 — verified live by `bash reference/tests/leaf-verifier.test.sh`.
- ✅ **Manifest header** reflects final counts: `Counts: ALLOW=23, EXCLUDED=62, union=85`.
- ✅ **`bash reference/tests/leaf-verifier.test.sh`** → passed=20 failed=0.

## Leaf-C checklist (304 regression test — PR #809)

- ✅ **File location**: `reference/tests/api-state-304-regression.test.sh` — basename matches
  the `EXCLUDED api-state-304-regression` manifest entry from leaf-B.
- ✅ **Two sequential `/api/state` requests**: Test 1 (cold, lines 95–109) and Test 2 (304-path,
  lines 117–131) each call `/api/state` and assert shape independently.
- ✅ **First request asserts JSON object**: checks `first char == '{'` and that all five keys
  (`board`, `agents`, `budget`, `flags`, `autonomy`) are present — not a JSON array.
- ✅ **Second request (304 path) asserts same shape**: same five-key check on the response after
  the stub `gh` returns HTTP 304 (triggered by `If-None-Match` in args). Test 3 additionally
  confirms `type(response).__name__ == 'dict'`, not `'list'`.
- ✅ **Cleanup via `trap`**: `trap cleanup EXIT` at line 39; `cleanup()` kills `$API_PID` and
  removes `$ROOT` — no background process leaks.
- ✅ **Syntax valid**: `bash -n reference/tests/api-state-304-regression.test.sh` exits 0.

---

## Acceptance gate results

```
check: bash -n reference/tests/api-state-304-regression.test.sh  → PASS
check: bash reference/tests/leaf-verifier.test.sh                → passed=20 failed=0
check: python3 -m py_compile ui/server/crewboss-api.py           → PASS
```

All three acceptance checks are green on the current HEAD of `charter/707`.

---

## Summary

The three leaves correctly fix the `build_state()` 304 regression (#527):

- **Leaf-A** restructures the if/else so that a 304 response sets `issues = _cached_issues` and
  board assembly runs normally — `json.loads` is never called on an empty body, and the
  exception handler `issues = []` is unreachable on the 304 path.
- **Leaf-B** promotes `ui-api-contract` to ALLOW, classifies the three previously-unclassified
  tests (`recovery-cap`, `triage`, `triage-bounce-evidence`) as EXCLUDED with documented
  reasoning, adds the `EXCLUDED api-state-304-regression` entry for leaf-C's new test, and
  updates all count literals and the manifest header to ALLOW=23 / EXCLUDED=62 / union=85.
- **Leaf-C** provides an end-to-end regression test with a stub `gh` that exercises the 304
  ETag path without any real network, asserting that both the cold response and the 304-path
  response are JSON objects with the correct board shape (not a raw issue list).

**Verdict: APPROVED.**
