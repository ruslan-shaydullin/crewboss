#!/usr/bin/env bash
# role-model-policy.test.sh — assert every agent .md has a non-empty model: YAML frontmatter
# field. Covers the two-tier model policy (charter #1234 P1): zero roles left on the sonnet
# box default.
#
# Directories checked:
#   .claude/agents/            — analyst, boss, executor, facilitator, integrator, qa-engineer,
#                                solution-analyst, task-helper, tech-lead, test-planner
#   reference/.claude/agents/  — analyst, boss, executor, git-resolver, integrator, observer,
#                                role-builder, task-helper, tech-lead, test-planner
#   team-example/roles/        — 17 product roles
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

# check_model <file>
# Extracts YAML frontmatter (between the first pair of --- delimiters) and asserts a line
# matching ^model: <non-empty-value> is present.
check_model() {
  local f="$1"
  local rel="${f#$REPO_ROOT/}"
  local model_line
  model_line=$(awk '
    BEGIN { in_fm=0; delim=0 }
    /^---[[:space:]]*$/ {
      delim++
      if (delim == 1) { in_fm=1; next }
      if (delim == 2) { in_fm=0; next }
    }
    in_fm && /^model:[[:space:]]+.+/ { print; exit }
  ' "$f" 2>/dev/null)

  if [ -n "$model_line" ]; then
    ok "$rel — $model_line"
  else
    ko "$rel — missing or empty model: field in frontmatter"
  fi
}

check_dir() {
  local dir="$1" label="$2"
  echo "=== $label ==="
  local found=0
  for f in "$dir"/*.md; do
    [ -f "$f" ] || continue
    found=1
    check_model "$f"
  done
  [ "$found" = "1" ] || printf '  (no .md files found in %s)\n' "$dir"
}

check_dir "$REPO_ROOT/.claude/agents"           ".claude/agents"
check_dir "$REPO_ROOT/reference/.claude/agents"  "reference/.claude/agents"
check_dir "$REPO_ROOT/team-example/roles"        "team-example/roles"

echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
