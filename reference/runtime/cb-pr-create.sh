#!/usr/bin/env bash
#
# cb-pr-create.sh — deterministic, rate-limit-aware `gh pr create` wrapper (charter #1004, issue #1043)
#
# WHY (self-contained context):
#   Bug #996 (2026-06-29): an executor leaf did all its work, but the inline `gh pr create`
#   ran the moment the GitHub primary rate-limit was at 0 remaining. There was NO retry and
#   NO loud failure, so the PR was silently never created and the leaf blocked forever.
#   This helper replaces the raw inline `gh pr create` in the executor prompt with a CODE path
#   that, deterministically: checks `remaining` -> retries-with-backoff -> hard-fails LOUDLY.
#   It is shipped as a canonical runtime-manifest row so deploy-runtime.sh scps it (by basename)
#   to /cbnet/cb-pr-create.sh, reachable READ-ONLY inside the jail; the executor prompt sources
#   it by that absolute path.
#
# PINNED contract (IDENTICAL to qa leaf #1041, tests/test_rl_live.sh test 4):
#   - Callable: `cb_pr_create <gh pr create args...>`, uses CB_REPO.
#   - RL-pressure injection seam: CB_RL_REMAINING_OVERRIDE bypasses `gh api /rate_limit`
#     so tests can force a low `remaining` deterministically.
#   - Knobs: CB_RL_FLOOR (default 1000), CB_PR_RETRY_MAX (default 3), CB_PR_BACKOFF_S (default 2).
#   - Loud-fail: return 75 + stderr marker CB_PR_CREATE_FAILED when RL pressure persists past
#     CB_PR_RETRY_MAX (NEVER a silent PR drop).
#
# This file is meant to be SOURCED (`source /cbnet/cb-pr-create.sh && cb_pr_create ...`).
# It must NOT alter the caller's shell options and must `return` (never `exit`) so a sourcing
# shell survives a loud-fail.

# _cb_pr_rl_remaining — emit the current primary-RL `remaining`, honouring the test seam.
_cb_pr_rl_remaining() {
  if [ -n "${CB_RL_REMAINING_OVERRIDE:-}" ]; then
    printf '%s\n' "$CB_RL_REMAINING_OVERRIDE"
    return 0
  fi
  gh api /rate_limit -q '.resources.core.remaining' 2>/dev/null || echo 0
}

# cb_pr_create <gh pr create args...>
#   Honours CB_REPO (passed through as --repo). Throttles + retries while the primary
#   rate-limit `remaining` is below CB_RL_FLOOR; loud-fails (return 75 + CB_PR_CREATE_FAILED)
#   once RL pressure persists past CB_PR_RETRY_MAX retries.
cb_pr_create() {
  local floor="${CB_RL_FLOOR:-1000}"
  local max="${CB_PR_RETRY_MAX:-3}"
  local backoff="${CB_PR_BACKOFF_S:-2}"
  local tries=0 remaining

  while :; do
    remaining="$(_cb_pr_rl_remaining)"
    # Non-numeric / unreadable -> treat as 0 (safest: assume pressure, retry, then loud-fail).
    case "$remaining" in
      ''|*[!0-9]*) remaining=0 ;;
    esac

    if [ "$remaining" -ge "$floor" ]; then
      # Healthy headroom: actually create the PR. Return gh's own exit code.
      if [ -n "${CB_REPO:-}" ]; then
        gh pr create --repo "$CB_REPO" "$@"
      else
        gh pr create "$@"
      fi
      return $?
    fi

    # Under RL pressure: count the attempt, back off, retry — until we exhaust the budget.
    tries=$((tries + 1))
    if [ "$tries" -gt "$max" ]; then
      echo "CB_PR_CREATE_FAILED: rate-limit remaining=$remaining < floor=$floor after $max retr(y/ies); PR NOT created (issue #1043 / bug #996)" >&2
      return 75
    fi
    echo "cb_pr_create: RL pressure (remaining=$remaining < floor=$floor); retry $tries/$max after ${backoff}s" >&2
    sleep "$backoff" 2>/dev/null || true
  done
}
