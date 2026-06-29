#!/usr/bin/env bash
# 969-bash-pagination.test.sh — regression guard for the #969 SHELL surface
# (proto/r6/board-gh.sh + reference/runtime/crewboss-launcher-gh.sh).
# Charter: #969 · qa-engineer leaf (MERGES FIRST, before any implementation).
#
# Guards the live-observed #969 defect #1: `gh issue list --paginate`.
#   `--paginate` is a NON-EXISTENT flag on `gh issue list` (it exists only on `gh api`).
#   The escape root cause was a subcommand-BLIND `gh` stub that accepted --paginate on
#   ANY subcommand and false-greened the broken code. This test drives a subcommand-AWARE
#   stub (tests/stub/gh) that rejects `gh issue list --paginate` exactly like real gh, while
#   still accepting `gh api --paginate`.
#
# Coverage (task #1018):
#   1. subcommand-aware stub unit (issue-list --paginate -> non-zero; api --paginate -> ok)
#   2. static regression: NEITHER board-gh NOR the launcher may carry `gh issue list ... --paginate`
#   3. PATH-stub drive: board launchable + launcher gh-fetch must be NON-EMPTY through the stub
#   4. live-gh branch: HARD-FAILS (not skips) when a GH token + CB_REPO are present
#
# Modes (self-provability — this leaf merges before any impl exists):
#   CB_969_MODE=fixture (default) — RED on bundled pre-fix fixtures, GREEN on bundled post-fix
#       fixtures. CB_969_FIXTURE=prefix selects the pre-fix set directly (-> non-zero).
#   CB_969_MODE=source — run the regression assertions against the REAL tree (impl leaves).
#
# ALLOW-class: stubbed gh via PATH; no real GitHub unless a live token is explicitly present.
set -uo pipefail

pass=0; fail=0
ok() { printf 'ok   %s\n' "$*"; pass=$((pass+1)); }
ko() { printf 'FAIL %s\n' "$*"; fail=$((fail+1)); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STUBDIR="$SCRIPT_DIR/stub"
FIX="$SCRIPT_DIR/fixtures/969"
BOARD_JSON="$FIX/board.json"

MODE="${CB_969_MODE:-fixture}"
SEL="${CB_969_FIXTURE:-postfix}"

# ── Prerequisites ──────────────────────────────────────────────────────────────
for cmd in jq python3; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    printf 'SKIP: %s not found\n' "$cmd"
    exit 0
  fi
done
[ -x "$STUBDIR/gh" ] || { printf 'FAIL: subcommand-aware stub missing/not exec: %s/gh\n' "$STUBDIR"; exit 1; }

# ── helpers ─────────────────────────────────────────────────────────────────────
# drive_board <board-gh.sh> [launchable.sh]  -> issue numbers via stub (stdout)
drive_board() {
  local board="$1" lsh="${2:-}"
  (
    export PATH="$STUBDIR:$PATH"
    export CB_REPO="test/repo969"
    export GH_FIXTURE="$BOARD_JSON"
    unset CB_MANIFEST
    [ -n "$lsh" ] && export CB_LAUNCHABLE="$lsh"
    bash "$board" launchable 2>/dev/null
  ) || true
}

# drive_fragment <launcher-fetch.sh>  -> issue numbers via stub (stdout)
drive_fragment() {
  local frag="$1"
  (
    export PATH="$STUBDIR:$PATH"
    export CB_REPO="test/repo969"
    export GH_FIXTURE="$BOARD_JSON"
    # shellcheck disable=SC1090
    . "$frag"
    lf_fetch_issues 2>/dev/null
  ) || true
}

# has_bad_paginate <file>  -> 0 (found) when a NON-COMMENT line invokes
#   `gh issue list ... --paginate`. Full-line comments are stripped first so that
#   doc/comment mentions (e.g. the real launcher's line-958 comment) never false-trip.
has_bad_paginate() {
  # NB: read the full stream into a var (no `grep -q`): under `set -o pipefail` a
  # downstream `grep -q` closing the pipe early SIGPIPEs the upstream grep on large
  # files (e.g. the ~2k-line launcher) and silently drops the match.
  local hits
  hits="$(grep -vE '^[[:space:]]*#' "$1" 2>/dev/null | grep -nE 'gh issue list.*--paginate' || true)"
  [ -n "$hits" ]
}

# run_regression_assertions <source|fixture-dir>
#   returns 0 when the target is CLEAN (post-fix), non-zero when the #969 regression is present.
#   Prints diagnostics only; does NOT touch the global pass/fail counters.
run_regression_assertions() {
  local target="$1"
  local board_sh launcher_file launchable_sh fragment have_fragment rc=0 out

  if [ "$target" = "source" ]; then
    board_sh="$REPO_ROOT/proto/r6/board-gh.sh"
    launcher_file="$REPO_ROOT/reference/runtime/crewboss-launcher-gh.sh"
    launchable_sh="$REPO_ROOT/proto/r6/launchable.sh"
    fragment=""
    have_fragment=0
  else
    # NB: fixture board adapter is named board-adapter.sh (NOT *board-gh.sh) so the
    # #993 smoke gate's `*board-gh.sh -> bash <s> launchable` adapter never discovers
    # and live-runs the deliberately-broken pre-fix fixture at this leaf's own merge.
    board_sh="$target/board-adapter.sh"
    launcher_file="$target/launcher-fetch.sh"
    launchable_sh=""
    fragment="$target/launcher-fetch.sh"
    have_fragment=1
  fi

  # (2a) static: board surface must NOT carry `gh issue list ... --paginate`
  if has_bad_paginate "$board_sh"; then
    echo "    [regress] board surface carries 'gh issue list --paginate': $board_sh"; rc=1
  fi
  # (2b) static: launcher surface must NOT carry `gh issue list ... --paginate`
  if has_bad_paginate "$launcher_file"; then
    echo "    [regress] launcher surface carries 'gh issue list --paginate': $launcher_file"; rc=1
  fi
  # (3a) stub-drive: board launchable must be non-empty through the subcommand-aware stub
  out="$(drive_board "$board_sh" "$launchable_sh")"
  if [ -z "$out" ]; then
    echo "    [regress] board launchable EMPTY through subcommand-aware stub: $board_sh"; rc=1
  fi
  # (3b) stub-drive: launcher gh-fetch must be non-empty (fixture fragments only)
  if [ "$have_fragment" = "1" ]; then
    out="$(drive_fragment "$fragment")"
    if [ -z "$out" ]; then
      echo "    [regress] launcher gh-fetch EMPTY through subcommand-aware stub: $fragment"; rc=1
    fi
  fi
  return $rc
}

# ── stub unit (always runs) ─────────────────────────────────────────────────────
echo "=== stub unit: subcommand-aware gh ==="
if ( export PATH="$STUBDIR:$PATH"; gh issue list -R x/y --state all --paginate >/dev/null 2>&1 ); then
  ko "stub ACCEPTED 'gh issue list --paginate' — subcommand-blind regression"
else
  ok "stub rejects 'gh issue list --paginate' (exit != 0, mirrors real gh)"
fi
if ( export PATH="$STUBDIR:$PATH"; gh api "repos/x/y/issues" --paginate >/dev/null 2>&1 ); then
  ok "stub accepts 'gh api --paginate' (valid surface — no false-red on the fix)"
else
  ko "stub rejected 'gh api --paginate' — would false-red the legitimate fix"
fi
# stub message must mirror real gh
msg="$( export PATH="$STUBDIR:$PATH"; gh issue list --paginate 2>&1 >/dev/null )"
case "$msg" in
  *"unknown flag: --paginate"*) ok "stub error message mirrors real gh ('unknown flag: --paginate')" ;;
  *) ko "stub error message does not mirror real gh: '$msg'" ;;
esac

# ── live-gh branch — HARD-FAIL (not skip) when token + CB_REPO present ───────────
# Dormant in fixture mode (offline self-proof); active only in source/live mode.
live_gh_gate() {
  local v val tok=""
  for v in GH_TOKEN GITHUB_TOKEN CB_API_TOKEN; do
    eval "val=\${$v:-}"
    if [ -n "${val:-}" ]; then tok=present; fi
  done
  val=""   # scrub — never echo a token value
  if [ -z "$tok" ] || [ -z "${CB_REPO:-}" ]; then
    echo "    [live] no GH token + CB_REPO in env — live gh branch not applicable"
    return 0
  fi
  if ! command -v gh >/dev/null 2>&1; then
    ko "LIVE: token + CB_REPO present but gh CLI absent — cannot gate (hard fail)"; return 1
  fi
  # HARD assertion against REAL gh: `gh issue list --paginate` must be rejected.
  if gh issue list -R "$CB_REPO" --state all --paginate -L 1 >/dev/null 2>&1; then
    ko "LIVE: real 'gh issue list --paginate' SUCCEEDED — #969 defect-1 guard is invalid"
  else
    ok "LIVE: real 'gh issue list --paginate' rejected (expected; #969 defect-1 confirmed live)"
  fi
}

# ── driver ───────────────────────────────────────────────────────────────────────
case "$MODE" in
  fixture)
    if [ "$SEL" = "prefix" ]; then
      echo "=== fixture mode: PRE-FIX fixtures (expected RED) ==="
      run_regression_assertions "$FIX/prefix"
      rc=$?
      if [ "$rc" -ne 0 ]; then
        echo "pre-fix fixtures are RED (regression detected) — exiting non-zero by design"
      else
        echo "pre-fix fixtures unexpectedly GREEN — guard is too weak"
      fi
      exit "$rc"
    fi
    echo "=== fixture mode: red-before-green self-proof ==="
    run_regression_assertions "$FIX/postfix"; post=$?
    run_regression_assertions "$FIX/prefix";  pre=$?
    [ "$post" -eq 0 ] && ok "post-fix fixtures GREEN (rc=0)" \
                      || ko "post-fix fixtures NOT green (rc=$post) — guard false-reds the fix"
    [ "$pre" -ne 0 ]  && ok "pre-fix fixtures RED (rc=$pre) — guard detects the #969 regression" \
                      || ko "pre-fix fixtures GREEN (rc=$pre) — guard is subcommand-blind/false-green"
    ;;
  source)
    echo "=== source mode: regression assertions against the REAL tree ==="
    run_regression_assertions "source"; rc=$?
    [ "$rc" -eq 0 ] && ok "real tree GREEN — no #969 shell-surface regression" \
                    || ko "real tree RED — #969 shell-surface regression present (see [regress] lines)"
    live_gh_gate
    ;;
  *)
    ko "unknown CB_969_MODE='$MODE' (want fixture|source)"
    ;;
esac

echo
printf '=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
