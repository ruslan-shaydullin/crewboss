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

# _cb_pr_head_branch <gh pr create args...> — the head branch this PR is created FROM.
#   Real rework/leaf call sites pass NO --head; the head is the checked-out branch, so we
#   derive it via `git branch --show-current`. If an explicit --head/-H is present (test
#   harness / manual override) it wins, so the sweep can be driven deterministically.
_cb_pr_head_branch() {
  local prev=""
  for a in "$@"; do
    case "$prev" in --head|-H) printf '%s\n' "$a"; return 0 ;; esac
    prev="$a"
  done
  git branch --show-current 2>/dev/null || true
}

# _cb_pr_supersede <new-pr-number> <head-branch> — rework-PR hygiene (charter #1290 P3).
#   Incident 2026-07-02 (leaf #1281): an RL storm piled 3 open PRs of one leaf (#1286/#1288/
#   #1289) — superseded rework PRs were never closed. ONLY when the head is `rework/<rid>-*`,
#   list every OTHER open PR of the SAME leaf id (heads `leaf/<rid>-*` or `rework/<rid>-*`),
#   comment "superseded by #N", and close it. The just-created PR (#N) is excluded by number,
#   so it never closes itself; unrelated leaves are out of scope. Best-effort: never disturbs
#   the pinned success/loud-fail contract of cb_pr_create.
_cb_pr_supersede() {
  local new="$1" head="$2"
  # Gate strictly on a rework head: leaf-executor call sites (leaf/<id>-*) never sweep.
  case "$head" in rework/*[0-9]-*) : ;; *) return 0 ;; esac
  local rid; rid="$(printf '%s' "$head" | sed -n 's,^rework/\([0-9][0-9]*\)-.*,\1,p')"
  [ -n "$rid" ] || return 0
  [ -n "$new" ] || return 0

  local repo_args=(); [ -n "${CB_REPO:-}" ] && repo_args=(--repo "$CB_REPO")
  local list; list="$(gh pr list "${repo_args[@]}" --state open \
                        --json number,headRefName --limit 200 2>/dev/null)" || return 0
  [ -n "$list" ] || return 0

  # Emit "<number>\t<headRefName>" rows without needing jq's presence assumptions.
  printf '%s\n' "$list" \
    | gh_pr_json_rows 2>/dev/null \
    | while IFS=$'\t' read -r num href; do
        [ -n "$num" ] || continue
        [ "$num" = "$new" ] && continue                 # never close the new PR itself
        case "$href" in
          leaf/"$rid"-*|rework/"$rid"-*)
            gh pr comment "$num" "${repo_args[@]}" --body "superseded by #$new" >/dev/null 2>&1 || true
            gh pr close   "$num" "${repo_args[@]}" >/dev/null 2>&1 || true
            ;;
        esac
      done
  return 0
}

# gh_pr_json_rows — parse `gh pr list --json number,headRefName` output into TSV rows.
#   Prefers jq; falls back to a tolerant sed/grep parser if jq is unavailable in the jail.
gh_pr_json_rows() {
  if command -v jq >/dev/null 2>&1; then
    jq -r '.[] | "\(.number)\t\(.headRefName)"' 2>/dev/null && return 0
  fi
  # Fallback: one object per line already, or a compact array — extract number + headRefName.
  tr '}' '\n' \
    | while IFS= read -r obj; do
        case "$obj" in *number*headRefName*|*headRefName*number*) : ;; *) continue ;; esac
        local n h
        n="$(printf '%s' "$obj" | sed -n 's/.*"number"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')"
        h="$(printf '%s' "$obj" | sed -n 's/.*"headRefName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
        [ -n "$n" ] && printf '%s\t%s\n' "$n" "$h"
      done
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
      # Capture gh's stdout (the new PR URL) so we can learn the new PR number N, while
      # STILL emitting that URL verbatim to the caller (contract unchanged for leaves).
      local out rc
      if [ -n "${CB_REPO:-}" ]; then
        out="$(gh pr create --repo "$CB_REPO" "$@")"; rc=$?
      else
        out="$(gh pr create "$@")"; rc=$?
      fi
      printf '%s\n' "$out"
      if [ "$rc" -eq 0 ]; then
        # Learn N from the trailing .../pull/<N> segment of the created-PR URL.
        local new_pr head
        new_pr="$(printf '%s' "$out" | grep -oE '/pull/[0-9]+' | grep -oE '[0-9]+' | tail -1)"
        head="$(_cb_pr_head_branch "$@")"
        _cb_pr_supersede "$new_pr" "$head"
      fi
      return "$rc"
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
