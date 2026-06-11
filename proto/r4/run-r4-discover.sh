#!/usr/bin/env bash
# Round 4 / discovery: capture syscall surface of claude EDITING a file
# inside the FS+net jail (seccomp OFF), strace -f. Union with the 3c surface.
set -u
source /home/ec2-user/.crewboss.env
export CLAUDE_CODE_OAUTH_TOKEN
cd /tmp/cbnet

# fresh work copy with a README to edit
rm -rf /tmp/cbnet/r4work; mkdir -p /tmp/cbnet/r4work
printf '# crewboss proto\n\nbaseline line\n' > /tmp/cbnet/r4work/README.md

pkill -f 'proxy.py /tmp/cbnet' 2>/dev/null; sleep 0.3
rm -f proxy.sock; : > proxy.log
nohup python3 /tmp/cbnet/proxy.py /tmp/cbnet/proxy.sock > proxy.out 2>&1 &
PROXY=$!
for i in $(seq 1 50); do [ -S proxy.sock ] && break; sleep 0.1; done

RO="-R /usr -R /bin -R /lib -R /lib64 -R /sbin -R /etc -R /home/ec2-user/.local"
PE="--env HTTPS_PROXY=http://127.0.0.1:3128 --env https_proxy=http://127.0.0.1:3128 --env NO_PROXY=localhost,127.0.0.1 --env no_proxy=localhost,127.0.0.1"

echo "=== claude edit under strace (FS+net jail, seccomp OFF) ==="
timeout 180 /usr/local/bin/nsjail -Mo \
  --rlimit_as max --rlimit_cpu max --rlimit_fsize max --rlimit_nofile 8192 \
  $RO -B /home/ec2-user/.claude -B /home/ec2-user/.claude.json -B /dev -B /tmp/cbnet:/cbnet \
  -B /tmp/cbnet/r4work:/work \
  -m none:/tmp:tmpfs:size=256M -e --env HOME=/home/ec2-user --cwd /work \
  --env CLAUDE_CODE_OAUTH_TOKEN $PE --env CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 --really_quiet \
  -- /usr/bin/strace -f -qq -c -U name -o /cbnet/sc-edit.txt /bin/bash /cbnet/payload-edit.sh > /dev/null 2>&1
echo "edit jail rc=$? result=$(jq -r .result /tmp/cbnet/r4-edit.run 2>/dev/null | head -c 60) is_error=$(jq -r .is_error /tmp/cbnet/r4-edit.run 2>/dev/null)"
kill "$PROXY" 2>/dev/null

echo "=== README after edit ==="; cat /tmp/cbnet/r4work/README.md

filt(){ grep -E '^[a-z][a-z0-9_]+$' "$1" | grep -vxE 'syscall|total'; }
filt /tmp/cbnet/sc-edit.txt | sort -u > /tmp/cbnet/sc-edit.list
echo "edit syscalls=$(wc -l < /tmp/cbnet/sc-edit.list)"
echo "=== NEW in edit (not in 3c union) ==="
comm -13 /tmp/cbnet/sc-union.list /tmp/cbnet/sc-edit.list | tr '\n' ' '; echo
cat /tmp/cbnet/sc-union.list /tmp/cbnet/sc-edit.list | sort -u > /tmp/cbnet/sc-r4union.list
echo "r4 union total=$(wc -l < /tmp/cbnet/sc-r4union.list)"
echo "=== done ==="
