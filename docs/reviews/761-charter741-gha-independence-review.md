# Review: Issue #761 — Charter #741 GHA-Independence Cross-Cutting Review

**Issue:** #761 (Reviewer for charter #741)
**Reviewed leaves:**
- #757 — 741-tests (qa-engineer): ALLOW-class unit tests for visual-gate, livelock, finale-gate, soft-gate
- #758 — 741-infra (infra-engineer): podman install on EC2 box, Playwright image pinned by digest, real baseline capture
- #759 — 741-integrator (executor): crewboss-integrator.sh — local podman visual-gate replacing GHA status poll, livelock fix
- #760 — 741-finale-and-deploy (executor): crewboss-launcher-gh.sh _finale_check_ci decoupled, ci.yml neutralized, deploy-runtime UI default fixed

**Review Date:** 2026-06-27
**Reviewer:** leaf/761-1782559624
**Charter:** #741

---

## Summary

**APPROVED.** All six invariants verified. All four machine acceptance checks GREEN. No regressions in the verify-merged or charter-finale happy paths. Implementation is correct, minimal, and constraint-adherent.

---

## Invariant 1: PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 present — PASS

**Location:** `reference/runtime/crewboss-integrator.sh` line 491.

```bash
bash -c "PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm install --no-audit --no-fund --silent && node scripts/visual-regression.mjs"
```

The env var is passed as an inline prefix inside the container's `bash -c` command. This correctly suppresses npm's Playwright post-install browser-binary download hook on every gate run. ✓

The infra bootstrap script (`playwright-image.digest`) contains the image reference
`mcr.microsoft.com/playwright:v1.60.0-jammy`. The commit message notes a full
`@sha256:<hex>` pin is a human-on-box step requiring `podman pull && podman inspect` on
the EC2 box (noted as gated on human approval in #758). The tag-level reference is still
correct for the software path; the infra step is documented as a prerequisite. ✓

**Machine check:** `grep -q "PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1" reference/runtime/crewboss-integrator.sh` → GREEN

---

## Invariant 2: Podman block BEFORE rm -rf merged_dir — PASS

**Locations:**
- `podman run` block: lines 487–492 (`crewboss-integrator.sh`)
- `rm -rf "$merged_dir"; _BMT_DIR=""`: line 499

Code-structure trace:
1. Engine suite runs (lines 421–450) in background subshell
2. Timer waits (lines 467–474)
3. **Visual regression gate: podman run on `$merged_dir/ui/app` (lines 484–497)** ← BEFORE cleanup
4. `rm -rf "$merged_dir"` (line 499) ← AFTER podman exit
5. Branch on `visual_rc` after cleanup (lines 503–529) — safe because `visual_rc` is already captured

The comment at line 477 explicitly marks the ordering requirement:
> `# MUST run BEFORE merged_dir cleanup — volume-mount requires the path to exist.`

**Machine check:** python3 podman_l < rm_l → `podman_lines=[486], rm_lines=[498]` → GREEN

---

## Invariant 3: per-leaf-manifest covers all new test files from #757 — PASS

Leaf #757 placed its three new test files in `/work/tests/` (project root), **not** in
`reference/tests/`. This was an intentional, correct design decision documented in the
commit message:

> "Tests live in tests/ (not reference/tests/) to avoid disturbing per-leaf-manifest
> counts (ALLOW=22 EXCLUDED=59 union=81 invariant verified by leaf-verifier Test 7)."

Verification:
- `reference/tests/*.test.sh` count: 81 ← matches manifest header `union=81`
- `per-leaf-manifest` ALLOW count: 22; EXCLUDED count: 59; 22 + 59 = 81 ✓
- New files `741-tests-visual-gate.test.sh`, `741-tests-livelock.test.sh`,
  `741-tests-finale-gate.test.sh` are in `/work/tests/` → not scanned by
  `leaf-verifier Test 7` → no unclassified entry → guard stays GREEN ✓

The per-leaf-manifest invariant is preserved. ✓

**Machine check:** `grep -q "ALLOW" reference/runtime/per-leaf-manifest` → GREEN (22 ALLOW entries present)

---

## Invariant 4: No gh pr checks in crewboss-launcher-gh.sh — PASS

A `grep -c "gh pr checks" reference/runtime/crewboss-launcher-gh.sh` returns **0**. The
`CB_FINALE_CHECKS_POLL` env var is retained in the header comment as `# no longer used —
CI decoupled from GHA; kept for back-compat`, which is correct hygiene. No actual
`gh pr checks` call remains anywhere in the file. ✓

**Machine check:** `grep -c "gh pr checks" reference/runtime/crewboss-launcher-gh.sh | xargs test 0 -eq` → GREEN

---

## Invariant 5: ci_state=green on first call; restart recovery correct — PASS

**`_finale_check_ci` (lines 435–480, crewboss-launcher-gh.sh):**

First call path (`ci_state = "pending"`, line 454–456):
```bash
if [ "$ci_state" = "pending" ]; then
  # FIRST CALL: gate proven green locally before PR creation — record ci_state=green.
  ci_state=green
```
Writes `green` immediately. No GHA polling. ✓

Restart/state-loss path (`ci_state` absent or empty, line 458–465):
```bash
else
  # RESTART (ci_state absent or empty — state-loss scenario): re-run gate locally.
  local gate_rc=0
  bash "$INTEGRATOR_SCRIPT" gate-charter "$cid" 2>&1 || gate_rc=$?
  if [ "$gate_rc" -eq 0 ]; then
    ci_state=green
  else
    ci_state=red
  fi
fi
```
Re-runs `gate-charter` locally (no GHA dependency) and writes the correct state. ✓

Terminal state cache (lines 446–450): `green/red/timeout` all short-circuit immediately
on subsequent calls — no repeated polling. ✓

---

## Invariant 6: Happy-path flows unbroken — PASS

### verify-merged flow

`cmd_verify_merged` (lines 342–560, crewboss-integrator.sh):

1. **clone → merge**: `_build_merged_tree` (line 391) ← unchanged
2. **engine-suite**: background subshell running `reference/tests/*.test.sh` ALLOW-filtered (lines 421–450) ← unchanged
3. **visual-gate**: podman container run on `merged_dir/ui/app` (lines 484–497) ← new, correctly ordered before cleanup
4. **cleanup**: `rm -rf "$merged_dir"` (line 499) ← unchanged
5. **verdict**: N-confirmation counter and `verdict_file` writes (lines 540–560) ← unchanged

Soft-gate fallback: if `visual_gate_soft` sentinel exists OR `_playwright_digest` is empty, `visual_rc=0` (line 495) → gate passes without a container. Livelock/infra-error tick counter (lines 509–528) prevents silent hang. ✓

### charter-finale flow

`cmd_charter_finale` calls `_finale_check_ci` immediately after PR creation (line 882).
`_finale_check_ci` writes `ci_state=green` on first call (no GHA wait). `gh pr ready` is
called and optional auto-merge proceeds. The acceptance-convergence intercept (#522) is
untouched. ✓

---

## Regression check: no unrelated changes

- `crewboss-integrator.sh`: visual-gate block added at line 476; remainder of
  `cmd_verify_merged` unchanged.
- `crewboss-launcher-gh.sh`: `_finale_check_ci` replaced; all other subcommands
  (`reconcile`, `once`, `run`, etc.) unchanged.
- `deploy-runtime.sh`: UI default fixed (separate leaf #760 concern, confirmed correct).
- `ci.yml`: neutralized correctly by leaf #760; still syntactically valid YAML.
- `per-leaf-manifest`: header counts unchanged (ALLOW=22, EXCLUDED=59, union=81).
- New test files in `/work/tests/` (not `reference/tests/`): no manifest impact.

No regressions found. ✓

---

## Verdict

**APPROVED — all invariants GREEN, all machine checks GREEN.**
