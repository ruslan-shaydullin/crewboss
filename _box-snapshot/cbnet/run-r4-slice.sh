#!/usr/bin/env bash
# Round 4: full edit->PR slice with the jail hardened by ALL THREE layers at once
# (FS 3a + net 3b + seccomp 3c). claude edits inside the tight jail; the host-side
# floor (trusted, deterministic) does mirror/clone/push/PR over the host network.
set -uo pipefail
source /home/ec2-user/.crewboss.env; export CLAUDE_CODE_OAUTH_TOKEN
GH_TOKEN=$(gh auth token); export GH_TOKEN
OWNER=stratch1989; REPO=crewboss-proto
TS=$(date +%s)
B=/tmp/cbnet/r4slice; rm -rf "$B"; mkdir -p "$B"
cd /tmp/cbnet

echo "=== 1. issue ==="
ISSUE=$(gh issue create -R $OWNER/$REPO -t "r4 tight-jail slice $TS" -b "claude appends a line to README inside FS+net+seccomp jail" | grep -oE '[0-9]+$' | tail -1)
echo "issue=#$ISSUE"

echo "=== 2. mirror + local clone + push-fix + branch ==="
git clone --mirror https://github.com/$OWNER/$REPO.git "$B/mirror.git" 2>&1 | tail -1
git clone --local "$B/mirror.git" "$B/work" 2>&1 | tail -1
cd "$B/work"
git remote set-url --push origin "https://x-access-token:${GH_TOKEN}@github.com/$OWNER/$REPO.git"
BR="task/r4-$TS"
git checkout -q -b "$BR"
echo "branch=$BR push-url=$(git remote get-url --push origin | sed 's#token:[^@]*@#token:REDACTED@#')"

echo "=== 3. claude edits inside FULLY-HARDENED jail (FS+net+seccomp KILL_PROCESS) ==="
cd /tmp/cbnet
pkill -f 'proxy.py /tmp/cbnet' 2>/dev/null; sleep 0.3
rm -f proxy.sock; : > proxy.log
nohup python3 /tmp/cbnet/proxy.py /tmp/cbnet/proxy.sock > proxy.out 2>&1 &
PROXY=$!
for i in $(seq 1 50); do [ -S proxy.sock ] && break; sleep 0.1; done
RO="-R /usr -R /bin -R /lib -R /lib64 -R /sbin -R /etc -R /home/ec2-user/.local"
PE="--env HTTPS_PROXY=http://127.0.0.1:3128 --env https_proxy=http://127.0.0.1:3128 --env NO_PROXY=localhost,127.0.0.1 --env no_proxy=localhost,127.0.0.1"
set +e
timeout 180 /usr/local/bin/nsjail -Mo \
  --rlimit_as max --rlimit_cpu max --rlimit_fsize max --rlimit_nofile 8192 \
  --seccomp_policy /tmp/cbnet/claude.kafel --seccomp_log \
  $RO -B /home/ec2-user/.claude -B /home/ec2-user/.claude.json -B /dev -B /tmp/cbnet:/cbnet \
  -B "$B/work:/work" \
  -m none:/tmp:tmpfs:size=256M -e --env HOME=/home/ec2-user --cwd /work \
  --env CLAUDE_CODE_OAUTH_TOKEN $PE --env CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 --really_quiet \
  -- /bin/bash /cbnet/payload-edit.sh
AGRC=$?
set -e
kill "$PROXY" 2>/dev/null
echo "agent jail rc=$AGRC result=$(jq -r .result /tmp/cbnet/r4-edit.run 2>/dev/null | head -c 60) is_error=$(jq -r .is_error /tmp/cbnet/r4-edit.run 2>/dev/null) cost=$(jq -r .total_cost_usd /tmp/cbnet/r4-edit.run 2>/dev/null)"

echo "=== 4. floor: diff + commit + push + PR ==="
cd "$B/work"
git --no-pager diff --stat
if git diff --quiet; then echo "NO CHANGES — abort"; gh issue close "$ISSUE" -R $OWNER/$REPO >/dev/null 2>&1; exit 1; fi
git -c user.email=crewboss@local -c user.name=crewboss commit -aqm "r4: append line via tight-jail claude (closes #$ISSUE)"
git push -q origin "$BR" 2>&1 | tail -1
PR=$(gh pr create -R $OWNER/$REPO -H "$BR" -t "r4 tight-jail slice $TS" -b "Edited by claude inside FS+net+seccomp jail. Closes #$ISSUE." 2>&1 | grep -oE 'https://[^ ]+/pull/[0-9]+' | tail -1)
echo "PR=$PR"
echo "=== done ==="
