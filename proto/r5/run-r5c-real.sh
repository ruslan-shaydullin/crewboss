#!/usr/bin/env bash
# Round 5c capstone: the LAUNCHER LOOP drives one real task end-to-end through the real
# adapter -> hardened jail -> agent -> real PR, with budget+redaction+status. One paid run.
set -u
source /home/ec2-user/.crewboss.env; export CLAUDE_CODE_OAUTH_TOKEN
export CB_HOME=/tmp/cbnet
CB=$CB_HOME; RUN=$CB/run; BOARD=$RUN/board
export CB_SPAWN=$CB/crewboss-prep-spawn.sh CB_RETRY_CAP=2 CB_MAX_PARALLEL=1
OWNER=stratch1989; REPO=crewboss-proto
GH_TOKEN=$(gh auth token); export GH_TOKEN

rm -rf "$RUN"; mkdir -p "$BOARD"
echo '{"monthly_credit_usd":100,"cost_pct":80}' > "$RUN/config.json"
echo '{"spent_usd":0,"runs":[]}' > "$RUN/budget.json"

echo "=== create issue (board task id = issue number) ==="
ISSUE=$(gh issue create -R $OWNER/$REPO -t "r5c launcher-driven $(date +%s)" -b "driven end-to-end by the launcher loop" | grep -oE '[0-9]+$' | tail -1)
echo "issue=#$ISSUE"
PROMPT='You are an executor in the git repository in the current directory; a task branch is already checked out. Do exactly these steps then stop: 1) append a new line with the exact text "executor via launcher loop (round 5c)" to README.md; 2) stage and commit ONLY that change with message "r5c: executor via launcher"; 3) push the current branch to origin; 4) open a pull request with gh pr create (short title and body). Finally print the PR URL on its own line.'
jq -n --argjson id "$ISSUE" --arg r executor --arg repo "$OWNER/$REPO" --arg p "$PROMPT" \
  '{id:$id,kind:"leaf",role:$r,state:"open",charter:null,deps:[],held:false,tries:0,pid:"",starttime:"",pr_repo:$repo,prompt:$p}' \
  > "$BOARD/$ISSUE.json"

echo "=== launcher once (real spawn via adapter) ==="
bash "$CB/crewboss-launcher.sh" once 2>&1 | sed 's/sk-ant-oat[A-Za-z0-9_-]*/REDACTED/g; s#x-access-token:[^@]*@#x-access-token:REDACTED@#g'

echo "=== verify ==="
echo "board task state: $(jq -r .state "$BOARD/$ISSUE.json")"
echo "status.json: $(jq -rc '{phase,cost_usd,pr,exit_code}' "$RUN/work/$ISSUE/status.json" 2>/dev/null)"
echo "budget spent: \$$(jq -r .spent_usd "$RUN/budget.json")"
echo "open PRs (this run): $(gh pr list -R $OWNER/$REPO --state open --json number,url,author -q '.[] | select(.author.login!="") | "#\(.number) \(.url)"' | tail -2)"
echo "run.log has no oauth token: $(grep -cF "$CLAUDE_CODE_OAUTH_TOKEN" "$RUN/work/$ISSUE/run.log" 2>/dev/null) hits (want 0)"
echo "=== done ==="
