#!/usr/bin/env bash
# triage-parse.sh — parse a ## Triage (machine) verdict block from stdin.
# Output (stdout, TSV):
#   root<TAB><class>
#   evidence<TAB><text>
#   route<TAB><stage>
# Exit non-zero on any validation failure (missing field, unknown class/route).
set -uo pipefail

VALID_ROOTS="executor-error test-flaky plan-flaw approach-flaw test-bug infra"
VALID_ROUTES="executor-rework test-flaky needs-plan needs-analysis test-bug infra"

input=$(cat)

# Find ## Triage (machine) header and extract the JSON line that follows it.
in_section=0
json=""
while IFS= read -r line; do
  if printf '%s' "$line" | grep -q '^## Triage (machine)'; then
    in_section=1
    continue
  fi
  if [ "$in_section" = "1" ]; then
    trimmed=$(printf '%s' "$line" | sed 's/^[[:space:]]*//')
    if printf '%s' "$trimmed" | grep -qE '^\{'; then
      json="$trimmed"
      break
    fi
  fi
done <<< "$input"

if [ -z "$json" ]; then
  printf 'triage-parse: no JSON found after ## Triage (machine) header\n' >&2
  exit 1
fi

# Extract required fields with jq.
root=$(printf '%s' "$json" | jq -r '.root // empty' 2>/dev/null) || {
  printf 'triage-parse: JSON parse error\n' >&2; exit 1
}
evidence=$(printf '%s' "$json" | jq -r '.evidence // empty' 2>/dev/null) || {
  printf 'triage-parse: JSON parse error\n' >&2; exit 1
}
route=$(printf '%s' "$json" | jq -r '.route // empty' 2>/dev/null) || {
  printf 'triage-parse: JSON parse error\n' >&2; exit 1
}

# Validate: required fields present.
[ -z "$root" ]     && { printf 'triage-parse: missing required field: root\n' >&2; exit 1; }
[ -z "$evidence" ] && { printf 'triage-parse: missing required field: evidence\n' >&2; exit 1; }
[ -z "$route" ]    && { printf 'triage-parse: missing required field: route\n' >&2; exit 1; }

# Validate: root class is known.
_valid_root=0
for _r in $VALID_ROOTS; do [ "$root" = "$_r" ] && _valid_root=1 && break; done
[ "$_valid_root" = "0" ] && {
  printf 'triage-parse: unknown root class: %s (valid: %s)\n' "$root" "$VALID_ROOTS" >&2; exit 1
}

# Validate: route value is known.
_valid_route=0
for _r in $VALID_ROUTES; do [ "$route" = "$_r" ] && _valid_route=1 && break; done
[ "$_valid_route" = "0" ] && {
  printf 'triage-parse: unknown route value: %s (valid: %s)\n' "$route" "$VALID_ROUTES" >&2; exit 1
}

# Success: emit TSV.
printf 'root\t%s\n' "$root"
printf 'evidence\t%s\n' "$evidence"
printf 'route\t%s\n' "$route"
