#!/usr/bin/env bash
#
# runtime-manifest-determinism.test.sh — regression harness for issue #708
#
# Runs runtime-manifest.test.sh 10× consecutively on the same unmodified tree
# and asserts every run produces byte-identical output (diff all against run 1).
#
# Purpose: detect the SIGPIPE/pipefail non-determinism described in #708 where
#   grep … | awk … pipelines in Test 2 would randomly yield UNCOVERED results
#   across sequential runs on an unchanged tree.
#
# Classification: EXCLUDED — meta-test that depends on external process state
#   (run 1 output used as reference); not a pure function of merged content alone.
#
# Exit 0: all 10 runs produced byte-identical output.
# Exit 1: one or more runs differed from run 1 (non-determinism detected).

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET="$HERE/runtime-manifest.test.sh"

pass=0; fail=0
ok() { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

echo "=== runtime-manifest-determinism: 10-run stability check ==="

if [ ! -f "$TARGET" ]; then
  no "runtime-manifest.test.sh not found at $TARGET"
  echo
  printf '=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"
  exit 1
fi

RUNS_DIR="$(mktemp -d)"
trap 'rm -rf "$RUNS_DIR"' EXIT

# Capture output of each run
for i in $(seq 1 10); do
  bash "$TARGET" > "$RUNS_DIR/run_${i}.txt" 2>&1 || true
done

# Assert all runs are byte-identical to run 1
all_match=1
for i in $(seq 2 10); do
  if ! diff -q "$RUNS_DIR/run_1.txt" "$RUNS_DIR/run_${i}.txt" > /dev/null 2>&1; then
    printf '  DIFF run 1 vs run %d:\n' "$i"
    diff "$RUNS_DIR/run_1.txt" "$RUNS_DIR/run_${i}.txt" | head -20 || true
    all_match=0
  fi
done

if [ "$all_match" -eq 1 ]; then
  ok "all 10 runs produced byte-identical output (no SIGPIPE/pipefail non-determinism)"
else
  no "one or more runs differed from run 1 (non-determinism detected — see diffs above)"
fi

echo
printf '=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
