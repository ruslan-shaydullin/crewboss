# Review: Issue #896 — PR #991 (`fix(#895)`: CB_QUEUE_LOOKAHEAD analysis-cycle lookahead)

**Charter:** #506
**Reviewed leaf:** #895 (impl-lookahead)
**Reviewed PR:** #991 (`fix(#895): implement CB_QUEUE_LOOKAHEAD analysis-cycle lookahead on charter/506`)
**Head commit reviewed:** `5b8a0e7` (impl), merged as `cb0514a` into `charter/506`
**Reviewer:** leaf/896 (review leaf, charter #506)
**Review date:** 2026-06-29

---

## Verdict: ✅ APPROVED — all 5 checks pass

The PR's only changes to `reference/runtime/crewboss-launcher-gh.sh` are (a) declaration of
`_q_lookahead_set`, (b) construction of the lookahead eligibility set, and (c) replacement of
the two analysis-cycle head-only guards. Manifest hash + `runtime-manifest.exclude` updates are
the expected bookkeeping. No write-stage guard, plan/launch/finale guard, or unrelated logic
was touched.

---

## Check 1 — Both analysis-cycle guards replaced · PASS ✅

**File:** `reference/runtime/crewboss-launcher-gh.sh`

- **Loop 1** (`plannable_scoped` path, now ~line 1517): the old
  `[ "$cid" = "$_q_head" ] || continue` is replaced by
  `case " $_q_lookahead_set " in *" $cid "*) ;; *) continue ;; esac`.
- **Loop 2** (`needs-analysis boards` / `$_analysis_boards` path, now ~line 1555): the identical
  guard is **also** replaced with the same membership check.

Both loops retain the `[ -z "$_q_head" ] && break` queue-empty guard. Neither was left head-only,
so charters reaching needs-analysis via the retry path are no longer silently stranded. ✅

## Check 2 — Eligibility set is skip-aware, not a raw positional slice · PASS ✅

The set is built (~lines 1474–1488) by iterating `$_q_order` and applying the **same skip set**
as `_q_head` (`done|blocked|hold|deferred → continue`), counting only active entries up to
`CB_QUEUE_LOOKAHEAD+1`:

```sh
_q_lookahead=${CB_QUEUE_LOOKAHEAD:-2}
_q_loo_count=0
for _qn in $_q_order; do
  [ "$_q_loo_count" -gt "$_q_lookahead" ] && break
  _qst=$(board get "$_qn" state 2>/dev/null || echo "unknown")
  case "$_qst" in done|blocked|hold|deferred) continue ;; esac
  _q_lookahead_set="${_q_lookahead_set:+$_q_lookahead_set }$_qn"
  _q_loo_count=$((_q_loo_count+1))
done
```

This is **not** a raw `_q_order[0..N]` index. A `done` charter at raw index 0 is skipped via
`continue` without incrementing `_q_loo_count`, so the real head is still admitted — exactly the
failure mode flagged in the task is avoided. The skip set matches the established `_q_accept_head`
pattern. ✅

## Check 3 — Write-stage guards remain head-only (unchanged) · PASS ✅

Confirmed via diff scope + source inspection that the following still use head-only
`[ "$cid" = "$_q_head" ]` / `[ "$cid" = "$_q_plan_head" ]` / `[ "$cid" = "$_q_accept_head" ]`
checks and were **not** modified:

- CTO / team-review (approval) stage — `[ "$cid" = "$_q_head" ] || continue` (~line 1582)
- plannable guard — `[ "$cid" = "$_q_head" ] || continue` (~line 1744)
- launchable guard — `[ "$cid" = "$_q_head" ] || continue` (~line 1765)
- finale dispatch — `[ "$_id_ch" = "$_q_head" ] || continue` (~line 1923)
- plan-conv / accept heads — `_q_plan_head` (~1788, 1850), `_q_accept_head` (~1872) unchanged

The PR diff contains no hunks touching any of these. ✅

## Check 4 — N=0 restores prior serial behavior · PASS ✅

With `CB_QUEUE_LOOKAHEAD=0`: first iteration `0 -gt 0` is false → one active entry added,
`_q_loo_count=1`; next iteration `1 -gt 0` is true → break. The set therefore contains **only the
head** (with leading skips honored), identical to the prior head-only serial behavior. ✅

## Check 5 — No forbidden shortcuts · PASS ✅

- No new `eslint-disable`, no `--no-verify`, no force-push in the diff.
- Commit message `fix(#895): implement CB_QUEUE_LOOKAHEAD analysis-cycle lookahead on charter/506`
  follows Conventional Commits. ✅

---

## Summary

Leaf #895's implementation correctly generalizes the analysis-cycle head-only gate into a
skip-aware lookahead eligibility set, replaces **both** analysis guards, leaves all write-stage
guards head-only, and degenerates to serial behavior at `N=0`. **Approved.**
