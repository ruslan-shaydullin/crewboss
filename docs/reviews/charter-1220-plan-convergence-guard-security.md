# Security Review: convergence approve-gate alignment (charter #1220, issue #1283)

**Status:** APPROVED
**Date:** 2026-07-02
**Reviewer role:** security-reviewer (review-only)
**Reviewed leaves:** #1281 (`ui/server/crewboss-api.py`), #1282 (`reference/bin/crewboss` `cmd_approve`)
**Spec:** `docs/design/plan-oversight-strategy.md` P1 (milestone #1219; doc lives in commit 31502cf)

---

## Machine acceptance checks (all green on head)

| Check | Command | Result |
|-------|---------|--------|
| 1 | `grep -n "plan_review_role" ui/server/crewboss-api.py reference/bin/crewboss` | present at all sites |
| 2 | `CB_690_MODE=source python3 tests/690-tests-plan-convergence-guard.test.py` | 18 passed, 0 failed |
| 3 | `bash tests/1220-cli-approve-guard.test.sh` | 5 passed, 0 failed |

---

## 1. No bypass remains (approve cannot flip `plan-review → approved` while role set & `plan:agreed` absent)

Three sites, one canonical predicate: **block/hide ⟺ `plan_review_role != ""` AND `plan:agreed` absent.**

- **API `build_state` visibility** (`crewboss-api.py:551`):
  `plan_convergence_active = plan_review_role != "" and "plan:agreed" not in labels`, guarded by `if st == "plan-review":` (else `False`). Button hidden exactly during convergence.
- **API approve-guard** (`crewboss-api.py:824`):
  rejects iff `_plan_review_role != "" and "status:plan-review" in _live_labels and "plan:agreed" not in _live_labels`. Reads org.json fresh and fetches **live** labels via `gh issue view` on every call — not cached board state, so a stale board cannot open the gate.
- **CLI `cmd_approve`** (`reference/bin/crewboss:156`):
  `if [ -n "$role" ] && ! printf '%s' "$labels" | grep -q 'plan:agreed'; then die ...` — the previously-unguarded live-board hole (`crewboss approve <N>` flipping `plan-review → approved`) is now closed. Labels fetched live via `gh issue view` per call.

**Verdict:** No path flips `plan-review → approved` while a review role is configured and `plan:agreed` is absent, on either the cockpit or the CLI surface.

## 2. Role-empty case correctly opened (deadlock removed, no over-broad relaxation)

All three sites permit when `plan_review_role == ""`: `build_state` yields `plan_convergence_active = False` (Approve button shown), and both approve-guards fall through to the promote. The 690/1220 tests confirm the pre-fix deadlock (button hidden AND approve rejected for role-empty human-park charters) is gone. The relaxation is bounded strictly to the role-empty leg — the role-set convergence path is unchanged and still blocks.

## 3. Single source for `plan_review_role` (nested `policy`, not flat)

- API build_state (`:497`): `(_org.get("policy") or {}).get("plan_review_role", "") or ""`.
- API approve-guard (`:818`): `(_org.get("policy") or {}).get("plan_review_role", "")`.
- CLI (`:154`): `jq -r '(.policy.plan_review_role) // ""'`.

All read the org.json nested `policy.plan_review_role`. No flat top-level `plan_review_role` reads remain — the historical false-green root cause is eliminated. The 690 test explicitly asserts a FLAT `{plan_review_role}` object resolves to `""`.

## 4. Spec cross-reference

Matches `docs/design/plan-oversight-strategy.md` §"CLI/кокпит симметрия": *approve rejected ⟺ `plan_review_role` set AND `plan:agreed` absent; allowed for role-empty*, scoped to `crewboss-api.py` (build_state + approve-guard) and `reference/bin/crewboss` `cmd_approve`. The undocumented `policy.plan_review_role` key is called out in the spec as the intended source.

## 5. Field-name & manifest integrity

- `plan_convergence_active` field name is unchanged (emitted at `crewboss-api.py:583`; predicate at `:551`) — no rename that would break `690-tests-*` / `App.tsx`.
- `reference/runtime-manifest.tsv` sha256 for `ui/server/crewboss-api.py` = `2153bf8d5ee33d1f6835cd95386bdb8951d97a3bb9c1775dba952dcd8b1f5f5e` matches `sha256sum` of the shipped file.

---

## Non-blocking observation

The API approve-guard carries an extra `"status:plan-review" in _live_labels` conjunct that the CLI guard omits. The CLI is therefore *stricter* (it also blocks approve when a role is set and `plan:agreed` is absent even outside plan-review) — this is a safe asymmetry, not a bypass: there is no `plan-review → approved` flip to protect when the item is not in plan-review. No change required.

---

## Summary

| Item | Verdict |
|---|---|
| 1. No approve bypass (API build_state + guard, CLI) | ✅ Closed at all three sites |
| 2. Role-empty opened, no over-broad relaxation | ✅ Deadlock removed, scoped |
| 3. Single nested `policy.plan_review_role` source | ✅ No flat reads remain |
| 4. Matches canonical spec P1 | ✅ Aligned |
| 5. Field name + manifest sha256 | ✅ Unchanged / matches |

**Overall: APPROVED** — the #1281/#1282 guard alignment is correct and bypass-complete. No blocking security findings.
