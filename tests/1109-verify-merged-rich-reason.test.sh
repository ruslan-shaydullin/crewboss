#!/usr/bin/env bash
# 1109-verify-merged-rich-reason.test.sh — charter #1048 / issue #1109 (qa-engineer leaf).
#
# Charter-acceptance ENTRYPOINT for the verify-merged rich-reason RED→GREEN contract.
# This is the deliverable the charter Acceptance ("проверено на реальном RED-листе")
# invokes; it runs the engine-side regression suites that drive the REAL
# cmd_verify_merged and assert the printed `RED_REASON:` line (and the persisted
# `${cache}.reason`) carry the EXACT failing assertion — not just the failing-test
# basename — while preserving the single-line / comma-join / cache / N-confirmation
# contract.
#
# Source of truth (kept OUT of the per-leaf verify-merged glob via EXCLUDED in
# reference/runtime/per-leaf-manifest, so this intentionally-RED contract cannot
# block the qa leaf's own merge gate before the fix lands):
#
#   reference/tests/1109-verify-merged-rich-reason.test.sh       (T1-T4 contract)
#   reference/tests/1109-verify-merged-rich-reason-live.test.sh  (T5 live RED-list)
#
# RED against the current basename-only behaviour; GREEN once the impl leaf enriches
# the RED_REASON / reason with the captured, bounded, single-line assertion text.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
# Repo root: this file lives at <root>/tests/ ; the engine suites at <root>/reference/tests/.
ROOT="$(cd "$HERE/.." && pwd)"
REF_TESTS="$ROOT/reference/tests"

SUITES="
1109-verify-merged-rich-reason.test.sh
1109-verify-merged-rich-reason-live.test.sh
"

rc=0
for s in $SUITES; do
  t="$REF_TESTS/$s"
  if [ ! -f "$t" ]; then
    printf 'FAIL missing engine suite: %s\n' "$t"
    rc=1
    continue
  fi
  printf '=== running %s ===\n' "$s"
  if bash "$t"; then
    printf 'ok   suite green: %s\n' "$s"
  else
    printf 'FAIL suite RED (RED_REASON rich-reason contract not yet satisfied): %s\n' "$s"
    rc=1
  fi
done

printf '\nverify-merged rich-reason contract: %s\n' "$([ "$rc" -eq 0 ] && echo PASS || echo RED)"
exit "$rc"
