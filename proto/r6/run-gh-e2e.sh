#!/usr/bin/env bash
# Capstone: a REAL GitHub issue, picked up by the gh-mode launcher loop, driven through the
# real adapter -> hardened jail -> agent -> real PR, with the issue ending in status:review.
set -u
source /home/ec2-user/.crewboss.env; export CLAUDE_CODE_OAUTH_TOKEN
export CB_REPO=stratch1989/crewboss-proto CB_HOME=/tmp/cbnet
export CB_SPAWN=/tmp/cbnet/crewboss-prep-spawn-gh.sh CB_RETRY_CAP=2 CB_MAX_PARALLEL=1 CB_LAUNCHER_ID=cbe2e
L=/tmp/cbnet/crewboss-launcher-gh.sh; BG=/tmp/cbnet/board-gh.sh
RUN=$CB_HOME/run
rm -rf "$RUN/state"; mkdir -p "$RUN/state"
echo '{"monthly_credit_usd":100,"cost_pct":80}' > "$RUN/config.json"
echo '{"spent_usd":0,"runs":[]}' > "$RUN/budget.json"
ghretry(){ local i o; for i in 1 2 3 4 5; do o=$(gh "$@" 2>/dev/null) && { echo "$o"; return 0; }; sleep 3; done; return 1; }

for l in type:charter status:approved status:in-progress status:review status:blocked hold; do
  gh label create "$l" -R $CB_REPO --color ededed 2>/dev/null || true; done
CH=$(ghretry issue create -R $CB_REPO -t "CHARTER e2e $(date +%s)" -b root -l type:charter -l status:approved | grep -oE '[0-9]+$' | tail -1)
BODY="Charter: #$CH

You are an executor in the git repository in the current directory; a task branch is already checked out. Do exactly these steps then stop: 1) append a new line with the exact text \"executor via gh-board loop (e2e)\" to README.md; 2) stage and commit ONLY that change with message \"e2e: executor via gh board\"; 3) push the current branch to origin; 4) open a pull request with gh pr create. Finally print the PR URL on its own line."
LEAF=$(ghretry issue create -R $CB_REPO -t "LEAF e2e append-readme $(date +%s)" -b "$BODY" | grep -oE '[0-9]+$' | tail -1)
echo "charter=#$CH leaf=#$LEAF"

echo "=== launcher-gh once (REAL spawn via adapter) ==="
bash "$L" once 2>&1 | sed 's/sk-ant-oat[A-Za-z0-9_-]*/REDACTED/g; s#x-access-token:[^@]*@#x-access-token:REDACTED@#g'

echo "=== verify ==="
echo "leaf board state: $(bash "$BG" get "$LEAF" state)  (want review)"
echo "status.json: $(jq -rc '{phase,cost_usd,pr,exit_code}' "$RUN/work/$LEAF/status.json" 2>/dev/null)"
echo "budget spent: \$$(jq -r .spent_usd "$RUN/budget.json")"
echo "oauth leak in run.log: $(grep -cF "$CLAUDE_CODE_OAUTH_TOKEN" "$RUN/work/$LEAF/run.log" 2>/dev/null) (want 0)"
PR=$(jq -r .pr "$RUN/work/$LEAF/status.json" 2>/dev/null)
echo "PR: $PR"
[ -n "$PR" ] && echo "PR files: $(gh pr diff "${PR##*/}" -R $CB_REPO --name-only 2>/dev/null | tr '\n' ' ')"
echo "(leaving charter #$CH + leaf #$LEAF open as artifacts; PR as proof)"
echo "=== done ==="
