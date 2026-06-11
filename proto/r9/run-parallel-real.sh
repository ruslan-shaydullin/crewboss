#!/usr/bin/env bash
# Real 2-parallel: two actual jailed claude agents running concurrently, each through its OWN
# per-task proxy socket. Proves the per-task-socket fix (no proxy collision under real load).
# Cheap prompts (reply OK, no git) keep cost ~2x a smoke.
set -u
source /home/ec2-user/.crewboss.env; export CLAUDE_CODE_OAUTH_TOKEN
export CB_REPO=stratch1989/crewboss-proto CB_HOME=/tmp/cbnet
export CB_SPAWN=/tmp/cbnet/crewboss-prep-spawn-gh.sh CB_RETRY_CAP=2 CB_MAX_PARALLEL=2 CB_POLL=2 CB_LAUNCHER_ID=cbpr
GH_TOKEN=$(gh auth token); export GH_TOKEN
L=/tmp/cbnet/crewboss-launcher-gh.sh; BG=/tmp/cbnet/board-gh.sh
RUN=$CB_HOME/run
rm -rf "$RUN/state" "$RUN/work" "$RUN/launcher.lock"; mkdir -p "$RUN/state"
echo '{"monthly_credit_usd":100,"cost_pct":80}' > "$RUN/config.json"
echo '{"spent_usd":0,"runs":[]}' > "$RUN/budget.json"
created=(); cleanup(){ for n in "${created[@]}"; do gh issue close "$n" -R $CB_REPO >/dev/null 2>&1; done; }
trap cleanup EXIT
for l in type:charter status:approved status:in-progress status:review status:blocked hold; do gh label create "$l" -R $CB_REPO --color ededed 2>/dev/null || true; done
CH=$(gh issue create -R $CB_REPO -t "CHARTER real-par $(date +%s)" -b root -l type:charter -l status:approved | grep -oE '[0-9]+$'|tail -1); created+=("$CH")
BODY="Charter: #$CH

Reply with exactly: OK. Do not use any tools, do not run any commands."
P=$(gh issue create -R $CB_REPO -t "realpar-P $(date +%s)" -b "$BODY" | grep -oE '[0-9]+$'|tail -1); created+=("$P")
Q=$(gh issue create -R $CB_REPO -t "realpar-Q $(date +%s)" -b "$BODY" | grep -oE '[0-9]+$'|tail -1); created+=("$Q")
echo "charter=#$CH leaves=#$P #$Q  cap=2 (real claude x2 concurrent)"

echo "=== run (REAL 2-parallel) ==="
t0=$(date +%s)
bash "$L" run 2>&1 | sed 's/^/  /; s/sk-ant-oat[A-Za-z0-9_-]*/REDACTED/g'
echo "wall=$(( $(date +%s) - t0 ))s"

echo "=== verify ==="
for n in "$P" "$Q"; do
  s=$(bash "$BG" get "$n" state)
  err=$(jq -r .is_error "$RUN/work/$n/status.json" 2>/dev/null; jq -r .is_error "$RUN/work/$n/result.json.raw" 2>/dev/null)
  cost=$(jq -r .cost_usd "$RUN/work/$n/status.json" 2>/dev/null)
  echo "#$n: state=$s cost=$cost"
done
echo "budget spent: \$$(jq -r .spent_usd "$RUN/budget.json")"
echo "--- per-task proxy logs (each its own socket; both should show api.anthropic.com) ---"
for n in "$P" "$Q"; do echo "#$n proxy:"; grep -c ALLOW "$RUN/work/$n/"*.out 2>/dev/null; grep ALLOW "$RUN/work/$n/proxy.out" 2>/dev/null | head -1; done
echo "=== concurrency: both started before either finished? (status starttime overlap) ==="
echo "=== done ==="
