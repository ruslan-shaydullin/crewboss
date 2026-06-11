#!/usr/bin/env bash
# Inside-jail payload for Round 4b: the AGENT itself does edit+commit+push+PR
# (git+gh as subprocesses), all through the proxy, under seccomp.
python3 /cbnet/bridge.py /cbnet/proxy.sock 3128 &
BR=$!
for i in $(seq 1 50); do (echo >/dev/tcp/127.0.0.1/3128) 2>/dev/null && break; sleep 0.1; done
read -r -d '' TASK <<'EOF'
You are an executor working in the git repository in the current directory; a task
branch is already checked out. Do exactly these steps, then stop:
1. Append a new line with the exact text "executor wrote this from inside the jail (round 4b)" to README.md.
2. Stage and commit only that change. Commit message: "r4b: executor edit from inside jail".
3. Push the current branch to origin.
4. Open a pull request with `gh pr create` (short title and body).
Finally print the pull request URL on its own line.
EOF
/home/ec2-user/.local/bin/claude -p "$TASK" \
  --dangerously-skip-permissions --output-format json > /cbnet/r4b-agent.run 2>&1
kill $BR 2>/dev/null
