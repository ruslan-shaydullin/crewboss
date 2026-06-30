#!/usr/bin/env bash
# recovery-parse.sh — parse a ## Recovery (machine) plan block from stdin.
# The block is emitted by the recovery-lead manager role and carries:
#   - an ORDERED JSON array of steps, each {"action":..,"target":..,"route":..}
#   - a terminal directive line: "terminal: merge" or "terminal: defer"
# Output (stdout, TSV):
#   <step_idx><TAB><action><TAB><target><TAB><route>   (one row per step)
#   terminal<TAB><merge|defer>                          (final row)
# Exit non-zero on any validation failure (malformed JSON, empty plan,
# unknown/invalid route, or missing terminal directive).
set -uo pipefail

VALID_ROUTES="executor-rework test-flaky needs-plan needs-analysis test-bug infra"
# Recovery-actionable subset of VALID_ROUTES.
RECOVERY_ROUTES="executor-rework test-bug needs-analysis"

input=$(cat)

# Find ## Recovery (machine) header and extract the JSON array line that follows
# it, plus the terminal directive.
in_section=0
json=""
terminal=""
while IFS= read -r line; do
  if printf '%s' "$line" | grep -q '^## Recovery (machine)'; then
    in_section=1
    continue
  fi
  if [ "$in_section" = "1" ]; then
    trimmed=$(printf '%s' "$line" | sed 's/^[[:space:]]*//')
    if [ -z "$json" ] && printf '%s' "$trimmed" | grep -qE '^\['; then
      json="$trimmed"
      continue
    fi
    if printf '%s' "$trimmed" | grep -qiE '^terminal:'; then
      terminal=$(printf '%s' "$trimmed" | sed -E 's/^[Tt]erminal:[[:space:]]*//' | sed 's/[[:space:]]*$//')
      break
    fi
  fi
done <<< "$input"

if [ -z "$json" ]; then
  printf 'recovery-parse: no JSON array found after ## Recovery (machine) header\n' >&2
  exit 1
fi

# Validate: JSON parses as an array.
count=$(printf '%s' "$json" | jq -r 'if type=="array" then length else "ERR" end' 2>/dev/null) || {
  printf 'recovery-parse: JSON parse error\n' >&2; exit 1
}
if [ "$count" = "ERR" ] || [ -z "$count" ]; then
  printf 'recovery-parse: malformed JSON (expected array of steps)\n' >&2; exit 1
fi

# Validate: plan is non-empty.
if [ "$count" = "0" ]; then
  printf 'recovery-parse: empty recovery plan array\n' >&2; exit 1
fi

# Validate: terminal directive present and known.
if [ -z "$terminal" ]; then
  printf 'recovery-parse: missing terminal directive (expected terminal: merge|defer)\n' >&2; exit 1
fi
if [ "$terminal" != "merge" ] && [ "$terminal" != "defer" ]; then
  printf 'recovery-parse: invalid terminal directive: %s (valid: merge|defer)\n' "$terminal" >&2; exit 1
fi

# Emit one TSV row per step, validating each route.
rows=""
idx=0
while [ "$idx" -lt "$count" ]; do
  action=$(printf '%s' "$json" | jq -r ".[$idx].action // empty" 2>/dev/null)
  target=$(printf '%s' "$json" | jq -r ".[$idx].target // empty" 2>/dev/null)
  route=$(printf '%s' "$json" | jq -r ".[$idx].route // empty" 2>/dev/null)

  if [ -z "$route" ]; then
    printf 'recovery-parse: step %s missing required field: route\n' "$idx" >&2; exit 1
  fi

  # Validate: route is within the recovery-actionable subset.
  _valid_route=0
  for _r in $RECOVERY_ROUTES; do [ "$route" = "$_r" ] && _valid_route=1 && break; done
  [ "$_valid_route" = "0" ] && {
    printf 'recovery-parse: step %s invalid route: %s (valid: %s)\n' "$idx" "$route" "$RECOVERY_ROUTES" >&2; exit 1
  }

  rows="${rows}$(printf '%s\t%s\t%s\t%s' "$idx" "$action" "$target" "$route")"$'\n'
  idx=$((idx + 1))
done

# Success: emit all step rows followed by the terminal row.
printf '%s' "$rows"
printf 'terminal\t%s\n' "$terminal"
