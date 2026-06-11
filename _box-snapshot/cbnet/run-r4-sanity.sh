#!/usr/bin/env bash
# Round 4 sanity: prove all THREE isolation layers are simultaneously active in the
# ONE hardened profile (not just each in isolation in earlier rounds).
set -u
cd /tmp/cbnet
pkill -f 'proxy.py /tmp/cbnet' 2>/dev/null; sleep 0.3
rm -f proxy.sock; : > proxy.log
nohup python3 /tmp/cbnet/proxy.py /tmp/cbnet/proxy.sock > proxy.out 2>&1 &
PROXY=$!
for i in $(seq 1 50); do [ -S proxy.sock ] && break; sleep 0.1; done
RO="-R /usr -R /bin -R /lib -R /lib64 -R /sbin -R /etc -R /home/ec2-user/.local"
PE="--env HTTPS_PROXY=http://127.0.0.1:3128 --env https_proxy=http://127.0.0.1:3128 --env NO_PROXY=localhost,127.0.0.1 --env no_proxy=localhost,127.0.0.1"
cat > /tmp/cbnet/sanity-payload.sh <<'P'
python3 /cbnet/bridge.py /cbnet/proxy.sock 3128 &
for i in $(seq 1 50); do (echo >/dev/tcp/127.0.0.1/3128) 2>/dev/null && break; sleep 0.1; done
echo "--- [NET] allowed host api.github.com (expect 200-ish) ---"
curl -m 15 -sS -o /dev/null -w "http=%{http_code}\n" https://api.github.com/zen || echo "curl rc=$?"
echo "--- [NET] arbitrary host example.com (expect CONNECT 403 -> rc56) ---"
curl -m 15 -sS https://example.com -o /dev/null; echo "curl rc=$?"
echo "--- [SECCOMP] mount(165) (expect SIGSYS kill rc159) ---"
python3 -c "import ctypes; ctypes.CDLL(None).syscall(165,0,0,0,0,0,0)"; echo "rc=$?"
echo "--- [SECCOMP] ptrace(101) (expect SIGSYS kill rc159) ---"
python3 -c "import ctypes; ctypes.CDLL(None).syscall(101,0,0,0,0,0,0)"; echo "rc=$?"
echo "--- [FS] host secret ~/.crewboss.env (expect NOT visible) ---"
if [ -e /home/ec2-user/.crewboss.env ]; then echo "VISIBLE <-- LEAK"; else echo "absent (good)"; fi
echo "--- [FS] what is visible under HOME ---"
ls -a /home/ec2-user 2>/dev/null | tr '\n' ' '; echo
P
echo "=== ONE hardened jail: FS + net + seccomp(KILL) all on ==="
timeout 90 /usr/local/bin/nsjail -Mo \
  --rlimit_as max --rlimit_cpu max --rlimit_fsize max --rlimit_nofile 8192 \
  --seccomp_policy /tmp/cbnet/claude.kafel \
  $RO -B /home/ec2-user/.claude -B /home/ec2-user/.claude.json -B /dev -B /tmp/cbnet:/cbnet \
  -m none:/tmp:tmpfs:size=64M -e --env HOME=/home/ec2-user --cwd /tmp $PE --really_quiet \
  -- /bin/bash /cbnet/sanity-payload.sh 2>&1
kill "$PROXY" 2>/dev/null
echo "=== proxy log ==="; grep -E 'ALLOW|DENY' /tmp/cbnet/proxy.log
echo "=== done ==="
