#!/usr/bin/env bash
# Round 3c discovery v3: trace the ENTIRE in-jail bash payload (bash + python bridge
# + claude / git+gh). v2 missed python(bridge) since it backgrounded before strace.
set -u
source /home/ec2-user/.crewboss.env
export CLAUDE_CODE_OAUTH_TOKEN
GH_TOKEN=$(gh auth token); export GH_TOKEN
cd /tmp/cbnet
pkill -f 'proxy.py /tmp/cbnet' 2>/dev/null; sleep 0.3
rm -f proxy.sock; : > proxy.log
nohup python3 /tmp/cbnet/proxy.py /tmp/cbnet/proxy.sock > proxy.out 2>&1 &
PROXY=$!
for i in $(seq 1 50); do [ -S proxy.sock ] && break; sleep 0.1; done

COMMON_RO="-R /usr -R /bin -R /lib -R /lib64 -R /sbin -R /etc -R /home/ec2-user/.local"
PROXENV="--env HTTPS_PROXY=http://127.0.0.1:3128 --env https_proxy=http://127.0.0.1:3128 --env NO_PROXY=localhost,127.0.0.1 --env no_proxy=localhost,127.0.0.1"

# Payloads (run under strace -f via /cbnet/payload-*.sh inside jail)
cat > /tmp/cbnet/payload-claude.sh <<'P'
python3 /cbnet/bridge.py /cbnet/proxy.sock 3128 &
BR=$!
for i in $(seq 1 50); do (echo >/dev/tcp/127.0.0.1/3128) 2>/dev/null && break; sleep 0.1; done
/home/ec2-user/.local/bin/claude -p "Reply with exactly: OK" --dangerously-skip-permissions --output-format json > /cbnet/sc-claude.run 2>&1
kill $BR 2>/dev/null
P
cat > /tmp/cbnet/payload-git.sh <<'P'
python3 /cbnet/bridge.py /cbnet/proxy.sock 3128 &
BR=$!
for i in $(seq 1 50); do (echo >/dev/tcp/127.0.0.1/3128) 2>/dev/null && break; sleep 0.1; done
GIT_TERMINAL_PROMPT=0 git clone --depth 1 "https://x-access-token:${GH_TOKEN}@github.com/stratch1989/crewboss-proto.git" /tmp/r
cd /tmp/r && git -c user.email=c@l -c user.name=c commit --allow-empty -m sc-probe
git push origin HEAD:refs/heads/sc-probe && git push origin :refs/heads/sc-probe
gh repo view stratch1989/crewboss-proto --json name -q .name
kill $BR 2>/dev/null
P

echo "=== A: full claude payload under strace ==="
timeout 180 /usr/local/bin/nsjail -Mo \
  --rlimit_as max --rlimit_cpu max --rlimit_fsize max --rlimit_nofile 8192 \
  $COMMON_RO -B /home/ec2-user/.claude -B /home/ec2-user/.claude.json -B /dev -B /tmp/cbnet:/cbnet \
  -m none:/tmp:tmpfs:size=256M -e --env HOME=/home/ec2-user --cwd /tmp \
  --env CLAUDE_CODE_OAUTH_TOKEN $PROXENV --env CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 --really_quiet \
  -- /usr/bin/strace -f -qq -c -U name -o /cbnet/sc-claude.txt /bin/bash /cbnet/payload-claude.sh > /dev/null 2>&1
echo "A rc=$? result=$(jq -r .result /tmp/cbnet/sc-claude.run 2>/dev/null) lines=$(wc -l < /tmp/cbnet/sc-claude.txt 2>/dev/null)"

echo "=== B: full git payload under strace ==="
timeout 180 /usr/local/bin/nsjail -Mo \
  --rlimit_as max --rlimit_cpu max --rlimit_fsize max --rlimit_nofile 8192 \
  $COMMON_RO -B /dev -B /tmp/cbnet:/cbnet \
  -m none:/tmp:tmpfs:size=128M -e --env HOME=/tmp --cwd /tmp \
  --env GH_TOKEN $PROXENV --really_quiet \
  -- /usr/bin/strace -f -qq -c -U name -o /cbnet/sc-git.txt /bin/bash /cbnet/payload-git.sh > /tmp/cbnet/sc-git.run 2>&1
echo "B rc=$? lines=$(wc -l < /tmp/cbnet/sc-git.txt 2>/dev/null)"

kill "$PROXY" 2>/dev/null
filt(){ grep -E '^[a-z][a-z0-9_]+$' "$1" | grep -vxE 'syscall|total'; }
filt /tmp/cbnet/sc-claude.txt | sort -u > /tmp/cbnet/sc-claude.list
filt /tmp/cbnet/sc-git.txt    | sort -u > /tmp/cbnet/sc-git.list
cat /tmp/cbnet/sc-claude.list /tmp/cbnet/sc-git.list | sort -u > /tmp/cbnet/sc-union.list
echo "claude=$(wc -l < /tmp/cbnet/sc-claude.list) git=$(wc -l < /tmp/cbnet/sc-git.list) union=$(wc -l < /tmp/cbnet/sc-union.list)"
echo "=== UNION ==="; tr '\n' ' ' < /tmp/cbnet/sc-union.list; echo
