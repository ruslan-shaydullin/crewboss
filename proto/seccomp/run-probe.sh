#!/usr/bin/env bash
set -u
cd /tmp/cbnet
echo "=== forbidden-syscall probes under claude.kafel (DEFAULT KILL_PROCESS) ==="
timeout 90 /usr/local/bin/nsjail -Mo --disable_clone_newnet \
  --rlimit_as max --rlimit_cpu max --rlimit_fsize max --rlimit_nofile 8192 \
  --seccomp_policy /tmp/cbnet/claude.kafel \
  -R /usr -R /bin -R /lib -R /lib64 -R /sbin -R /etc -B /dev -B /tmp/cbnet:/cbnet \
  -m none:/tmp:tmpfs:size=64M -e --env HOME=/tmp --cwd /tmp --really_quiet \
  -- /bin/bash /cbnet/probe.sh 2>/dev/null | sort
echo "=== sanity: an ALLOWED syscall (getpid=39) must NOT be blocked ==="
timeout 30 /usr/local/bin/nsjail -Mo --disable_clone_newnet \
  --seccomp_policy /tmp/cbnet/claude.kafel \
  -R /usr -R /bin -R /lib -R /lib64 -R /sbin -R /etc -B /dev -B /tmp/cbnet:/cbnet \
  -m none:/tmp:tmpfs:size=64M -e --env HOME=/tmp --cwd /tmp --really_quiet \
  -- /usr/bin/python3 -c "import ctypes; print('getpid=',ctypes.CDLL(None).syscall(39)); print('ALLOWED-OK')" 2>/dev/null
echo "=== done ==="
