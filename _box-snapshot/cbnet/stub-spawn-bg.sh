#!/usr/bin/env bash
# Background test stub: simulates a spawn that takes STUB_SLEEP seconds, then writes the
# status.json the launcher routes on. Logs START/END timestamps so the test can measure
# real concurrency. Exit/phase from run/stub-ctl/<id> (0 done | 2 failed | 3 budget).
id="$1"
CB_HOME="${CB_HOME:-/tmp/cbnet}"; RUN="$CB_HOME/run"
mkdir -p "$RUN/work/$id"
echo "START $id $(date +%s.%N)" >> "$RUN/parallel-calls.log"
sleep "${STUB_SLEEP:-4}"
code=0; ctl="$RUN/stub-ctl/$id"; [ -f "$ctl" ] && code=$(cat "$ctl")
case "$code" in 0) ph=done ;; 3) ph=budget-stop ;; *) ph=failed ;; esac
printf '{"task":"%s","phase":"%s","exit_code":"%s","cost_usd":0,"pr":""}\n' "$id" "$ph" "$code" > "$RUN/work/$id/status.json"
echo "END $id $(date +%s.%N)" >> "$RUN/parallel-calls.log"
exit "$code"
