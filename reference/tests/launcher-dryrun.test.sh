#!/usr/bin/env bash
# Deterministic test of the launcher's --dry-run planning against a synthetic board.
# --dry-run + --board-file = fully read-only (no gh, no worktree, no heartbeat, no launches).
HERE="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER="$HERE/../launcher/crewboss-launcher.sh"

BOARD='[
 {"number":1,"state":"OPEN","labels":[{"name":"status:approved"},{"name":"type:charter"}],"body":"goal"},
 {"number":2,"state":"OPEN","labels":[{"name":"status:plan-review"},{"name":"type:charter"}],"body":"goal"},
 {"number":99,"state":"CLOSED","labels":[],"body":"dep done"},
 {"number":16,"state":"CLOSED","labels":[],"body":"Charter: #1"},
 {"number":10,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"Charter: #1"},
 {"number":11,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"Charter: #1\nDepends-on: #10"},
 {"number":12,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"Charter: #2"},
 {"number":13,"state":"OPEN","labels":[{"name":"status:in-progress"}],"body":"Charter: #1"},
 {"number":14,"state":"OPEN","labels":[{"name":"hold"}],"body":"Charter: #1"},
 {"number":15,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"Charter: #1\nDepends-on: #99"},
 {"number":17,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"Charter: #1\nDepends-on: #16"},
 {"number":20,"state":"OPEN","labels":[],"body":"no charter ref"}
]'

TMP="$(mktemp)"; printf '%s' "$BOARD" > "$TMP"
OUT="$(CREWBOSS_CONCURRENCY=10 bash "$LAUNCHER" --once --dry-run --board-file "$TMP" 2>&1)"
rm -f "$TMP"

pass=0; fail=0
want(){ if printf '%s\n' "$OUT" | grep -q "DRY launch #$1$"; then echo "ok   would launch #$1"; pass=$((pass+1)); else echo "FAIL missing #$1"; fail=$((fail+1)); fi; }
deny(){ if printf '%s\n' "$OUT" | grep -q "DRY launch #$1$"; then echo "FAIL unexpected #$1"; fail=$((fail+1)); else echo "ok   not launched #$1"; pass=$((pass+1)); fi; }

want 10; want 15; want 17
deny 11; deny 12; deny 13; deny 14; deny 16; deny 20

echo "passed=$pass failed=$fail"
[ "$fail" = "0" ]
