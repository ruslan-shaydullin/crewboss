#!/usr/bin/env bash
# manifest-stat.sh — count canonical and pending-backport rows in runtime-manifest.tsv.
# Issue #239 (charter #238).
#
# Usage: bash manifest-stat.sh
# Env:   MANIFEST_PATH — override default manifest path (useful for tests)
# Output (stdout, exactly one line): canonical=<N> pending=<M> total=<K>
# Exit 0 always.
#
# Skips lines starting with '#' and blank/whitespace-only lines.
# Counts rows where the 3rd tab-separated column equals 'canonical' (N)
# or 'pending-backport' (M).  Prints K = N+M as total.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MANIFEST="${MANIFEST_PATH:-$REPO_ROOT/reference/runtime-manifest.tsv}"

awk -F'\t' '
  /^[[:space:]]*#/ { next }
  /^[[:space:]]*$/ { next }
  $3 == "canonical"        { n++ }
  $3 == "pending-backport" { m++ }
  END { printf "canonical=%d pending=%d total=%d\n", n+0, m+0, n+m }
' "$MANIFEST"
