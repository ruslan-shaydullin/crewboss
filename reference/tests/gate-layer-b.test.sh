#!/usr/bin/env bash
# Layer-B (completion proof-contract, gvozd-2) executable tests.
# Stubs `gh` (PATH shim serving canned fixtures) so the gate sees controlled PR/issue state,
# then asserts the merge (§5.2) / ready (§5.2) / close 5-rule (§5.1) verdicts.
# Pairs with gate-layer-a.test.sh (role-scoped command gating). Requires: jq.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$HERE/../.claude/hooks/crewboss-gate.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"

# ── gh shim: serves $GH_FIXTURES/{pr,issue}-<n>.json; missing fixture => exit 1 (gh failure) ──
cat > "$BIN/gh" <<'SHIM'
#!/usr/bin/env bash
obj="$1"; shift; shift          # drop object ("pr"/"issue") and verb ("view")
num=""; jqf=""
while [ $# -gt 0 ]; do
  case "$1" in
    --json) shift ;;            # skip the field list
    -q|--jq) jqf="$2"; shift ;;
    -*) ;;                      # ignore other flags
    *) [ -z "$num" ] && num="$1" ;;
  esac
  shift
done
case "$obj" in
  pr) f="$GH_FIXTURES/pr-$num.json" ;;
  issue) f="$GH_FIXTURES/issue-$num.json" ;;
  *) exit 1 ;;
esac
[ -f "$f" ] || exit 1           # missing fixture => simulate gh failure (fail-closed paths)
if [ -n "$jqf" ]; then jq -r "$jqf" "$f"; else cat "$f"; fi
SHIM
chmod +x "$BIN/gh"

pass=0; fail=0
fx(){ export GH_FIXTURES="$TMP/fx-$1"; mkdir -p "$GH_FIXTURES"; }   # fresh fixtures dir per scenario
wf(){ printf '%s' "$2" > "$GH_FIXTURES/$1"; }                      # wf <filename> <json>
run(){ # run <name> <role> <cmd> <expected_exit>
  local name="$1" role="$2" cmd="$3" exp="$4" json rc
  json=$(jq -nc --arg r "$role" --arg c "$cmd" '{tool_name:"Bash",agent_type:$r,tool_input:{command:$c}}')
  printf '%s' "$json" | PATH="$BIN:$PATH" bash "$GATE" >/dev/null 2>&1; rc=$?
  if [ "$rc" = "$exp" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $name (got exit $rc, want $exp)"; fi
}

# ── merge gate (§5.2): non-author APPROVED + green checks on head ─────────────────────
fx m1; wf pr-7.json '{"reviewDecision":"APPROVED","statusCheckRollup":[{"conclusion":"SUCCESS"}]}'
run "merge: approved + green -> allow"           tech-lead "gh pr merge 7" 0
fx m2; wf pr-7.json '{"reviewDecision":"REVIEW_REQUIRED","statusCheckRollup":[{"conclusion":"SUCCESS"}]}'
run "merge: not approved -> deny"                tech-lead "gh pr merge 7" 2
fx m3; wf pr-7.json '{"reviewDecision":"APPROVED","statusCheckRollup":[{"conclusion":"FAILURE"}]}'
run "merge: red check -> deny"                   tech-lead "gh pr merge 7" 2
fx m4; wf pr-7.json '{"reviewDecision":"APPROVED","statusCheckRollup":[{"conclusion":"SUCCESS"},{"conclusion":"SKIPPED"},{"state":"NEUTRAL"}]}'
run "merge: success+skipped+neutral -> allow"    tech-lead "gh pr merge 7" 0
fx m5  # empty dir: gh pr view fails
run "merge: gh read fails -> deny (fail-closed)" tech-lead "gh pr merge 7" 2
fx m6; wf pr-7.json '{"reviewDecision":"APPROVED","statusCheckRollup":null}'
run "merge: no checks at all -> allow (KNOWN soft spot: rely on branch-protection required-checks)" tech-lead "gh pr merge 7" 0
fx m7  # no number -> gh pr view (current) -> shim miss -> fail-closed
run "merge: no PR number -> deny (fail-closed)"  tech-lead "gh pr merge" 2

# ── ready gate (§5.2): green checks on head (any role at Layer A) ─────────────────────
fx r1; wf pr-7.json '{"statusCheckRollup":[{"conclusion":"SUCCESS"}]}'
run "ready: green -> allow"                      executor "gh pr ready 7" 0
fx r2; wf pr-7.json '{"statusCheckRollup":[{"conclusion":"FAILURE"}]}'
run "ready: red check -> deny"                   executor "gh pr ready 7" 2
fx r3  # gh fails
run "ready: gh read fails -> deny (fail-closed)" executor "gh pr ready 7" 2

# ── close 5-rule (§5.1): role=tech-lead (Layer A already gates close to tech-lead) ────
fx c1; wf issue-7.json '{"labels":[{"name":"type:agent"}],"body":"do it","comments":[],"closedByPullRequestsReferences":[{"number":30}]}'; wf pr-30.json '{"state":"MERGED"}'
run "close: leaf w/ merged PR -> allow (rule 3)" tech-lead "gh issue close 7" 0
fx c2; wf issue-7.json '{"labels":[{"name":"type:human-decision"}],"body":"","comments":[],"closedByPullRequestsReferences":[]}'
run "close: human-owned -> deny (rule 1)"        tech-lead "gh issue close 7" 2
fx c3; wf issue-7.json '{"labels":[{"name":"type:charter"}],"body":"- [ ] #20","comments":[],"closedByPullRequestsReferences":[]}'; wf issue-20.json '{"state":"OPEN"}'
run "close: open child -> deny (rule 2)"         tech-lead "gh issue close 7" 2
fx c4; wf issue-7.json '{"labels":[{"name":"type:charter"}],"body":"- [ ] #20","comments":[],"closedByPullRequestsReferences":[]}'; wf issue-20.json '{"state":"CLOSED"}'
run "close: all children closed -> allow (parent)" tech-lead "gh issue close 7" 0
fx c5; wf issue-7.json '{"labels":[{"name":"type:analysis"}],"body":"","comments":[{"body":"crewboss-digest: findings"}],"closedByPullRequestsReferences":[]}'
run "close: analysis + digest -> allow (rule 4)" tech-lead "gh issue close 7" 0
fx c6; wf issue-7.json '{"labels":[{"name":"type:analysis"}],"body":"","comments":[{"body":"just a note"}],"closedByPullRequestsReferences":[]}'
run "close: analysis, no digest -> deny (rule 4)" tech-lead "gh issue close 7" 2
fx c7; wf issue-7.json '{"labels":[{"name":"type:agent"}],"body":"","comments":[],"closedByPullRequestsReferences":[]}'
run "close: plain leaf, no proof -> deny (rule 5)" tech-lead "gh issue close 7" 2
fx c8; wf issue-7.json '{"labels":[{"name":"type:agent"}],"body":"","comments":[],"closedByPullRequestsReferences":[{"number":30}]}'; wf pr-30.json '{"state":"OPEN"}'
run "close: closing PR not merged -> deny"       tech-lead "gh issue close 7" 2
fx c9  # issue view fails
run "close: gh read fails -> deny (fail-closed)" tech-lead "gh issue close 7" 2
fx c10 # number missing
run "close: no issue number -> deny (fail-closed)" tech-lead "gh issue close" 2

echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
