#!/usr/bin/env bash
# acceptance-parse.sh — parse the ## Acceptance (machine) block from an issue body.
#
# Usage:
#   acceptance-parse.sh [file]       read body from file
#   echo "body" | acceptance-parse.sh   read body from stdin
#
# stdout: one executable check per line
#   - test: <path>  →  bash <path>
#   - check: <cmd>  →  <cmd>  (as-is)
#
# exit 0 : valid block found (≥1 test: or check: line)
# exit 1 : no valid block (missing header, empty section, or only garbage lines)
#
# Block format (board-orchestration.md § Acceptance (machine)):
#   ## Acceptance (machine)
#   - test: reference/tests/foo.sh
#   - check: some-shell-command
#   [... more lines ...]
#   ## Next section     ← ends the block (or EOF)

set -u

if [ $# -ge 1 ]; then
  body="$(cat "$1")"
else
  body="$(cat)"
fi

in_block=0
found=0

while IFS= read -r line; do
  if [ "$in_block" = 0 ]; then
    # Look for the block header (exact prefix match, tolerates trailing spaces)
    case "$line" in
      "## Acceptance (machine)"*) in_block=1 ;;
    esac
    continue
  fi

  # Inside the block — stop at the next level-2 heading
  case "$line" in
    "## "*) break ;;
  esac

  # Translate valid lines
  if printf '%s\n' "$line" | grep -qE '^- test: .+'; then
    path="${line#- test: }"
    printf 'bash %s\n' "$path"
    found=$((found + 1))
  elif printf '%s\n' "$line" | grep -qE '^- check: .+'; then
    cmd="${line#- check: }"
    printf '%s\n' "$cmd"
    found=$((found + 1))
  fi
done <<< "$body"

[ "$found" -gt 0 ]
