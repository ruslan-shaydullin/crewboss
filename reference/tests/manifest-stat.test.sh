#!/usr/bin/env bash
# manifest-stat.test.sh — unit tests for reference/bin/manifest-stat.sh
# Issue #239 (charter #238).
#
# Self-contained: creates all fixtures in mktemp -d, cleaned up via trap.
# Drives the REAL script via MANIFEST_PATH env-var override.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../bin/manifest-stat.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok() { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko() { fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

# ── Case 1: 2 canonical + 1 pending-backport + 1 comment line ─────────────────
# Expected: canonical=2 pending=1 total=3
FIXTURE1="$TMP/fixture1.tsv"
printf '%s\n' \
  '# comment line — must be ignored' \
  "path/to/file1	abc123	canonical	some purpose" \
  "path/to/file2	def456	canonical	another purpose" \
  "path/to/file3	ghi789	pending-backport	yet another" \
  > "$FIXTURE1"

OUT1="$(MANIFEST_PATH="$FIXTURE1" bash "$SCRIPT")"
EXP1="canonical=2 pending=1 total=3"
[ "$OUT1" = "$EXP1" ] \
  && ok "case1 (2 canonical + 1 pending + 1 comment): [$OUT1]" \
  || ko "case1: expected [$EXP1] got [$OUT1]"

# ── Case 2: only comment lines and blank lines ────────────────────────────────
# Expected: canonical=0 pending=0 total=0
FIXTURE2="$TMP/fixture2.tsv"
printf '%s\n' \
  '# this is a comment' \
  '' \
  '# another comment' \
  '' \
  > "$FIXTURE2"

OUT2="$(MANIFEST_PATH="$FIXTURE2" bash "$SCRIPT")"
EXP2="canonical=0 pending=0 total=0"
[ "$OUT2" = "$EXP2" ] \
  && ok "case2 (only comments/blanks): [$OUT2]" \
  || ko "case2: expected [$EXP2] got [$OUT2]"

# ── Summary ───────────────────────────────────────────────────────────────────
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
