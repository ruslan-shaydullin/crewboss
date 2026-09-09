# Verification Review: PR #386 — docs: add CB environment flags reference

**Issue:** #385 (Verifier for charter #383)
**Reviewed PR:** #386 (`Closes #384`)
**Review Date:** 2026-06-20
**Reviewer:** leaf/385-1781937663
**Canonical sources checked:**
- `reference/runtime/crewboss-launcher-gh.sh` (1316 lines, authoritative for launcher flags)
- `reference/runtime/crewboss-spawn.sh` (spawn flags — bind-mount semantics)
- `reference/runtime/crewboss-prep-spawn-gh.sh` (spawn flags — CB_FS_* assignment)

---

## Criterion 1: All nine flags present

- [x] `CB_MANIFEST` ✓
- [x] `CB_CONVERGE_CAP` ✓
- [x] `CB_PLAN_CONVERGE_CAP` ✓
- [x] `CB_AUTO_PLAN_APPROVE` ✓
- [x] `CB_AUTO_MERGE` ✓
- [x] `CB_FS_WORK` ✓
- [x] `CB_FS_CBNET` ✓
- [x] `CB_MAX_PARALLEL` ✓
- [x] `CB_RETRY_CAP` ✓

**Result: PASS** — all nine flags appear in the table.

---

## Criterion 2: Defaults match source

Cross-checked each flag default against the bash parameter expansion in the canonical sources:

| Flag | Doc Default | Source Expression | Match? |
|------|-------------|-------------------|--------|
| `CB_CONVERGE_CAP` | `4` | `${CB_CONVERGE_CAP:-4}` (launcher line 1118, also line 1085) | ✓ |
| `CB_AUTO_PLAN_APPROVE` | `0` | `${CB_AUTO_PLAN_APPROVE:-0}` (launcher line 920) | ✓ |
| `CB_AUTO_MERGE` | `0` | `${CB_AUTO_MERGE:-0}` (launcher line 485) | ✓ |
| `CB_MAX_PARALLEL` | `2` | `${CB_MAX_PARALLEL:-2}` (launcher line 19) | ✓ |
| `CB_RETRY_CAP` | `2` | `${CB_RETRY_CAP:-2}` (launcher line 19) | ✓ |
| `CB_FS_WORK` | `rw` | `case "${CB_FS_WORK:-}" in ""\|rw) WORK_MOUNT="-B" ;; esac` (spawn line 31) — empty = read-write | ✓ |
| `CB_FS_CBNET` | `rw` | `case "${CB_FS_CBNET:-}" in ""\|rw) CBNET_MOUNT="-B" ;; esac` (spawn line 32) — empty = read-write | ✓ |
| `CB_MANIFEST` | `(unset)` | No default expansion; block is guarded by `[ -n "${CB_MANIFEST:-}" ]` | ✓ |
| `CB_PLAN_CONVERGE_CAP` | `(forthcoming)` | Not present in source (confirmed by grep) | ✓ |

**Result: PASS** — all confirmed defaults match source exactly.

---

## Criterion 3: Descriptions accurate

Verified each description against source behavior:

- **CB_MANIFEST**: Correctly describes the manifest library lookup, `manifest_validate` call, `exit 65` on missing library or invalid manifest, and `export CB_MANIFEST` to child spawns. No-op when unset. ✓
- **CB_CONVERGE_CAP**: Correctly describes the analyst↔reviewer substance-convergence round cap, and the fallback pattern `${CB_FORMAT_CAP:-${CB_CONVERGE_CAP:-4}}` for `CB_FORMAT_CAP`. ✓
- **CB_PLAN_CONVERGE_CAP**: Marked as forthcoming companion to `CB_CONVERGE_CAP` for the plan-review loop. ✓
- **CB_AUTO_PLAN_APPROVE**: Correctly describes auto-approval of charters at `plan-review` state when set to `1`. ✓
- **CB_AUTO_MERGE**: Correctly describes auto-merge of the charter-finale PR into `main` when set to `1`. ✓
- **CB_FS_WORK**: Correctly describes the `/work` bind-mount mode (`-B` = rw when empty/`rw`, `-R` = read-only otherwise). Correctly notes the fail-safe (non-rw/unrecognised → lock down to read-only). Correctly states it is set from the manifest role field `fs_work` by `crewboss-prep-spawn-gh.sh`. ✓
- **CB_FS_CBNET**: Same semantics as `CB_FS_WORK` but for `/cbnet` mount. All details accurate. ✓
- **CB_MAX_PARALLEL**: Correctly describes max concurrent executor spawns in `run` mode. ✓
- **CB_RETRY_CAP**: Correctly describes max consecutive failure attempts before routing to `blocked` state. ✓

**Result: PASS** — all descriptions are accurate and match source behavior.

---

## Criterion 4: CB_PLAN_CONVERGE_CAP marked forthcoming

- Table row shows `*(forthcoming)*` in the Default column and description reads "Planned companion to `CB_CONVERGE_CAP` for the plan-review loop — forthcoming (see §Forthcoming below)". ✓
- A dedicated **Forthcoming** subsection states: "CB_PLAN_CONVERGE_CAP is not yet implemented in the launcher source." ✓
- Confirmed absence: `grep "CB_PLAN_CONVERGE_CAP" reference/runtime/crewboss-launcher-gh.sh` returns no results. ✓

**Result: PASS** — flag is clearly marked as not yet in source.

---

## Overall Verdict: APPROVED

All four criteria pass. The document `docs/reference/cb-env-flags.md` is accurate, complete, and correctly notes the forthcoming flag. PR #386 is approved.

Note: GitHub may block a formal `APPROVE` review submission if the PR was opened by the same GitHub account used for this review. This document serves as the authoritative verification record in that case.
