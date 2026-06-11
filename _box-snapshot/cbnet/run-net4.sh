#!/usr/bin/env bash
# Round 3b / net4: git clone + push to github THROUGH the proxy from inside the jail.
# Throwaway repo stratch1989/crewboss-proto; pushes then deletes branch net-test-3b.
set -u
GH_TOKEN=$(gh auth token) || { echo "no gh token"; exit 1; }
export GH_TOKEN
cd /tmp/cbnet
pkill -f 'python3 /tmp/cbnet/proxy.py' 2>/dev/null; sleep 0.3
rm -f proxy.sock; : > proxy.log
nohup python3 /tmp/cbnet/proxy.py /tmp/cbnet/proxy.sock >/tmp/cbnet/proxy.out 2>&1 &
for i in $(seq 1 50); do [ -S proxy.sock ] && break; sleep 0.1; done
[ -S proxy.sock ] || { echo "proxy failed to start"; exit 1; }
exec > /tmp/cbnet/net4.out 2>&1
/usr/local/bin/nsjail -Mo \
  --rlimit_as max --rlimit_cpu max --rlimit_fsize max --rlimit_nofile 8192 \
  -R /usr -R /bin -R /lib -R /lib64 -R /sbin -R /etc \
  -R /home/ec2-user/.local \
  -B /dev \
  -B /tmp/cbnet:/cbnet \
  -m none:/tmp:tmpfs:size=64M \
  -e --env HOME=/tmp --cwd /tmp \
  --env GH_TOKEN \
  --env HTTPS_PROXY=http://127.0.0.1:3128 --env https_proxy=http://127.0.0.1:3128 \
  --env NO_PROXY=localhost,127.0.0.1 --env no_proxy=localhost,127.0.0.1 \
  --really_quiet \
  -- /bin/bash -c '
python3 /cbnet/bridge.py /cbnet/proxy.sock 3128 &
for i in $(seq 1 50); do (echo >/dev/tcp/127.0.0.1/3128) 2>/dev/null && break; sleep 0.1; done
echo "== clone via proxy =="
GIT_TERMINAL_PROMPT=0 git clone --depth 1 \
  "https://x-access-token:${GH_TOKEN}@github.com/stratch1989/crewboss-proto.git" /tmp/r 2>&1 | tail -2
echo clone_rc=$?
cd /tmp/r || exit 1
git -c user.email=crewboss@local -c user.name=crewboss commit --allow-empty -m "net-test 3b: push through egress proxy"
echo "== push via proxy =="
git push origin HEAD:refs/heads/net-test-3b 2>&1 | tail -3; echo push_rc=$?
echo "== cleanup remote branch =="
git push origin :refs/heads/net-test-3b 2>&1 | tail -2; echo del_rc=$?
'
echo "jail_rc=$?"
