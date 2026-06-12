#!/usr/bin/env bash
# gate-integrator.test.sh — Layer-A/B gate tests for the integrator role (issue #88).
# Class iii: PreToolUse-JSON on stdin, stub gh in PATH.
# RED->green: all 4 RED scenarios were failing before the integrator gate branch was added.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$HERE/../.claude/hooks/crewboss-gate.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"

# gh shim: serves canned fixtures from $GH_FIXTURES.
# Supported calls:
#   gh pr view N [--json ...]       -> pr-N.json
#   gh pr list --head task/N [...]  -> prlist-N.json
# Missing fixture => exit 1 (simulates gh failure -> fail-closed paths).
cat > "$BIN/gh" <<'SHIM'
#!/usr/bin/env bash
obj="$1"; verb="$2"; shift 2
jqf=""; num=""; head=""
while [ $# -gt 0 ]; do
  case "$1" in
    --json|--state|-L|--limit) shift ;;
    -q|--jq) jqf="$2"; shift ;;
    --head) head="$2"; shift ;;
    -*) ;;
    *) [ -z "$num" ] && num="$1" ;;
  esac
  shift
done
case "$obj $verb" in
  "pr view")  f="$GH_FIXTURES/pr-${num}.json" ;;
  "pr list")  n="${head#task/}"; f="$GH_FIXTURES/prlist-${n}.json" ;;
  *)          exit 1 ;;
esac
[ -f "$f" ] || exit 1
if [ -n "$jqf" ]; then jq -r "$jqf" "$f"; else cat "$f"; fi
SHIM
chmod +x "$BIN/gh"

pass=0; fail=0
fx(){ export GH_FIXTURES="$TMP/fx-$1"; mkdir -p "$GH_FIXTURES"; }
wf(){ printf '%s' "$2" > "$GH_FIXTURES/$1"; }
run(){
  local name="$1" role="$2" cmd="$3" exp="$4" json rc
  json=$(jq -nc --arg r "$role" --arg c "$cmd" \
    '{tool_name:"Bash",agent_type:$r,tool_input:{command:$c}}')
  printf '%s' "$json" | PATH="$BIN:$PATH" bash "$GATE" >/dev/null 2>&1; rc=$?
  if [ "$rc" = "$exp" ]; then
    pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else
    fail=$((fail+1)); printf 'FAIL %s (got %s, want %s)\n' "$name" "$rc" "$exp"
  fi
}

# ── RED-a: integrator merges PR 7 into charter/5, checks green → allow ──────────────
# Before fix: role unknown to gate → falls through Layer A → deny (not tech-lead). RED.
fx a
wf pr-7.json '{"baseRefName":"charter/5","statusCheckRollup":[{"conclusion":"SUCCESS"}]}'
run "RED-a: integrator merge charter/5 (green) -> allow" integrator "gh pr merge 7" 0

# ── RED-b: integrator tries to merge into main → deny (charter→main: human only) ────
# Formalises the charter #84 invariant before AND after implementation: always exit 2.
fx b
wf pr-7.json '{"baseRefName":"main","reviewDecision":"APPROVED","statusCheckRollup":[{"conclusion":"SUCCESS"}]}'
run "RED-b: integrator merge main (approved+green) -> deny (invariant)" integrator "gh pr merge 7" 2

# ── RED-c: executor cannot merge into charter branch (roles not widened) ─────────────
fx c
wf pr-7.json '{"baseRefName":"charter/5","statusCheckRollup":[{"conclusion":"SUCCESS"}]}'
run "RED-c: executor merge charter/5 -> deny (wrong role)" executor "gh pr merge 7" 2

# ── RED-d: integrator closes leaf #10 ────────────────────────────────────────────────
# With MERGED PR into charter/5 → allow
fx d1
wf prlist-10.json '[{"number":42,"state":"MERGED","baseRefName":"charter/5"}]'
run "RED-d (ok): integrator close #10 (MERGED PR charter/5) -> allow" integrator "gh issue close 10" 0

# Same leaf, no merged PR → deny
fx d2
wf prlist-10.json '[{"number":43,"state":"OPEN","baseRefName":"charter/5"}]'
run "RED-d (deny): integrator close #10 (OPEN PR only) -> deny" integrator "gh issue close 10" 2

# ── Extra hardening scenarios ────────────────────────────────────────────────────────
fx e
wf pr-7.json '{"baseRefName":"charter/5","statusCheckRollup":[{"conclusion":"FAILURE"}]}'
run "extra: integrator merge charter/5 (red checks) -> deny" integrator "gh pr merge 7" 2

fx f
wf pr-7.json '{"baseRefName":"charter/abc","statusCheckRollup":[{"conclusion":"SUCCESS"}]}'
run "extra: integrator merge charter/abc (non-numeric) -> deny" integrator "gh pr merge 7" 2

fx g
run "extra: integrator merge, gh unreadable -> deny (fail-closed)" integrator "gh pr merge 7" 2

fx h
run "extra: integrator gh issue create -> deny (no board-authorship)" integrator "gh issue create -t x -b y" 2

fx i
run "extra: integrator close #10, gh unreadable -> deny (fail-closed)" integrator "gh issue close 10" 2

echo
echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
