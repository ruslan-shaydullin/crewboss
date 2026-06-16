#!/usr/bin/env bash
# manifest-stat.sh — count canonical and pending-backport rows in runtime-manifest.tsv
#
# Usage: bash manifest-stat.sh
# Env:   MANIFEST_PATH — override TSV path (default: <repo_root>/reference/runtime-manifest.tsv)
#
# Output (one line to stdout):
#   canonical=<N> pending=<M> total=<K>
#
# Exit 0 always.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MANIFEST_PATH="${MANIFEST_PATH:-$REPO_ROOT/reference/runtime-manifest.tsv}"

canonical=0
pending=0

while IFS= read -r line; do
  # Skip comment lines (starting with #) and blank/whitespace-only lines
  case "$line" in
    '#'*) continue ;;
    '')   continue ;;
  esac
  # Check if line is whitespace-only
  if printf '%s' "$line" | grep -qE '^[[:space:]]*$'; then
    continue
  fi
  # Extract 3rd tab-separated column (status)
  status="$(printf '%s' "$line" | awk -F'\t' '{print $3}')"
  case "$status" in
    canonical)         canonical=$((canonical+1)) ;;
    pending-backport)  pending=$((pending+1))     ;;
  esac
done < "$MANIFEST_PATH"

total=$((canonical + pending))
printf 'canonical=%d pending=%d total=%d\n' "$canonical" "$pending" "$total"
