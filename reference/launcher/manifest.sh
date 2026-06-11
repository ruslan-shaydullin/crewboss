#!/usr/bin/env bash
# manifest.sh — source-able bash library of pure accessor functions over a crewboss team
# manifest directory (org.json + roles/*.md + rubric.json). No network; only jq/sed/grep.
#
# Usage:
#   source "$(dirname "$0")/manifest.sh"
#   manifest_validate  <dir>
#   manifest_policy    <dir> <key>
#   manifest_analysis_roles <dir>
#   manifest_roles     <dir>
#   manifest_role_field  <dir> <role> <field>
#   manifest_role_prompt <dir> <role>
#   manifest_role_profile <dir> <role>
#
# All functions are pure: they read files in <dir> and write to stdout.
# Non-zero exit codes signal errors / not-found where meaningful; missing optional
# fields produce empty stdout (not an error), matching manifest-spec.ru.md semantics.

# ---------------------------------------------------------------------------
# manifest_validate <dir>
#   Run the manifest validator. Uses <dir>/manifest-doctor.sh if present,
#   otherwise falls back to team-example/manifest-doctor.sh <dir>.
#   Exits non-zero when the manifest is invalid.
# ---------------------------------------------------------------------------
manifest_validate() {
  local dir="${1:?manifest_validate: dir required}"
  local doctor
  if [ -f "$dir/manifest-doctor.sh" ]; then
    doctor="$dir/manifest-doctor.sh"
    bash "$doctor" "$dir"
  else
    # Locate the reference copy relative to this file.
    local here; here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    doctor="$here/../../team-example/manifest-doctor.sh"
    if [ ! -f "$doctor" ]; then
      echo "manifest_validate: cannot find manifest-doctor.sh" >&2
      return 2
    fi
    bash "$doctor" "$dir"
  fi
}

# ---------------------------------------------------------------------------
# manifest_policy <dir> <key>
#   Print the value of policy.<key> from <dir>/org.json.
#   Supported keys: span_max, approval_role, human_approval_above_usd
#   Returns 1 if org.json missing or key not found; empty stdout on null.
# ---------------------------------------------------------------------------
manifest_policy() {
  local dir="${1:?manifest_policy: dir required}"
  local key="${2:?manifest_policy: key required}"
  local org="$dir/org.json"
  [ -f "$org" ] || { echo "manifest_policy: no org.json in $dir" >&2; return 1; }
  jq -r --arg k "$key" '.policy[$k] // empty' "$org"
}

# ---------------------------------------------------------------------------
# manifest_analysis_roles <dir>
#   Print policy.analysis_roles[] from <dir>/org.json, one per line.
# ---------------------------------------------------------------------------
manifest_analysis_roles() {
  local dir="${1:?manifest_analysis_roles: dir required}"
  local org="$dir/org.json"
  [ -f "$org" ] || { echo "manifest_analysis_roles: no org.json in $dir" >&2; return 1; }
  jq -r '.policy.analysis_roles[]? // empty' "$org"
}

# ---------------------------------------------------------------------------
# manifest_roles <dir>
#   Print all role names (basename without .md) from <dir>/roles/*.md, one per line.
# ---------------------------------------------------------------------------
manifest_roles() {
  local dir="${1:?manifest_roles: dir required}"
  local roles_dir="$dir/roles"
  [ -d "$roles_dir" ] || { echo "manifest_roles: no roles/ dir in $dir" >&2; return 1; }
  for f in "$roles_dir"/*.md; do
    [ -f "$f" ] || continue
    basename "$f" .md
  done
}

# ---------------------------------------------------------------------------
# _manifest_frontmatter_field <role_file> <field>
#   Internal helper: extract a YAML frontmatter field value from a role .md file.
#   Matches the field() function pattern in manifest-doctor.sh.
# ---------------------------------------------------------------------------
_manifest_frontmatter_field() {
  local file="$1" field="$2"
  sed -n '/^---$/,/^---$/p' "$file" 2>/dev/null \
    | grep -iE "^${field}:" \
    | head -1 \
    | sed -E "s/^[^:]*:[[:space:]]*//"
}

# ---------------------------------------------------------------------------
# manifest_role_field <dir> <role> <field>
#   Print a frontmatter field (kind/tools/domain/profile/code_blind/skills)
#   from <dir>/roles/<role>.md. Empty stdout when field is absent.
# ---------------------------------------------------------------------------
manifest_role_field() {
  local dir="${1:?manifest_role_field: dir required}"
  local role="${2:?manifest_role_field: role required}"
  local field="${3:?manifest_role_field: field required}"
  local file="$dir/roles/$role.md"
  [ -f "$file" ] || { echo "manifest_role_field: no role file $file" >&2; return 1; }
  _manifest_frontmatter_field "$file" "$field"
}

# ---------------------------------------------------------------------------
# manifest_role_prompt <dir> <role>
#   Print the system-prompt body (everything after the closing ---) of
#   <dir>/roles/<role>.md. Does not include frontmatter. Returns 1 if file missing.
# ---------------------------------------------------------------------------
manifest_role_prompt() {
  local dir="${1:?manifest_role_prompt: dir required}"
  local role="${2:?manifest_role_prompt: role required}"
  local file="$dir/roles/$role.md"
  [ -f "$file" ] || { echo "manifest_role_prompt: no role file $file" >&2; return 1; }
  # Skip past the second --- delimiter (end of frontmatter), print the rest.
  awk 'BEGIN{dashes=0} /^---$/{dashes++; if(dashes==2){found=1; next}} found{print}' "$file"
}

# ---------------------------------------------------------------------------
# manifest_role_profile <dir> <role>
#   Print the `profile` frontmatter field of <dir>/roles/<role>.md.
#   If the field is absent or empty, fall back to the `kind` field (default
#   per manifest-spec.ru.md: "profile — ссылка на sandbox-профиль; по умолчанию = kind").
# ---------------------------------------------------------------------------
manifest_role_profile() {
  local dir="${1:?manifest_role_profile: dir required}"
  local role="${2:?manifest_role_profile: role required}"
  local file="$dir/roles/$role.md"
  [ -f "$file" ] || { echo "manifest_role_profile: no role file $file" >&2; return 1; }
  local profile
  profile="$(_manifest_frontmatter_field "$file" "profile")"
  if [ -n "$profile" ]; then
    printf '%s\n' "$profile"
  else
    _manifest_frontmatter_field "$file" "kind"
  fi
}
