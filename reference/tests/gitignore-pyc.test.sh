#!/usr/bin/env bash
# gitignore-pyc.test.sh — verifies that __pycache__/ and *.pyc are in .gitignore
# and that ui/server/__pycache__ pyc files are untracked (issue #367/#368 hygiene fix).
# Class: pure content check — grep .gitignore + git ls-files.
# ALLOW-eligible: no launcher loop, no background processes, no timing/poll/sleep.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

# Check .gitignore has __pycache__/ entry
grep -q '^__pycache__/' "$REPO/.gitignore" \
  && ok ".gitignore has __pycache__/ entry" \
  || ko ".gitignore missing __pycache__/ entry"

# Check .gitignore has *.pyc entry
grep -q '^\*\.pyc' "$REPO/.gitignore" \
  && ok ".gitignore has *.pyc entry" \
  || ko ".gitignore missing *.pyc entry"

# Check no pyc files are tracked under ui/server/__pycache__
TRACKED="$(git -C "$REPO" ls-files -- 'ui/server/__pycache__/')"
[ -z "$TRACKED" ] \
  && ok "ui/server/__pycache__/ has no tracked pyc files" \
  || ko "ui/server/__pycache__/ still has tracked files: $TRACKED"

echo
echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
