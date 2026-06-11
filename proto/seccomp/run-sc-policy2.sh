#!/usr/bin/env bash
# Round 3c v2: kafel allowlist where 5 names absent from this kafel's amd64 table
# (stat/fstat/lstat/sendfile/uname) are expressed numerically as SYSCALL[n].
set -u
source /home/ec2-user/.crewboss.env
export CLAUDE_CODE_OAUTH_TOKEN
GH_TOKEN=$(gh auth token); export GH_TOKEN
cd /tmp/cbnet
bash /tmp/cbnet/gen-names.sh >/dev/null   # -> policy-names.txt (173 names incl the 5 unknowns)

# split: drop the 5 kafel-unknown names, add them as SYSCALL[n]
KNOWN=$(grep -vxE 'stat|fstat|lstat|sendfile|uname' /tmp/cbnet/policy-names.txt | paste -sd,)
NUMERIC='SYSCALL[4],SYSCALL[5],SYSCALL[6],SYSCALL[40],SYSCALL[63]'   # stat fstat lstat sendfile uname
{ echo "ALLOW {"; echo "${KNOWN},${NUMERIC}"; echo "}"; echo "DEFAULT KILL_PROCESS"; } > /tmp/cbnet/claude.kafel
echo "policy bytes=$(wc -c < /tmp/cbnet/claude.kafel) names=$(echo "$KNOWN" | tr ',' '\n' | wc -l)+5numeric"

echo "=== 0: parse on /bin/true ==="
/usr/local/bin/nsjail -Mo --disable_clone_newnet --really_quiet \
  -R /usr -R /bin -R /lib -R /lib64 -R /sbin -R /etc \
  --seccomp_policy /tmp/cbnet/claude.kafel -- /bin/true 2>/tmp/cbnet/parse.err
PRC=$?; echo "parse+true rc=$PRC"; grep -iE "prepare|undefined" /tmp/cbnet/parse.err && { echo "PARSE FAIL"; exit 1; }

pkill -f 'proxy.py /tmp/cbnet' 2>/dev/null; sleep 0.3
rm -f proxy.sock; : > proxy.log
nohup python3 /tmp/cbnet/proxy.py /tmp/cbnet/proxy.sock > proxy.out 2>&1 &
PROXY=$!
for i in $(seq 1 50); do [ -S proxy.sock ] && break; sleep 0.1; done
RO="-R /usr -R /bin -R /lib -R /lib64 -R /sbin -R /etc -R /home/ec2-user/.local"
PE="--env HTTPS_PROXY=http://127.0.0.1:3128 --env https_proxy=http://127.0.0.1:3128 --env NO_PROXY=localhost,127.0.0.1 --env no_proxy=localhost,127.0.0.1"

echo "=== 1: claude smoke under seccomp (KILL_PROCESS default) ==="
timeout 120 /usr/local/bin/nsjail -Mo \
  --rlimit_as max --rlimit_cpu max --rlimit_fsize max --rlimit_nofile 8192 \
  --seccomp_policy /tmp/cbnet/claude.kafel --seccomp_log \
  $RO -B /home/ec2-user/.claude -B /home/ec2-user/.claude.json -B /dev -B /tmp/cbnet:/cbnet \
  -m none:/tmp:tmpfs:size=256M -e --env HOME=/home/ec2-user --cwd /tmp \
  --env CLAUDE_CODE_OAUTH_TOKEN $PE --env CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 --really_quiet \
  -- /bin/bash /cbnet/payload-claude.sh > /dev/null 2>/tmp/cbnet/claude.jailerr
echo "claude rc=$? result=$(jq -r .result /tmp/cbnet/sc-claude.run 2>/dev/null) is_error=$(jq -r .is_error /tmp/cbnet/sc-claude.run 2>/dev/null)"

echo "=== 2: git clone+push under seccomp ==="
timeout 120 /usr/local/bin/nsjail -Mo \
  --rlimit_as max --rlimit_cpu max --rlimit_fsize max --rlimit_nofile 8192 \
  --seccomp_policy /tmp/cbnet/claude.kafel --seccomp_log \
  $RO -B /dev -B /tmp/cbnet:/cbnet \
  -m none:/tmp:tmpfs:size=128M -e --env HOME=/tmp --cwd /tmp \
  --env GH_TOKEN $PE --really_quiet \
  -- /bin/bash /cbnet/payload-git.sh > /tmp/cbnet/sc-git.run 2>/tmp/cbnet/git.jailerr
echo "git rc=$?"; grep -iE 'new branch|deleted|To https' /tmp/cbnet/sc-git.run | sed 's#https://[^ ]*#https://REDACTED#'

kill "$PROXY" 2>/dev/null

echo "=== 3: forbidden-syscall probes (expect BLOCKED) ==="
timeout 60 /usr/local/bin/nsjail -Mo --disable_clone_newnet \
  --rlimit_as max --rlimit_cpu max --rlimit_fsize max --rlimit_nofile 8192 \
  --seccomp_policy /tmp/cbnet/claude.kafel \
  -R /usr -R /bin -R /lib -R /lib64 -R /sbin -R /etc -B /dev -B /tmp/cbnet:/cbnet \
  -m none:/tmp:tmpfs:size=64M -e --env HOME=/tmp --cwd /tmp --really_quiet \
  -- /bin/bash /cbnet/probe.sh 2>/dev/null | sort
echo "=== done ==="
