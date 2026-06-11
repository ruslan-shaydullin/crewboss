#!/usr/bin/env bash
# Deterministic test of the launchable predicate against a synthetic board (NO network).
HERE="$(cd "$(dirname "$0")" && pwd)"
PRED="$HERE/../launcher/launchable.sh"

# Board:
#  #1 charter APPROVED (open) ; #2 charter plan-review (not approved)
#  #99 CLOSED dep ; #16 CLOSED leaf
#  #10 leaf/#1, no deps                          -> launchable
#  #11 leaf/#1, depends #10 (open)               -> blocked (dep open)
#  #12 leaf/#2 (charter not approved)            -> blocked
#  #13 leaf/#1, status:in-progress               -> excluded
#  #14 leaf/#1, hold                             -> excluded
#  #15 leaf/#1, depends #99 (closed)             -> launchable
#  #17 leaf/#1, depends #16 (closed)             -> launchable
#  #20 no Charter ref                            -> not a managed leaf
#  #21 leaf/#1, **Charter: #1** (bold)           -> launchable (markdown-tolerant ref)
#  #22 leaf/#1, type:human-decision (not agent)  -> excluded (whitelist: must have type:agent)
#  #23 leaf/#1, no labels                        -> excluded (whitelist: must have type:agent)
BOARD='[
 {"number":1,"state":"OPEN","labels":[{"name":"status:approved"},{"name":"type:charter"}],"body":"goal"},
 {"number":2,"state":"OPEN","labels":[{"name":"status:plan-review"},{"name":"type:charter"}],"body":"goal"},
 {"number":3,"state":"OPEN","labels":[{"name":"status:approved"},{"name":"type:bug"}],"body":"approved but NOT a charter"},
 {"number":18,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"Charter: #3"},
 {"number":99,"state":"CLOSED","labels":[],"body":"dep done"},
 {"number":16,"state":"CLOSED","labels":[],"body":"Charter: #1"},
 {"number":10,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"Charter: #1"},
 {"number":11,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"Charter: #1\nDepends-on: #10"},
 {"number":12,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"Charter: #2"},
 {"number":13,"state":"OPEN","labels":[{"name":"status:in-progress"}],"body":"Charter: #1"},
 {"number":14,"state":"OPEN","labels":[{"name":"hold"}],"body":"Charter: #1"},
 {"number":15,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"Charter: #1\nDepends-on: #99"},
 {"number":17,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"Charter: #1\nDepends-on: #16"},
 {"number":20,"state":"OPEN","labels":[],"body":"no charter ref"},
 {"number":21,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"**Charter: #1**"},
 {"number":22,"state":"OPEN","labels":[{"name":"type:human-decision"}],"body":"Charter: #1"},
 {"number":23,"state":"OPEN","labels":[],"body":"Charter: #1"}
]'

GOT=$(printf '%s' "$BOARD" | bash "$PRED" | sort -n | tr '\n' ' ' | sed 's/ *$//')
EXP="10 15 17 21"
if [ "$GOT" = "$EXP" ]; then
  echo "ok   launchable = [$GOT]"; exit 0
else
  echo "FAIL exp=[$EXP] got=[$GOT]"; exit 1
fi
