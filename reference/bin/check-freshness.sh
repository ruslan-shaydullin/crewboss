#!/usr/bin/env bash
# check-freshness.sh — fail if current branch is behind origin/main by more than
# FRESHNESS_THRESHOLD commits (default 0).
#
# Called by:
#   .github/workflows/ci.yml  (freshness job, PR with base charter/*)
#   reference/tests/infra-false-green.test.sh  (direct invocation from a git context)
#
# Usage: run from inside a git working tree with origin/main fetched.
# Env:   FRESHNESS_THRESHOLD — max allowed commits behind origin/main (default 0)
set -euo pipefail

THRESHOLD="${FRESHNESS_THRESHOLD:-0}"

count=$(git rev-list --count HEAD..origin/main 2>/dev/null) || {
  echo "FAIL: cannot compute rev-list HEAD..origin/main (origin/main not fetched?)"
  exit 1
}

if [ "$count" -gt "$THRESHOLD" ]; then
  echo "FAIL: branch is ${count} commit(s) behind origin/main (threshold=${THRESHOLD})"
  exit 1
fi

echo "OK: branch is ${count} commit(s) behind origin/main (within threshold=${THRESHOLD})"
