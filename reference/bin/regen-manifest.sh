#!/usr/bin/env bash
# regen-manifest.sh — recompute the sha256 column of runtime-manifest.tsv for
# canonical rows from the actual repo files (issue #128 / #206 Part A).
#
# WHY: the sha column of reference/runtime-manifest.tsv was hand-maintained — the
# root of E1 (a canonical runtime file changes, the hash is not refreshed →
# runtime-manifest.test.sh Test 3 sha-lock RED at green-looking work) and of #130
# (transient drift-fail). This tool makes the sha-lock derivable, not hand-typed.
#
# SOUNDNESS (NOT a tautology): regen ONLY rewrites the sha of files that exist on
# disk with status=canonical. It does NOT:
#   - add/remove rows, or change the status column (Test 4 still guards structure);
#   - touch a row whose file is MISSING on disk (Test 3 still RED on a removed
#     canonical file — regen must not mask a deletion);
#   - touch pending-backport / non-canonical rows.
# The sha-lock asserts manifest==tree; it is sound only because the FULL engine
# suite runs on the SAME tree before this regen is persisted (see #206 Part A):
# the suite proves the tree correct, the sha-lock proves the manifest matches it.
#
# Usage:
#   regen-manifest.sh [REPO_ROOT]
#     REPO_ROOT defaults to the repo root inferred from this script's location
#     (reference/bin/.. /..). In-clone callers (verify-merged) cd into the merged
#     tree and run `bash reference/bin/regen-manifest.sh`, so the default resolves
#     to that tree.
#
# Exit: 0 always on success (including no-op: manifest absent, or already fresh).
#       Prints the basename of each row whose sha was refreshed (one per line) to
#       stderr; nothing on stdout. Caller decides whether a diff means "persist".
set -uo pipefail

root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)}"
manifest="$root/reference/runtime-manifest.tsv"

# No-op safety: synthetic/merged trees without the manifest (e.g. verify-merged
# fixtures) must not error — regen simply has nothing to do.
[ -f "$manifest" ] || exit 0

tmp="$(mktemp 2>/dev/null)" || exit 0

changed=0
while IFS= read -r line || [ -n "$line" ]; do
  # cut on TAB: comment/blank lines have no tabs, so field 3 != "canonical" and
  # field 1 keeps a leading '#'/whitespace — both guards below pass them through
  # verbatim (preserving the human-authored header exactly).
  rp="$(printf '%s' "$line" | cut -f1)"
  st="$(printf '%s' "$line" | cut -f3)"
  case "$rp" in
    ''|'#'*) printf '%s\n' "$line" >> "$tmp"; continue ;;
  esac
  if [ "$st" = "canonical" ] && [ -f "$root/$rp" ]; then
    sha="$(printf '%s' "$line" | cut -f2)"
    pu="$(printf '%s' "$line" | cut -f4-)"
    new="$(sha256sum "$root/$rp" | cut -d' ' -f1)"
    if [ "$new" != "$sha" ]; then
      printf '%s\n' "$rp" >&2
      changed=$((changed + 1))
    fi
    printf '%s\t%s\t%s\t%s\n' "$rp" "$new" "$st" "$pu" >> "$tmp"
  else
    # Missing canonical file (Test 3 MISSING must stay RED), pending-backport,
    # or any non-canonical row: pass through untouched.
    printf '%s\n' "$line" >> "$tmp"
  fi
done < "$manifest"

if [ "$changed" -gt 0 ]; then
  cat "$tmp" > "$manifest"
fi
rm -f "$tmp"
exit 0
