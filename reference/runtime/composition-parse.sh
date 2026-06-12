#!/usr/bin/env bash
# composition-parse.sh — parse the ## Composition (machine) block from a charter comment,
# validate doctor-invariants (Ф1: span≤span_max, roles exist in manifest), emit TSV.
#
# Usage: composition-parse.sh <manifest-dir> [file]
#   <manifest-dir>  path to a crewboss team manifest directory (org.json + roles/)
#   [file]          optional file to parse; reads from stdin if omitted
#
# Stdout (TSV):
#   approach<TAB><text>
#   role<TAB><id>              (one line per role: entry)
#   leaf<TAB><id><TAB><role>   (one line per leaf: entry)
#   est_cost_usd<TAB><num>
#
# Exit codes:
#   0  valid block, all invariants satisfied
#   1  block missing / format error / est_cost_usd is not a number
#   4  doctor invariant violated:
#        leaf count > span_max (Ф1 — one level, one manager),
#        role or leaf role not in manifest_roles,
#        leaf role not declared in role: lines

set -u

MANIFEST_DIR="${1:?composition-parse: manifest-dir required}"
shift
INPUT_FILE="${1:-}"

# Locate manifest.sh relative to this script
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../launcher/manifest.sh"
[ -f "$LIB" ] || { printf 'composition-parse: cannot find manifest.sh at %s\n' "$LIB" >&2; exit 1; }
# shellcheck source=../launcher/manifest.sh
source "$LIB"

# Read body from file or stdin
if [ -n "$INPUT_FILE" ]; then
  [ -f "$INPUT_FILE" ] || { printf 'composition-parse: not a file: %s\n' "$INPUT_FILE" >&2; exit 1; }
  body=$(< "$INPUT_FILE")
else
  body=$(cat)
fi

# ── Extract the ## Composition (machine) block ──────────────────────────────
# Starts after the exact header line, ends before the next ## section or EOF.
if ! printf '%s\n' "$body" | grep -qx '## Composition (machine)'; then
  printf 'composition-parse: no '"'"'## Composition (machine)'"'"' block found\n' >&2
  exit 1
fi

block=$(printf '%s\n' "$body" | awk '
  $0 == "## Composition (machine)" { found=1; next }
  found && substr($0,1,3) == "## " { exit }
  found { print }
')

# ── Parse fields from the block ──────────────────────────────────────────────
approach=""
approach_count=0
est_cost_usd=""
est_cost_count=0
role_ids=""
role_count=0
leaf_entries=""
leaf_count=0

while IFS= read -r line; do
  case "$line" in
    "- approach: "*)
      val="${line#- approach: }"
      val="$(printf '%s' "$val" | sed 's/[[:space:]]*$//')"
      approach="$val"
      approach_count=$((approach_count + 1))
      ;;
    "- role: "*)
      val="${line#- role: }"
      val="$(printf '%s' "$val" | sed 's/[[:space:]]*$//')"
      role_ids="${role_ids}${val}
"
      role_count=$((role_count + 1))
      ;;
    "- leaf: "*)
      rest="${line#- leaf: }"
      if printf '%s' "$rest" | grep -qF ' -> '; then
        leaf_id="${rest%% -> *}"
        leaf_role="${rest#* -> }"
        leaf_id="$(printf '%s' "$leaf_id" | sed 's/[[:space:]]*$//')"
        leaf_role="$(printf '%s' "$leaf_role" | sed 's/[[:space:]]*$//')"
        leaf_entries="${leaf_entries}${leaf_id}	${leaf_role}
"
        leaf_count=$((leaf_count + 1))
      else
        printf 'composition-parse: malformed leaf line (missing " -> "): %s\n' "$line" >&2
        exit 1
      fi
      ;;
    "- est_cost_usd: "*)
      val="${line#- est_cost_usd: }"
      val="$(printf '%s' "$val" | sed 's/[[:space:]]*$//')"
      est_cost_usd="$val"
      est_cost_count=$((est_cost_count + 1))
      ;;
  esac
done < <(printf '%s\n' "$block")

# ── Validate field counts ──────────────────────────────────────────────────
if [ "$approach_count" -ne 1 ]; then
  printf 'composition-parse: expected exactly 1 approach: line, got %d\n' "$approach_count" >&2
  exit 1
fi
if [ "$role_count" -lt 1 ]; then
  printf 'composition-parse: expected >=1 role: lines, got %d\n' "$role_count" >&2
  exit 1
fi
if [ "$leaf_count" -lt 1 ]; then
  printf 'composition-parse: expected >=1 leaf: lines, got %d\n' "$leaf_count" >&2
  exit 1
fi
if [ "$est_cost_count" -ne 1 ]; then
  printf 'composition-parse: expected exactly 1 est_cost_usd: line, got %d\n' "$est_cost_count" >&2
  exit 1
fi

# est_cost_usd must be a non-negative number (integer or decimal)
if ! printf '%s' "$est_cost_usd" | grep -qE '^[0-9]+(\.[0-9]+)?$'; then
  printf 'composition-parse: est_cost_usd is not a valid number: %s\n' "$est_cost_usd" >&2
  exit 1
fi

# ── Load manifest data ─────────────────────────────────────────────────────
span_max=$(manifest_policy "$MANIFEST_DIR" span_max) \
  || { printf 'composition-parse: cannot read span_max from manifest\n' >&2; exit 1; }
manifest_role_list=$(manifest_roles "$MANIFEST_DIR") \
  || { printf 'composition-parse: cannot read roles from manifest\n' >&2; exit 1; }

# ── Doctor invariants (exit 4) ─────────────────────────────────────────────
inv_fail=0

# Ф1: leaf count must not exceed span_max (one level, one manager)
if [ "$leaf_count" -gt "$span_max" ]; then
  printf 'composition-parse: invariant violated: leaf count (%d) > span_max (%d)\n' \
    "$leaf_count" "$span_max" >&2
  inv_fail=1
fi

# All declared role: values must exist in the manifest
while IFS= read -r rid; do
  [ -z "$rid" ] && continue
  if ! printf '%s\n' "$manifest_role_list" | grep -qx "$rid"; then
    printf 'composition-parse: invariant violated: role '"'"'%s'"'"' not in manifest\n' "$rid" >&2
    inv_fail=1
  fi
done < <(printf '%s' "$role_ids")

# All leaf: role values must exist in manifest AND be declared in role: lines
while IFS=$'\t' read -r lid lrole; do
  [ -z "$lid" ] && continue
  if ! printf '%s\n' "$manifest_role_list" | grep -qx "$lrole"; then
    printf 'composition-parse: invariant violated: leaf '"'"'%s'"'"' role '"'"'%s'"'"' not in manifest\n' \
      "$lid" "$lrole" >&2
    inv_fail=1
  fi
  if ! printf '%s' "$role_ids" | grep -qx "$lrole"; then
    printf 'composition-parse: invariant violated: leaf '"'"'%s'"'"' role '"'"'%s'"'"' not in declared role: lines\n' \
      "$lid" "$lrole" >&2
    inv_fail=1
  fi
done < <(printf '%s' "$leaf_entries")

[ "$inv_fail" -ne 0 ] && exit 4

# ── Emit TSV output ────────────────────────────────────────────────────────
printf 'approach\t%s\n' "$approach"
while IFS= read -r rid; do
  [ -z "$rid" ] && continue
  printf 'role\t%s\n' "$rid"
done < <(printf '%s' "$role_ids")
while IFS=$'\t' read -r lid lrole; do
  [ -z "$lid" ] && continue
  printf 'leaf\t%s\t%s\n' "$lid" "$lrole"
done < <(printf '%s' "$leaf_entries")
printf 'est_cost_usd\t%s\n' "$est_cost_usd"

exit 0
