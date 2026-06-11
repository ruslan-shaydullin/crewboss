#!/usr/bin/env bash
# Test stub for crewboss-spawn.sh: no jail, no cost. Exit code per task comes from
# run/stub-ctl/<id> (0 ok | 2 fail | 3 budget). Records each call for assertions.
id="$1"
ctl="$CB_HOME/run/stub-ctl/$id"
code=0; [ -f "$ctl" ] && code=$(cat "$ctl")
echo "$id" >> "$CB_HOME/run/stub-calls.log"
exit "$code"
