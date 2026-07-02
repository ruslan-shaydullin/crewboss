# Charter #1220 — Final Review Verdict (issue #1284, reviewer)

**Status:** APPROVED — charter acceptance bar met end-to-end.
**Date:** 2026-07-02
**Role:** reviewer (review-only; no code modified).
**Charter:** #1220 · P1 of `docs/design/plan-oversight-strategy.md` (milestone #1219).
**Leaves reviewed:** #1280 (qa/tests), #1281 (`crewboss-api.py`), #1282 (`reference/bin/crewboss` CLI), #1283 (security).
**Head SHA reviewed:** `770c783` (charter/1220 tip; leaf branch identical).

---

## Machine acceptance (all GREEN on head)

| # | Command | Result |
|---|---------|--------|
| 1 | `CB_690_MODE=source python3 tests/690-tests-plan-convergence-guard.test.py` | 18 passed, 0 failed |
| 2 | `bash tests/1220-cli-approve-guard.test.sh` | 5 passed, 0 failed |
| 3 | `bash reference/tests/runtime-manifest.test.sh` | 5 passed, 0 failed |
| 4 | `bash reference/tests/plan-convergence.test.sh` | 30 passed, 0 failed (clean env) |
| 5 | `bash reference/tests/plan-decomposition.test.sh` | 5 passed, 0 failed |

> Note on path: the manifest/plan-convergence/plan-decomposition suites are tracked under
> `reference/tests/` (the acceptance list's `tests/` prefix is shorthand). The `690` and
> `1220-cli` suites live under `tests/`.

## Charter acceptance bar — item-by-item

1. **Role-empty plan-review charter** — Approve VISIBLE (`plan_convergence_active == false`)
   and approve SUCCEEDS via API *and* CLI. Deadlock gone. ✅ (690 source cases a; CLI test).
2. **Convergence charter** (`plan_review_role` set, `plan:agreed` absent) — button hidden,
   approve REJECTED in cockpit API *and* CLI. CLI hole closed. ✅ (690 source case b; CLI test).
3. **`690` in `CB_690_MODE=source`** — real `crewboss-api.py` `do_command('approve')` +
   `build_state()` exercised; production matches the reference-impl; the historical
   false-green (flat vs nested `policy.plan_review_role`) is eliminated. Fixtures use nested
   `{"policy": {"plan_review_role": ...}}`. ✅
4. **`runtime-manifest.test.sh`** — sha256 of `ui/server/crewboss-api.py`
   (`2153bf8d5ee33d1f6835cd95386bdb8951d97a3bb9c1775dba952dcd8b1f5f5e`) matches the
   `reference/runtime-manifest.tsv` row and the shipped file. ✅
5. **Untouched-and-green** — `per-charter-auto-gate` **S1/S2** green, `convergence.test.sh`
   20/0 (incl. line 326 CONVERGE gate), `plan-convergence` 30/0, `plan-decomposition` 5/0.
   Auto/convergence paths undisturbed. ✅
6. **Scope** — files touched are limited to `crewboss-api.py`, `reference/bin/crewboss`,
   the 690/1220 tests, `runtime-manifest.tsv`, and the security doc. **No launcher change, no
   `oversight:human` label, no default inversion** (all P2+). ✅

## Code quality & coverage

- **Single canonical predicate at all three sites:** `block/hide ⟺ plan_review_role != "" AND
  "plan:agreed" absent`. `build_state` visibility (`crewboss-api.py:551`), API approve-guard
  (`:824`), CLI `cmd_approve` (`reference/bin/crewboss:156`).
- **Fresh, uncached reads:** both guards read `policy.plan_review_role` from `org.json` and
  fetch live labels via `gh issue view` per call — a stale board cannot open the gate.
- **`plan_convergence_active` field name unchanged** — no break to `App.tsx` / 690 consumers.
  Additive `plan_review_role`/`plan_round`/`plan_cap` fields are cheap reads only.
- **Coverage adequacy:** the 690 port asserts pre-fix-vs-post-fix at the reference impl *and*
  runs the real source (`CB_690_MODE=source`), including the flat-object false-green assertion;
  the CLI test covers convergence-reject, role-empty-allow, and role+`plan:agreed`-allow.

## Non-blocking observation (no change required)

The API approve-guard carries an extra `"status:plan-review" in _live_labels` conjunct the CLI
omits, making the CLI *stricter* (also blocks when a role is set and `plan:agreed` is absent
outside plan-review). This is a safe asymmetry — there is no `plan-review → approved` flip to
protect when the item is not in plan-review — and was already noted in the #1283 security
sign-off. Optionally align later; not a bypass.

## Environment note (test-harness, not code)

The interactive harness exports `CB_PLAN_CONVERGE_CAP=8`, which leaks into the
`PLAN-ESCALATE-CAP6` case of `plan-convergence.test.sh` (it requires the var unset to exercise
the launcher's fallback of 6). Under a clean env — as the deterministic gate runs — the suite is
30/0. Identical behaviour reproduces at the merge-base (`963d72d`), confirming it is neither
charter-introduced nor a code defect. Same applies to the pre-existing `per-charter-auto-gate`
S3/S4 CI-promotion failures (out of scope; S1/S2 required by this charter are green).

---

**Verdict: APPROVED.** The three-site approve-gate consistency fix is correct and
bypass-complete; the deadlock is removed for role-empty charters, the CLI convergence hole is
closed, and the source-mode false-green is eliminated. Charter #1220 meets its acceptance bar.
