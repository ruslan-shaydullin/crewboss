#!/usr/bin/env bash
# Round 5: validate the spawn primitive's load-bearing rails live.
set -u
source /home/ec2-user/.crewboss.env; export CLAUDE_CODE_OAUTH_TOKEN
CB=/tmp/cbnet; export CB_HOME=$CB
RUN=$CB/run
rm -rf "$RUN"; mkdir -p "$RUN/work"
echo '{"monthly_credit_usd":100,"cost_pct":80}' > "$RUN/config.json"
echo '{"spent_usd":0,"runs":[]}' > "$RUN/budget.json"
pass=0; fail=0
ok(){ echo "  PASS $1"; pass=$((pass+1)); }
no(){ echo "  FAIL $1"; fail=$((fail+1)); }

echo "=== TEST 2: redactor unit (no cost) ==="
LINE="oauth=$CLAUDE_CODE_OAUTH_TOKEN gh=ghp_AAAAAAAAAAAAAAAAAAAA0000 ant=sk-ant-api03-ZZZZZZZZZZZZ url=https://x-access-token:secretpush@github.com/o/r.git"
OUT=$(printf '%s\n' "$LINE" | perl "$CB/redact.pl")
echo "$OUT" | grep -q "$CLAUDE_CODE_OAUTH_TOKEN" && no "oauth token leaked" || ok "oauth token masked"
echo "$OUT" | grep -q "ghp_AAAA" && no "ghp_ leaked" || ok "ghp_ masked"
echo "$OUT" | grep -q "sk-ant-api03-ZZ" && no "sk-ant leaked" || ok "sk-ant masked"
echo "$OUT" | grep -q "secretpush@" && no "push creds leaked" || ok "push creds masked"

echo "=== TEST 3: budget hard-stop refuses to spawn (no cost) ==="
echo '{"spent_usd":999,"runs":[]}' > "$RUN/budget.json"
mkdir -p "$CB/r5work"; printf 'reply OK\n' > "$CB/r5prompt.txt"
bash "$CB/crewboss-spawn.sh" 9001 executor "$CB/r5prompt.txt" "$CB/r5work" >/tmp/cbnet/r5-t3.out 2>&1
RC=$?
[ "$RC" = "3" ] && ok "exit 3 (budget hard-stop)" || no "exit was $RC (want 3)"
PH=$(jq -r .phase "$RUN/work/9001/status.json" 2>/dev/null)
[ "$PH" = "budget-stop" ] && ok "status phase=budget-stop" || no "status phase=$PH"
RUNS=$(jq -r '.runs|length' "$RUN/budget.json")
[ "$RUNS" = "0" ] && ok "no run recorded (did not spawn)" || no "runs=$RUNS (should be 0)"

echo "=== TEST 1: real smoke — pipeline wiring + budget + status (one paid run) ==="
echo '{"spent_usd":0,"runs":[]}' > "$RUN/budget.json"
printf 'Reply with exactly: OK\n' > "$CB/r5prompt.txt"
bash "$CB/crewboss-spawn.sh" 9002 executor "$CB/r5prompt.txt" "$CB/r5work" >/tmp/cbnet/r5-t1.out 2>&1
RC=$?
sed 's/sk-ant-oat[A-Za-z0-9_-]*/REDACTED/g' /tmp/cbnet/r5-t1.out
ST="$RUN/work/9002/status.json"; LOG="$RUN/work/9002/run.log"
[ "$RC" = "0" ] && ok "spawn exit 0" || no "spawn exit $RC"
# pipeline wiring: the redacted run.log carries the agent JSON result
grep -q '"type":"result"' "$LOG" && ok "agent JSON reached run.log (stdout->redact->log wired)" || no "no JSON in run.log"
grep -q '"result":"OK"' "$LOG" && ok "agent replied OK through the jail" || no "no OK in run.log"
# real secret must never appear in the redacted log
grep -qF "$CLAUDE_CODE_OAUTH_TOKEN" "$LOG" && no "OAuth token LEAKED in run.log" || ok "OAuth token absent in run.log"
PH=$(jq -r .phase "$ST"); [ "$PH" = "done" ] && ok "status phase=done" || no "status phase=$PH"
C=$(jq -r .cost_usd "$ST"); awk -v c="$C" 'BEGIN{exit !(c>0)}' && ok "status cost_usd=$C >0" || no "cost_usd=$C"
SP=$(jq -r .spent_usd "$RUN/budget.json"); awk -v s="$SP" 'BEGIN{exit !(s>0)}' && ok "budget.spent_usd=$SP incremented" || no "spent=$SP"
M=$(stat -c '%a' "$ST"); [ "$M" = "600" ] && ok "status.json mode 600" || no "status mode $M"
M=$(stat -c '%a' "$LOG"); [ "$M" = "600" ] && ok "run.log mode 600" || no "run.log mode $M"

echo "=== SUMMARY: $pass passed, $fail failed ==="
echo "=== done ==="
