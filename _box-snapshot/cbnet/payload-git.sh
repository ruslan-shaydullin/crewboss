python3 /cbnet/bridge.py /cbnet/proxy.sock 3128 &
BR=$!
for i in $(seq 1 50); do (echo >/dev/tcp/127.0.0.1/3128) 2>/dev/null && break; sleep 0.1; done
GIT_TERMINAL_PROMPT=0 git clone --depth 1 "https://x-access-token:${GH_TOKEN}@github.com/stratch1989/crewboss-proto.git" /tmp/r
cd /tmp/r && git -c user.email=c@l -c user.name=c commit --allow-empty -m sc-probe
git push origin HEAD:refs/heads/sc-probe && git push origin :refs/heads/sc-probe
gh repo view stratch1989/crewboss-proto --json name -q .name
kill $BR 2>/dev/null
