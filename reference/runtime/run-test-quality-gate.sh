#!/usr/bin/env bash
# run-test-quality-gate.sh — 3-stage test-quality gate (charter #597)
#
# Fires after BOTH the qa-engineer AND impl leaves have merged into the charter
# branch tree. SCOPED execution only (bootstrap caveat #193) — called by the
# launcher's _tqg_cycle, which only runs when CREWBOSS_CHARTER is set.
#
# Routing signals (applied via gh issue edit):
#   status:test-broken  — the test itself is broken (fails anti-pattern lint,
#                         fails on known-correct code, or is flaky); the
#                         qa-engineer leaf is re-dispatched for rework.
#   status:impl-broken  — the implementation is broken (test is sound but fails
#                         against the actual impl); the executor leaf is
#                         re-dispatched for rework.
#
# No other signal forms are valid. The exact label names above MUST be used.
# Re-dispatch: gate applies the diagnostic label + reopens the leaf issue +
# adds status:needs-rework; the launcher's existing rework path handles dispatch.
#
# Usage:
#   run-test-quality-gate.sh --charter CID --qa-leaf QID --impl-leaf IID
#                             [--repo OWNER/REPO] [--repo-dir DIR]
#
# --charter  CID       GitHub issue number of the charter
# --qa-leaf  QID       GitHub issue number of the qa-engineer leaf
# --impl-leaf IID      GitHub issue number of the executor/impl leaf
# --repo     OWNER/REPO  defaults to CB_REPO env (ruslan-shaydullin/crewboss)
# --repo-dir DIR       local path to charter branch tree (for lint + harness);
#                      omit to skip Stage 1 lint and Stage 3 harness execution
#
# Exit codes:
#   0 — gate green; caller (launcher _tqg_cycle) should record tqg:done state
#   1 — gate routed: status:test-broken or status:impl-broken applied to leaf
#   2 — infra error: missing required args, cannot determine routing

set -uo pipefail

REPO="${CB_REPO:-ruslan-shaydullin/crewboss}"
CHARTER_ID=""
QA_LEAF=""
IMPL_LEAF=""
REPO_DIR=""

# ── Argument parsing ────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --charter)   CHARTER_ID="$2"; shift 2 ;;
    --qa-leaf)   QA_LEAF="$2";    shift 2 ;;
    --impl-leaf) IMPL_LEAF="$2";  shift 2 ;;
    --repo)      REPO="$2";       shift 2 ;;
    --repo-dir)  REPO_DIR="$2";   shift 2 ;;
    *) echo "run-test-quality-gate: unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "$CHARTER_ID" ] || { echo "run-test-quality-gate: --charter required" >&2; exit 2; }
[ -n "$QA_LEAF" ]    || { echo "run-test-quality-gate: --qa-leaf required"  >&2; exit 2; }
[ -n "$IMPL_LEAF" ]  || { echo "run-test-quality-gate: --impl-leaf required" >&2; exit 2; }

_route_test_broken() {
  local reason="$1"
  echo "tqg: status:test-broken (charter #${CHARTER_ID} qa-leaf #${QA_LEAF}): ${reason}" >&2
  gh issue edit   "$QA_LEAF" -R "$REPO" --add-label    "status:test-broken"  >/dev/null 2>&1 || true
  gh issue reopen "$QA_LEAF" -R "$REPO"                                       >/dev/null 2>&1 || true
  gh issue edit   "$QA_LEAF" -R "$REPO" --add-label    "status:needs-rework"  >/dev/null 2>&1 || true
}

_route_impl_broken() {
  local reason="$1"
  echo "tqg: status:impl-broken (charter #${CHARTER_ID} impl-leaf #${IMPL_LEAF}): ${reason}" >&2
  gh issue edit   "$IMPL_LEAF" -R "$REPO" --add-label    "status:impl-broken"  >/dev/null 2>&1 || true
  gh issue reopen "$IMPL_LEAF" -R "$REPO"                                       >/dev/null 2>&1 || true
  gh issue edit   "$IMPL_LEAF" -R "$REPO" --add-label    "status:needs-rework"  >/dev/null 2>&1 || true
}

# ── Stage 1: Anti-pattern lint ──────────────────────────────────────────────
# Scan test files in the charter tree for patterns known to cause false failures.
# Lint checks are derived from the near-miss on #522 (charter #597 motivation).
if [ -n "$REPO_DIR" ] && [ -d "$REPO_DIR/reference/tests" ]; then
  _lint_reason=""
  while IFS= read -r -d '' _tf; do
    # Anti-pattern A: grep -c ... || echo 0
    #   grep -c returns exit 1 when there are no matches; the || catches the
    #   non-zero exit but the resulting "0" is then compared arithmetically in
    #   the wrong context (integer vs string), silently yielding wrong verdicts.
    if grep -qE 'grep -c .* \|\| echo 0' "$_tf" 2>/dev/null; then
      _lint_reason="grep -c ... || echo 0 in $(basename "$_tf") (use || true; count=$(...) pattern)"
      break
    fi
    # Anti-pattern B: BIN used in PATH but not exported
    #   Background subshells inherit exported vars only; if BIN is set but not
    #   exported before PATH is built from it, stubs silently disappear from
    #   child processes — see #522 near-miss (BIN not exported → stub failed).
    if grep -qE 'PATH=.*\$BIN' "$_tf" 2>/dev/null && \
       ! grep -qE 'export BIN|export.*BIN' "$_tf" 2>/dev/null; then
      _lint_reason="PATH uses \$BIN but BIN not exported in $(basename "$_tf")"
      break
    fi
  done < <(find "$REPO_DIR/reference/tests" -name "*.test.sh" -print0 2>/dev/null)

  if [ -n "$_lint_reason" ]; then
    _route_test_broken "lint: $_lint_reason"
    exit 1
  fi
fi

# ── Stage 2: Harness sanity (run test in isolation against current tree) ────
# If the test fails when run against the charter tree (impl present), we must
# determine whether the test or the impl is at fault.
# Heuristic: if Stage 1 lint is clean AND the test fails → impl is broken.
# If lint had warnings AND the test fails → test is broken.
# Stage 2 executes the harness; Stage 3 applies the routing decision.
_stage2_rc=0
if [ -n "$REPO_DIR" ] && [ -d "$REPO_DIR/reference/tests" ]; then
  # Find test files associated with this charter's qa-engineer leaf.
  # Convention: qa-engineer tests are in reference/tests/ with a filename
  # that references the charter number (e.g. tqg-<CID>.test.sh) OR they are
  # identifiable via the CREWBOSS_CHARTER env var.  For portability the entire
  # ALLOW-classified suite is run here; the qa-engineer's test is part of it.
  _plm="$REPO_DIR/reference/runtime/per-leaf-manifest"
  if [ -f "$_plm" ]; then
    ( cd "$REPO_DIR"
      shopt -s nullglob
      _fail=0
      for _t in reference/tests/*.test.sh; do
        _base="$(basename "$_t" .test.sh)"
        grep -qE "^ALLOW[[:space:]]+${_base}$" "$_plm" 2>/dev/null || continue
        bash "$_t" >/dev/null 2>&1 || { _fail=1; echo "$_base" >&2; }
      done
      exit "$_fail"
    ) || _stage2_rc=$?
  fi
fi

# ── Stage 3: Routing decision ────────────────────────────────────────────────
if [ "$_stage2_rc" != "0" ]; then
  # Test suite failed; route to impl-broken (lint was clean — Stage 1 passed)
  _route_impl_broken "test suite RED in charter #${CHARTER_ID} tree (lint clean → impl is broken)"
  exit 1
fi

# All stages passed — gate is green
echo "tqg: gate green (charter #${CHARTER_ID})" >&2
exit 0
