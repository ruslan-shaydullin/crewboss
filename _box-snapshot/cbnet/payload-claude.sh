python3 /cbnet/bridge.py /cbnet/proxy.sock 3128 &
BR=$!
for i in $(seq 1 50); do (echo >/dev/tcp/127.0.0.1/3128) 2>/dev/null && break; sleep 0.1; done
/home/ec2-user/.local/bin/claude -p "Reply with exactly: OK" --dangerously-skip-permissions --output-format json > /cbnet/sc-claude.run 2>&1
kill $BR 2>/dev/null
