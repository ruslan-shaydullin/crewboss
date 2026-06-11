#!/usr/bin/env bash
# Round 3b / net3: claude smoke through netns + proxy.
# Changes vs validated 3a recipe: netns ON, proxy env, /run/systemd/resolve DROPPED
# (proxy resolves DNS on host; jail needs no resolver).
set -u
source /home/ec2-user/.crewboss.env
export CLAUDE_CODE_OAUTH_TOKEN
cd /tmp/cbnet
pkill -f 'python3 /tmp/cbnet/proxy.py' 2>/dev/null; sleep 0.3
rm -f proxy.sock; : > proxy.log
nohup python3 /tmp/cbnet/proxy.py /tmp/cbnet/proxy.sock >/tmp/cbnet/proxy.out 2>&1 &
for i in $(seq 1 50); do [ -S proxy.sock ] && break; sleep 0.1; done
[ -S proxy.sock ] || { echo "proxy failed to start"; exit 1; }
exec > /tmp/cbnet/net3.out 2>&1
time /usr/local/bin/nsjail -Mo \
  --rlimit_as max --rlimit_cpu max --rlimit_fsize max --rlimit_nofile 8192 \
  -R /usr -R /bin -R /lib -R /lib64 -R /sbin -R /etc \
  -R /home/ec2-user/.local \
  -B /home/ec2-user/.claude -B /home/ec2-user/.claude.json -B /dev \
  -B /tmp/cbnet:/cbnet \
  -m none:/tmp:tmpfs:size=256M \
  -e --env HOME=/home/ec2-user --cwd /tmp \
  --env CLAUDE_CODE_OAUTH_TOKEN \
  --env HTTPS_PROXY=http://127.0.0.1:3128 --env https_proxy=http://127.0.0.1:3128 \
  --env HTTP_PROXY=http://127.0.0.1:3128 --env http_proxy=http://127.0.0.1:3128 \
  --env NO_PROXY=localhost,127.0.0.1 --env no_proxy=localhost,127.0.0.1 \
  --env CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
  --really_quiet \
  -- /bin/bash -c '
python3 /cbnet/bridge.py /cbnet/proxy.sock 3128 &
for i in $(seq 1 50); do (echo >/dev/tcp/127.0.0.1/3128) 2>/dev/null && break; sleep 0.1; done
exec /home/ec2-user/.local/bin/claude -p "Reply with exactly: OK" --dangerously-skip-permissions --output-format json'
echo "jail_rc=$?"
