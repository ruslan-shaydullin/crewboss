#!/usr/bin/env bash
#
# gate-comment-payload.test.sh — P1.5 regression tests: "gate false-deny quoted-payload".
# Verifies that GATED-verb matching does NOT trigger on --body/--title content (false-deny),
# and that real gated commands and chaining are still denied (anti-weakening).
# Class iii — Layer-A/B; PreToolUse-JSON on stdin (same harness as gate-layer-a.test.sh).
#
# Run: bash reference/tests/gate-comment-payload.test.sh
# Requires: jq, bash.

HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$HERE/../.claude/hooks/crewboss-gate.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"
pass=0; fail=0

# run <expected_exit> <role> <command> [tool]
run() {
  local exp="$1" role="$2" command="$3" tool="${4:-Bash}" json code
  json="$(jq -nc --arg t "$tool" --arg r "$role" --arg c "$command" \
    '{tool_name:$t, agent_type:$r, tool_input:{command:$c}}')"
  printf '%s' "$json" | PATH="$BIN:$PATH" bash "$GATE" >/dev/null 2>&1; code=$?
  if [ "$code" = "$exp" ]; then
    printf 'ok   exp=%s [%-12s] %s\n' "$exp" "$role" "$(printf '%s' "$command" | head -c 80)"; pass=$((pass+1))
  else
    printf 'FAIL exp=%s got=%s [%-12s] %s\n' "$exp" "$code" "$role" "$(printf '%s' "$command" | head -c 80)"; fail=$((fail+1))
  fi
}

# ── gh stub: returns REVIEW_REQUIRED (not approved) for Layer-B anti-weakening tests ──
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '{"reviewDecision":"REVIEW_REQUIRED","statusCheckRollup":[{"conclusion":"SUCCESS"}]}'
STUB
chmod +x "$BIN/gh"

# ── RED-a: analyst comment, --body contains a CONTACT gh+verb phrase in backtick-quotes ──
# Before fix: canon() strips quotes → "gh pr merge" floats into canonical form → Layer A deny
#             (executor-level role check fires on the body's cited command, not the actual command).
# After fix: strip_payload() removes --body value before canon() → only "gh issue comment" is
#            visible in cmdc → not a gated verb → exit 0.
echo "== RED-a: comment --body quoting a contact gated verb → must allow (exit 0) =="
run 0 analyst \
  'gh issue comment 5 --body "интегратор зовёт `gh pr merge 5 --squash` после зелёных чеков"'

# Also verify with double-quoted body (no backtick, just inline text):
run 0 analyst \
  'gh issue comment 5 --body "next step: gh pr merge 5 --squash when checks are green"'

# ── RED-b: tech-lead comment with multiline markdown body ──
# Body contains backticks (triggers has_sep), newlines (triggers has_newline), and cited gated
# verbs. Before fix: has_newline + GATED-match on body content → deny.
# After fix: strip_payload removes body → cmdc has no GATED match → exit 0.
echo "== RED-b: multiline markdown body with backticks/pipes/cited verbs → must allow (exit 0) =="
body="$(printf 'Анализ результатов:\n- шаг 1: `gh pr merge 5 --squash`\n- шаг 2: gh issue close 7\n\n| шаг | verb |\n|------|------|\n| merge | gh pr merge |')"
run 0 tech-lead "$(printf 'gh issue comment 7 --body "%s"' "$body")"

# Same scenario, role=analyst (comment is non-gated for any role):
run 0 analyst "$(printf 'gh issue comment 5 --body "%s"' "$body")"

# ── RED-c: anti-weakening — real gated commands must still be denied ──
echo "== RED-c: anti-weakening — real gated chains still exit 2 =="

# Real chain: comment + merge via && — gh pr merge IS in command position (after &&), not payload
run 2 executor \
  'gh issue comment 5 -b "summary" && gh pr merge 5'

# Wrong role: executor cannot merge (Layer A)
run 2 executor \
  'gh pr merge 5'

# Right role (tech-lead), but NOT APPROVED → Layer B deny (stub returns REVIEW_REQUIRED)
run 2 tech-lead \
  'gh pr merge 7'

# Chain with gated verb inside body AND real gated verb after separator — still deny
run 2 executor \
  'gh issue comment 5 --body "gh pr merge 3 done" && gh pr merge 5'

echo
echo "passed=$pass failed=$fail"
[ "$fail" = "0" ]
