#!/usr/bin/env bash
# leaf-lint.sh — validate a leaf issue body for Charter / Depends-on fields
#
# Usage:
#   leaf-lint.sh <file>     # lint file at given path
#   leaf-lint.sh            # read from stdin (no arguments)
#
# Exit codes:
#   0 — body is valid
#   1 — one or more problems found (each emitted to stderr)
set -euo pipefail

# ── Read input ────────────────────────────────────────────────────────────────
if [ $# -ge 1 ]; then
  input_file="$1"
  body=$(cat "$input_file")
else
  body=$(cat)
fi

errors=0

# ── Check 1: exactly one Charter: #<digits> line ─────────────────────────────
charter_count=$(printf '%s\n' "$body" | grep -cE '^Charter: #[0-9]+$' || true)

if [ "$charter_count" -eq 0 ]; then
  echo "missing Charter" >&2
  errors=$((errors+1))
elif [ "$charter_count" -ge 2 ]; then
  echo "duplicate Charter" >&2
  errors=$((errors+1))
fi

# ── Check 2: every Depends-on: line must be well-formed ──────────────────────
# Pattern: Depends-on: #<digits>(, #<digits>)*
while IFS= read -r line; do
  if [[ "$line" =~ ^Depends-on: ]]; then
    if ! [[ "$line" =~ ^Depends-on:[[:space:]]+#[0-9]+(,[[:space:]]*#[0-9]+)*$ ]]; then
      echo "malformed Depends-on line: $line" >&2
      errors=$((errors+1))
    fi
  fi
done <<< "$body"

# ── Exit ─────────────────────────────────────────────────────────────────────
if [ "$errors" -gt 0 ]; then
  exit 1
fi
exit 0
