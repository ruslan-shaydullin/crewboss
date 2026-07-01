# Review: Issue #837 — Charter #442 HD Escalation UX Cross-Review

**Issue:** #837 (Reviewer for charter #442)
**Reviewed leaves:**
- #833 — launcher-enrich: HD issue creation enriched at all 5 gates in `reference/runtime/crewboss-launcher-gh.sh`
- #834 — api-hd-actions: `approve-hd`, `request-changes-hd`, `close-hd` dispatch added to `ui/server/crewboss-api.py`
- #835 — cockpit-hd-buttons: `HumanTaskCard` HD action buttons added to `ui/app/src/App.tsx`

**Review Date:** 2026-07-01
**Reviewer:** leaf/837-1782892998
**Charter:** #442

---

## Machine Acceptance Checks

```
$ bash tests/test_442_hd_enrichment.sh 2>&1 | tail -1
ALL GREEN    (36 passed, 0 failed)

$ bash tests/test_442_api_hd_actions.sh 2>&1 | tail -1
ALL GREEN    (59 passed, 0 failed)
```

Both gates GREEN on current HEAD.

---

## Checklist 1 — Acceptance-criteria coverage

**PASS.** All 5 launcher gates (`composition not converging`, `analysis did not converge`,
`Human approval required`, `plan did not converge`, `acceptance did not converge`) produce
HD issue bodies that contain:

- `Charter: #$cid` link — confirmed by grep in test Section 3 (gates 1–5 launcher probe).
- Plan/composition block or graceful empty — confirmed by `_check_comp_or_empty` (ok at all gates).
- All three command names (`approve-hd`, `request-changes-hd`, `close-hd`) — confirmed by
  `_check_commands` (all ok, no skips after #833 merged).

Cockpit `HumanTaskCard` shows three action buttons wired to the correct `onAction` calls:
`approve-hd`, `request-changes-hd`, `close-hd` (App.tsx lines 699–708). ✓

Test suite (#830) covers all acceptance criteria and passes ALL GREEN. ✓

---

## Checklist 2 — Label mutation correctness per HD type (#834)

Verified in `ui/server/crewboss-api.py` lines 883–887 and test Section 1 (59 assertions):

| HD title contains | Add to charter | Remove from charter | Verified |
|---|---|---|---|
| composition not converging | `composition:approved`, `status:needs-plan` | `status:team-review` | ✓ gate1 |
| analysis did not converge | `review:agreed` | (none) | ✓ gate2 |
| approval required | `composition:approved`, `status:needs-plan` | `status:team-review` | ✓ gate3 |
| plan did not converge | `plan:agreed` | (none) | ✓ gate4 |
| acceptance did not converge | `accept:agreed` | (none) | ✓ gate5 |

`request-changes-hd` for `approval required` (HD #503): adds `status:needs-analysis`,
removes `status:team-review` from charter, closes HD, posts reason to charter — confirmed
by test Section 2, Case 7. ✓

`close-hd`: ZERO charter label mutations (`issue edit` NOT called on charter) — confirmed
by test Section 3, Cases 9–10. ✓

---

## Checklist 3 — Stale-variable fix (#833)

**PASS.** Gates 4 and 5 in `reference/runtime/crewboss-launcher-gh.sh` use `_fresh_comp`
(a local, per-cid fetch via `gh issue view "$cid" ...`), not the outer `_comp_body` global.

- Gate 4 (lines 2223–2224): `_fresh_comp=$(gh issue view "$cid" ... 2>/dev/null | jq ... 2>/dev/null || true)`
- Gate 5 (lines 2332–2333): identical pattern.

Both fetches are guarded with `|| true` (failure safe). The stale-variable sentinel test
in Section 2 (reference simulation) confirms neither gate references `$_comp_body`, and
the launcher source probe in Section 3 (`grep -qE '\$_comp_body'`) confirms the same
in the actual script. ✓

---

## Checklist 4 — UI consistency (#835)

**PASS.**

- Button styling: `btn sm pri` (approve) and `btn sm ghost` (request-changes, close) —
  identical class names used by the existing plan-review card (CharterCard lines 817–821).
- `ask()` signatures follow the same pattern: title string, body string, callback, optional
  `withInput=true` for the `request-changes-hd` button (App.tsx lines 699–708). ✓
- HD buttons are scoped inside `{isHD && (...)}` where
  `const isHD = t.labels.includes('type:human-decision')` (App.tsx line 673). Plan-review
  issues with other label types are unaffected. ✓

---

## Checklist 5 — No regressions

**PASS.**

- Existing `approve` / `request-changes` (plan-review) command paths in `crewboss-api.py`
  are untouched (HD dispatch lives in a separate `elif` branch gated on
  `a in (CMD_APPROVE_HD, CMD_REQUEST_CHANGES_HD, CMD_CLOSE_HD)`).
- Regression test Section 4 (Cases 11–12) confirms both plan-review commands still return
  `ok=true`, mutate the correct labels, and do not cross-contaminate charter #100. ✓

---

## Checklist 6 — Test completeness (#830)

**PASS.** `test_442_api_hd_actions.sh` covers:

- 5 approve-hd cases (one per HD type × label-mutation matrix) — Section 1.
- 3 request-changes-hd cases (gate1/composition, gate2/analysis, gate3/approval-required
  with exception labels) — Section 2.
- 2 close-hd cases (gate1, gate3) verifying zero charter edits — Section 3.
- 2 plan-review regression cases (approve, request-changes) — Section 4.

Total: 10+ label-mutation cases, the stale-variable regression guard (Section 2 of
`test_442_hd_enrichment.sh`), and all enrichment/command-name checks across 5 gates.

---

## Verdict

**REVIEW: agreed**

All 6 checklist items pass. Machine acceptance gates are GREEN (36 + 59 = 95 tests,
0 failures). Implementation is correct, consistent with the plan-review UX patterns, and
contains no regressions. PRs #833, #834, and #835 are approved for charter #442.
