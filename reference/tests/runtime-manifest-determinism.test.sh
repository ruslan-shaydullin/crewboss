#!/usr/bin/env bash
#
# runtime-manifest-determinism.test.sh — regression harness for SIGPIPE+pipefail fix (#996)
#
# Runs runtime-manifest.test.sh 10 consecutive times on the same unmodified tree and
# asserts that every run produces byte-identical output (stdout+stderr combined).
# This proves the awk-exit-removal fix from PR #996 is durable: no SIGPIPE race can
# cause run-to-run divergence in the grep|awk pipelines inside the while-loop.
#
# Usage: bash reference/tests/runtime-manifest-determinism.test.sh
# Exit 0 on all-identical; non-zero on any divergence.
#
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUBJECT="$HERE/runtime-manifest.test.sh"

if [ ! -f "$SUBJECT" ]; then
  printf 'ERROR: subject not found: %s
' "$SUBJECT" >&2
  exit 1
fi

RUNS=10
TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

printf 'Running %s %d times...
' "$(basename "$SUBJECT")" "$RUNS"

ref_output="$TMPDIR_BASE/run_1.out"
diverged=0

for i in $(seq 1 "$RUNS"); do
  out="$TMPDIR_BASE/run_${i}.out"
  bash "$SUBJECT" >"$out" 2>&1 || true   # capture regardless of exit code
  if [ "$i" -eq 1 ]; then
    ref_output="$out"
  else
    if ! diff -q "$ref_output" "$out" >/dev/null 2>&1; then
      printf 'FAIL: run %d output differs from run 1
' "$i"
      printf '--- run 1
+++ run %d
' "$i"
      diff "$ref_output" "$out" || true
      diverged=$((diverged + 1))
    fi
  fi
done

if [ "$diverged" -eq 0 ]; then
  printf 'PASS: %d/%d runs identical
' "$RUNS" "$RUNS"
  exit 0
else
  printf 'FAIL: %d run(s) diverged from run 1 (expected deterministic output)
' "$diverged"
  exit 1
fi
