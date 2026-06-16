#!/usr/bin/env bash
# manifest-stat.test.sh — unit tests for reference/bin/manifest-stat.sh
#
# Self-contained: creates all fixtures in mktemp -d, cleans up with trap.
# Drives the REAL script via MANIFEST_PATH=<fixture>.
#
# Case 1: TSV with 2 canonical + 1 pending-backport rows (plus comment + blank)
#   Expected: canonical=2 pending=1 total=3
# Case 2: TSV with only comment lines and blank lines
#   Expected: canonical=0 pending=0 total=0

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../bin/manifest-stat.sh"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

# ── Case 1: 2 canonical + 1 pending-backport + comment + blank ───────────────
FIXTURE1="$TMPDIR/manifest1.tsv"
printf '# This is a comment line\n' > "$FIXTURE1"
printf '\n' >> "$FIXTURE1"
printf 'proto/r6/board-gh.sh\tabc123\tcanonical\tGitHub board adapter\n' >> "$FIXTURE1"
printf 'proto/net/bridge.py\tdef456\tpending-backport\tIn-jail CONNECT proxy\n' >> "$FIXTURE1"
printf 'proto/provision/build.sh\tghi789\tcanonical\tAssembles provision.sh\n' >> "$FIXTURE1"

OUT1="$(MANIFEST_PATH="$FIXTURE1" bash "$SCRIPT")"
EC1=$?

[ "$EC1" -eq 0 ] \
  && ok "case1: exit 0" \
  || ko "case1: expected exit 0, got $EC1"

[ "$OUT1" = "canonical=2 pending=1 total=3" ] \
  && ok "case1: output matches 'canonical=2 pending=1 total=3'" \
  || ko "case1: expected 'canonical=2 pending=1 total=3', got '$OUT1'"

# ── Case 2: only comments and blank lines ────────────────────────────────────
FIXTURE2="$TMPDIR/manifest2.tsv"
printf '# Only comments here\n' > "$FIXTURE2"
printf '#\n' >> "$FIXTURE2"
printf '\n' >> "$FIXTURE2"
printf '   \n' >> "$FIXTURE2"

OUT2="$(MANIFEST_PATH="$FIXTURE2" bash "$SCRIPT")"
EC2=$?

[ "$EC2" -eq 0 ] \
  && ok "case2: exit 0" \
  || ko "case2: expected exit 0, got $EC2"

[ "$OUT2" = "canonical=0 pending=0 total=0" ] \
  && ok "case2: output matches 'canonical=0 pending=0 total=0'" \
  || ko "case2: expected 'canonical=0 pending=0 total=0', got '$OUT2'"

# ── summary ──────────────────────────────────────────────────────────────────
echo
echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
