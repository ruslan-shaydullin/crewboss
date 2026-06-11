#!/usr/bin/env bash
# manifest-lib.test.sh — deterministic tests for reference/launcher/manifest.sh.
# Runs entirely against team-example/ (no network). Pattern mirrors launchable.test.sh.
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../launcher/manifest.sh"
TEAM="$HERE/../../team-example"

# shellcheck source=../launcher/manifest.sh
source "$LIB" || { echo "FATAL: cannot source $LIB"; exit 2; }

pass=0; fail=0

ok()   { printf 'ok   %s\n' "$*"; pass=$((pass+1)); }
fail() { printf 'FAIL %s\n' "$*"; fail=$((fail+1)); }

check_eq() {
  local label="$1" got="$2" exp="$3"
  if [ "$got" = "$exp" ]; then ok "$label: [$got]"
  else fail "$label: got=[$got] exp=[$exp]"; fi
}

check_nonempty() {
  local label="$1" val="$2"
  if [ -n "$val" ]; then ok "$label: non-empty"
  else fail "$label: expected non-empty, got empty"; fi
}

check_exit0() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$label: exit 0"
  else fail "$label: expected exit 0 but got non-zero"; fi
}

check_exitfail() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then fail "$label: expected non-zero exit but got 0"
  else ok "$label: non-zero exit as expected"; fi
}

# ---------------------------------------------------------------------------
echo "== manifest_validate =="

check_exit0 "validate team-example" manifest_validate "$TEAM"

# Broken manifest: two roots in nodes (violates "exactly one root" invariant).
TMPDIR_BROKEN="$(mktemp -d)"
cp -r "$TEAM"/* "$TMPDIR_BROKEN"/
# Patch org.json: set reports_to of 'cto' from null to some non-existent parent
# so there is no root, OR add a second root (reports_to=null on another node).
# Easiest: set solution-analyst.reports_to = null (adds a second root).
jq '.nodes = [.nodes[] | if .role == "solution-analyst" then .reports_to = null else . end]' \
  "$TEAM/org.json" > "$TMPDIR_BROKEN/org.json"
check_exitfail "validate broken manifest (two roots)" manifest_validate "$TMPDIR_BROKEN"
rm -rf "$TMPDIR_BROKEN"

# ---------------------------------------------------------------------------
echo "== manifest_policy =="

SM="$(manifest_policy "$TEAM" span_max)"
check_eq "span_max" "$SM" "5"

AR="$(manifest_policy "$TEAM" approval_role)"
check_eq "approval_role" "$AR" "cto"

HA="$(manifest_policy "$TEAM" human_approval_above_usd)"
check_eq "human_approval_above_usd" "$HA" "1.00"

# Unknown key → empty output (no error message on stdout), non-zero or empty is ok.
UNK="$(manifest_policy "$TEAM" no_such_key 2>/dev/null)"
check_eq "unknown policy key → empty" "$UNK" ""

# ---------------------------------------------------------------------------
echo "== manifest_analysis_roles =="

AROLES="$(manifest_analysis_roles "$TEAM")"
check_eq "analysis_roles" "$AROLES" "solution-analyst"

# ---------------------------------------------------------------------------
echo "== manifest_roles =="

ROLES="$(manifest_roles "$TEAM" | sort)"
check_nonempty "manifest_roles non-empty" "$ROLES"
# solution-analyst and go-backend-dev must be in the list
if printf '%s\n' "$ROLES" | grep -q "^solution-analyst$"; then ok "manifest_roles contains solution-analyst"
else fail "manifest_roles missing solution-analyst"; fi
if printf '%s\n' "$ROLES" | grep -q "^go-backend-dev$"; then ok "manifest_roles contains go-backend-dev"
else fail "manifest_roles missing go-backend-dev"; fi

# ---------------------------------------------------------------------------
echo "== manifest_role_field =="

KIND_SA="$(manifest_role_field "$TEAM" solution-analyst kind)"
check_eq "solution-analyst kind" "$KIND_SA" "analyst"

TOOLS_SA="$(manifest_role_field "$TEAM" solution-analyst tools)"
check_eq "solution-analyst tools" "$TOOLS_SA" "Read, Bash"

KIND_GBD="$(manifest_role_field "$TEAM" go-backend-dev kind)"
check_eq "go-backend-dev kind" "$KIND_GBD" "executor"

TOOLS_GBD="$(manifest_role_field "$TEAM" go-backend-dev tools)"
check_eq "go-backend-dev tools" "$TOOLS_GBD" "Read, Edit, Write, Bash"

# Missing field → empty stdout
CB_SA="$(manifest_role_field "$TEAM" solution-analyst code_blind 2>/dev/null)"
check_eq "solution-analyst code_blind (absent) → empty" "$CB_SA" ""

# ---------------------------------------------------------------------------
echo "== manifest_role_prompt =="

PROMPT_SA="$(manifest_role_prompt "$TEAM" solution-analyst)"
check_nonempty "solution-analyst prompt non-empty" "$PROMPT_SA"

# Must not contain a frontmatter delimiter.
if printf '%s\n' "$PROMPT_SA" | grep -q "^---$"; then
  fail "solution-analyst prompt contains frontmatter delimiter"
else
  ok "solution-analyst prompt has no frontmatter"
fi

# Must not contain frontmatter field lines (e.g. "kind: analyst").
if printf '%s\n' "$PROMPT_SA" | grep -qE "^kind:"; then
  fail "solution-analyst prompt leaks frontmatter field 'kind'"
else
  ok "solution-analyst prompt has no frontmatter fields"
fi

PROMPT_GBD="$(manifest_role_prompt "$TEAM" go-backend-dev)"
check_nonempty "go-backend-dev prompt non-empty" "$PROMPT_GBD"

# ---------------------------------------------------------------------------
echo "== manifest_role_profile =="

# Explicit profile field present.
PROF_SA="$(manifest_role_profile "$TEAM" solution-analyst)"
check_eq "solution-analyst profile (explicit)" "$PROF_SA" "analyst"

PROF_GBD="$(manifest_role_profile "$TEAM" go-backend-dev)"
check_eq "go-backend-dev profile (explicit)" "$PROF_GBD" "executor"

# Default fallback: create a tmp role without a profile field, expect kind as default.
TMPDIR_ROLE="$(mktemp -d)"
mkdir -p "$TMPDIR_ROLE/roles"
cat > "$TMPDIR_ROLE/roles/noprofile-executor.md" <<'EOF'
---
name: noprofile-executor
kind: executor
domain: test
tools: Read, Edit, Write, Bash
---
A test executor role with no profile field, to verify the fallback.
EOF
PROF_NP="$(manifest_role_profile "$TMPDIR_ROLE" noprofile-executor)"
check_eq "role without profile → default to kind" "$PROF_NP" "executor"
rm -rf "$TMPDIR_ROLE"

# ---------------------------------------------------------------------------
echo
echo "passed=$pass failed=$fail"
[ "$fail" = "0" ]
