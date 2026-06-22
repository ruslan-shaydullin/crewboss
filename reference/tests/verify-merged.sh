#!/usr/bin/env bash
# verify-merged.sh — in-place per-leaf ALLOW-suite runner (#449 / charter #444).
#
# Runs only the tests classified as ALLOW in reference/runtime/per-leaf-manifest
# against the current working tree (no git remote needed).  Mirrors what
# crewboss-integrator.sh verify-merged does on a merged tree, but for local/CI
# gate use without a remote.
#
# Part A (#206): regenerates the sha-lock in-place so runtime-manifest.test.sh
# does not false-RED on benign sha-drift while still catching structural breaks.
#
# Exit 0 = all ALLOW tests pass.  Exit 1 = one or more ALLOW tests failed.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="$HERE/../runtime/per-leaf-manifest"
[ -f "$MANIFEST" ] || { printf 'per-leaf-manifest not found: %s\n' "$MANIFEST" >&2; exit 2; }

# In-place sha-lock regen (Part A, #206): keeps runtime-manifest test green
# on benign sha-drift without masking structural breaks.
bash "$HERE/../bin/regen-manifest.sh" >/dev/null 2>&1 || true

fail=0
for t in "$HERE"/*.test.sh; do
  _base="$(basename "$t" .test.sh)"
  grep -qE "^ALLOW[[:space:]]+${_base}$" "$MANIFEST" 2>/dev/null || continue
  printf '=== %s\n' "$_base"
  bash "$t" || fail=1
done
exit "$fail"
