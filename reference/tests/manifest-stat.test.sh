#!/usr/bin/env bash
# manifest-stat.test.sh — deterministic tests for reference/bin/manifest-stat.sh
# Self-contained: fixtures created in mktemp -d, cleaned up via trap.
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../bin/manifest-stat.sh"

TMPDIR_TESTS="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TESTS"' EXIT

pass=0; fail=0
ok() { printf 'ok   %s\n' "$*"; pass=$((pass+1)); }
ko() { printf 'FAIL %s\n' "$*"; fail=$((fail+1)); }

# =============================================================================
# Case 1: 2 canonical + 1 pending-backport + 1 comment line
# Expected: canonical=2 pending=1 total=3
# =============================================================================
FIXTURE1="$TMPDIR_TESTS/manifest1.tsv"
printf '%s\n' \
  '# this is a comment line' \
  "repo/path/a	abc123	canonical	some purpose" \
  "repo/path/b	def456	pending-backport	another purpose" \
  "repo/path/c	ghi789	canonical	third entry" \
  > "$FIXTURE1"

got1="$(MANIFEST_PATH="$FIXTURE1" bash "$SCRIPT")"
exp1="canonical=2 pending=1 total=3"
if [ "$got1" = "$exp1" ]; then
  ok "case1 (2 canonical + 1 pending + comment): [$got1]"
else
  ko "case1: expected [$exp1] got [$got1]"
fi

# =============================================================================
# Case 2: only comment lines and blank lines
# Expected: canonical=0 pending=0 total=0
# =============================================================================
FIXTURE2="$TMPDIR_TESTS/manifest2.tsv"
printf '%s\n' \
  '# comment 1' \
  '' \
  '# comment 2' \
  '   ' \
  > "$FIXTURE2"

got2="$(MANIFEST_PATH="$FIXTURE2" bash "$SCRIPT")"
exp2="canonical=0 pending=0 total=0"
if [ "$got2" = "$exp2" ]; then
  ok "case2 (only comments + blanks): [$got2]"
else
  ko "case2: expected [$exp2] got [$got2]"
fi

# =============================================================================
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
