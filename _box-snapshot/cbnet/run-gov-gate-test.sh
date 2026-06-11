#!/usr/bin/env bash
# Test A (free): the crewboss PreToolUse gate runs INSIDE the hardened jail (FS+net+seccomp)
# and enforces nail-2 — executor cannot merge/author-board; benign edits/push pass; canon()
# catches in-model obfuscations. Pure stdin->exit-code; Layer A needs no network.
set -u
cd /tmp/cbnet
GATE=/cbnet/gov/.claude/hooks/crewboss-gate.sh
pass=0; fail=0
ok(){ echo "  PASS $1"; pass=$((pass+1)); }
no(){ echo "  FAIL $1 (got rc=$2)"; fail=$((fail+1)); }

# run one PreToolUse json through the gate inside the jail; echo the exit code
gate(){ # role, command  -> prints rc
  local role="$1" cmd="$2"
  local json; json=$(jq -nc --arg r "$role" --arg c "$cmd" '{tool_name:"Bash",agent_type:$r,tool_input:{command:$c}}')
  timeout 30 /usr/local/bin/nsjail -Mo --disable_clone_newnet \
    --rlimit_as max --rlimit_cpu max --rlimit_fsize max --rlimit_nofile 8192 \
    --seccomp_policy /tmp/cbnet/claude.kafel \
    -R /usr -R /bin -R /lib -R /lib64 -R /sbin -R /etc -B /dev -B /tmp/cbnet:/cbnet \
    -m none:/tmp:tmpfs:size=64M -e --env HOME=/tmp --cwd /tmp --really_quiet \
    -- /bin/bash -c "printf '%s' '$json' | $GATE >/dev/null 2>&1; echo \$?"
}
deny(){ local rc; rc=$(gate "$1" "$2"); [ "$rc" = "2" ] && ok "DENY [$1] $2" || no "expected DENY [$1] $2" "$rc"; }
allow(){ local rc; rc=$(gate "$1" "$2"); [ "$rc" = "0" ] && ok "ALLOW [$1] $2" || no "expected ALLOW [$1] $2" "$rc"; }

echo "=== executor: merge / board-authorship DENIED (Layer A, nail-2) ==="
deny  executor "gh pr merge 1"
deny  executor "gh issue close 5"
deny  executor "gh issue create -t x -b y"
deny  executor "gh pr ready 1"

echo "=== executor: obfuscations folded by canon() -> still DENIED ==="
deny  executor 'gh pr "merge" 1'
deny  executor "command gh pr merge 1"
deny  executor "/usr/bin/gh pr merge 1"
deny  executor "gh -R o/r pr merge 1"
deny  executor "gh api -X PUT repos/o/r/pulls/1/merge"
deny  executor "echo hi && gh pr merge 1"

echo "=== executor: legitimate work ALLOWED (push not gated; edits/commits fine) ==="
allow executor "git push origin task/42"
allow executor "git commit -m 'work'"
allow executor "git add -A"
allow executor "gh pr view 1"

echo "=== SUMMARY: $pass passed, $fail failed ==="
echo "=== done ==="
