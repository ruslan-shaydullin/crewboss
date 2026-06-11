#!/bin/bash
# Round 3b / net2 payload: runs INSIDE the jail.
set -u
python3 /cbnet/bridge.py /cbnet/proxy.sock 3128 &
BR=$!
ok=0
for i in $(seq 1 50); do (echo >/dev/tcp/127.0.0.1/3128) 2>/dev/null && { ok=1; break; }; sleep 0.1; done
echo "bridge_up=$ok"
export HTTPS_PROXY=http://127.0.0.1:3128 https_proxy=http://127.0.0.1:3128
export HTTP_PROXY=http://127.0.0.1:3128 http_proxy=http://127.0.0.1:3128
export NO_PROXY=localhost,127.0.0.1 no_proxy=localhost,127.0.0.1

echo "== ALLOW api.github.com/zen =="
curl -m 20 -sS https://api.github.com/zen; echo; echo rc=$?
echo "== ALLOW api.anthropic.com (TLS through proxy; 4xx body ok) =="
curl -m 20 -sS -o /dev/null -w "%{http_code}\n" https://api.anthropic.com/v1/models; echo rc=$?
echo "== ALLOW console.anthropic.com =="
curl -m 20 -sS -o /dev/null -w "%{http_code}\n" https://console.anthropic.com; echo rc=$?
echo "== ALLOW platform.claude.com =="
curl -m 20 -sS -o /dev/null -w "%{http_code}\n" https://platform.claude.com; echo rc=$?
echo "== ALLOW raw.githubusercontent.com (wildcard) =="
curl -m 20 -sS -o /dev/null -w "%{http_code}\n" https://raw.githubusercontent.com/octocat/Hello-World/master/README; echo rc=$?
echo "== ALLOW git ls-remote via proxy =="
GIT_TERMINAL_PROMPT=0 timeout 30 git ls-remote https://github.com/octocat/Hello-World.git HEAD; echo rc=$?
echo "== BLOCK example.com:443 (expect CONNECT 403 -> curl rc=56) =="
curl -m 15 -sS https://example.com -o /dev/null; echo rc=$?
echo "== BLOCK evil.githubusercontent.com.attacker.io (suffix spoof) =="
curl -m 15 -sS https://githubusercontent.com.attacker.example -o /dev/null; echo rc=$?
echo "== BLOCK plain http://github.com (port 80 / non-CONNECT) =="
curl -m 15 -sS http://github.com -o /dev/null; echo rc=$?
echo "== BLOCK direct egress without proxy (expect immediate fail) =="
env -u HTTPS_PROXY -u https_proxy -u HTTP_PROXY -u http_proxy \
  curl -m 8 -sS https://example.com -o /dev/null; echo rc=$?
kill $BR 2>/dev/null
exit 0
