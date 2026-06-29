#!/usr/bin/env bash
# cb-pr-create.sh — deterministic, rate-limit-aware `gh pr create` wrapper (charter #1004, leaf #1043).
#
# WHY (self-contained context): the crewboss loop exhausts the GitHub REST rate-limit
# (5000/h authenticated). At remaining=0 a raw inline `gh pr create` fails with no retry,
# the leaf's PR is never created, the leaf goes review-stale and blocks (observed #996,
# 2026-06-29: work done, PR silently never created at RL=0). The executor prompt used to
# interpolate a raw `gh pr create` (crewboss-prep-spawn-gh.sh) with NO retry and NO loud
# failure — a silent PR drop. This helper replaces that path with a CODE contract:
#   check `remaining` -> retry-with-backoff -> hard-fail LOUDLY (never a silent drop).
#
# This file is a `canonical` row in reference/runtime-manifest.tsv, so deploy-runtime.sh
# scps it (by basename) to the box ~/cbnet/cb-pr-create.sh -> reachable READ-ONLY inside the
# nsjail at the absolute path /cbnet/cb-pr-create.sh. The executor sources it from there:
#   source /cbnet/cb-pr-create.sh && cb_pr_create --base <CB> --title '<short>' --body 'Closes #<id>'
#
# PINNED CONTRACT (IDENTICAL to qa leaf #1041 test 4, tests/test_rl_live.sh _ref_cb_pr_create):
#   - inputs : `gh pr create` args + CB_REPO (passed via `gh pr create -R "$CB_REPO"`).
#   - RL-pressure injection seam: CB_RL_REMAINING_OVERRIDE bypasses `gh api /rate_limit`
#     so tests can force a low `remaining` deterministically (no network).
#   - knobs  : CB_RL_FLOOR (default 1000), CB_PR_RETRY_MAX (default 3), CB_PR_BACKOFF_S (default 2).
#   - loud-fail: exit 75 + stderr marker CB_PR_CREATE_FAILED when RL pressure persists past
#     CB_PR_RETRY_MAX (NEVER a silent PR drop).
#
# Usage (sourced; defines the function in the caller's shell):
#   source /cbnet/cb-pr-create.sh
#   cb_pr_create --base charter/123 --title 'short' --body 'Closes #456'

cb_pr_create() {
  local floor="${CB_RL_FLOOR:-1000}"
  local max="${CB_PR_RETRY_MAX:-3}"
  local backoff="${CB_PR_BACKOFF_S:-2}"
  local tries=0 remaining
  while :; do
    # RL pressure read: deterministic override seam first, else the live /rate_limit core.
    if [ -n "${CB_RL_REMAINING_OVERRIDE:-}" ]; then
      remaining="$CB_RL_REMAINING_OVERRIDE"
    else
      remaining="$(gh api /rate_limit -q '.resources.core.remaining' 2>/dev/null || echo 0)"
    fi
    [ -n "$remaining" ] || remaining=0
    # Healthy headroom -> actually create the PR (wraps the raw `gh pr create`, -R CB_REPO).
    if [ "$remaining" -ge "$floor" ] 2>/dev/null; then
      gh pr create -R "${CB_REPO:-x/y}" "$@" && return 0
    fi
    tries=$((tries + 1))
    # Loud-fail: never drop the PR silently. Exit 75 + machine-readable marker on stderr.
    if [ "$tries" -ge "$max" ]; then
      echo "CB_PR_CREATE_FAILED: rate-limit remaining=$remaining < floor=$floor after $tries attempt(s)" >&2
      return 75
    fi
    sleep "$backoff" 2>/dev/null || true
  done
}
