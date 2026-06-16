#!/usr/bin/env bash
# manifest-stat.sh — count canonical / pending-backport rows in runtime-manifest.tsv
#
# Output (stdout, exactly one line):
#   canonical=<N> pending=<M> total=<K>
# where K = N + M.
#
# Supports optional MANIFEST_PATH env-var override for testing.
# Exits 0 always.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_PATH="${MANIFEST_PATH:-$SCRIPT_DIR/../../reference/runtime-manifest.tsv}"

canonical=0
pending=0

while IFS= read -r line; do
  # Skip comment lines and blank/whitespace-only lines
  case "$line" in
    '#'*) continue ;;
    '') continue ;;
  esac
  [[ "$line" =~ ^[[:space:]]*$ ]] && continue

  # Extract 3rd tab-separated column (status)
  status="$(printf '%s' "$line" | cut -f3)"

  case "$status" in
    canonical)        canonical=$((canonical + 1)) ;;
    pending-backport) pending=$((pending + 1)) ;;
  esac
done < "$MANIFEST_PATH"

total=$((canonical + pending))
printf 'canonical=%d pending=%d total=%d\n' "$canonical" "$pending" "$total"
exit 0
