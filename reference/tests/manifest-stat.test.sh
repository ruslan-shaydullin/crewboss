#!/usr/bin/env bash
# manifest-stat.test.sh — TDD tests for reference/bin/manifest-stat.sh (issue #239)
#
# Self-contained: creates all fixtures in a temp dir, cleans up via trap.
# Drives the REAL script via MANIFEST_PATH env-var override.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../bin/manifest-stat.sh"

TMPDIR_FIXTURES="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_FIXTURES"' EXIT

pass=0; fail=0

ok() { printf '  ok   %s\n' "$*"; pass=$((pass + 1)); }
ko() { printf '  FAIL %s\n' "$*"; fail=$((fail + 1)); }

check_eq() {
  local label="$1" got="$2" exp="$3"
  if [ "$got" = "$exp" ]; then
    ok "$label: [$got]"
  else
    ko "$label: got=[$got] exp=[$exp]"
  fi
}

# ---------------------------------------------------------------------------
# Case 1: 2 canonical + 1 pending-backport + 1 comment line
# ---------------------------------------------------------------------------
echo "=== Case 1: 2 canonical + 1 pending-backport ==="

FIXTURE1="$TMPDIR_FIXTURES/case1.tsv"
printf '%s\n' \
  "# this is a comment line" \
  "reference/foo.sh	abc123	canonical	first canonical file" \
  "reference/bar.sh	def456	canonical	second canonical file" \
  "reference/baz.sh	789abc	pending-backport	pending file" \
  > "$FIXTURE1"

got1="$(MANIFEST_PATH="$FIXTURE1" bash "$SCRIPT")"
check_eq "case1 output" "$got1" "canonical=2 pending=1 total=3"

# ---------------------------------------------------------------------------
# Case 2: only comment lines and blank lines (no data rows)
# ---------------------------------------------------------------------------
echo "=== Case 2: only comments and blanks ==="

FIXTURE2="$TMPDIR_FIXTURES/case2.tsv"
printf '%s\n' \
  "# comment one" \
  "" \
  "   " \
  "# comment two" \
  > "$FIXTURE2"

got2="$(MANIFEST_PATH="$FIXTURE2" bash "$SCRIPT")"
check_eq "case2 output" "$got2" "canonical=0 pending=0 total=0"

# ---------------------------------------------------------------------------
echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
