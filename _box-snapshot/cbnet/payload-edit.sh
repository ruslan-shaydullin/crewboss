#!/usr/bin/env bash
# Inside-jail payload: bring up bridge, then claude EDITS a file (no git).
python3 /cbnet/bridge.py /cbnet/proxy.sock 3128 &
BR=$!
for i in $(seq 1 50); do (echo >/dev/tcp/127.0.0.1/3128) 2>/dev/null && break; sleep 0.1; done
/home/ec2-user/.local/bin/claude -p "Append a single new line with the exact text 'hello from crewboss prototype round 4' to the file README.md in the current directory, then stop. Do not run git." \
  --dangerously-skip-permissions --output-format json > /cbnet/r4-edit.run 2>&1
kill $BR 2>/dev/null
