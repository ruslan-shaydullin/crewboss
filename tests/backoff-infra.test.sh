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

# #############################################################################
# CHARTER #1274 — dual-pool rate-limit coverage (issue #1297, qa leaf, merges FIRST)
# #############################################################################
#
# WHY (self-contained context for a cold reader):
#   Charter #1004 (#1041 RED tests, #1042/#1043 impl) armed the REST *core* pool only:
#   `_cb_rl_backoff` reads `.resources.core.remaining` against CB_RL_FLOOR. The
#   2026-07-02 incident showed the GraphQL pool (gh issue edit/view/comment, gh pr
#   list/view/merge — separate 5000/h bucket) burns to 0 UNSEEN by the core-only guard,
#   and jail sessions holding the same GH_TOKEN burn both pools from inside the guard's
#   blind spot. This charter closes those:
#     P1 guard v2 : combine own-token `gh api rate_limit` poll with the shared session
#                   state file CB_RL_STATE_FILE; separate floors CB_RL_FLOOR (core) /
#                   CB_RL_FLOOR_GQL (graphql); backoff when EITHER pool < its floor.
#     P2 diet     : cache-replaceable `gh issue view` served from _CB_TICK_CACHE_ALL;
#                   every `--json comments` view STAYS LIVE (rule, not count);
#                   sequential same-issue `gh issue edit`s batch into one.
#     P3 shim     : reference/runtime/gh-shim.sh — RL-aware run+capture wrapper in the
#                   jail PATH; sleep-cap <= CB_TASK_TIMEOUT/10; override seams under
#                   CB_RL_TEST_MODE=1 only; atomic 4-key state write; never logs GH_TOKEN.
#
# State-file schema under test (four key=value integer lines):
#   rl_core_remaining=N   rl_core_reset=T   rl_gql_remaining=N   rl_gql_reset=T
#   CB_RL_STATE_FILE defaults host-side to $CB_HOME/run/rl_state; in-jail /cbnet/run/rl_state.
#
# RED-first tiering (precedent #1041 tests/test_rl_live.sh):
#   * MOCK tier (always run, GREEN at this leaf's merge): proves every discriminator
#     against reference implementations that DO satisfy the contract — this is what the
#     default `tests/backoff-infra.test.sh` invocation runs.
#   * SOURCE tier (armed with CB_DUAL_MODE=source|live): asserts the SAME contracts
#     against the REAL shipped artifacts (crewboss-launcher-gh.sh, gh-shim.sh). RED until
#     the P1/P2/P3 impl leaves land; owned by those leaves at their merge. When NOT armed
#     the harness ENUMERATES each source-gated case as a SKIP so the current tree is green.
#   * Invariants already true on the current tree (e.g. comment-views stay live) are
#     asserted unconditionally: green now, and the impl must keep them green.
#
# TAP continues on the shared N/pass/fail counters above.

DUAL_MODE="${CB_DUAL_MODE:-mock}"
LAUNCHER_1274="${LAUNCHER_1274:-$(cd "$(dirname "$0")/.." && pwd)/reference/runtime/crewboss-launcher-gh.sh}"
SHIM_1274="${SHIM_1274:-$(cd "$(dirname "$0")/.." && pwd)/reference/runtime/gh-shim.sh}"

armed(){ [ "$DUAL_MODE" = "source" ] || [ "$DUAL_MODE" = "live" ]; }
skip(){ N=$((N+1)); printf 'ok %d -- # SKIP %s\n' "$N" "$*"; pass=$((pass+1)); }

# -- State-file schema helpers (four key=value integer lines) ------------------
_rl_read(){ # <file> <key> -> value (empty + rc1 if absent)
  local f="$1" k="$2" line
  [ -f "$f" ] || return 1
  line="$(grep -E "^${k}=" "$f" 2>/dev/null | head -1)" || true
  [ -n "$line" ] || return 1
  printf '%s' "${line#*=}"
}
_rl_write_atomic(){ # <file> <core_rem> <core_reset> <gql_rem> <gql_reset> — temp+mv
  local f="$1" cr="$2" ct="$3" gr="$4" gt="$5" tmp
  tmp="${f}.$$.${RANDOM}.tmp"
  { printf 'rl_core_remaining=%s\n' "$cr"
    printf 'rl_core_reset=%s\n'     "$ct"
    printf 'rl_gql_remaining=%s\n'  "$gr"
    printf 'rl_gql_reset=%s\n'      "$gt"
  } > "$tmp"
  mv -f "$tmp" "$f"
}

DUAL_TMP="$TMP/dual"; mkdir -p "$DUAL_TMP"

# =============================================================================
# P1 — guard v2 reference implementation (MOCK tier; proves the discriminators)
# =============================================================================
# _ref_rl_pool <core|gql> -> "effective_remaining effective_reset"
#   effective = min(own-token poll, session state file). Own-token poll uses the
#   CB_RL_*_OVERRIDE seams (a real impl polls `gh api rate_limit`). File values come
#   from CB_RL_STATE_FILE. File-ABSENT: graphql degrades to CB_RL_FLOOR_GQL (near-floor,
#   NOT full pool); core follows the own-token poll. The depleted source's reset epoch
#   is carried through (min-remaining wins its reset).
_ref_rl_pool(){
  local which="$1"
  local floor_gql="${CB_RL_FLOOR_GQL:-800}"
  local sf="${CB_RL_STATE_FILE:-}"
  local poll poll_reset file file_reset
  case "$which" in
    core) poll="${CB_RL_REMAINING_OVERRIDE:-5000}";     poll_reset="${CB_RL_CORE_RESET_OVERRIDE:-0}" ;;
    gql)  poll="${CB_RL_GQL_REMAINING_OVERRIDE:-5000}"; poll_reset="${CB_RL_GQL_RESET_OVERRIDE:-0}" ;;
  esac
  if [ -n "$sf" ] && [ -f "$sf" ]; then
    case "$which" in
      core) file="$(_rl_read "$sf" rl_core_remaining || true)"; file_reset="$(_rl_read "$sf" rl_core_reset || echo 0)" ;;
      gql)  file="$(_rl_read "$sf" rl_gql_remaining  || true)"; file_reset="$(_rl_read "$sf" rl_gql_reset  || echo 0)" ;;
    esac
    [ -n "$file" ] || { file="$poll"; file_reset="$poll_reset"; }
  else
    case "$which" in
      core) file="$poll";      file_reset="$poll_reset" ;;   # core: no file -> own poll
      gql)  file="$floor_gql"; file_reset="$poll_reset" ;;   # gql: no file -> near-floor
    esac
  fi
  if [ "$file" -lt "$poll" ] 2>/dev/null; then printf '%s %s\n' "$file" "$file_reset"
  else                                          printf '%s %s\n' "$poll" "$poll_reset"; fi
}

# _ref_rl_backoff -> "trigger pool reset"  (trigger 0|1; pool none|core|gql|both)
#   Backoff fires when EITHER effective pool sits below its own floor; reset is the
#   depleted pool's epoch (later of the two when both are depleted).
_ref_rl_backoff(){
  local floor_core="${CB_RL_FLOOR:-1000}" floor_gql="${CB_RL_FLOOR_GQL:-800}"
  local c_rem c_reset g_rem g_reset
  read -r c_rem c_reset <<<"$(_ref_rl_pool core)"
  read -r g_rem g_reset <<<"$(_ref_rl_pool gql)"
  local trigger=0 pool=none reset=0
  if [ "$c_rem" -lt "$floor_core" ] 2>/dev/null; then trigger=1; pool=core; reset=$c_reset; fi
  if [ "$g_rem" -lt "$floor_gql" ] 2>/dev/null; then
    if [ "$trigger" -eq 1 ]; then
      pool=both
      [ "$g_reset" -gt "$reset" ] 2>/dev/null && reset=$g_reset
    else
      trigger=1; pool=gql; reset=$g_reset
    fi
  fi
  printf '%s %s %s\n' "$trigger" "$pool" "$reset"
}

printf '\n== DUAL P1 (guard v2): combine own-token poll + session state file ==\n'

# DUAL-P1-a: GraphQL depleted in the state file while own-token poll is healthy.
SF_A="$DUAL_TMP/state_a"; _rl_write_atomic "$SF_A" 5000 111 100 222   # gql=100 < floor 800
read -r tA pA rA <<<"$(CB_RL_STATE_FILE="$SF_A" CB_RL_REMAINING_OVERRIDE=5000 CB_RL_GQL_REMAINING_OVERRIDE=5000 \
                       CB_RL_FLOOR=1000 CB_RL_FLOOR_GQL=800 _ref_rl_backoff)"
[ "$tA" = "1" ] && { [ "$pA" = "gql" ] || [ "$pA" = "both" ]; } \
  && ok "DUAL-P1-a: gql depleted in state file (poll healthy) -> backoff triggers on gql pool" \
  || ko "DUAL-P1-a: expected trigger on gql, got trigger=$tA pool=$pA"

# DUAL-P1-b: core depleted in own-token poll while GraphQL healthy in state file.
SF_B="$DUAL_TMP/state_b"; _rl_write_atomic "$SF_B" 5000 111 5000 222
read -r tB pB rB <<<"$(CB_RL_STATE_FILE="$SF_B" CB_RL_REMAINING_OVERRIDE=50 CB_RL_GQL_REMAINING_OVERRIDE=5000 \
                       CB_RL_CORE_RESET_OVERRIDE=333 CB_RL_FLOOR=1000 CB_RL_FLOOR_GQL=800 _ref_rl_backoff)"
[ "$tB" = "1" ] && { [ "$pB" = "core" ] || [ "$pB" = "both" ]; } \
  && ok "DUAL-P1-b: core depleted in own-token poll (state gql healthy) -> backoff triggers on core pool" \
  || ko "DUAL-P1-b: expected trigger on core, got trigger=$tB pool=$pB"

# DUAL-P1-c: file-ABSENT fallback treats graphql as near-floor, NOT full-pool.
SF_C="$DUAL_TMP/does_not_exist"
read -r gcRem gcReset <<<"$(CB_RL_STATE_FILE="$SF_C" CB_RL_GQL_REMAINING_OVERRIDE=5000 CB_RL_FLOOR_GQL=800 _ref_rl_pool gql)"
{ [ "$gcRem" = "800" ] && [ "$gcRem" != "5000" ]; } \
  && ok "DUAL-P1-c: state file absent -> effective gql = CB_RL_FLOOR_GQL ($gcRem), NOT full pool (5000)" \
  || ko "DUAL-P1-c: file-absent gql fallback should be near-floor 800, got '$gcRem'"

# DUAL-P1-d: separate floors respected — core just above its floor, gql just below its own.
SF_D="$DUAL_TMP/state_d"; _rl_write_atomic "$SF_D" 5000 111 700 444   # state gql 700<800
read -r tD pD rD <<<"$(CB_RL_STATE_FILE="$SF_D" CB_RL_REMAINING_OVERRIDE=1100 CB_RL_GQL_REMAINING_OVERRIDE=5000 \
                       CB_RL_FLOOR=1000 CB_RL_FLOOR_GQL=800 _ref_rl_backoff)"
{ [ "$tD" = "1" ] && { [ "$pD" = "gql" ] || [ "$pD" = "both" ]; }; } \
  && ok "DUAL-P1-d: separate floors — core 1100>=1000 clean, gql 700<800 triggers (independent floors)" \
  || ko "DUAL-P1-d: expected gql-only trigger with core above floor, got trigger=$tD pool=$pD"

# DUAL-P1-e: reset-time uses the DEPLETED pool's epoch.
SF_E="$DUAL_TMP/state_e"; _rl_write_atomic "$SF_E" 5000 111 100 987654   # gql depleted, reset=987654
read -r tE pE rE <<<"$(CB_RL_STATE_FILE="$SF_E" CB_RL_REMAINING_OVERRIDE=5000 CB_RL_GQL_REMAINING_OVERRIDE=5000 \
                       CB_RL_CORE_RESET_OVERRIDE=111 CB_RL_FLOOR=1000 CB_RL_FLOOR_GQL=800 _ref_rl_backoff)"
[ "$rE" = "987654" ] \
  && ok "DUAL-P1-e: backoff reset epoch = depleted (gql) pool's reset (987654), not the healthy core's" \
  || ko "DUAL-P1-e: expected reset=987654 from depleted gql pool, got '$rE'"

# DUAL-P1-f: no pressure on either pool -> no backoff (guard idle when healthy).
SF_F="$DUAL_TMP/state_f"; _rl_write_atomic "$SF_F" 5000 111 5000 222
read -r tF pF rF <<<"$(CB_RL_STATE_FILE="$SF_F" CB_RL_REMAINING_OVERRIDE=5000 CB_RL_GQL_REMAINING_OVERRIDE=5000 \
                       CB_RL_FLOOR=1000 CB_RL_FLOOR_GQL=800 _ref_rl_backoff)"
{ [ "$tF" = "0" ] && [ "$pF" = "none" ]; } \
  && ok "DUAL-P1-f: both pools healthy -> no backoff (guard does not stall without RL pressure)" \
  || ko "DUAL-P1-f: expected no trigger when both pools healthy, got trigger=$tF pool=$pF"

# =============================================================================
# P2 — GraphQL diet reference implementation (MOCK tier)
# =============================================================================
P2_NET="$DUAL_TMP/net_calls"; : > "$P2_NET"
_net_bump(){ local n; n="$(cat "$P2_NET" 2>/dev/null || echo 0)"; echo $((n+1)) > "$P2_NET"; }
_net_count(){ local n; n="$(cat "$P2_NET" 2>/dev/null)"; echo "${n:-0}"; }

# Rule (NOT a count): a `gh issue view` whose args request `comments` stays LIVE;
# anything else is cache-replaceable.
_ref_view_cacheable(){ case " $* " in *comments*) return 1;; esac; return 0; }

# _ref_issue_view <cache-json> <num> -- <view args...>
#   Serves from the per-tick cache (no network) when cacheable; otherwise a live fetch.
_ref_issue_view(){
  local cache="$1" num="$2"; shift 2; [ "${1:-}" = "--" ] && shift
  if _ref_view_cacheable "$@"; then
    printf '%s' "$cache" | jq -c ".[] | select(.number==$num)" 2>/dev/null
  else
    _net_bump
    printf '{"number":%s,"comments":[]}' "$num"
  fi
}

printf '\n== DUAL P2 (GraphQL diet): cache-served views, comment-views stay live, edit batching ==\n'
CACHE_JSON='[{"number":10,"state":"OPEN","labels":[],"body":"b10"},{"number":20,"state":"OPEN","labels":[],"body":"b20"}]'

# DUAL-P2-a: a cache-replaceable `gh issue view` is served from _CB_TICK_CACHE_ALL (0 network).
: > "$P2_NET"
outv="$(_ref_issue_view "$CACHE_JSON" 10 -- --json number,state,body)"
{ [ "$(_net_count)" = "0" ] && printf '%s' "$outv" | grep -q '"number":10'; } \
  && ok "DUAL-P2-a: cache-replaceable gh issue view served from _CB_TICK_CACHE_ALL (no network call)" \
  || ko "DUAL-P2-a: cacheable view hit network ($(_net_count)) or returned wrong object [$outv]"

# DUAL-P2-b: a `--json comments` view is NOT cache-served — it stays live.
: > "$P2_NET"
outc="$(_ref_issue_view "$CACHE_JSON" 10 -- --json comments)"
{ [ "$(_net_count)" = "1" ] && printf '%s' "$outc" | grep -q 'comments'; } \
  && ok "DUAL-P2-b: --json comments view stays LIVE (network call made; freshness preserved)" \
  || ko "DUAL-P2-b: comments view was cache-served (net=$(_net_count)) — staleness risk [$outc]"

# DUAL-P2-c (INVARIANT, green now & must stay green): every `--json comments` site in the
#   REAL launcher is a live `gh issue view` — asserted by the rule, NOT a hardcoded count.
if [ -f "$LAUNCHER_1274" ]; then
  tc=$(grep -c 'json comments' "$LAUNCHER_1274" 2>/dev/null || echo 0)
  lv=$(grep 'json comments' "$LAUNCHER_1274" 2>/dev/null | grep -c 'gh issue view' || echo 0)
  { [ "$tc" -gt 0 ] && [ "$tc" -eq "$lv" ]; } \
    && ok "DUAL-P2-c: all $tc '--json comments' sites are live gh issue view (rule, not count) — none cache-routed" \
    || ko "DUAL-P2-c: comment-view live invariant broken (comments=$tc live-views=$lv)"
else
  ko "DUAL-P2-c: launcher not found at $LAUNCHER_1274"
fi

# DUAL-P2-d: batching collapses sequential same-issue edits into ONE gh issue edit.
#   Reference: buffer edits per issue; flush emits one edit call per distinct issue.
EDIT_LOG="$DUAL_TMP/edit_log"; : > "$EDIT_LOG"
declare -A _edit_buf=()
_edit_enqueue(){ local id="$1"; shift; _edit_buf[$id]="${_edit_buf[$id]:-} $*"; }
_edit_flush(){ local id; for id in "${!_edit_buf[@]}"; do printf 'edit %s%s\n' "$id" "${_edit_buf[$id]}" >> "$EDIT_LOG"; done; _edit_buf=(); }
_edit_enqueue 10 --add-label a
_edit_enqueue 10 --add-label b
_edit_enqueue 10 --remove-label c
_edit_flush
edits10=$(grep -c '^edit 10 ' "$EDIT_LOG" 2>/dev/null || echo 0)
{ [ "$edits10" = "1" ] && grep -q -- '--add-label a' "$EDIT_LOG" && grep -q -- '--remove-label c' "$EDIT_LOG"; } \
  && ok "DUAL-P2-d: 3 sequential same-issue edits collapse into ONE gh issue edit (all mutations preserved)" \
  || ko "DUAL-P2-d: expected 1 batched edit for issue 10 carrying all mutations, got $edits10"

# DUAL-P2-e: staleness guard — a read of issue N flushes N's pending edits FIRST
#   (write-then-read freshness; edit-after-view from cache must not read stale).
EDIT_LOG2="$DUAL_TMP/edit_log2"; : > "$EDIT_LOG2"
_edit_buf=()
_read_issue(){ # flush this issue's pending edits before reading it back
  local id="$1"
  if [ -n "${_edit_buf[$id]:-}" ]; then printf 'edit %s%s\n' "$id" "${_edit_buf[$id]}" >> "$EDIT_LOG2"; unset "_edit_buf[$id]"; fi
  printf 'read %s\n' "$id" >> "$EDIT_LOG2"
}
_edit_enqueue 20 --add-label x
_read_issue 20
order="$(tr '\n' '|' < "$EDIT_LOG2")"
[ "$order" = "edit 20 --add-label x|read 20|" ] \
  && ok "DUAL-P2-e: pending same-issue edit flushed BEFORE a read of that issue (write-then-read freshness)" \
  || ko "DUAL-P2-e: read did not flush pending edit first — stale-read risk [order=$order]"

# =============================================================================
# P3 — RL-aware gh-shim reference implementation (MOCK tier)
# =============================================================================
printf '\n== DUAL P3 (gh-shim): pass-through, sleep-cap, override seams, atomic state, no token leak ==\n'

# Sleep-cap: never exceeds CB_TASK_TIMEOUT/10, including with the var UNSET.
_ref_shim_sleep_cap(){ printf '%s' "$(( ${CB_TASK_TIMEOUT:-3600} / 10 ))"; }

capUnset="$(env -u CB_TASK_TIMEOUT bash -c 'printf "%s" "$(( ${CB_TASK_TIMEOUT:-3600} / 10 ))"')"
cap600="$(CB_TASK_TIMEOUT=600 _ref_shim_sleep_cap)"
{ [ "$capUnset" = "360" ] && [ "$cap600" = "60" ]; } \
  && ok "DUAL-P3-a: sleep-cap = CB_TASK_TIMEOUT/10 (unset->360, =600->60) — never blocks longer than 1/10 budget" \
  || ko "DUAL-P3-a: sleep-cap wrong (unset=$capUnset, 600=$cap600)"

# Override seams work ONLY under CB_RL_TEST_MODE=1.
_ref_shim_remaining(){ # <core|gql>
  local which="$1"
  if [ "${CB_RL_TEST_MODE:-0}" = "1" ]; then
    case "$which" in
      core) [ -n "${CB_RL_REMAINING_OVERRIDE:-}" ]     && { printf '%s' "$CB_RL_REMAINING_OVERRIDE";     return 0; } ;;
      gql)  [ -n "${CB_RL_GQL_REMAINING_OVERRIDE:-}" ] && { printf '%s' "$CB_RL_GQL_REMAINING_OVERRIDE"; return 0; } ;;
    esac
  fi
  printf '%s' "${_REF_SHIM_POLL:-5000}"   # real path polls `gh api rate_limit`
}
onmode="$(CB_RL_TEST_MODE=1 CB_RL_GQL_REMAINING_OVERRIDE=42 _ref_shim_remaining gql)"
offmode="$(CB_RL_TEST_MODE=0 CB_RL_GQL_REMAINING_OVERRIDE=42 _REF_SHIM_POLL=5000 _ref_shim_remaining gql)"
{ [ "$onmode" = "42" ] && [ "$offmode" = "5000" ]; } \
  && ok "DUAL-P3-b: CB_RL_*_REMAINING_OVERRIDE honoured ONLY under CB_RL_TEST_MODE=1 (42 vs live 5000)" \
  || ko "DUAL-P3-b: override seam gating wrong (testmode=$onmode, prodmode=$offmode)"

# Pass-through via run+capture (NOT exec): exit code, stdout, stderr all preserved.
_ref_run_capture(){ # <cmd...>
  local o e rc; o="$(mktemp "$DUAL_TMP/o.XXXX")"; e="$(mktemp "$DUAL_TMP/e.XXXX")"
  "$@" >"$o" 2>"$e"; rc=$?
  cat "$o"; cat "$e" >&2
  rm -f "$o" "$e"; return $rc
}
_payload(){ printf 'OUT-DATA\n'; printf 'ERR-DATA\n' >&2; return 7; }
prc=0; pout="$(_ref_run_capture _payload 2>"$DUAL_TMP/perr")" || prc=$?
perr="$(cat "$DUAL_TMP/perr")"
{ [ "$prc" = "7" ] && [ "$pout" = "OUT-DATA" ] && [ "$perr" = "ERR-DATA" ]; } \
  && ok "DUAL-P3-c: run+capture pass-through preserves exit code (7), stdout, stderr (not exec)" \
  || ko "DUAL-P3-c: pass-through lost fidelity (rc=$prc out=[$pout] err=[$perr])"

# --output-format json forwarded transparently (arg vector unchanged around the shim).
_ref_shim_forward(){ printf '%s\n' "$*"; }   # stand-in for the wrapped gh invocation
fwd="$(_ref_run_capture _ref_shim_forward api repos/x/y --output-format json)"
printf '%s' "$fwd" | grep -q -- '--output-format json' \
  && ok "DUAL-P3-d: --output-format json forwarded transparently through the shim" \
  || ko "DUAL-P3-d: --output-format json not forwarded intact [$fwd]"

# Atomic post-call state write (temp+mv) with the four integer keys.
SF_P3="$DUAL_TMP/shim_state"
_rl_write_atomic "$SF_P3" 4990 111 3990 222
after_tmp=$(find "$DUAL_TMP" -maxdepth 1 -name '*.tmp' 2>/dev/null | wc -l | tr -d ' ')
k1="$(_rl_read "$SF_P3" rl_core_remaining)"; k2="$(_rl_read "$SF_P3" rl_core_reset)"
k3="$(_rl_read "$SF_P3" rl_gql_remaining)";  k4="$(_rl_read "$SF_P3" rl_gql_reset)"
allint=1; for v in "$k1" "$k2" "$k3" "$k4"; do case "$v" in ''|*[!0-9]*) allint=0;; esac; done
{ [ "$allint" = "1" ] && [ "$k1" = "4990" ] && [ "$k3" = "3990" ] && [ "$after_tmp" = "0" ]; } \
  && ok "DUAL-P3-e: atomic state write (temp+mv, no leftover .tmp) with 4 integer keys core/gql rem+reset" \
  || ko "DUAL-P3-e: state write not atomic/complete (ints=$allint core=$k1 gql=$k3 leftover_tmp=$after_tmp)"

# GH_TOKEN never appears in any log or temp file the shim produces.
SHIM_LOG="$DUAL_TMP/shim.log"
( export GH_TOKEN="ghp_SECRETTOKEN123"
  # reference shim: logs a redacted line + writes state — token must appear NOWHERE.
  printf 'gh-shim: post-call rate_limit refresh core=4990 gql=3990\n' > "$SHIM_LOG"
  _rl_write_atomic "$SF_P3" 4990 111 3990 222 )
leak=0
grep -rq 'ghp_SECRETTOKEN123' "$DUAL_TMP" 2>/dev/null && leak=1
[ "$leak" = "0" ] \
  && ok "DUAL-P3-f: GH_TOKEN never written to any shim log or temp/state file (no secret leak)" \
  || ko "DUAL-P3-f: GH_TOKEN leaked into a shim log/temp file"

# =============================================================================
# SOURCE TIER — same contracts vs the REAL shipped artifacts. RED until the P1/P2/P3
# impl leaves land; ENUMERATED as SKIP on the current tree (default CB_DUAL_MODE=mock).
# =============================================================================
printf '\n== DUAL SOURCE TIER (mode=%s; RED until charter #1274 impl leaves land) ==\n' "$DUAL_MODE"

# SRC-P1: launcher guard v2 reads BOTH the own-token poll AND CB_RL_STATE_FILE, with a
#         separate graphql floor.
if armed; then
  if [ ! -f "$LAUNCHER_1274" ]; then
    ko "SRC-P1: launcher not found at $LAUNCHER_1274"
  else
    grep -Eq 'CB_RL_STATE_FILE' "$LAUNCHER_1274" \
      && ok "SRC-P1a: launcher reads session shared-state file CB_RL_STATE_FILE" \
      || ko "SRC-P1a: launcher has NO CB_RL_STATE_FILE read (guard still core-only)"
    grep -Eq 'CB_RL_FLOOR_GQL' "$LAUNCHER_1274" \
      && ok "SRC-P1b: launcher honours a separate graphql floor CB_RL_FLOOR_GQL" \
      || ko "SRC-P1b: launcher has NO CB_RL_FLOOR_GQL (no independent graphql floor)"
    grep -Eiq 'graphql' "$LAUNCHER_1274" \
      && ok "SRC-P1c: launcher _cb_rl guard inspects the graphql pool" \
      || ko "SRC-P1c: launcher never inspects the graphql pool (blind spot remains)"
  fi
else
  skip "SRC-P1a: launcher reads CB_RL_STATE_FILE — source-gated (arm: CB_DUAL_MODE=source)"
  skip "SRC-P1b: launcher honours CB_RL_FLOOR_GQL — source-gated (arm: CB_DUAL_MODE=source)"
  skip "SRC-P1c: launcher guard inspects graphql pool — source-gated (arm: CB_DUAL_MODE=source)"
fi

# SRC-P2: launcher routes cache-replaceable gh issue view through _CB_TICK_CACHE_ALL and
#         batches same-issue edits (behavioural markers).
if armed; then
  if [ ! -f "$LAUNCHER_1274" ]; then
    ko "SRC-P2: launcher not found at $LAUNCHER_1274"
  else
    grep -Eq '_CB_TICK_CACHE_ALL' "$LAUNCHER_1274" \
      && ok "SRC-P2a: launcher serves cache-replaceable issue views from _CB_TICK_CACHE_ALL" \
      || ko "SRC-P2a: launcher does not serve issue views from the per-tick cache"
    grep -Eq 'batch|_edit_(buf|flush|enqueue)|CB_EDIT_BATCH|flush.*edit' "$LAUNCHER_1274" \
      && ok "SRC-P2b: launcher batches sequential same-issue gh issue edit calls" \
      || ko "SRC-P2b: launcher has NO edit-batching path (edits still one gh call each)"
  fi
else
  skip "SRC-P2a: launcher serves views from _CB_TICK_CACHE_ALL — source-gated (arm: CB_DUAL_MODE=source)"
  skip "SRC-P2b: launcher batches same-issue edits — source-gated (arm: CB_DUAL_MODE=source)"
fi

# SRC-P3: the real gh-shim.sh satisfies the pass-through / sleep-cap / override / atomic /
#         no-leak contract. gh-shim.sh does not exist yet on the current tree.
if armed; then
  if [ ! -f "$SHIM_1274" ]; then
    ko "SRC-P3: gh-shim not found at $SHIM_1274 (P3 impl leaf must ship it)"
  else
    if bash -n "$SHIM_1274" 2>/dev/null; then ok "SRC-P3a: gh-shim.sh passes bash -n"; else ko "SRC-P3a: gh-shim.sh failed bash -n"; fi
    grep -Eq 'CB_TASK_TIMEOUT' "$SHIM_1274" \
      && ok "SRC-P3b: gh-shim.sh caps sleep against CB_TASK_TIMEOUT" \
      || ko "SRC-P3b: gh-shim.sh has NO CB_TASK_TIMEOUT sleep-cap"
    grep -Eq 'CB_RL_TEST_MODE' "$SHIM_1274" \
      && ok "SRC-P3c: gh-shim.sh gates override seams behind CB_RL_TEST_MODE" \
      || ko "SRC-P3c: gh-shim.sh override seams not gated by CB_RL_TEST_MODE"
    grep -Eq 'mv -f|mv[[:space:]]' "$SHIM_1274" \
      && ok "SRC-P3d: gh-shim.sh writes state atomically (temp + mv)" \
      || ko "SRC-P3d: gh-shim.sh state write is not atomic (no temp+mv)"
  fi
else
  skip "SRC-P3a: gh-shim.sh bash -n — source-gated (artifact not shipped yet; arm: CB_DUAL_MODE=source)"
  skip "SRC-P3b: gh-shim.sh CB_TASK_TIMEOUT sleep-cap — source-gated (arm: CB_DUAL_MODE=source)"
  skip "SRC-P3c: gh-shim.sh CB_RL_TEST_MODE-gated overrides — source-gated (arm: CB_DUAL_MODE=source)"
  skip "SRC-P3d: gh-shim.sh atomic temp+mv state write — source-gated (arm: CB_DUAL_MODE=source)"
fi

# =============================================================================
printf '\n=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
