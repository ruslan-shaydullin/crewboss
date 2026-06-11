#!/usr/bin/env bash
# Round 4b: the AGENT (not the floor) edits + commits + pushes + opens the PR,
# all from INSIDE the jail hardened by FS+net+seccomp(KILL), git/gh via the proxy.
# Floor only preps the repo+branch and verifies after.
set -uo pipefail
source /home/ec2-user/.crewboss.env; export CLAUDE_CODE_OAUTH_TOKEN
GH_TOKEN=$(gh auth token); export GH_TOKEN
OWNER=stratch1989; REPO=crewboss-proto
TS=$(date +%s)
B=/tmp/cbnet/r4bslice; rm -rf "$B"; mkdir -p "$B"
cd /tmp/cbnet

echo "=== 1. issue ==="
ISSUE=$(gh issue create -R $OWNER/$REPO -t "r4b executor-from-jail $TS" -b "agent itself pushes a PR from inside FS+net+seccomp jail" | grep -oE '[0-9]+$' | tail -1)
echo "issue=#$ISSUE"

echo "=== 2. floor: mirror + local clone + push-fix + branch (agent will push to it) ==="
git clone --mirror https://github.com/$OWNER/$REPO.git "$B/mirror.git" 2>&1 | tail -1
git clone --local "$B/mirror.git" "$B/work" 2>&1 | tail -1
cd "$B/work"
# push-url -> github with token so the AGENT's `git push` reaches github (fetch stays local mirror)
git remote set-url --push origin "https://x-access-token:${GH_TOKEN}@github.com/$OWNER/$REPO.git"
BR="task/r4b-$TS"
git checkout -q -b "$BR"
echo "branch=$BR fetch=$(git remote get-url origin) push=$(git remote get-url --push origin | sed 's#token:[^@]*@#token:REDACTED@#')"

echo "=== 3. AGENT does edit+commit+push+PR INSIDE hardened jail ==="
cd /tmp/cbnet
pkill -f 'proxy.py /tmp/cbnet' 2>/dev/null; sleep 0.3
rm -f proxy.sock; : > proxy.log
nohup python3 /tmp/cbnet/proxy.py /tmp/cbnet/proxy.sock > proxy.out 2>&1 &
PROXY=$!
for i in $(seq 1 50); do [ -S proxy.sock ] && break; sleep 0.1; done
RO="-R /usr -R /bin -R /lib -R /lib64 -R /sbin -R /etc -R /home/ec2-user/.local"
PE="--env HTTPS_PROXY=http://127.0.0.1:3128 --env https_proxy=http://127.0.0.1:3128 --env NO_PROXY=localhost,127.0.0.1 --env no_proxy=localhost,127.0.0.1"
set +e
timeout 240 /usr/local/bin/nsjail -Mo \
  --rlimit_as max --rlimit_cpu max --rlimit_fsize max --rlimit_nofile 8192 \
  --seccomp_policy /tmp/cbnet/claude.kafel --seccomp_log \
  $RO -B /home/ec2-user/.claude -B /home/ec2-user/.claude.json -B /dev -B /tmp/cbnet:/cbnet \
  -B "$B/work:/work" \
  -m none:/tmp:tmpfs:size=256M -e --env HOME=/home/ec2-user --cwd /work \
  --env CLAUDE_CODE_OAUTH_TOKEN --env GH_TOKEN --env GH_REPO=$OWNER/$REPO $PE \
  --env CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 --really_quiet \
  -- /bin/bash /cbnet/payload-exec.sh
AGRC=$?
set -e
kill "$PROXY" 2>/dev/null
echo "agent jail rc=$AGRC is_error=$(jq -r .is_error /tmp/cbnet/r4b-agent.run 2>/dev/null) cost=$(jq -r .total_cost_usd /tmp/cbnet/r4b-agent.run 2>/dev/null) num_turns=$(jq -r .num_turns /tmp/cbnet/r4b-agent.run 2>/dev/null)"
echo "--- agent result text ---"; jq -r .result /tmp/cbnet/r4b-agent.run 2>/dev/null | sed 's#https://[^ ]*@#https://REDACTED@#'

echo "=== 4. floor verifies the AGENT's work landed on github ==="
echo "local commits ahead:"; git -C "$B/work" --no-pager log --oneline origin/HEAD..$BR 2>/dev/null | head -3 || git -C "$B/work" --no-pager log --oneline -2
echo "remote branch on github:"; git ls-remote "https://x-access-token:${GH_TOKEN}@github.com/$OWNER/$REPO.git" "refs/heads/$BR" | sed 's#x-access-token:[^@]*@#REDACTED@#'
echo "open PRs for this branch:"; gh pr list -R $OWNER/$REPO --head "$BR" --json number,url,author -q '.[] | "PR #\(.number) \(.url) by \(.author.login)"'
echo "=== proxy egress log ==="; grep -E 'ALLOW|DENY' /tmp/cbnet/proxy.log | sort | uniq -c
echo "=== done ==="
