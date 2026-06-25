#!/usr/bin/env bash
#
# runtime-manifest-determinism.test.sh — determinism regression harness (issue #708)
#
# Runs runtime-manifest.test.sh 10 consecutive times on the same unmodified tree,
# captures stdout of each run, and asserts every run produces byte-identical output
# (diff all against run 1).  Exits 0 only if all 10 runs match; prints differing
# run(s) and exits non-zero otherwise.
#
# Classification: EXCLUDED — meta-test that depends on external process state
# (it invokes another test script as a subprocess); not a pure function of merged
# content alone.  See per-leaf-manifest for rationale.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET="$HERE/runtime-manifest.test.sh"

pass=0; fail=0
ok() { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
ko() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

echo "=== Test 1: runtime-manifest.test.sh produces deterministic output across 10 runs ==="

if [ ! -f "$TARGET" ]; then
  ko "runtime-manifest.test.sh not found at $TARGET"
  echo
  printf '=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"
  exit 1
fi

if [ ! -x "$TARGET" ]; then
  ko "runtime-manifest.test.sh is not executable: $TARGET"
  echo
  printf '=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"
  exit 1
fi

RUNS=10
TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Capture all 10 runs
for i in $(seq 1 $RUNS); do
  "$TARGET" > "$TMPDIR_BASE/run_$i.out" 2>&1 || true
done

# Diff all runs against run 1
all_match=1
for i in $(seq 2 $RUNS); do
  if ! diff -q "$TMPDIR_BASE/run_1.out" "$TMPDIR_BASE/run_$i.out" > /dev/null 2>&1; then
    all_match=0
    printf '  DIFF: run 1 vs run %d:\n' "$i"
    diff "$TMPDIR_BASE/run_1.out" "$TMPDIR_BASE/run_$i.out" | head -30 | sed 's/^/    /'
  fi
done

if [ "$all_match" -eq 1 ]; then
  ok "all $RUNS runs produced byte-identical output (no non-determinism detected)"
else
  ko "output differed across runs — non-determinism detected in runtime-manifest.test.sh"
fi

echo
printf '=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
