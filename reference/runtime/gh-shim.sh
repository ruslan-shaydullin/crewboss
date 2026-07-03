#!/usr/bin/env bash
#
# gh-shim.sh — RL-aware transparent `gh` wrapper for jail sessions (charter #1274, issue #1299)
#
# WHY (self-contained context):
#   Incident 2026-07-02 01:25 UTC: GitHub rate-limit exhaustion (403 core + GraphQL pool
#   exceeded). Jail sessions receive GH_TOKEN and burn BOTH the REST-core and the GraphQL
#   5000/h pools from *inside* the jail (gh issue view, gh pr create, gh pr checks, ...).
#   The launcher's floor-guard lives outside the jail and cannot restrain those in-jail
#   calls. This shim is placed FIRST in the jail's PATH as `gh`, so every in-jail `gh`
#   invocation flows through it: it backs off BEFORE the call when a pool is depleted, then
#   RUNS the real gh, then refreshes the shared rate-limit state AFTER the call.
#
#   Pattern precedent: the RL-aware `cb_pr_create` from charter #1004 / issue #1043
#   (cb-pr-create.sh:33 — post-call `gh api rate_limit` refresh). This shim generalises that
#   to every gh subcommand and covers BOTH pools.
#
#   Transparent to role prompts: it forwards argv unchanged, faithfully preserves the real
#   gh exit code / stdout / stderr, and honours `--output-format json` / `--jq` contracts.
#   Deploy wiring (manifest row, PATH-prepend, env injection, rw bind of the state file) is
#   a SEPARATE leaf (1274-p3-deploy). This leaf ships ONLY this script.
#
# State-file schema (four key=value integer lines), CB_RL_STATE_FILE:
#   rl_core_remaining=N   rl_core_reset=T   rl_gql_remaining=N   rl_gql_reset=T
#   In-jail default path: /cbnet/run/rl_state.
#
# SECURITY: GH_TOKEN is NEVER logged — not in argument logging, not in error messages,
#           not in any temp/state file this shim writes.

set -uo pipefail

# ── Config knobs (all overridable via env; jail-safe defaults) ────────────────
CB_RL_STATE_FILE="${CB_RL_STATE_FILE:-/cbnet/run/rl_state}"
CB_RL_FLOOR="${CB_RL_FLOOR:-1000}"          # REST-core floor
CB_RL_FLOOR_GQL="${CB_RL_FLOOR_GQL:-800}"   # GraphQL floor (independent pool)

# ── Logging — writes to stderr, NEVER includes GH_TOKEN or argv ───────────────
_gh_shim_log() { printf 'gh-shim: %s\n' "$*" >&2; }

# ── Integer predicate ─────────────────────────────────────────────────────────
_gh_shim_isint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# ── Fully resolve a path through BOTH file and directory symlinks ─────────────
# Returns an absolute canonical path. Used to compare a PATH candidate against
# THIS script: the candidate is often a symlink named `gh` pointing at this very
# shim (that is exactly how the shim is wired into a jail's PATH), so we MUST
# resolve the candidate the same way we resolve ourselves — otherwise the shim
# selects itself as the "real" gh and recurses without bound (fork bomb; #1274
# regression observed live 2026-07-03: `/cbnet/gh -> gh-shim.sh` self-selected
# because the candidate was dir-resolved but not file-symlink-resolved).
_gh_shim_resolve() {
  local src="$1" dir
  while [ -h "$src" ]; do
    dir="$(cd -P "$(dirname "$src")" 2>/dev/null && pwd)"
    src="$(readlink "$src")"
    case "$src" in /*) : ;; *) src="$dir/$src" ;; esac
  done
  printf '%s' "$(cd -P "$(dirname "$src")" 2>/dev/null && pwd)/$(basename "$src")"
}

# ── Resolve the REAL gh binary (this script sits first in PATH as `gh`) ────────
# Walks PATH, returns the first executable `gh` that is NOT this very script.
# Honours CB_GH_REAL as an explicit override (deploy/test seam).
_gh_shim_real() {
  if [ -n "${CB_GH_REAL:-}" ] && [ -x "${CB_GH_REAL}" ]; then
    printf '%s' "$CB_GH_REAL"
    return 0
  fi

  # Absolute, symlink-resolved path of this script (to exclude from the search).
  local self_real
  self_real="$(_gh_shim_resolve "${BASH_SOURCE[0]}")"

  local IFS=: p cand cand_real
  for p in $PATH; do
    [ -n "$p" ] || p="."
    cand="$p/gh"
    [ -x "$cand" ] && [ ! -d "$cand" ] || continue
    # Resolve the candidate through symlinks BEFORE comparing — a `gh` symlink
    # pointing at this shim must be recognised as ourselves, not followed.
    cand_real="$(_gh_shim_resolve "$cand")"
    [ "$cand_real" = "$self_real" ] && continue   # never resolve to ourselves
    printf '%s' "$cand"
    return 0
  done
  return 1
}

# ── State-file reader: <file> <key> -> value on stdout (empty if absent) ───────
_gh_shim_read_key() {
  local f="$1" k="$2" line
  [ -f "$f" ] || return 1
  line="$(grep -E "^${k}=" "$f" 2>/dev/null | head -1)" || true
  [ -n "$line" ] || return 1
  printf '%s' "${line#*=}"
}

# ── Atomic 4-key state write (temp file + mv) ─────────────────────────────────
_gh_shim_write_atomic() {
  local f="$1" cr="$2" ct="$3" gr="$4" gt="$5" tmp dir
  dir="$(dirname "$f")"
  mkdir -p "$dir" 2>/dev/null || true
  tmp="${f}.$$.${RANDOM}.tmp"
  {
    printf 'rl_core_remaining=%s\n' "$cr"
    printf 'rl_core_reset=%s\n'     "$ct"
    printf 'rl_gql_remaining=%s\n'  "$gr"
    printf 'rl_gql_reset=%s\n'      "$gt"
  } > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  mv -f "$tmp" "$f" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
}

# ── Sleep-until-reset, capped at CB_TASK_TIMEOUT/10 (default var may be unset) ─
# <reset_epoch> <cap_seconds> <reason>
_gh_shim_sleep_until() {
  local reset="$1" cap="$2" reason="$3" now dur
  now="$(date +%s 2>/dev/null || echo 0)"
  _gh_shim_isint "$reset" || reset="$now"
  dur=$(( reset - now ))
  [ "$dur" -lt 0 ] 2>/dev/null && dur=0
  [ "$dur" -gt "$cap" ] 2>/dev/null && dur="$cap"
  _gh_shim_log "rate-limit backoff: ${reason}; sleeping ${dur}s (cap ${cap}s) until pool reset"
  [ "$dur" -gt 0 ] 2>/dev/null && sleep "$dur" 2>/dev/null || true
}

# ── PRE-CALL: consult the shared state file; back off if a pool is depleted ────
# File absent -> bootstrap mode: proceed WITHOUT sleeping.
_gh_shim_precall() {
  local sf="$CB_RL_STATE_FILE"
  if [ ! -f "$sf" ]; then
    _gh_shim_log "state file absent ($sf) — bootstrap mode, proceeding without backoff"
    return 0
  fi

  # Sleep cap: 1/10 of the task budget. CB_TASK_TIMEOUT may be UNSET inside the jail.
  local cap
  cap=$(( ${CB_TASK_TIMEOUT:-3600} / 10 ))

  local c_rem c_reset g_rem g_reset
  c_rem="$(_gh_shim_read_key "$sf" rl_core_remaining || true)"
  c_reset="$(_gh_shim_read_key "$sf" rl_core_reset   || echo 0)"
  g_rem="$(_gh_shim_read_key "$sf" rl_gql_remaining  || true)"
  g_reset="$(_gh_shim_read_key "$sf" rl_gql_reset    || echo 0)"

  # REST-core pool below its floor -> wait for the core reset.
  if _gh_shim_isint "$c_rem" && [ "$c_rem" -lt "$CB_RL_FLOOR" ]; then
    _gh_shim_sleep_until "$c_reset" "$cap" "core remaining=${c_rem} < floor=${CB_RL_FLOOR}"
  fi

  # GraphQL pool below its (independent) floor -> wait for the graphql reset.
  if _gh_shim_isint "$g_rem" && [ "$g_rem" -lt "$CB_RL_FLOOR_GQL" ]; then
    _gh_shim_sleep_until "$g_reset" "$cap" "graphql remaining=${g_rem} < floor=${CB_RL_FLOOR_GQL}"
  fi

  return 0
}

# ── POST-CALL: refresh the shared state from an own-token `gh api rate_limit` ──
# `gh api rate_limit` is FREE (does not consume either pool) and is per-token accurate.
# Test seams (CB_RL_*_REMAINING_OVERRIDE) are honoured ONLY under CB_RL_TEST_MODE=1.
_gh_shim_postcall() {
  local real="$1"
  local c_rem c_reset g_rem g_reset

  if [ "${CB_RL_TEST_MODE:-0}" = "1" ] \
     && { [ -n "${CB_RL_REMAINING_OVERRIDE:-}" ] || [ -n "${CB_RL_GQL_REMAINING_OVERRIDE:-}" ]; }; then
    # Deterministic test path: bypass the network, use injected remainders.
    c_rem="${CB_RL_REMAINING_OVERRIDE:-5000}";     c_reset="${CB_RL_CORE_RESET_OVERRIDE:-0}"
    g_rem="${CB_RL_GQL_REMAINING_OVERRIDE:-5000}"; g_reset="${CB_RL_GQL_RESET_OVERRIDE:-0}"
  else
    local json=""
    json="$("$real" api rate_limit 2>/dev/null)" || json=""
    [ -n "$json" ] || return 1
    if command -v jq >/dev/null 2>&1; then
      c_rem="$(printf '%s' "$json"   | jq -r '.resources.core.remaining    // empty' 2>/dev/null)"
      c_reset="$(printf '%s' "$json" | jq -r '.resources.core.reset        // empty' 2>/dev/null)"
      g_rem="$(printf '%s' "$json"   | jq -r '.resources.graphql.remaining // empty' 2>/dev/null)"
      g_reset="$(printf '%s' "$json" | jq -r '.resources.graphql.reset     // empty' 2>/dev/null)"
    else
      # jq-less fallback: query each field via gh's own --jq (still free calls).
      c_rem="$(  "$real" api rate_limit -q '.resources.core.remaining'    2>/dev/null)"
      c_reset="$("$real" api rate_limit -q '.resources.core.reset'        2>/dev/null)"
      g_rem="$(  "$real" api rate_limit -q '.resources.graphql.remaining' 2>/dev/null)"
      g_reset="$("$real" api rate_limit -q '.resources.graphql.reset'     2>/dev/null)"
    fi
  fi

  # Only persist a fully-parsed, all-integer snapshot — never corrupt the state file.
  _gh_shim_isint "$c_rem" && _gh_shim_isint "$c_reset" \
    && _gh_shim_isint "$g_rem" && _gh_shim_isint "$g_reset" || return 1

  _gh_shim_write_atomic "$CB_RL_STATE_FILE" "$c_rem" "$c_reset" "$g_rem" "$g_reset" \
    && _gh_shim_log "post-call rate_limit refresh core=${c_rem} gql=${g_rem}"
}

# ── Main ──────────────────────────────────────────────────────────────────────
_gh_shim_main() {
  local real
  real="$(_gh_shim_real)" || {
    _gh_shim_log "FATAL: could not locate the real gh binary in PATH"
    return 127
  }

  # 1) Back off first if the shared state says a pool is depleted.
  _gh_shim_precall

  # 2) RUN (not exec) the real gh with argv forwarded verbatim so that
  #    --output-format json / --jq contracts pass through untouched. stdout/stderr
  #    inherit the caller's fds for byte-faithful, unbuffered pass-through.
  local rc=0
  "$real" "$@"
  rc=$?

  # 3) Refresh the shared rate-limit state (best-effort; never masks gh's exit code).
  _gh_shim_postcall "$real" || true

  return "$rc"
}

# Entry point. CB_GH_SHIM_NO_MAIN lets tests source this file to unit-test the
# helpers (e.g. _gh_shim_resolve) without running the wrapper or exiting.
if [ -z "${CB_GH_SHIM_NO_MAIN:-}" ]; then
  _gh_shim_main "$@"
  exit $?
fi
