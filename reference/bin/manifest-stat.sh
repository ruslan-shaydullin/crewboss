#!/usr/bin/env bash
# manifest-stat.sh — count canonical and pending-backport rows in runtime-manifest.tsv
#
# Output (exactly one line to stdout):
#   canonical=<N> pending=<M> total=<K>
# where K = N + M.
#
# Env override: MANIFEST_PATH — path to the TSV file (default: auto-detected relative to script).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MANIFEST="${MANIFEST_PATH:-$REPO_ROOT/reference/runtime-manifest.tsv}"

canonical=0
pending=0

while IFS= read -r line; do
  # Skip comment lines and blank/whitespace-only lines
  case "$line" in
    '#'*) continue ;;
    *) ;;
  esac
  [[ "$line" =~ ^[[:space:]]*$ ]] && continue

  # Extract the 3rd tab-separated column
  status="$(printf '%s' "$line" | cut -f3)"

  case "$status" in
    canonical)         canonical=$((canonical + 1)) ;;
    pending-backport)  pending=$((pending + 1)) ;;
  esac
done < "$MANIFEST"

total=$((canonical + pending))
printf 'canonical=%d pending=%d total=%d\n' "$canonical" "$pending" "$total"
