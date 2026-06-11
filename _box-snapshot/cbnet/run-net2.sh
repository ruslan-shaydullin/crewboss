#!/usr/bin/env bash
# Round 3b / net2: netns + unix-socket proxy + in-jail bridge, curl-level tests.
set -u
cd /tmp/cbnet
pkill -f 'python3 /tmp/cbnet/proxy.py' 2>/dev/null; sleep 0.3
rm -f proxy.sock; : > proxy.log
nohup python3 /tmp/cbnet/proxy.py /tmp/cbnet/proxy.sock >/tmp/cbnet/proxy.out 2>&1 &
for i in $(seq 1 50); do [ -S proxy.sock ] && break; sleep 0.1; done
[ -S proxy.sock ] || { echo "proxy failed to start"; cat /tmp/cbnet/proxy.out; exit 1; }
exec > /tmp/cbnet/net2.out 2>&1
/usr/local/bin/nsjail -Mo \
  --rlimit_as max --rlimit_cpu max --rlimit_fsize max --rlimit_nofile 8192 \
  -R /usr -R /bin -R /lib -R /lib64 -R /sbin -R /etc -R /run/systemd/resolve \
  -R /home/ec2-user/.local \
  -B /dev \
  -B /tmp/cbnet:/cbnet \
  -m none:/tmp:tmpfs:size=64M \
  -e --env HOME=/home/ec2-user --cwd /tmp \
  --really_quiet \
  -- /bin/bash /cbnet/jail-test.sh
echo "jail_rc=$?"
