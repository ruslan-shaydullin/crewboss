#!/usr/bin/env bash
#
# independent-test-authorship.test.sh — gate assertions for independent test authorship
# (charter #523). Verifies that crewboss-gate.sh denies executor from writing test files
# via Edit, Write, and MultiEdit tools.
#
# Key facts validated here:
#   - All three tools (Edit, Write, MultiEdit) expose the target path at
#     tool_input.file_path at the top level.
#   - tool_input.edits[].file_path is null on real MultiEdit payloads; top-level
#     file_path is the reliable field.
#   - Protected patterns: *.test.sh, *.test.ts, paths under tests/ directory.
#   - Non-test paths (e.g. src/tests-utils.ts) must not be false-denied.
#
# Assertions:
#   (a) Gate blocks executor from editing test files via Edit, Write, MultiEdit.
#   (c) verify-merged presence check: this file exists on disk.
#
# Assertion (b) gh-pr-ready interlock is intentionally omitted — enforced
#   structurally by launcher Depends-on; no gate extension needed.
#
# Class ALLOW: verdict = pure function of merged content (pure stdin JSON against
#   gate binary, no network, no gh-shim). No launcher loops, no background processes,
#   no timing/poll/sleep. Meets ALLOW criterion (reference/runtime/per-leaf-manifest).
#
# Run: bash reference/tests/independent-test-authorship.test.sh
# Requires: jq, bash.

HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$HERE/../.claude/hooks/crewboss-gate.sh"
pass=0; fail=0

ok() { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko() { fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

# run_file <tool_name> <role> <file_path> <expected_exit>
run_file() {
  local tool="$1" role="$2" fp="$3" exp="$4" json code
  json="$(jq -nc --arg t "$tool" --arg r "$role" --arg p "$fp" \
    '{tool_name:$t, agent_type:$r, tool_input:{file_path:$p}}')"
  printf '%s' "$json" | bash "$GATE" >/dev/null 2>&1; code=$?
  if [ "$code" = "$exp" ]; then
    ok "exit=$exp [$tool/role=$role] $fp"
  else
    ko "exit=$exp got=$code [$tool/role=$role] $fp"
  fi
}

# =============================================================================
# (a) Gate blocks executor from editing test files via Edit, Write, MultiEdit
# =============================================================================
echo "== (a) executor denied: Edit to protected test paths =="
run_file Edit executor "foo.test.sh"                        2
run_file Edit executor "foo.test.ts"                        2
run_file Edit executor "src/tests/bar.sh"                   2
run_file Edit executor "reference/tests/baz.test.sh"        2

echo "== (a) executor denied: Write to protected test paths =="
run_file Write executor "foo.test.sh"                       2
run_file Write executor "foo.test.ts"                       2
run_file Write executor "src/tests/bar.sh"                  2
run_file Write executor "reference/tests/baz.test.sh"       2

echo "== (a) executor denied: MultiEdit to protected test paths =="
run_file MultiEdit executor "foo.test.sh"                   2
run_file MultiEdit executor "foo.test.ts"                   2
run_file MultiEdit executor "src/tests/bar.sh"              2
run_file MultiEdit executor "reference/tests/baz.test.sh"   2

echo "== (a) no false-deny: legitimate executor paths exit 0 =="
run_file Edit    executor "src/tests-utils.ts"              0
run_file Write   executor "src/impl.ts"                     0
run_file Edit    executor "src/main.sh"                     0
run_file Write   executor "reference/runtime/per-leaf-manifest" 0
run_file MultiEdit executor "src/app.py"                    0

echo "== (a) non-executor roles: qa-engineer may write test files =="
run_file Edit    qa-engineer "foo.test.sh"                  0
run_file Write   qa-engineer "reference/tests/foo.test.sh"  0
run_file MultiEdit tech-lead "src/tests/bar.sh"             0

# =============================================================================
# (c) verify-merged presence check
# =============================================================================
echo "== (c) verify-merged presence check =="
[ -f "$HERE/independent-test-authorship.test.sh" ] \
  && ok "presence: reference/tests/independent-test-authorship.test.sh exists on disk" \
  || ko "presence: reference/tests/independent-test-authorship.test.sh missing"

# =============================================================================
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
