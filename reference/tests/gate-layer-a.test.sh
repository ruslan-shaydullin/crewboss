#!/usr/bin/env bash
#
# Layer-A (role-gating) test harness for crewboss-gate.sh.
# Deterministic: only exercises paths that DECIDE BEFORE any gh/network call —
# i.e. Layer-A denials, allowed pass-throughs, and tech-lead board-authorship
# that is not under a Layer-B proof gate. The Layer-B proof gates (merge / ready /
# close) require live gh and are validated in the sandbox demo (spinout-plan
# workstream H), not here.
#
# Requires: jq, bash. Run: bash tests/gate-layer-a.test.sh

HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$HERE/../.claude/hooks/crewboss-gate.sh"
pass=0; fail=0

# run <expected_exit> <role> <command> [tool]
run() {
  local exp="$1" role="$2" command="$3" tool="${4:-Bash}" json code
  json="$(jq -nc --arg t "$tool" --arg r "$role" --arg c "$command" \
    '{tool_name:$t, agent_type:$r, tool_input:{command:$c}}')"
  printf '%s' "$json" | bash "$GATE" >/dev/null 2>&1; code=$?
  if [ "$code" = "$exp" ]; then
    printf 'ok   exp=%s [%-12s] %s\n' "$exp" "$role" "$command"; pass=$((pass+1))
  else
    printf 'FAIL exp=%s got=%s [%-12s] %s\n' "$exp" "$code" "$role" "$command"; fail=$((fail+1))
  fi
}

echo "== deny (exit 2): escalation attempted by the wrong role =="
run 2 executor      "gh pr merge 5"
run 2 executor      "gh issue create -t x -b y"
run 2 task-helper   "gh issue create -t x"
run 2 task-helper   "gh pr merge 5"
run 2 dev-assistant "gh issue close 3"
run 2 executor      "gh label create foo"
run 2 ""            "gh issue create -t x"   # empty agent_type => default dev-assistant

echo "== allow (exit 0): tech-lead board authorship not under a Layer-B gate =="
run 0 tech-lead     "gh issue create -t x -b y"
run 0 tech-lead     "gh label create foo"
run 0 tech-lead     "gh issue reopen 3"

echo "== allow (exit 0): non-gated commands, any role =="
run 0 task-helper   "gh issue comment 3 -b hi"
run 0 task-helper   "gh issue edit 3 --add-label triage"
run 0 executor      "git commit -m wip"
run 0 dev-assistant "gh pr view 3"

echo "== allow (exit 0): non-Bash tool short-circuits =="
run 0 executor      "irrelevant" Edit

echo "== boss: code-blind + exec-blind (allowlist) =="
run 0 boss          "gh issue create -t goal -b why"
run 0 boss          "gh issue comment 27 -b note"
run 0 boss          "gh issue view 30"
run 2 boss          "gh pr merge 5"
run 2 boss          "git push origin main"
run 2 boss          "cat quarter-ts/src/index.ts"
run 2 boss          "gh issue create -t x && cat src/x"

echo "== analyst: read-only investigator (Layer A, like other non-tech-lead) =="
run 0 analyst       "gh issue comment 5 -b findings"
run 2 analyst       "gh issue create -t x"
run 2 analyst       "gh pr merge 5"

echo "== red-team hardening negatives =="
run 2 tech-lead     "gh pr merge 1 && gh pr merge 2"
run 2 executor      "gh  pr  merge 5"
run 2 boss          "git log -p"
run 0 boss          "git log --oneline"
run 2 boss          "gh issue create -t x -b y > /tmp/z"
run 2 boss          "$(printf 'gh issue view 3\nrm -rf /tmp/zz')"

echo "== in-model verb variants: canon() must fold these to the literal verb (DENY) =="
run 2 executor      'gh pr "merge" 5'                                   # quoting the verb
run 2 executor      "gh pr mer'g'e 5"                                   # split-quote verb
run 2 executor      "gh p\"\"r merge 5"                                 # empty-quote split
run 2 executor      "gh -R o/r pr merge 5"                              # gh global flag (-R val)
run 2 executor      "gh --repo o/r pr merge 5"                          # gh global flag (--repo val)
run 2 executor      "command gh pr merge 5"                             # benign command prefix
run 2 executor      "/usr/bin/gh pr merge 5"                            # path-qualified program
run 2 executor      "gh api -X PUT repos/o/r/pulls/5/merge"            # REST merge -> tech-lead-only (Layer A pre-network)
run 2 executor      "gh api --method PATCH repos/o/r/issues/5 -f state=closed"  # REST close -> tech-lead-only

echo "== boundary: adversarial evasion is INTENTIONALLY out of model (still slips, exit 0) =="
run 0 executor      'gh${IFS}pr${IFS}merge 5'                           # param-expansion — documented non-goal (header SCOPE)

echo "== positive guards: canon() must NOT false-deny legit commands =="
run 0 tech-lead     'gh issue create --title "merge the feature"'      # gated verb word inside a quoted value, but role ok
run 0 executor      "gh -R o/r pr view 5"                               # global flag + non-gated subcommand
run 0 executor      "gh api repos/o/r/issues"                          # api GET (list) — must NOT become 'issue create'
run 0 executor      "git commit -m \"merge main into feature\""        # 'merge' in a git commit msg, not gh
run 0 dev-assistant "gh pr view 5"                                      # plain read

echo
echo "passed=$pass failed=$fail"
[ "$fail" = "0" ]
