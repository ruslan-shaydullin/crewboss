#!/usr/bin/env bash
# composition-parse.sh — parse the ## Composition (machine) block from a charter comment.
#
# Usage:
#   composition-parse.sh <manifest-dir> [file]     read body from file
#   echo "body" | composition-parse.sh <manifest-dir>   read body from stdin
#
# stdout (TSV):
#   approach<TAB><text>
#   role<TAB><id>               (one per role: line)
#   leaf<TAB><id><TAB><role>    (one per leaf: line)
#   est_cost_usd<TAB><num>
#
# exit 0 : valid block found, all invariants satisfied
# exit 1 : no valid block (missing header, empty section, or format error)
# exit 4 : invariants violated — leaf count > span_max (Ф1), role not in manifest,
#           or leaf's assigned role not declared in role: lines
#
# Block format (charter comment):
#   ## Composition (machine)
#   - approach: <one line>
#   - role: <role-id>           ← repeatable; at least one required
#   - leaf: <leaf-id> -> <role-id>   ← repeatable; at least one required
#   - est_cost_usd: <number>
#   ## Next section             ← ends the block (or EOF)

set -u

MANIFEST_DIR="${1:?composition-parse.sh: manifest-dir required}"
shift

if [ $# -ge 1 ]; then
  body="$(cat "$1")"
else
  body="$(cat)"
fi

# Source manifest accessor library (manifest_policy, manifest_roles)
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../launcher/manifest.sh
source "$HERE/../launcher/manifest.sh"

# ── Phase 1: extract and parse block ─────────────────────────────────────────

in_block=0
approach=""
roles=()
leaf_ids=()
leaf_roles=()
est_cost=""
found_approach=0
found_est_cost=0

while IFS= read -r line; do
  if [ "$in_block" = 0 ]; then
    case "$line" in
      "## Composition (machine)"*) in_block=1 ;;
    esac
    continue
  fi

  # Inside the block — stop at the next level-2 heading
  case "$line" in
    "## "*) break ;;
  esac

  # Parse - approach: <text>
  if printf '%s\n' "$line" | grep -qE '^- approach: .+'; then
    found_approach=$((found_approach + 1))
    approach="${line#- approach: }"

  # Parse - role: <role-id>  (no spaces in id)
  elif printf '%s\n' "$line" | grep -qE '^- role: [^ ]+$'; then
    role_id="${line#- role: }"
    roles+=("$role_id")

  # Parse - leaf: <leaf-id> -> <role-id>
  elif printf '%s\n' "$line" | grep -qE '^- leaf: [^ ]+ -> [^ ]+$'; then
    rest="${line#- leaf: }"
    leaf_ids+=("${rest% -> *}")
    leaf_roles+=("${rest#* -> }")

  # Parse - est_cost_usd: <value>
  elif printf '%s\n' "$line" | grep -qE '^- est_cost_usd: .+'; then
    found_est_cost=$((found_est_cost + 1))
    est_cost="${line#- est_cost_usd: }"
  fi
done <<< "$body"

# ── Phase 2: validate format ──────────────────────────────────────────────────

# Block must have been entered
[ "$in_block" = 1 ] || exit 1

# Exactly one approach line
[ "$found_approach" -eq 1 ] || exit 1

# At least one role: line
[ "${#roles[@]}" -ge 1 ] || exit 1

# At least one leaf: line
[ "${#leaf_ids[@]}" -ge 1 ] || exit 1

# Exactly one est_cost_usd: line, value must be a number (integer or decimal)
[ "$found_est_cost" -eq 1 ] || exit 1
printf '%s\n' "$est_cost" | grep -qE '^[0-9]+(\.[0-9]+)?$' || exit 1

# ── Phase 3: validate doctor invariants (Ф1) ─────────────────────────────────

# Retrieve span_max from manifest
span_max="$(manifest_policy "$MANIFEST_DIR" span_max 2>/dev/null)" || span_max=5
[ -n "$span_max" ] || span_max=5

# Retrieve all known roles from manifest
known_roles="$(manifest_roles "$MANIFEST_DIR" 2>/dev/null)" || exit 4

# Ф1: number of leaf: lines must not exceed span_max (one level, one manager)
[ "${#leaf_ids[@]}" -le "$span_max" ] || exit 4

# Every declared role: must exist in the manifest
for r in "${roles[@]}"; do
  printf '%s\n' "$known_roles" | grep -qxF "$r" || exit 4
done

# Every leaf: assigned role must (a) exist in the manifest and (b) be declared in role: lines
for i in "${!leaf_roles[@]}"; do
  lr="${leaf_roles[$i]}"
  # Must be a known manifest role
  printf '%s\n' "$known_roles" | grep -qxF "$lr" || exit 4
  # Must be declared in a role: line
  found_in_roles=0
  for r in "${roles[@]}"; do
    [ "$r" = "$lr" ] && found_in_roles=1 && break
  done
  [ "$found_in_roles" = 1 ] || exit 4
done

# ── Phase 4: emit TSV output ─────────────────────────────────────────────────

printf 'approach\t%s\n' "$approach"
for r in "${roles[@]}"; do
  printf 'role\t%s\n' "$r"
done
for i in "${!leaf_ids[@]}"; do
  printf 'leaf\t%s\t%s\n' "${leaf_ids[$i]}" "${leaf_roles[$i]}"
done
printf 'est_cost_usd\t%s\n' "$est_cost"
