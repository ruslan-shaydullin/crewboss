#!/usr/bin/env bash
# 1181-tick-cache-latch.test.sh — charter #1181 regression tests for the
# tick-cache latch bug: per-tick board snapshot (_CB_TICK_CACHE_ALL) could
# latch on a poisoned "[]" when _cb_issue_fetch transiently returned empty,
# and the self-sustaining 304 dead-lock kept the poison in place indefinitely.
#
# Covers charter acceptance criterion 4:
#   4a) mock fetch→empty on tick → cache does NOT latch; next tick forces full
#       re-fetch (guard: skip _CB_TICK_CACHE_OK=1 and ETag update on empty result)
#   4b) mock 304 with alive non-empty cache → last non-empty snapshot is served,
#       not reset to []  (guard: 304 short-circuit is only taken when cache is valid)
#
# Authorship: qa-engineer leaf for charter #1181 (issue #1192).
# GREEN after impl fix (leaf/1181-fix-cache-latch) merges into charter/1181;
# RED before that fix on current code (EXCLUDED from per-leaf verify-merged so
# the qa leaf does not block its own gate — same precedent as 1109-verify-merged-rich-reason).
#
# Self-contained: shell-function overrides only; no live GitHub access.
#
# Run: bash reference/tests/1181-tick-cache-latch.test.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER="${LAUNCHER_OVERRIDE:-$HERE/../runtime/crewboss-launcher-gh.sh}"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

CBHOME="$ROOT/cbhome"
mkdir -p "$CBHOME"

# ── helper: _source_launcher_fns ──────────────────────────────────────────────
# Sources crewboss-launcher-gh.sh in the current shell to load its function
# definitions WITHOUT running cmd_once/cmd_run.  Technique:
#   1. Override the `exit` builtin with a no-op function so that the launcher's
#      `case "${1:-once}"` `*)` branch ("NOOP" arg) calls exit 64 → our
#      function returns 64 instead of terminating the shell, and execution
#      continues past the case statement to the script's EOF.
#   2. Set $1=NOOP so the case hits the `*` branch (no real command runs).
#   3. After sourcing, call `set +u` so that the test code can work with
#      unset variables freely (the launcher sets -uo pipefail, not -e).
# The launcher sets `set -uo pipefail` (no -e), so a non-zero return from the
# source command does not abort the shell, and the function definitions survive.
_source_launcher_fns(){
  # Define exit as a no-op function to intercept the case *) exit 64 call.
  # The function uses `return` which exits the function (not the shell).
  exit() { return "${1:-0}"; }

  # Set $1=NOOP so the case statement dispatches to the *) branch.
  set -- NOOP

  CB_REPO="test/repo"
  CB_HOME="$CBHOME"

  # Source the launcher; suppress stdout+stderr (case *) prints usage).
  # The launcher's set -uo pipefail is NOT set -e, so exit code 64 from the
  # source is NOT fatal (no automatic abort on non-zero exit).
  . "$LAUNCHER" >/dev/null 2>&1

  # Restore permissive mode after the launcher's set -uo pipefail.
  set +u
}

# ─────────────────────────────────────────────────────────────────────────────
# Test A — empty-fetch guard (criterion 4a)
#
# Simulates: _cb_issue_fetch returns empty (transient API failure).
# Expected (fixed behaviour):
#   _CB_TICK_CACHE_OK  stays unset   (guard: do not mark empty snapshot valid)
#   _CB_ISSUE_ETAG     stays "before" (guard: do not pin ETag to a bad fetch)
#   _CB_TICK_CACHE_ALL != "[]"        (guard: do not commit the poisoned value)
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Test A: empty-fetch guard (criterion 4a) ==="

_RES_A_CACHE_OK="$ROOT/a-cache-ok"
_RES_A_ETAG="$ROOT/a-etag"
_RES_A_CACHE_ALL="$ROOT/a-cache-all"

(
  _source_launcher_fns

  # Override gh so the conditional probe (gh api --include …) returns empty —
  # simulating a network failure or API outage at the probe level.
  gh() { return 0; }

  # Override _cb_issue_fetch to return empty string — the "transient API failure"
  # that triggers the latch bug in unfixed code.
  _cb_issue_fetch() { printf ''; }

  # Pre-prime ETag (must not be updated after an empty fetch).
  _CB_ISSUE_ETAG='"before"'
  # Ensure the cache is unpopulated (simulates a fresh / cold cache tick).
  _CB_TICK_CACHE_OK=""
  _CB_TICK_CACHE_ALL=""

  # Call the function under test.
  _cb_tick_cache_refresh >/dev/null 2>&1

  # Persist state to files for the outer shell to assert on.
  printf '%s' "${_CB_TICK_CACHE_OK:-}"  > "$_RES_A_CACHE_OK"
  printf '%s' "${_CB_ISSUE_ETAG:-}"     > "$_RES_A_ETAG"
  printf '%s' "${_CB_TICK_CACHE_ALL:-}" > "$_RES_A_CACHE_ALL"
) 2>/dev/null || true

_a_cache_ok="$(cat "$_RES_A_CACHE_OK" 2>/dev/null)"
_a_etag="$(cat "$_RES_A_ETAG" 2>/dev/null)"
_a_cache_all="$(cat "$_RES_A_CACHE_ALL" 2>/dev/null)"

# A1: _CB_TICK_CACHE_OK must NOT be set after an empty fetch.
[ -z "$_a_cache_ok" ] \
  && ok "A1: _CB_TICK_CACHE_OK is unset after empty fetch — guard prevented the latch" \
  || ko "A1: _CB_TICK_CACHE_OK='$_a_cache_ok' set after empty fetch — latch bug active (fix: skip _CB_TICK_CACHE_OK=1 when fetch is empty)"

# A2: _CB_ISSUE_ETAG must remain unchanged (was NOT updated to a bad value).
[ "$_a_etag" = '"before"' ] \
  && ok "A2: _CB_ISSUE_ETAG unchanged after empty fetch — ETag not pinned to bad fetch" \
  || ko "A2: _CB_ISSUE_ETAG='$_a_etag' changed after empty fetch (expected '\"before\"') — ETag pinned to poisoned fetch"

# A3: _CB_TICK_CACHE_ALL must NOT be the poisoned "[]" value.
[ "$_a_cache_all" != "[]" ] \
  && ok "A3: _CB_TICK_CACHE_ALL not set to poisoned '[]' after empty fetch" \
  || ko "A3: _CB_TICK_CACHE_ALL='[]' (poisoned) — empty result was committed as valid snapshot"

# ─────────────────────────────────────────────────────────────────────────────
# Test B — 304 early-return with live non-empty cache (criterion 4b)
#
# Simulates: conditional probe returns HTTP 304; a primed non-empty cache exists.
# Expected (already correct in current code AND in fixed code):
#   _CB_TICK_CACHE_ALL  == primed non-empty value (NOT reset to [])
#   _CB_TICK_CACHE_OK   still set (1)
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Test B: 304 early-return preserves non-empty cache (criterion 4b) ==="

PRIMED='[{"number":1,"state":"OPEN","labels":[],"body":""}]'
_RES_B_CACHE_OK="$ROOT/b-cache-ok"
_RES_B_CACHE_ALL="$ROOT/b-cache-all"

(
  _source_launcher_fns

  # Override gh so the conditional probe (gh api --include …) returns an HTTP
  # 304 response.  The function is called as an array: "${_cmd[@]}", so we
  # shadow the `gh` command entirely.
  gh() {
    printf 'HTTP/1.1 304 Not Modified\r\n'
    printf '\r\n'
    return 0
  }

  # Prime the cache: non-empty snapshot + valid ETag + OK flag.
  _CB_TICK_CACHE_ALL="$PRIMED"
  _CB_TICK_CACHE_OK=1
  _CB_ISSUE_ETAG='"etag-xyz"'

  # Call the function under test.
  _cb_tick_cache_refresh >/dev/null 2>&1

  # Persist state.
  printf '%s' "${_CB_TICK_CACHE_OK:-}"  > "$_RES_B_CACHE_OK"
  printf '%s' "${_CB_TICK_CACHE_ALL:-}" > "$_RES_B_CACHE_ALL"
) 2>/dev/null || true

_b_cache_ok="$(cat "$_RES_B_CACHE_OK" 2>/dev/null)"
_b_cache_all="$(cat "$_RES_B_CACHE_ALL" 2>/dev/null)"

# B1: _CB_TICK_CACHE_ALL must remain at the primed non-empty value.
[ "$_b_cache_all" = "$PRIMED" ] \
  && ok "B1: _CB_TICK_CACHE_ALL preserved (304 reused non-empty snapshot — not reset to [])" \
  || ko "B1: _CB_TICK_CACHE_ALL='$_b_cache_all' (expected primed value — 304 short-circuit did not preserve cache)"

# B2: _CB_TICK_CACHE_OK must remain set (cache is still valid).
[ -n "$_b_cache_ok" ] \
  && ok "B2: _CB_TICK_CACHE_OK still set after 304 with live non-empty cache" \
  || ko "B2: _CB_TICK_CACHE_OK cleared after 304 — cache marked invalid despite non-empty primed snapshot"

echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
