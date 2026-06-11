#!/usr/bin/env bash
# Full autonomy chain via the launcher: charter(needs-plan) -> tech-lead decomposes ->
# plan-review -> (boss approves) -> executors run the leaves -> PRs. One real run each phase.
set -u
source /home/ec2-user/.crewboss.env; export CLAUDE_CODE_OAUTH_TOKEN
export CB_REPO=stratch1989/crewboss-proto CB_HOME=/tmp/cbnet
export CB_SPAWN=/tmp/cbnet/crewboss-prep-spawn-gh.sh CB_GOVERNED=1
export CB_RETRY_CAP=2 CB_MAX_PARALLEL=2 CB_POLL=3 CB_LAUNCHER_ID=cbtl CB_MAX_TICKS=80
GH_TOKEN=$(gh auth token); export GH_TOKEN
L=/tmp/cbnet/crewboss-launcher-gh.sh; BG=/tmp/cbnet/board-gh.sh; RUN=$CB_HOME/run
rm -rf "$RUN/state" "$RUN/work" "$RUN/launcher.lock" "$RUN/pause" "$RUN/kill_switch"; mkdir -p "$RUN/state"
echo '{"monthly_credit_usd":100,"cost_pct":80}' > "$RUN/config.json"
echo '{"spent_usd":0,"runs":[]}' > "$RUN/budget.json"
for l in type:charter status:needs-plan status:plan-review status:approved status:in-progress status:review status:blocked hold; do gh label create "$l" -R $CB_REPO --color ededed 2>/dev/null||true; done

echo ">> boss files a charter (needs-plan):"
CH=$(gh issue create -R $CB_REPO -t "Charter: polish the README" -b "Goal: make README.md nicer. Create exactly TWO small leaf tasks: (1) add a short '## Usage' section with a one-line example, (2) add a one-line license note at the very bottom. Each leaf edits only README.md and opens a PR." -l type:charter -l status:needs-plan | grep -oE '[0-9]+$'|tail -1)
echo "   charter #$CH  https://github.com/$CB_REPO/issues/$CH"

echo ">> PHASE 1 — launcher runs tech-lead to decompose:"
bash "$L" run 2>&1 | sed 's/^/   /; s/sk-ant-oat[A-Za-z0-9_-]*/REDACTED/g; s#x-access-token:[^@]*@#REDACTED@#g'
echo "   charter state now: $(bash "$BG" get "$CH" state)"
echo "   sub-issues created (Charter: #$CH):"
SUBS=$(gh issue list -R $CB_REPO --state open -L 50 --search "Charter: #$CH in:body" --json number,title -q '.[] | "   #\(.number) \(.title)"')
echo "$SUBS"

echo ">> boss APPROVES the plan (simulated):"
gh issue edit "$CH" -R $CB_REPO --add-label status:approved --remove-label status:plan-review >/dev/null && echo "   #$CH -> approved"

echo ">> PHASE 2 — launcher runs executors on the approved leaves:"
rm -rf "$RUN/state"; mkdir -p "$RUN/state"   # fresh run-state for phase 2
bash "$L" run 2>&1 | sed 's/^/   /; s/sk-ant-oat[A-Za-z0-9_-]*/REDACTED/g; s#x-access-token:[^@]*@#REDACTED@#g'

echo ">> RESULT:"
echo "   pool spent: \$$(jq -r .spent_usd "$RUN/budget.json")"
for n in $(echo "$SUBS" | grep -oE '#[0-9]+' | tr -d '#'); do
  echo "   leaf #$n: state=$(bash "$BG" get "$n" state)  pr=$(jq -r '.pr//""' "$RUN/work/$n/status.json" 2>/dev/null)"
done
echo "=== done ==="
