#!/usr/bin/env bash
# Smoke test for the `crewboss` CLI — deterministic, offline parts (help / init / status / errors).
# gh-dependent paths (labels, branch protection) are not asserted here.
# Unset charter-scope env var so the launchable predicate sees all charters in fixtures.
unset CREWBOSS_CHARTER
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
CLI="$HERE/../bin/crewboss"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

# help
"$CLI" help 2>&1 | grep -q "crewboss init" && ok "help lists commands" || ko "help"
# unknown -> exit 2
"$CLI" frobnicate >/dev/null 2>&1; [ $? -eq 2 ] && ok "unknown command -> exit 2" || ko "unknown exit code"

# init in a fresh repo
REPO="$TMP/repo"; git init -q "$REPO"; ( cd "$REPO" && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m init )
( cd "$REPO" && "$CLI" init >/dev/null 2>&1 )
S="$REPO/.claude/settings.json"
[ -f "$REPO/.claude/hooks/crewboss-gate.sh" ] && ok "init: hook copied" || ko "init: no hook"
[ -x "$REPO/.claude/hooks/crewboss-gate.sh" ] && ok "init: hook executable" || ko "init: hook not +x"
[ -f "$REPO/.claude/agents/executor.md" ] && ok "init: agents copied" || ko "init: no agents"
jq -e '(.permissions.allow // []) | index("Bash")' "$S" >/dev/null 2>&1 && ok "init: permissions.allow has Bash" || ko "init: no allow"
jq -e 'any(.hooks.PreToolUse[]?.hooks[]?.command; test("crewboss-gate.sh"))' "$S" >/dev/null 2>&1 && ok "init: hook wired" || ko "init: hook not wired"
# init is idempotent — second run must not duplicate the hook entry or the allow list
( cd "$REPO" && "$CLI" init >/dev/null 2>&1 )
[ "$(jq '[.hooks.PreToolUse[].hooks[].command] | map(select(test("crewboss-gate.sh"))) | length' "$S")" = "1" ] && ok "init: idempotent (no dup hook)" || ko "init: duplicated hook"
[ "$(jq '.permissions.allow | length' "$S")" = "4" ] && ok "init: idempotent (allow not duplicated)" || ko "init: allow duplicated"

# status --board-file (reuse the dry-run fixture: launchable = 10 15 17, charters #1 #2)
BOARD="$TMP/board.json"
cat > "$BOARD" <<'JSON'
[
 {"number":1,"state":"OPEN","labels":[{"name":"status:approved"},{"name":"type:charter"}],"title":"goal A","body":"goal"},
 {"number":2,"state":"OPEN","labels":[{"name":"status:plan-review"},{"name":"type:charter"}],"title":"goal B","body":"goal"},
 {"number":10,"state":"OPEN","labels":[{"name":"type:agent"}],"title":"leaf ten","body":"Charter: #1\n## Acceptance (machine)\n- check: true"},
 {"number":13,"state":"OPEN","labels":[{"name":"status:in-progress"}],"title":"wip","body":"Charter: #1"},
 {"number":15,"state":"OPEN","labels":[{"name":"type:agent"}],"title":"leaf fifteen","body":"Charter: #1\nDepends-on: #99\n## Acceptance (machine)\n- check: true"},
 {"number":17,"state":"OPEN","labels":[{"name":"type:agent"}],"title":"leaf seventeen","body":"Charter: #1\nDepends-on: #16\n## Acceptance (machine)\n- check: true"},
 {"number":99,"state":"CLOSED","labels":[],"body":"dep done"},
 {"number":16,"state":"CLOSED","labels":[],"body":"Charter: #1"}
]
JSON
OUT="$("$CLI" status --board-file "$BOARD" 2>&1)"
printf '%s' "$OUT" | grep -q "Launchable now"                  && ok "status: has Launchable section" || ko "status: no section"
for n in 10 15 17; do printf '%s' "$OUT" | grep -q "#$n " && ok "status: launchable #$n shown" || ko "status: #$n missing"; done
printf '%s' "$OUT" | grep -q "#1 goal A"                        && ok "status: charter #1 listed" || ko "status: charter missing"
{ printf '%s' "$OUT" | grep -q "In progress" && printf '%s' "$OUT" | grep -q "#13"; } && ok "status: in-progress section shows #13" || ko "status: in-progress"

echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
