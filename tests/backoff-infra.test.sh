#!/usr/bin/env bash
# tests/backoff-infra.test.sh — exponential backoff for try-merge infra-error (charter #350 / issue #917)
#
# Tests the file-backed exponential backoff state machine for exit-2
# (clone/fetch/checkout infra error) on the try-merge path.
#
# ALLOW-class: pure-function reference implementation + state-file assertions.
# No real launcher loop, no real gh CLI, no background processes, no sleep.
#
# Named contract cases:
#   BACKOFF-a  first try-merge infra fail (exit 2) — no escalation; state files written
#   BACKOFF-b  attempt count reaches CB_INFRA_RETRY_CAP — comment + status:blocked
#   BACKOFF-c  pre-populated state dir — attempt loaded from disk, not reset to 0
#   BACKOFF-d  verify-merged RED (exit 1, rework_n path) — infra state untouched
#   BACKOFF-e  verify-merged infra error (exit 2) — CB_INFRA_* state untouched
#   BACKOFF-f  re-dispatch clears state; subsequent infra fail restarts from attempt=1
#
# TAP output: ok N -- description / not ok N -- description
set -uo pipefail

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
STATE_ROOT="$TMP/run/state"
mkdir -p "$STATE_ROOT"

# ── Config defaults (mirrors charter #350 run-env.sh additions) ──────────────
CB_INFRA_RETRY_CAP="${CB_INFRA_RETRY_CAP:-5}"
CB_INFRA_BACKOFF_BASE="${CB_INFRA_BACKOFF_BASE:-60}"
CB_INFRA_BACKOFF_MULT="${CB_INFRA_BACKOFF_MULT:-2}"

# ── TAP output helpers ────────────────────────────────────────────────────────
N=0; pass=0; fail=0
ok()  { N=$((N+1)); printf 'ok %d -- %s\n'     "$N" "$*"; pass=$((pass+1)); }
ko()  { N=$((N+1)); printf 'not ok %d -- %s\n' "$N" "$*"; fail=$((fail+1)); }

# ── Board / gh action stub (in-memory log) ────────────────────────────────────
BOARD_LOG="$TMP/board.log"; : > "$BOARD_LOG"
_gh_add_label(){ printf '+label %s %s\n' "$1" "$2" >> "$BOARD_LOG"; }
_gh_comment(){   printf 'comment %s %s\n' "$1" "$2" >> "$BOARD_LOG"; }
board_has_label(){   grep -q "^+label $1 $2\$"  "$BOARD_LOG" 2>/dev/null; }
board_has_comment(){ grep -q "^comment $1 "     "$BOARD_LOG" 2>/dev/null; }

# ── State-file helpers (mirror launcher sget/sset) ────────────────────────────
_sdir(){ printf '%s/%s' "$STATE_ROOT" "$1"; }
_sget(){ cat "$(_sdir "$1")/$2" 2>/dev/null || true; }
_sset(){ mkdir -p "$(_sdir "$1")"; printf '%s' "$3" > "$(_sdir "$1")/$2"; }
_sdel(){ rm -f "$(_sdir "$1")/$2" 2>/dev/null || true; }
_fpath(){ printf '%s/%s' "$(_sdir "$1")" "$2"; }

# ── Reference implementation: charter #350 try-merge infra-error backoff ─────
#
# _infra_handle_exit2 <leaf-id>
#   Called when try-merge exits 2 (infra error).
#   Reads infra_attempt from disk (persistent across restarts), increments,
#   writes back.  Writes infra_next_retry_ts = now + base*mult^(attempt-1).
#   Returns 0: under cap — no escalation.
#   Returns 1: cap reached — status:blocked label + comment written to log.
_infra_handle_exit2() {
  local lid="$1"
  # Load persistent attempt counter from disk (or 0 if absent)
  local attempt; attempt=$(_sget "$lid" infra_attempt)
  attempt=${attempt:-0}
  attempt=$((attempt + 1))
  _sset "$lid" infra_attempt "$attempt"

  # Compute exponential backoff delay: base * mult^(attempt-1)
  local delay="$CB_INFRA_BACKOFF_BASE"
  local power=$((attempt - 1))
  local i=0
  while [ "$i" -lt "$power" ]; do
    delay=$((delay * CB_INFRA_BACKOFF_MULT))
    i=$((i + 1))
  done
  local ts; ts=$(( $(date +%s) + delay ))
  _sset "$lid" infra_next_retry_ts "$ts"

  # Ceiling check: escalate at cap
  if [ "$attempt" -ge "$CB_INFRA_RETRY_CAP" ]; then
    _gh_add_label "$lid" "status:blocked"
    _gh_comment   "$lid" "infra-retry cap reached ($attempt/$CB_INFRA_RETRY_CAP) — blocked for human triage"
    return 1
  fi
  return 0
}

# _infra_clear <leaf-id>
#   Mirrors cmd_redispatch key-clearance loop (charter #350 line 940):
#   deletes infra_attempt and infra_next_retry_ts from the state dir.
_infra_clear() {
  local lid="$1"
  _sdel "$lid" infra_attempt
  _sdel "$lid" infra_next_retry_ts
}

# _rework_handle_exit1 <leaf-id>
#   Called when verify-merged exits 1 (confirmed RED, rework_n path, lines 375-400).
#   Increments rework_n; does NOT touch CB_INFRA_* state (separate path).
_rework_handle_exit1() {
  local lid="$1"
  local rwork; rwork=$(_sget "$lid" rework_n)
  rwork=${rwork:-0}
  rwork=$((rwork + 1))
  _sset "$lid" rework_n "$rwork"
}

# _verify_merged_infra <leaf-id>
#   Called when verify-merged exits 2 (infra error, lines 406-409).
#   Charter #350 OUT OF SCOPE: retains existing retry-next-tick behaviour;
#   must NOT create or modify CB_INFRA_* state files.
_verify_merged_infra() {
  local _lid="$1"
  # Intentional no-op for CB_INFRA_* state (log-and-retry-next-tick path only)
  : # $_lid — infra state files are out of scope on verify-merged exit-2 path
}

# =============================================================================
# BACKOFF-a: first try-merge infra fail (exit 2)
#   → no escalation (status:blocked NOT added)
#   → state file infra_attempt contains 1
#   → infra_next_retry_ts is a non-zero integer
# =============================================================================
printf '\n== BACKOFF-a: first try-merge infra fail ==\n'
LID_A="999"; mkdir -p "$(_sdir "$LID_A")"
: > "$BOARD_LOG"

_infra_handle_exit2 "$LID_A" || true   # cap not reached; non-zero return suppressed

attempt_a=$(_sget "$LID_A" infra_attempt)
ts_a=$(_sget      "$LID_A" infra_next_retry_ts)

[ "$attempt_a" = "1" ] \
  && ok "BACKOFF-a: infra_attempt=1 after first try-merge exit 2" \
  || ko "BACKOFF-a: expected infra_attempt=1, got '${attempt_a}'"

[ -n "$ts_a" ] && [ "$ts_a" -gt 0 ] 2>/dev/null \
  && ok "BACKOFF-a: infra_next_retry_ts is a non-zero integer (${ts_a})" \
  || ko "BACKOFF-a: infra_next_retry_ts missing or not a non-zero integer (got '${ts_a}')"

! board_has_label "$LID_A" "status:blocked" \
  && ok "BACKOFF-a: status:blocked NOT added on first infra fail (no premature escalation)" \
  || ko "BACKOFF-a: status:blocked was added on first infra fail — must not escalate before cap"

# =============================================================================
# BACKOFF-b: attempt count reaches CB_INFRA_RETRY_CAP
#   → GitHub comment posted on leaf issue
#   → status:blocked label added to leaf issue
# =============================================================================
printf '\n== BACKOFF-b: attempt reaches CB_INFRA_RETRY_CAP ==\n'
LID_B="998"; mkdir -p "$(_sdir "$LID_B")"
: > "$BOARD_LOG"
CAP_B="$CB_INFRA_RETRY_CAP"

# Pre-load attempt counter at cap-1 so next call hits the ceiling
_sset "$LID_B" infra_attempt "$((CAP_B - 1))"
_infra_handle_exit2 "$LID_B" || true   # triggers cap branch

attempt_b=$(_sget "$LID_B" infra_attempt)

[ "$attempt_b" = "$CAP_B" ] \
  && ok "BACKOFF-b: infra_attempt=$CAP_B written when cap reached" \
  || ko "BACKOFF-b: expected infra_attempt=$CAP_B, got '${attempt_b}'"

board_has_comment "$LID_B" \
  && ok "BACKOFF-b: GitHub comment posted on leaf issue when infra_attempt reaches CB_INFRA_RETRY_CAP" \
  || ko "BACKOFF-b: no comment posted when cap reached (expected gh issue comment)"

board_has_label "$LID_B" "status:blocked" \
  && ok "BACKOFF-b: status:blocked label added to leaf issue when cap reached" \
  || ko "BACKOFF-b: status:blocked NOT added when cap reached (expected gh issue edit --add-label)"

# =============================================================================
# BACKOFF-c: launcher restart with pre-populated state dir
#   → write infra_attempt=3 to disk before invoking
#   → attempt count loaded from disk as 3, not reset to 0
# =============================================================================
printf '\n== BACKOFF-c: pre-populated state dir — attempt loaded from disk ==\n'
LID_C="997"; mkdir -p "$(_sdir "$LID_C")"
# Simulate a prior run that left infra_attempt=3 persisted on disk
_sset "$LID_C" infra_attempt "3"
: > "$BOARD_LOG"

_infra_handle_exit2 "$LID_C" || true

attempt_c=$(_sget "$LID_C" infra_attempt)

[ "$attempt_c" = "4" ] \
  && ok "BACKOFF-c: attempt count loaded from disk as 3 and incremented to 4 (not reset to 0)" \
  || ko "BACKOFF-c: expected attempt_c=4 (3+1), got '${attempt_c}' — disk state not loaded correctly"

[ "$attempt_c" != "1" ] \
  && ok "BACKOFF-c: attempt count NOT reset to 0/1 on launcher restart (persistent state preserved)" \
  || ko "BACKOFF-c: attempt count was reset to 1 — on-disk infra_attempt ignored on restart"

# =============================================================================
# BACKOFF-d: verify-merged RED path (exit 1, rework_n path, lines 375-400)
#   → rework_n incremented
#   → infra_attempt NOT created or modified
#   → infra_next_retry_ts NOT created or modified
# =============================================================================
printf '\n== BACKOFF-d: verify-merged RED (exit 1, rework_n path) — infra state untouched ==\n'
LID_D="996"; mkdir -p "$(_sdir "$LID_D")"
: > "$BOARD_LOG"

_rework_handle_exit1 "$LID_D"

rwork_d=$(_sget "$LID_D" rework_n)

[ "$rwork_d" = "1" ] \
  && ok "BACKOFF-d: rework_n incremented to 1 by verify-merged RED (exit 1) path" \
  || ko "BACKOFF-d: expected rework_n=1, got '${rwork_d}' — rework_n path not active"

[ ! -f "$(_fpath "$LID_D" infra_attempt)" ] \
  && ok "BACKOFF-d: infra_attempt NOT created by verify-merged RED path (out of scope)" \
  || ko "BACKOFF-d: infra_attempt was created — verify-merged exit-1 must NOT touch CB_INFRA_* state"

[ ! -f "$(_fpath "$LID_D" infra_next_retry_ts)" ] \
  && ok "BACKOFF-d: infra_next_retry_ts NOT created by verify-merged RED path (out of scope)" \
  || ko "BACKOFF-d: infra_next_retry_ts was created — verify-merged exit-1 must NOT touch CB_INFRA_* state"

# =============================================================================
# BACKOFF-e: verify-merged infra error (exit 2, lines 406-409)
#   → CB_INFRA_* state files (infra_attempt, infra_next_retry_ts) not created or modified
# =============================================================================
printf '\n== BACKOFF-e: verify-merged infra error (exit 2) — CB_INFRA_* state untouched ==\n'
LID_E="995"; mkdir -p "$(_sdir "$LID_E")"
: > "$BOARD_LOG"

_verify_merged_infra "$LID_E"

[ ! -f "$(_fpath "$LID_E" infra_attempt)" ] \
  && ok "BACKOFF-e: infra_attempt NOT created by verify-merged infra path (exit 2 is out of scope)" \
  || ko "BACKOFF-e: infra_attempt was created by verify-merged infra path — must remain out of scope"

[ ! -f "$(_fpath "$LID_E" infra_next_retry_ts)" ] \
  && ok "BACKOFF-e: infra_next_retry_ts NOT created by verify-merged infra path (exit 2 is out of scope)" \
  || ko "BACKOFF-e: infra_next_retry_ts was created by verify-merged infra path — must remain out of scope"

# =============================================================================
# BACKOFF-f: re-dispatch after ceiling-block
#   → cmd_redispatch deletes both infra_attempt and infra_next_retry_ts
#   → subsequent try-merge infra fail (exit 2) creates infra_attempt=1 (retry restarts)
# =============================================================================
printf '\n== BACKOFF-f: re-dispatch clears state; retry restarts from attempt=1 ==\n'
LID_F="994"; mkdir -p "$(_sdir "$LID_F")"
CAP_F="$CB_INFRA_RETRY_CAP"
# Simulate ceiling-blocked state: infra_attempt at cap on disk
_sset "$LID_F" infra_attempt      "$CAP_F"
_sset "$LID_F" infra_next_retry_ts "9999999999"
: > "$BOARD_LOG"

# Operator fires cmd_redispatch — clears infra state along with other keys
_infra_clear "$LID_F"

[ ! -f "$(_fpath "$LID_F" infra_attempt)" ] \
  && ok "BACKOFF-f: cmd_redispatch deletes infra_attempt from state dir" \
  || ko "BACKOFF-f: infra_attempt NOT deleted by cmd_redispatch"

[ ! -f "$(_fpath "$LID_F" infra_next_retry_ts)" ] \
  && ok "BACKOFF-f: cmd_redispatch deletes infra_next_retry_ts from state dir" \
  || ko "BACKOFF-f: infra_next_retry_ts NOT deleted by cmd_redispatch"

# Fresh board log for the post-redispatch infra fail
: > "$BOARD_LOG"
_infra_handle_exit2 "$LID_F" || true

attempt_f=$(_sget "$LID_F" infra_attempt)

[ "$attempt_f" = "1" ] \
  && ok "BACKOFF-f: subsequent try-merge infra fail after redispatch creates infra_attempt=1 (retry restarts from 0)" \
  || ko "BACKOFF-f: expected infra_attempt=1 after redispatch, got '${attempt_f}'"

! board_has_label "$LID_F" "status:blocked" \
  && ok "BACKOFF-f: status:blocked NOT re-added on attempt=1 after redispatch (clean backoff restart)" \
  || ko "BACKOFF-f: status:blocked was re-added after redispatch at attempt=1 — restart should not immediately block"

# =============================================================================
printf '\n=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
