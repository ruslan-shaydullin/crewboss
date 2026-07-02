#!/usr/bin/env bash
# test-watchdog-stall.sh — charter #1142 regression tests for the forward-progress
# dead-man's-switch: `_stall_check()` in reference/runtime/crewboss-launcher-gh.sh.
#
# Background: on the night of 2026-06-30->07-01 the launcher loop stayed alive
# (heartbeat + keepalive ticking) but merged NOTHING for ~8h because the queue
# head was jammed — and nothing alerted. `_stall_check()` closes that gap by
# alerting on lack of *forward progress* (merges), not just liveness.
#
# This is the qa-engineer leaf (issue #1275). It OWNS all test files for the
# charter and merges FIRST; the implementation leaf (which adds `_stall_check()`
# and the CB_PROGRESS_STALL_HOURS / CB_STALL_NTFY_URL env vars) depends on it.
# Therefore the positive scenarios below are EXPECTED TO FAIL until the impl
# leaf lands — this is test-first, by design.
#
# Contract exercised (from the approved, code-grounded analysis intent):
#   1. Merge detection: gh pr list --state merged --base main --json
#      number,headRefName ; filter headRefName matching charter/* ; track the
#      most-recently-seen merged PR number in $CB_HOME/run/last-stall-pr ; on a
#      new merge write `date +%s` to $CB_HOME/run/last-merge-ts and delete
#      $CB_HOME/run/stall-alert-issue (stall-clear). Covers BOTH human-merge and
#      CB_AUTO_MERGE paths (same gh query).
#   2. Elapsed check: baseline = cat $CB_HOME/run/last-merge-ts || date +%s
#      (NO start-ts file exists in the runtime — fallback to current epoch
#      prevents cold-start false alerts). Not stalled if
#      now - baseline < CB_PROGRESS_STALL_HOURS*3600.
#   3. Launchable-work predicate: `board launchable` / `plannable_scoped`
#      non-empty (mirrors _loop_is_alive). Both empty -> idle, no alert.
#   4. Dedup: if $CB_HOME/run/stall-alert-issue exists & non-empty -> no-op.
#   5. Label guard: idempotently ensure the ops:alert label exists (gh, tolerant
#      of already-exists) before the first alert issue is opened.
#   6. Alert: open a GitHub issue (gh) labelled ops:alert, title including
#      elapsed hours; write the issue number to the dedup file.
#   7. Push notification: [ -n "$CB_STALL_NTFY_URL" ] && curl -s -d ... "$URL"
#      || true — degrades gracefully when unset.
#
# Self-contained: shell-function overrides only; no live GitHub / network access.
# Run: bash reference/tests/test-watchdog-stall.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER="${LAUNCHER_OVERRIDE:-$HERE/../runtime/crewboss-launcher-gh.sh}"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

# ── _source_launcher_fns ──────────────────────────────────────────────────────
# Sources crewboss-launcher-gh.sh in the current (sub)shell to load its function
# definitions WITHOUT running cmd_once/cmd_run. Technique borrowed verbatim from
# 1181-tick-cache-latch.test.sh:
#   1. Override the `exit` builtin with a `return` shim so the launcher's
#      `case "${1:-once}"` `*)` branch (usage -> exit 64) returns instead of
#      terminating the shell; execution continues to EOF, all fns defined.
#   2. Set $1=NOOP so dispatch hits the `*)` branch (no real command runs).
#   3. `set +u` afterwards so test code can touch unset vars freely.
# Reads the GLOBAL $CBHOME (set per-scenario before this is called) so that the
# launcher pins RUN="$CB_HOME/run" to the scenario's temp home.
_source_launcher_fns(){
  exit() { return "${1:-0}"; }
  set -- NOOP
  CB_REPO="test/repo"
  CB_HOME="$CBHOME"
  . "$LAUNCHER" >/dev/null 2>&1
  set +u
}

# ── install_stubs ─────────────────────────────────────────────────────────────
# Defines gh / board / plannable_scoped / curl AS the scenario needs. Called
# AFTER _source_launcher_fns inside each subshell so these override the launcher's
# own board()/plannable_scoped() definitions. All behaviour is data-driven via
# files under $CBHOME so the same stubs serve every scenario:
#   $GH_MERGED_JSON   — JSON array returned by `gh pr list --state merged ...`
#   $BOARD_LAUNCHABLE — lines returned by `board launchable`
#   $BOARD_PLANNABLE  — lines returned by `plannable_scoped`
#   $GH_LOG           — append-log of every gh mutation (asserted on)
#   $CURL_LOG         — append-log of every curl call (asserted on)
#   $GH_ISSUE_SEQ     — monotonic issue-number source for `gh issue create`
install_stubs(){
  gh() {
    local obj="${1:-}" verb="${2:-}"
    case "$obj $verb" in
      "pr list")
        # Merge detection query: --state merged --base main --json number,headRefName
        cat "$GH_MERGED_JSON" 2>/dev/null || printf '[]\n'
        ;;
      "label create")
        # Label guard (idempotent): tolerate already-exists like the real impl.
        printf 'label create %s\n' "$*" >> "$GH_LOG"
        return 0
        ;;
      "issue create")
        # Alert path. Log the full arg vector (captures --label ops:alert and the
        # elapsed-hours title) and emit an issue URL on stdout, exactly as the
        # real `gh issue create` does, so the impl can parse the number from it.
        local n
        n=$(( $(cat "$GH_ISSUE_SEQ" 2>/dev/null || printf 900) + 1 ))
        printf '%s' "$n" > "$GH_ISSUE_SEQ"
        printf 'issue create %s\n' "$*" >> "$GH_LOG"
        printf 'https://github.com/%s/issues/%s\n' "${CB_REPO:-test/repo}" "$n"
        return 0
        ;;
      *)
        printf 'gh-unhandled %s %s %s\n' "$obj" "$verb" "$*" >> "$GH_LOG"
        return 0
        ;;
    esac
  }
  board() {
    case "${1:-}" in
      launchable) cat "$BOARD_LAUNCHABLE" 2>/dev/null || true ;;
      *) : ;;
    esac
  }
  plannable_scoped() { cat "$BOARD_PLANNABLE" 2>/dev/null || true; }
  curl() { printf 'curl %s\n' "$*" >> "$CURL_LOG"; return 0; }
}

# ── new_scenario <name> ────────────────────────────────────────────────────────
# Fresh, isolated $CBHOME + reset data/log files for one scenario.
new_scenario(){
  CBHOME="$ROOT/$1"
  rm -rf "$CBHOME"; mkdir -p "$CBHOME/run"
  GH_LOG="$CBHOME/gh.log";          : > "$GH_LOG"
  CURL_LOG="$CBHOME/curl.log";      : > "$CURL_LOG"
  GH_ISSUE_SEQ="$CBHOME/issue.seq"
  GH_MERGED_JSON="$CBHOME/merged.json";  printf '[]\n' > "$GH_MERGED_JSON"
  BOARD_LAUNCHABLE="$CBHOME/launchable"; : > "$BOARD_LAUNCHABLE"
  BOARD_PLANNABLE="$CBHOME/plannable";   : > "$BOARD_PLANNABLE"
  export CBHOME GH_LOG CURL_LOG GH_ISSUE_SEQ GH_MERGED_JSON BOARD_LAUNCHABLE BOARD_PLANNABLE
}

NOW="$(date +%s)"
OLD_TS=$(( NOW - 3*3600 ))   # 3h ago — past the default 2h stall threshold
issue_creates(){ local c; c="$(grep -c "issue create" "$GH_LOG" 2>/dev/null || true)"; printf '%s' "${c:-0}"; }
dedup_file(){ printf '%s' "$CBHOME/run/stall-alert-issue"; }

# =============================================================================
# Scenario 1 — Stalled + work present -> alert opened (once), deduped, ntfy fired
# =============================================================================
# last-merge-ts is 3h old, `board launchable` non-empty, no merges since. First
# tick MUST: ensure the ops:alert label, open ONE ops:alert issue, write the
# dedup file, and (ntfy URL set) fire a push alert. Second tick MUST be a no-op
# (dedup) — no second issue.
echo "=== Scenario 1: stalled + work present -> dedup'd ops:alert issue + push ==="
new_scenario s1
printf '%s' "$OLD_TS" > "$CBHOME/run/last-merge-ts"
printf '1275\n'       > "$BOARD_LAUNCHABLE"
(
  _source_launcher_fns
  install_stubs
  export CB_PROGRESS_STALL_HOURS=2
  export CB_STALL_NTFY_URL="https://ntfy.example/crewboss"
  _stall_check   # tick 1
  _stall_check   # tick 2 (must dedup)
) >/dev/null 2>&1 || true

n1="$(issue_creates)"
[ "$n1" -ge 1 ] \
  && ok "S1: an ops:alert issue was opened on the stalled tick" \
  || ko "S1: no issue opened despite stall (>=2h, work present) — _stall_check missing/broken"
grep -q "ops:alert" "$GH_LOG" \
  && ok "S1: the alert issue carries the ops:alert label" \
  || ko "S1: alert issue not labelled ops:alert"
[ -s "$(dedup_file)" ] \
  && ok "S1: dedup file run/stall-alert-issue written with the issue number" \
  || ko "S1: dedup file not written — subsequent ticks will spam"
[ "$n1" -eq 1 ] \
  && ok "S1: second tick did NOT open a second issue (dedup honoured)" \
  || ko "S1: dedup failed — $n1 issues opened across two ticks (expected exactly 1)"
[ -s "$CURL_LOG" ] \
  && ok "S1: push alert fired via curl (CB_STALL_NTFY_URL set)" \
  || ko "S1: no curl push alert although CB_STALL_NTFY_URL was set"

# =============================================================================
# Scenario 2 — Idle (nothing to do) -> NO alert
# =============================================================================
# last-merge-ts old, but BOTH board launchable and plannable_scoped are empty.
# "idle: nothing to do" must be distinguished from "stalled: work exists but 0
# progress" — idle gets NO alert.
echo "=== Scenario 2: idle (no launchable/plannable work) -> no alert ==="
new_scenario s2
printf '%s' "$OLD_TS" > "$CBHOME/run/last-merge-ts"
: > "$BOARD_LAUNCHABLE"   # empty
: > "$BOARD_PLANNABLE"    # empty
(
  _source_launcher_fns
  install_stubs
  export CB_PROGRESS_STALL_HOURS=2
  export CB_STALL_NTFY_URL="https://ntfy.example/crewboss"
  _stall_check
) >/dev/null 2>&1 || true

[ "$(issue_creates)" -eq 0 ] \
  && ok "S2: no issue opened when idle (no work) — idle != stalled" \
  || ko "S2: issue opened while idle — idle/stalled distinction broken"
[ ! -s "$(dedup_file)" ] \
  && ok "S2: no dedup file written when idle" \
  || ko "S2: dedup file written while idle (no alert should have occurred)"

# =============================================================================
# Scenario 3 — Active (recent merge) + work present -> NO alert
# =============================================================================
# last-merge-ts is NOW (progress just happened); work exists. Elapsed < threshold
# -> not stalled -> no alert.
echo "=== Scenario 3: active (recent last-merge-ts) -> no alert ==="
new_scenario s3
printf '%s' "$NOW" > "$CBHOME/run/last-merge-ts"
printf '1275\n'    > "$BOARD_LAUNCHABLE"
(
  _source_launcher_fns
  install_stubs
  export CB_PROGRESS_STALL_HOURS=2
  export CB_STALL_NTFY_URL="https://ntfy.example/crewboss"
  _stall_check
) >/dev/null 2>&1 || true

[ "$(issue_creates)" -eq 0 ] \
  && ok "S3: no issue opened when merge is recent (elapsed < threshold)" \
  || ko "S3: issue opened despite recent forward progress — elapsed check broken"

# =============================================================================
# Scenario 4 — Stall clears on human merge -> dedup removed -> fresh stall re-alerts
# =============================================================================
# (a) Stall -> alert + dedup file. (b) A NEW charter/* PR appears in the merged
# list (a human merged it): _stall_check must refresh last-merge-ts and DELETE
# the dedup file (stall-clear). (c) Force stall again (old ts, no new merge):
# a FRESH ops:alert issue must open.
echo "=== Scenario 4: stall clears on human merge -> fresh stall opens a new issue ==="
new_scenario s4
printf '%s' "$OLD_TS" > "$CBHOME/run/last-merge-ts"
printf '100'          > "$CBHOME/run/last-stall-pr"   # last-seen merged PR
printf '1275\n'       > "$BOARD_LAUNCHABLE"

# (a) initial stall
(
  _source_launcher_fns; install_stubs
  export CB_PROGRESS_STALL_HOURS=2 CB_STALL_NTFY_URL=""
  _stall_check
) >/dev/null 2>&1 || true
s4_first="$(issue_creates)"

# (b) human merges a new charter/* PR -> appears in the merged list
printf '[{"number":500,"headRefName":"charter/1142","baseRefName":"main"}]\n' > "$GH_MERGED_JSON"
(
  _source_launcher_fns; install_stubs
  export CB_PROGRESS_STALL_HOURS=2 CB_STALL_NTFY_URL=""
  _stall_check
) >/dev/null 2>&1 || true

dedup_cleared=1
[ -s "$(dedup_file)" ] && dedup_cleared=0
[ "$dedup_cleared" -eq 1 ] \
  && ok "S4: dedup file removed after a new charter/* merge was detected (stall-clear)" \
  || ko "S4: dedup file NOT removed on merge — stall would stay silently latched"

# (c) stall again with no further merges -> fresh alert
printf '%s' "$OLD_TS" > "$CBHOME/run/last-merge-ts"   # force stale again
printf '500'          > "$CBHOME/run/last-stall-pr"   # PR 500 now already seen
(
  _source_launcher_fns; install_stubs
  export CB_PROGRESS_STALL_HOURS=2 CB_STALL_NTFY_URL=""
  _stall_check
) >/dev/null 2>&1 || true
s4_after="$(issue_creates)"

[ "$s4_after" -gt "$s4_first" ] \
  && ok "S4: a fresh ops:alert issue opened after the cleared stall re-stalled" \
  || ko "S4: no fresh issue after re-stall — clear+re-alert cycle broken"

# =============================================================================
# Scenario 5 — Stall clears on auto-merge (CB_AUTO_MERGE) -> same detection path
# =============================================================================
# CB_AUTO_MERGE and a human merge are INDISTINGUISHABLE to _stall_check: both
# land as merged PRs surfaced by `gh pr list --state merged --base main`. This
# scenario asserts the equivalence with Scenario 4 by driving the identical
# clear via an auto-merged charter/* PR.
echo "=== Scenario 5: stall clears on auto-merge (same gh detection path as S4) ==="
new_scenario s5
printf '%s' "$OLD_TS" > "$CBHOME/run/last-merge-ts"
printf '200'          > "$CBHOME/run/last-stall-pr"
printf '1275\n'       > "$BOARD_LAUNCHABLE"

# initial stall -> alert + dedup
(
  _source_launcher_fns; install_stubs
  export CB_PROGRESS_STALL_HOURS=2 CB_STALL_NTFY_URL=""
  _stall_check
) >/dev/null 2>&1 || true

# CB_AUTO_MERGE merged a new charter/* PR — surfaced by the SAME merged query
printf '[{"number":777,"headRefName":"charter/1142","baseRefName":"main"}]\n' > "$GH_MERGED_JSON"
ts_before="$(cat "$CBHOME/run/last-merge-ts" 2>/dev/null || printf 0)"
(
  _source_launcher_fns; install_stubs
  export CB_PROGRESS_STALL_HOURS=2 CB_STALL_NTFY_URL=""
  _stall_check
) >/dev/null 2>&1 || true
ts_after="$(cat "$CBHOME/run/last-merge-ts" 2>/dev/null || printf 0)"

[ ! -s "$(dedup_file)" ] \
  && ok "S5: auto-merge cleared the dedup file (equivalent to human-merge in S4)" \
  || ko "S5: auto-merge did not clear the dedup file — detection path not source-agnostic"
[ "$ts_after" -gt "$ts_before" ] \
  && ok "S5: last-merge-ts refreshed by the auto-merged charter/* PR" \
  || ko "S5: last-merge-ts not refreshed on auto-merge — merge detection missed the PR"

# =============================================================================
# Scenario 6 — No ntfy URL set -> NO curl attempted, but the issue still opens
# =============================================================================
# CB_STALL_NTFY_URL empty/unset. The push notification must degrade gracefully
# (no curl), yet the ops:alert issue still opens on a genuine stall.
echo "=== Scenario 6: CB_STALL_NTFY_URL unset -> no curl, issue still opened ==="
new_scenario s6
printf '%s' "$OLD_TS" > "$CBHOME/run/last-merge-ts"
printf '1275\n'       > "$BOARD_LAUNCHABLE"
(
  _source_launcher_fns
  install_stubs
  export CB_PROGRESS_STALL_HOURS=2
  unset CB_STALL_NTFY_URL
  _stall_check
) >/dev/null 2>&1 || true

[ "$(issue_creates)" -ge 1 ] \
  && ok "S6: ops:alert issue opened even with no ntfy URL configured" \
  || ko "S6: no issue opened when ntfy URL unset — alert must not depend on ntfy"
[ ! -s "$CURL_LOG" ] \
  && ok "S6: no curl call attempted when CB_STALL_NTFY_URL is unset (graceful)" \
  || ko "S6: curl was called despite unset CB_STALL_NTFY_URL — not degrading gracefully"

# =============================================================================
# Scenario 7 — Cold start (no last-merge-ts, no start-ts) -> NO immediate alert
# =============================================================================
# There is NO last-merge-ts file and (by design) NO start-ts file in the runtime.
# Baseline must fall back to `date +%s` (current epoch) -> elapsed ~ 0 -> NOT
# stalled -> no alert, even with launchable work present. Prevents cold-start
# false alarms right after a fresh boot.
echo "=== Scenario 7: cold start (no last-merge-ts) -> baseline=now -> no false alert ==="
new_scenario s7
# deliberately DO NOT create run/last-merge-ts
printf '1275\n' > "$BOARD_LAUNCHABLE"
(
  _source_launcher_fns
  install_stubs
  export CB_PROGRESS_STALL_HOURS=2
  export CB_STALL_NTFY_URL="https://ntfy.example/crewboss"
  _stall_check
) >/dev/null 2>&1 || true

[ "$(issue_creates)" -eq 0 ] \
  && ok "S7: no alert on cold start (baseline falls back to now -> elapsed ~0)" \
  || ko "S7: false alert on cold start — baseline did not fall back to current epoch"
[ ! -s "$(dedup_file)" ] \
  && ok "S7: no dedup file written on cold start" \
  || ko "S7: dedup file written on cold start — false alert path taken"

# =============================================================================
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
