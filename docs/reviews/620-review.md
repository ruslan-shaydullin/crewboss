# Substance Review: Issue #620 — exec-592 False-Blocked Race Fix

**Issue:** #620 (Reviewer for charter #592)
**Reviewed:** exec-592 PR #619 (commit `605c822`) — `feat(#619): fix false-blocked race — per-role timeouts, kind at dispatch, nsjail-detach guard`
**Review Date:** 2026-06-24
**Reviewer:** leaf/620-1782290262
**Charter:** #592

---

## Summary

**APPROVED.** All three core changes are correct and additive. One minor gh-fallback edge-case noted (non-blocking), one minor log-clarity gap noted (non-blocking). No regressions to hang-protection (#212). RED-g and RED-h tests (from qa-592 #618) verified to target the correct code paths.

---

## (a) Kind storage correctness — PASS

**Location:** `reference/runtime/crewboss-launcher-gh.sh` line 1582 (post-exec-592).

```bash
board claim "$id" "$LID" >/dev/null; sset "$id" starttime "$(now)"; sset "$id" kind "$(board get "$id" role)"
```

- `sset "$id" kind` is appended to the **executor leaf claim line** — the single site where executor/qa-engineer/reviewer leaves are dispatched. ✓
- Value is `board get "$id" role`, which is the leaf's role label (e.g. `executor`, `qa-engineer`, `reviewer`). ✓
- No other dispatch site was modified; named-role leaves (analysis, review, acceptance-review) already stored `kind` at their own claim sites. ✓

**Uppercasing** (line 892):
```bash
_kind_upper=$(printf '%s' "$_kind" | tr '[:lower:]-' '[:upper:]_')
eval "_eff_timeout=\${CB_${_kind_upper}_SPAWN_TIMEOUT:-${CB_SPAWN_TIMEOUT:-1800}}"
```
- `tr '[:lower:]-' '[:upper:]_'` correctly maps lower-to-upper AND hyphen-to-underscore in a single pass. ✓
- Examples: `qa-engineer` → `QA_ENGINEER`, `plan-review` → `PLAN_REVIEW`, `executor` → `EXECUTOR`. ✓
- `eval` is safe: `_kind_upper` is restricted to `[A-Z_]` by the `tr` filter, so no injection risk. ✓

---

## (b) Completion-detect guard placement — PASS

**Location:** lines 904–920.

```bash
        fi
          continue          # still running (or just timed-out+routed)
        fi
        # [#619 exec-592] completion-detect guard: pid gone but phase=starting …
        if _phase=$(jq -r '.phase // ""' "$RUN/work/$id/status.json" 2>/dev/null) && [ "$_phase" = "starting" ]; then
          …
          if [ -n "$_pr_url" ]; then
            …
            continue
          fi
        fi
        # analysis task: route by charter state …
```

- The guard sits **after** the `continue  # still running` that closes the `if kill -0 "$pid"` block (line 902). This is strictly in the `else` path — pid is already gone at this point. ✓
- Entry condition is `_phase = "starting"` (status.json written by spawn before nsjail starts) **AND** a non-empty `_pr_url`. ✓
- Genuine hangs (phase ≠ starting, or phase = starting but no PR URL found): the inner `if [ -n "$_pr_url" ]` block is skipped; execution falls through to the existing analysis / review / executor routing blocks unchanged. ✓

---

## (c) run.log grep and gh-fallback robustness — PASS WITH MINOR FINDING

**Location:** lines 907–910.

```bash
_pr_url=$(grep -oE 'https://github.com/[^ "]+/pull/[0-9]+' "$RUN/work/$id/run.log" 2>/dev/null | tail -1)
if [ -z "$_pr_url" ]; then
  _leaf_branch="$(board get "$id" branch 2>/dev/null || true)"
  [ -n "$_leaf_branch" ] && _pr_url=$(gh pr list --head "$_leaf_branch" --state open --json url -q '.[0].url' 2>/dev/null || true)
fi
```

**grep pattern:** `'https://github.com/[^ "]+/pull/[0-9]+'` — correctly matches GitHub PR URLs. `[^ "]+` captures the repo slug; `/pull/[0-9]+` anchors the pull-request path. The `2>/dev/null` suppresses errors if `run.log` is missing; `| tail -1` takes the last URL if multiple are logged. ✓

**Order:** local `run.log` checked first; gh API fallback only when `run.log` yields nothing. ✓

**Error-exit safety:** `2>/dev/null || true` on both grep and gh calls — neither can exit the loop body with a non-zero code. ✓

**Minor finding (non-blocking):** When `gh pr list` finds no matching open PR it returns `[]`, and `jq '.[0].url'` on an empty array evaluates to `null`, printed as the literal string `"null"` by gh's `--jq` output. `[ -n "null" ]` is truthy, so `_pr_url` would be set to `"null"`, which could falsely trigger the completion-detect guard for a genuinely hung process whose branch happens to be set but has no PR. Recommended fix: add a null guard, e.g.:

```bash
_pr_url=$(gh pr list --head "$_leaf_branch" --state open --json url -q '.[0].url // ""' 2>/dev/null || true)
```

Using `// ""` in jq coerces null to empty string, making the bash emptiness test reliable. This is low-probability (requires: `phase=starting` + branch set + no PR opened + genuine hang) but worth fixing. Does **not** block approval.

---

## (d) No regression to hang-protection (#212) — PASS

- The kill path (`kill -9 "$pid"`) in the `if kill -0 "$pid"` block (lines 894–900) is **unchanged**. The completion-detect guard only activates **after** the pid is already gone (post-kill routing path). ✓
- A long-running process with no PR URL: the guard at line 912 (`if [ -n "$_pr_url" ]`) is not entered; execution continues to the existing analysis/review/executor routing, which increments `tries` and eventually routes to `blocked` after `RETRY_CAP` kills. ✓
- Per-role timeout strictly **replaces** the hardcoded `1800` with a dynamic lookup that falls back to `${CB_SPAWN_TIMEOUT:-1800}` — identical behaviour when no per-role override is set. ✓
- The guard is purely additive: zero new code paths are introduced for the non-detach-race case. ✓

---

## (e) Log clarity — PASS WITH MINOR GAP

**Timeout resolution log** (lines 897–898):
```bash
log "#$id spawn timeout (>${_eff_timeout}s) -> kill -9 + blocked"
log "#$id spawn timeout (>${_eff_timeout}s) -> kill -9 + requeue"
```
The effective timeout value (`_eff_timeout`) is logged. A future operator can see `spawn timeout (>2s)` for a qa-engineer leaf with `CB_QA_ENGINEER_SPAWN_TIMEOUT=2`. ✓

**nsjail-detach bypass log** (line 913):
```bash
log "#$id pid gone but PR found ($_pr_url), routing done (nsjail-detach race)"
```
Leaf id and PR URL are logged — sufficient to diagnose future incidents. ✓

**Minor gap (non-blocking):** The per-role variable name consulted (e.g. `CB_QA_ENGINEER_SPAWN_TIMEOUT`) is not logged — only its resolved value. If `CB_QA_ENGINEER_SPAWN_TIMEOUT` is not set and the fallback `CB_SPAWN_TIMEOUT` is used, the log reads identically to the pre-exec-592 case. Adding `log "#$id kind=$_kind, timeout var CB_${_kind_upper}_SPAWN_TIMEOUT resolved to ${_eff_timeout}s"` would make it unambiguous which variable drove the decision. Does **not** block approval.

---

## Additional Change: CB_MANIFEST graceful fallback — PASS

Lines 65–97 (manifest block): if `CB_MANIFEST` is set but the directory does not exist (stale env from old install), the code now clears `CB_MANIFEST` and proceeds rather than `exit 65`. This is a safe, conservative improvement that prevents launcher outages from stale environment variables. The `exit 65` path is preserved for all cases where the directory exists but the manifest library or validation fails. ✓

---

## Test Coverage (qa-592 #618, commit `7ad122d`)

**RED-g** (lines 446–497 of `run-liveness.test.sh`): wedge writes `{"phase":"starting","pr":""}` to `status.json` + PR URL to `run.log` then exits, simulating the nsjail-detach race. Asserts `status:review` label after `CB_SPAWN_TIMEOUT=2` + `CB_MAX_TICKS=10`. This directly exercises the new completion-detect guard. ✓

**RED-h** (lines 500–560 of `run-liveness.test.sh`): executor leaf dispatched via real claim path (exercises Change 1 `sset kind`); wedge sleeps 30s. `CB_EXECUTOR_SPAWN_TIMEOUT=2` with `CB_SPAWN_TIMEOUT=3600`. Asserts executor killed+blocked after ~3s while analysis leaf (kind=analysis, global fallback) survives 6-tick window. Directly tests Change 1 + Change 2. ✓

Both tests confirmed GREEN against exec-592 commit `605c822` (tests verify the implemented behaviour).

---

## Verdict

**APPROVED.** All five review criteria pass. Two minor non-blocking findings noted (jq null edge case in gh-fallback, missing per-role var name in timeout log). Neither is a correctness hazard in normal operation.
