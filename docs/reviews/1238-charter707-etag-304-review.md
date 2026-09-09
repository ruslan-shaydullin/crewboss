# Review: Issue #1238 — Charter #707 ETag 304-Path Board Empty (Bug #527)

**Issue:** #1238 (Reviewer for charter #707)
**Reviewed leaves:**
- #1237 (leaf-A, executor): `_parsed_c` pattern fix in `ui/server/crewboss-api.py`
- #1236 (leaf-B, executor): manifest promotion + leaf-verifier ALLOW literal update
- #1235 (leaf-C, qa-engineer): new `reference/tests/api-state-304-regression.test.sh`

**Review Date:** 2026-07-01
**Reviewer:** leaf/1238-1782939241
**Charter:** #707

---

## Summary

**APPROVED.** All three leaves are correct, complete, and mutually consistent. The fix closes
bug #527 without regressing any existing protection (#1131 non-list guard, #969 paginator).
All 8 machine acceptance checks pass. Gate coverage is solid: the 304 regression test
exercises both the 200+ETag seeding path and the 304 fallback path with a deterministic
stub — no live credentials, no production network.

---

## Leaf-A (#1237) — `ui/server/crewboss-api.py` ETag/304 fix

### Checklist

- [x] `_parsed_c = json.loads(body_c)` present (line 466 — temp var, not assigning directly to cache)
- [x] `if isinstance(_parsed_c, list):` assigns both `_cached_charters = _parsed_c` and
  `charters = _parsed_c` (lines 467–469)
- [x] `else:` branch sets `charters = []` and leaves `_cached_charters` unchanged;
  comment `# _cached_charters unchanged -- preserve last known good list` present (lines 470–472)
- [x] Old pattern `_cached_charters = json.loads(body_c)` is absent — the direct assignment
  that could poison the cache with a non-list error dict is gone
- [x] On 304: `charters = _cached_charters or []` (line 460) correctly falls back to the
  last known good list when GitHub returns 304 Not Modified
- [x] #1131 non-list-response protection is intact: the new `else:` branch sets
  `charters = []` and preserves `_cached_charters`, maintaining the same invariant as
  the prior guard

### Correctness analysis

The two-step assignment (`_parsed_c` → guard → `_cached_charters`) is the minimal correct
fix. The 304 branch is independent and fires first (before the ETag extraction / parse
block), so it cannot interfere with the new guard. The `or []` fallback handles the
cold-start case (first call ever with no cached list) without risk.

**Verdict: PASS**

---

## Leaf-B (#1236) — `reference/runtime/per-leaf-manifest` + `leaf-verifier.test.sh`

### Checklist

- [x] ALLOW criterion comment present above `ALLOW ui-api-contract` (line 100 of manifest:
  "static grep/awk of .ts/.tsx + crewboss-api.py; no background process, no network;
  verdict = pure function of merged content")
- [x] `ALLOW ui-api-contract` present (line 101 — promoted from EXCLUDED)
- [x] ALLOW criterion comment present above `ALLOW phantom-closed-leaf` (line 253:
  "self-contained python3+bash; no network access, no real GitHub repo; no background
  process, no timing/poll; verdict = pure function of merged content")
- [x] `ALLOW phantom-closed-leaf` entry present (line 254)
- [x] `EXCLUDED api-state-304-regression` entry present (line 255) — consistent with
  leaf-C's background-server classification
- [x] Manifest header: `ALLOW=25, EXCLUDED=77, union=102` (line 17) — verified by manual
  count: 25 ALLOW entries, 77 EXCLUDED entries, sum = 102 ✓
- [x] `leaf-verifier.test.sh` ALLOW literal updated to 25 in all three places:
  echo line (line 251: `ALLOW=25`), assertion (line 269: `-eq 25`), ok message (line 270:
  `"guard: ALLOW count=25"`)
- [x] EXCLUDED and actual counts NOT hardcoded — both derived dynamically via `grep -c` /
  `wc -l` / `ls *.test.sh` (lines 257–263), consistent with the #1073/#994 precedent
  that baked literal EXCLUDED/actual counts churn

### Minor observation (non-blocking)

The `ko` failure message on line 271 still reads `"guard: ALLOW count expected 23, got
$_allow_count"` — a stale copy of the old 23 baseline. This message is only displayed on
assertion failure (i.e., if the guard is broken), so it does not affect correctness or
gating. Recommend updating to `25` in a follow-up for clarity.

**Verdict: PASS**

---

## Leaf-C (#1235) — `reference/tests/api-state-304-regression.test.sh`

### Checklist

- [x] File exists at `reference/tests/api-state-304-regression.test.sh`
- [x] Background server: `python3 "$API_PY" --port "$PORT" > "$TMP/server.out" 2>&1 &`
  (line 150–151); `SERVER_PID=$!` (line 153); polled until ready (lines 155–167)
- [x] First GET `/api/state` (200 path): asserts response is a dict with keys `board`,
  `agents`, `budget`, `flags`, `autonomy` (lines 175–209)
- [x] Second GET `/api/state` (304 path): asserts same-shaped dict with all five keys
  still present (lines 217–236)
- [x] `board` is non-empty after 304 path — core regression assertion for bug #527 (lines
  238–253): passes only when `_cached_charters` was preserved and flowed through correctly
- [x] Background server cleaned up on exit: `trap cleanup EXIT` (line 51); `cleanup()`
  kills `$SERVER_PID` and removes `$TMP` (lines 47–50)
- [x] Classified `EXCLUDED` in manifest (leaf-B's entry on line 255 of per-leaf-manifest)
  — comment in test header confirms reason: "uses a background server process" (line 19)
- [x] Self-contained: stub `gh` binary written to `$TMP/bin/` (lines 75–135); `CB_REPO`,
  `CB_HOME`, `CB_API_TOKEN` set to local/empty values; no live GitHub credentials, no
  production server, no network required

### Stub quality

The stub uses a Python counter file (`$COUNTER`) to deliver 200+ETag on call 1 and 304 on
call 2+. The `--include` detection reliably distinguishes the charter ETag fetch from
`paginate_issues()` calls (which get `[]` — clean pagination termination). The `\\r\\n`
encoding in the stub output mirrors real `gh --include` output, ensuring `build_state()`
picks the correct `sep_c = "\\r\\n\\r\\n"` branch.

The verification assertion at lines 256–262 confirms the stub actually hit the 304 path
(call count ≥ 2), ruling out false-GREEN from the stub never being called.

**Verdict: PASS**

---

## Acceptance checks (all GREEN)

```
✅ grep -q "_parsed_c" ui/server/crewboss-api.py
✅ grep -q "isinstance(_parsed_c, list)" ui/server/crewboss-api.py
✅ grep -q "ALLOW ui-api-contract" reference/runtime/per-leaf-manifest
✅ grep -q "ALLOW phantom-closed-leaf" reference/runtime/per-leaf-manifest
✅ grep -q "EXCLUDED api-state-304-regression" reference/runtime/per-leaf-manifest
✅ grep -q "ALLOW=25" reference/runtime/per-leaf-manifest
✅ test -f reference/tests/api-state-304-regression.test.sh
✅ grep -q "board" reference/tests/api-state-304-regression.test.sh
```

---

## Overall verdict

**APPROVED — all three leaves are correct and the gate is covered.**

Bug #527 (ETag 304-path empties board) is fixed by leaf-A with minimal surgical change.
Leaf-B maintains manifest hygiene (correct ALLOW/EXCLUDED counts, correct criterion
justifications). Leaf-C provides a deterministic, self-contained regression test that
will prevent the bug from recurring. Charter #707 is ready for finale merge.
