#!/usr/bin/env bash
# reference/runtime/cb-pr-create.sh — deterministic rate-limit-aware PR-create helper.
#
# Charter #1004 / leaf #1043 (executor-prcreate). Self-contained context:
#   Bug #996 (2026-06-29): the executor did the work, but the INLINE `gh pr create`
#   interpolated into the spawn prompt hit GitHub REST rate-limit = 0 with no retry,
#   so the PR was never created and the leaf silently blocked (review-stale). A raw
#   `gh pr create` has NO rate-limit guard, NO retry, and NO loud failure — a dropped
#   PR is indistinguishable from "agent forgot to open one".
#
# This helper makes the failure mode DETERMINISTIC and LOUD, in code:
#   check `remaining` (via gh api /rate_limit, or the injection seam) ->
#   retry-with-backoff while under RL pressure -> hard-fail loudly (exit 75 +
#   stderr marker CB_PR_CREATE_FAILED) when pressure persists past CB_PR_RETRY_MAX.
#   It NEVER silently drops a PR.
#
# Deploy/jail: shipped as a `canonical` row in reference/runtime-manifest.tsv so
#   deploy-runtime.sh scps it (by basename) to ~/cbnet/cb-pr-create.sh -> reachable
#   read-only inside the jail at the ABSOLUTE path /cbnet/cb-pr-create.sh. The spawn
#   prompt sources it from there:
#     source /cbnet/cb-pr-create.sh && cb_pr_create --base "$CB" --title '<short>' --body 'Closes #<id>'
#
# PINNED contract (IDENTICAL to qa leaf #1041 tests/test_rl_live.sh test 4):
#   inputs : `gh pr create` args (forwarded verbatim) + CB_REPO (repo for -R).
#   seam   : CB_RL_REMAINING_OVERRIDE bypasses `gh api /rate_limit` so tests can force
#            a low `remaining` deterministically (no network).
#   knobs  : CB_RL_FLOOR (default 1000), CB_PR_RETRY_MAX (default 3),
#            CB_PR_BACKOFF_S (default 2).
#   fail   : exit 75 + stderr marker CB_PR_CREATE_FAILED when RL pressure persists
#            past CB_PR_RETRY_MAX (never a silent PR drop).

# cb_pr_create <gh pr create args...>
#   Returns 0 on a successful `gh pr create`; 75 (loud-fail) when RL pressure persists.
cb_pr_create() {
  local floor="${CB_RL_FLOOR:-1000}"
  local max="${CB_PR_RETRY_MAX:-3}"
  local backoff="${CB_PR_BACKOFF_S:-2}"
  local tries=0 remaining

  while :; do
    # Rate-limit pressure read. The override seam lets tests force a deterministic
    # `remaining` with no network (and no gh) in play.
    if [ -n "${CB_RL_REMAINING_OVERRIDE:-}" ]; then
      remaining="$CB_RL_REMAINING_OVERRIDE"
    else
      remaining="$(gh api /rate_limit -q '.resources.core.remaining' 2>/dev/null || echo 0)"
    fi
    [ -n "$remaining" ] || remaining=0

    # Healthy headroom -> actually create the PR (forward all args verbatim).
    if [ "$remaining" -ge "$floor" ] 2>/dev/null; then
      gh pr create -R "${CB_REPO:-x/y}" "$@" && return 0
    fi

    # Under RL pressure: retry-with-backoff up to CB_PR_RETRY_MAX, then loud-fail.
    tries=$((tries + 1))
    if [ "$tries" -ge "$max" ]; then
      echo "CB_PR_CREATE_FAILED: rate-limit remaining=$remaining < floor=$floor after $tries attempt(s) — PR NOT created (issue #996 loud-fail, no silent drop)" >&2
      return 75
    fi
    sleep "$backoff" 2>/dev/null || true
  done
}

# Allow direct CLI invocation as well as sourcing:  cb-pr-create.sh <gh pr create args...>
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  cb_pr_create "$@"
fi
