#!/usr/bin/env bash
# Round 3b / net1: netns ON (no --disable_clone_newnet), no proxy.
# Expect: lo only, lo is UP, zero egress, DNS dead.
set -u
exec > /tmp/cbnet/net1.out 2>&1
/usr/local/bin/nsjail -Mo \
  --rlimit_as max --rlimit_cpu max --rlimit_fsize max --rlimit_nofile 8192 \
  -R /usr -R /bin -R /lib -R /lib64 -R /sbin -R /etc -R /run/systemd/resolve \
  -R /home/ec2-user/.local \
  -B /dev \
  -m none:/tmp:tmpfs:size=64M \
  -e --env HOME=/home/ec2-user --cwd /tmp \
  --really_quiet \
  -- /bin/bash -c '
echo "== ip addr =="; ip addr
echo "== curl https://example.com (expect fail) =="
curl -m 8 -sS https://example.com -o /dev/null; echo rc=$?
echo "== curl https://1.1.1.1 (expect fail) =="
curl -m 8 -sS https://1.1.1.1 -o /dev/null; echo rc=$?
echo "== getent hosts example.com (expect fail) =="
timeout 6 getent hosts example.com; echo rc=$?
echo "== loopback self-test: python bind+connect 127.0.0.1 =="
python3 -c "
import socket
s=socket.socket(); s.bind((\"127.0.0.1\",0)); s.listen(1)
c=socket.socket(); c.connect(s.getsockname()); print(\"lo-ok\")
"
'
echo "jail_rc=$?"
