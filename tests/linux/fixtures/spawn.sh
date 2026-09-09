#!/usr/bin/env bash
# Keep GitHub/git transport fictional; exercise the actual sandbox/provider path.
set -euo pipefail
id="$1"
role="$(bash "$CB_HOME/board-gh.sh" get "$id" role)"
work="$CB_HOME/run/fixture-checkout-$id"
mkdir -p "$work"
bash "$CB_HOME/board-gh.sh" get "$id" prompt > "$work/prompt.txt"
exec bash "$CB_HOME/crewboss-spawn.sh" "$id" "$role" "$work/prompt.txt" "$work" fixture/project
