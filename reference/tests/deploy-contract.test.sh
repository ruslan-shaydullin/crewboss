#!/usr/bin/env bash
# deploy-contract.test.sh — deploy-env auto-loop P1 fix (issue #117, finding F9).
#
# Tests RED-a … RED-e as specified in the issue acceptance matrix.
# All tests model the REAL deploy env (what run-charter.sh exports), NOT a convenience env.
#
# RED-a: cmd_run without CB_GIT_REMOTE → log contains "DISABLED" + "CB_GIT_REMOTE"
# RED-b: run-charter.sh (sandbox HOME + stub launcher) exports CB_GIT_REMOTE + CB_PLAN_SPAWN
# RED-c: crewboss-prep-spawn-gh.sh tech-lead prompt has "type:agent" + "## Acceptance (machine)"
# RED-d: cmd_run needs-plan charter: CB_PLAN_SPAWN used; CB_SPAWN (exit-2) NOT used → not blocked
# RED-e: crewboss-prep-spawn-gh.sh for charter leaf → branch prefix is leaf/, not task/
#
# Requires: jq, git, bash, flock.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
LAUNCHER="${LAUNCHER_OVERRIDE:-$HERE/../runtime/crewboss-launcher-gh.sh}"
RUN_CHARTER="$REPO_ROOT/reference/runtime/run-charter.sh"
PREP_SPAWN="$REPO_ROOT/reference/runtime/crewboss-prep-spawn-gh.sh"
BOARD_GH_SRC="$REPO_ROOT/proto/r6/board-gh.sh"
LAUNCHABLE_SRC="$REPO_ROOT/proto/r6/launchable.sh"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"; mkdir -p "$BIN"

BOARD_STATE="$ROOT/board.json"
GH_LOG="$ROOT/gh.log"
export BOARD_STATE GH_LOG

pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

has_label(){
  [ "$(jq -r --argjson n "$1" \
    'map(select(.number==$n))[0].labels[]?.name' "$BOARD_STATE" \
    | grep -c "^$2$")" -ge 1 ]
}

# ── shared gh stub (stateful board-JSON mutations) ─────────────────────────────
cat > "$BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
obj="$1"; verb="$2"; shift 2

_args=()
while [ $# -gt 0 ]; do
  case "$1" in -R|--repo|-L|--limit) shift ;; *) _args+=("$1") ;; esac; shift
done
set -- "${_args[@]+"${_args[@]}"}"

case "$obj $verb" in
  "auth token")
    printf 'testtoken\n'; exit 0 ;;

  "issue list")
    cat "$BOARD_STATE" ;;

  "issue view")
    n="$1"; shift; jqf=""
    while [ $# -gt 0 ]; do case "$1" in --jq|-q) jqf="$2"; shift ;; esac; shift; done
    o="$(jq --argjson n "$n" 'map(select(.number==$n))[0] // {}' "$BOARD_STATE")"
    if [ -n "$jqf" ]; then printf '%s' "$o" | jq -r "$jqf"; else printf '%s\n' "$o"; fi ;;

  "issue edit")
    n="$1"; shift
    adds=(); rems=()
    while [ $# -gt 0 ]; do
      case "$1" in --add-label) adds+=("$2"); shift ;; --remove-label) rems+=("$2"); shift ;; esac
      shift
    done
    adds_json="$(printf '%s\n' "${adds[@]+"${adds[@]}"}" | jq -R . | jq -s .)"
    rems_json="$(printf '%s\n' "${rems[@]+"${rems[@]}"}" | jq -R . | jq -s .)"
    jq --argjson n "$n" --argjson adds "$adds_json" --argjson rems "$rems_json" '
      map(if .number == $n then
        .labels = [(.labels // [])[] | select(.name as $nm | ($rems | index($nm)) == null)]
        | reduce $adds[] as $a (.;
            if ([.labels[].name] | index($a)) == null
            then .labels += [{name: $a}] else . end)
      else . end)' \
      "$BOARD_STATE" > "$BOARD_STATE.t" && mv "$BOARD_STATE.t" "$BOARD_STATE"
    { printf 'edit #%s' "$n"
      [ "${#adds[@]}" -gt 0 ] && printf ' +[%s]' "${adds[*]}"
      [ "${#rems[@]}" -gt 0 ] && printf ' -[%s]' "${rems[*]}"
      printf '\n'; } >> "$GH_LOG" ;;

  "issue comment")
    n="$1"; shift; body=""
    while [ $# -gt 0 ]; do case "$1" in --body|-b) body="$2"; shift ;; esac; shift; done
    jq --argjson n "$n" --arg b "$body" \
      'map(if .number==$n then .comments=((.comments//[])+[{body:$b}]) else . end)' \
      "$BOARD_STATE" > "$BOARD_STATE.t" && mv "$BOARD_STATE.t" "$BOARD_STATE"
    echo "comment #$n: $body" >> "$GH_LOG" ;;

  "issue close")
    n="$1"
    jq --argjson n "$n" 'map(if .number==$n then .state="CLOSED" else . end)' \
      "$BOARD_STATE" > "$BOARD_STATE.t" && mv "$BOARD_STATE.t" "$BOARD_STATE"
    echo "close #$n" >> "$GH_LOG" ;;

  "pr list") printf '[]\n' ;;
  "pr create") ;;
  "label create") ;;

  *) echo "gh-stub UNHANDLED: $obj $verb $*" >> "$GH_LOG" ;;
esac
exit 0
GHEOF
chmod +x "$BIN/gh"

# =============================================================================
# RED-a: cmd_run WITHOUT CB_GIT_REMOTE → log must contain "DISABLED" + "CB_GIT_REMOTE"
# Before fix: _integrator_cycle and _charter_finale_cycle silently return 0 — no log line.
# After fix : one visible log line per run "integrator+finale DISABLED: CB_GIT_REMOTE not set".
# =============================================================================
echo "== RED-a: no CB_GIT_REMOTE → log contains DISABLED + CB_GIT_REMOTE =="

CBHOME_A="$ROOT/cbhome_a"
mkdir -p "$CBHOME_A"
cp "$BOARD_GH_SRC"  "$CBHOME_A/board-gh.sh"
cp "$LAUNCHABLE_SRC" "$CBHOME_A/launchable.sh"
chmod +x "$CBHOME_A/board-gh.sh" "$CBHOME_A/launchable.sh"

# Empty board: loop exits idle immediately
cat > "$BOARD_STATE" <<'JSON'
[]
JSON
: > "$GH_LOG"

# Spawn stub that exits 0 immediately
cat > "$ROOT/noop-spawn.sh" <<'SPEOF'
#!/usr/bin/env bash
exit 0
SPEOF
chmod +x "$ROOT/noop-spawn.sh"

# Run launcher WITHOUT CB_GIT_REMOTE; capture output
launcher_out=$(
  PATH="$BIN:$PATH" \
  CB_REPO="test/repo" \
  CB_HOME="$CBHOME_A" \
  CB_SPAWN="$ROOT/noop-spawn.sh" \
  CB_POLL=0 \
  CB_MAX_TICKS=5 \
  CB_IDLE_CONFIRM=1 \
  bash "$LAUNCHER" run 2>&1
)

printf '%s' "$launcher_out" | grep -q "DISABLED" \
  && ok "RED-a: log contains 'DISABLED'" \
  || ko "RED-a: log does NOT contain 'DISABLED' (got: $(printf '%s' "$launcher_out" | head -5))"

printf '%s' "$launcher_out" | grep -q "CB_GIT_REMOTE" \
  && ok "RED-a: log mentions 'CB_GIT_REMOTE'" \
  || ko "RED-a: log does NOT mention 'CB_GIT_REMOTE'"

# Verify it logs at most once (not on every tick — debounce guard)
count=$(printf '%s' "$launcher_out" | grep -c "DISABLED" || true)
[ "$count" -le 2 ] \
  && ok "RED-a: DISABLED message not repeated excessively (count=$count)" \
  || ko "RED-a: DISABLED message repeated $count times (should be ≤2 per run)"

# =============================================================================
# RED-b: run-charter.sh (sandbox HOME) exports CB_GIT_REMOTE and CB_PLAN_SPAWN
# Before fix: run-charter.sh never exports these → absent from env stub receives.
# After fix : CB_GIT_REMOTE="https://x-access-token:..." + CB_PLAN_SPAWN set.
# Test models ACTUAL deploy env: real run-charter.sh is executed, HOME is redirected.
# =============================================================================
echo "== RED-b: run-charter.sh exports CB_GIT_REMOTE and CB_PLAN_SPAWN =="

FAKE_HOME="$ROOT/fake_home"
mkdir -p "$FAKE_HOME/cbnet/run"

# Stub .crewboss.env — real token replaced with test value
cat > "$FAKE_HOME/.crewboss.env" <<'ENVEOF'
GH_TOKEN=testtoken
ENVEOF

# Stub launcher: dumps env to env.dump, writes one line to launcher.out so tail -1 returns
cat > "$FAKE_HOME/cbnet/crewboss-launcher-gh.sh" <<'LAUNCHEOF'
#!/usr/bin/env bash
env > "$HOME/cbnet/run/env.dump"
echo "[launcher-gh] env dumped (stub)"
LAUNCHEOF
chmod +x "$FAKE_HOME/cbnet/crewboss-launcher-gh.sh"

# Run run-charter.sh with fake HOME (takes ~2s due to sleep 2 in the script)
HOME="$FAKE_HOME" PATH="$BIN:$PATH" bash "$RUN_CHARTER" >/dev/null 2>&1 || true

# Wait briefly for background stub to finish (it writes quickly; sleep 2 in run-charter.sh covers it)
ENV_DUMP="$FAKE_HOME/cbnet/run/env.dump"

[ -f "$ENV_DUMP" ] \
  && ok "RED-b: env.dump created by launcher stub" \
  || ko "RED-b: env.dump NOT found at $ENV_DUMP"

if [ -f "$ENV_DUMP" ]; then
  grep -q "^CB_GIT_REMOTE=" "$ENV_DUMP" \
    && ok "RED-b: CB_GIT_REMOTE present in launcher env" \
    || ko "RED-b: CB_GIT_REMOTE NOT in launcher env (expected export from run-charter.sh)"

  grep -q "^CB_PLAN_SPAWN=" "$ENV_DUMP" \
    && ok "RED-b: CB_PLAN_SPAWN present in launcher env" \
    || ko "RED-b: CB_PLAN_SPAWN NOT in launcher env (expected export from run-charter.sh)"

  # Value sanity: CB_GIT_REMOTE should contain the repo URL (not empty)
  val=$(grep "^CB_GIT_REMOTE=" "$ENV_DUMP" | head -1 | cut -d= -f2-)
  [ -n "$val" ] \
    && ok "RED-b: CB_GIT_REMOTE is non-empty (val: ${val:0:30}...)" \
    || ko "RED-b: CB_GIT_REMOTE is empty"
fi

# =============================================================================
# RED-c: crewboss-prep-spawn-gh.sh tech-lead prompt contains "type:agent" and
#        "## Acceptance (machine)".
# Before fix: prompt only mentions gh issue create + plan-review edit — no type:agent or
#             acceptance block instructions.
# After fix : prompt explicitly instructs both.
# =============================================================================
echo "== RED-c: tech-lead prompt contains type:agent and ## Acceptance (machine) =="

CBHOME_C="$ROOT/cbhome_c"
mkdir -p "$CBHOME_C/run" "$CBHOME_C/repo-cache"

cp "$LAUNCHABLE_SRC" "$CBHOME_C/launchable.sh"
chmod +x "$CBHOME_C/launchable.sh"

# board-gh.sh stub for RED-c: returns pr_repo + prompt for get queries
cat > "$CBHOME_C/board-gh.sh" <<'BOARDEOF'
#!/usr/bin/env bash
ID="${2:-}"; FIELD="${3:-}"
case "$FIELD" in
  pr_repo)  echo "test/repo" ;;
  prompt)   echo "Charter goal: build something" ;;
  charter)  echo "" ;;
  *)        echo "" ;;
esac
exit 0
BOARDEOF
chmod +x "$CBHOME_C/board-gh.sh"

# crewboss-spawn.sh stub for RED-c (exec at end of prep-spawn)
cat > "$CBHOME_C/crewboss-spawn.sh" <<'SPAWNEOF'
#!/usr/bin/env bash
exit 0
SPAWNEOF
chmod +x "$CBHOME_C/crewboss-spawn.sh"

# Pre-create a fake git repo cache so the clone-from-cache step succeeds
# (task.prompt is written BEFORE the git ops; even if checkout fails, prompt is already there)
CACHE_REPO="$CBHOME_C/repo-cache/test_repo.git"
git init --bare -q "$CACHE_REPO" 2>/dev/null
_ctmp="$(mktemp -d)"
git clone -q "$CACHE_REPO" "$_ctmp/work" 2>/dev/null
git -C "$_ctmp/work" config user.email t@t 2>/dev/null
git -C "$_ctmp/work" config user.name T 2>/dev/null
echo "init" > "$_ctmp/work/README.md"
git -C "$_ctmp/work" add -A 2>/dev/null
git -C "$_ctmp/work" commit -qm init 2>/dev/null
git -C "$_ctmp/work" push -q origin HEAD:refs/heads/main 2>/dev/null
rm -rf "$_ctmp"

# Run prep-spawn with role=tech-lead (script writes task.prompt before git ops that may fail)
PATH="$BIN:$PATH" CB_HOME="$CBHOME_C" \
  bash "$PREP_SPAWN" 100 tech-lead 2>/dev/null || true

TASK_PROMPT_C="$CBHOME_C/run/work/100/task.prompt"
[ -f "$TASK_PROMPT_C" ] \
  && ok "RED-c: task.prompt created for tech-lead" \
  || ko "RED-c: task.prompt NOT found at $TASK_PROMPT_C"

if [ -f "$TASK_PROMPT_C" ]; then
  grep -q "type:agent" "$TASK_PROMPT_C" \
    && ok "RED-c: prompt contains 'type:agent'" \
    || ko "RED-c: prompt does NOT contain 'type:agent' — tech-lead won't label leaves correctly"

  grep -q "## Acceptance (machine)" "$TASK_PROMPT_C" \
    && ok "RED-c: prompt contains '## Acceptance (machine)'" \
    || ko "RED-c: prompt does NOT contain '## Acceptance (machine)' — leaves will not be launchable"
fi

# =============================================================================
# RED-d: cmd_run with needs-plan charter: planning uses CB_PLAN_SPAWN (not CB_SPAWN).
# Before fix: line 398 calls "$SPAWN" for tech-lead → exit-2 stub causes blocked after RETRY_CAP.
# After fix : line 398 calls "$PLAN_SPAWN" → logger+plan-review stub → charter not blocked.
# =============================================================================
echo "== RED-d: planning uses CB_PLAN_SPAWN; CB_SPAWN (exit-2 stub) not called for planning =="

CBHOME_D="$ROOT/cbhome_d"
mkdir -p "$CBHOME_D"
cp "$BOARD_GH_SRC"  "$CBHOME_D/board-gh.sh"
cp "$LAUNCHABLE_SRC" "$CBHOME_D/launchable.sh"
chmod +x "$CBHOME_D/board-gh.sh" "$CBHOME_D/launchable.sh"

PLAN_LOG="$ROOT/plan_spawn.log"
SPAWN_LOG_D="$ROOT/spawn_d.log"
export PLAN_LOG SPAWN_LOG_D BOARD_STATE GH_LOG

# CB_SPAWN stub: simulates charter-leaf-prep.sh behavior — exits 2 if called for a charter body
cat > "$ROOT/bad-spawn.sh" <<'BADEOF'
#!/usr/bin/env bash
echo "bad_spawn called: $1 $2" >> "$SPAWN_LOG_D"
exit 2
BADEOF
chmod +x "$ROOT/bad-spawn.sh"

# CB_PLAN_SPAWN stub: logs the call AND sets charter to plan-review so launcher considers success
cat > "$ROOT/plan-spawn.sh" <<'PLANEOF'
#!/usr/bin/env bash
ID="$1"; ROLE="$2"
echo "plan_spawn: $ID $ROLE" >> "$PLAN_LOG"
# Set plan-review so the launcher considers planning successful (not retried/blocked)
gh issue edit "$ID" -R "test/repo" \
  --add-label status:plan-review \
  --remove-label status:needs-plan 2>/dev/null || true
exit 0
PLANEOF
chmod +x "$ROOT/plan-spawn.sh"

# Board: one needs-plan charter, no leaves yet
cat > "$BOARD_STATE" <<'JSON'
[
  {"number":7,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:needs-plan"}],
   "body":"the charter","comments":[]}
]
JSON
: > "$GH_LOG"
: > "$PLAN_LOG"
: > "$SPAWN_LOG_D"

PATH="$BIN:$PATH" \
  CB_REPO="test/repo" \
  CB_HOME="$CBHOME_D" \
  CB_SPAWN="$ROOT/bad-spawn.sh" \
  CB_PLAN_SPAWN="$ROOT/plan-spawn.sh" \
  CB_POLL=0 \
  CB_MAX_TICKS=20 \
  CB_IDLE_CONFIRM=2 \
  CB_MAX_PARALLEL=2 \
  CB_RETRY_CAP=2 \
  bash "$LAUNCHER" run 2>/dev/null

grep -q "plan_spawn:" "$PLAN_LOG" \
  && ok "RED-d: CB_PLAN_SPAWN was called for charter planning" \
  || ko "RED-d: CB_PLAN_SPAWN was NOT called — planning still uses CB_SPAWN"

! grep -q "bad_spawn called:" "$SPAWN_LOG_D" \
  && ok "RED-d: CB_SPAWN (exit-2 stub) was NOT called for charter planning" \
  || ko "RED-d: CB_SPAWN was called for charter planning — spawn not separated"

! has_label 7 "status:blocked" \
  && ok "RED-d: charter #7 is NOT blocked" \
  || ko "RED-d: charter #7 is BLOCKED — planning incorrectly called CB_SPAWN (exit 2)"

# =============================================================================
# RED-e: crewboss-prep-spawn-gh.sh for charter leaf → branch prefix leaf/, not task/
# Before fix: BRANCH="task/$ID-$TS" for all non-tech-lead roles → integrator can't find PR.
# After fix : BRANCH="leaf/$ID-$TS" when charter is present → integrator matches leaf/<id>-.
# =============================================================================
echo "== RED-e: charter leaf gets branch prefix leaf/ (not task/) =="

CBHOME_E="$ROOT/cbhome_e"
mkdir -p "$CBHOME_E/run" "$CBHOME_E/repo-cache"

cp "$LAUNCHABLE_SRC" "$CBHOME_E/launchable.sh"
chmod +x "$CBHOME_E/launchable.sh"

# board-gh.sh stub for RED-e: leaf belongs to charter #5
cat > "$CBHOME_E/board-gh.sh" <<'BOARDEOF'
#!/usr/bin/env bash
ID="${2:-}"; FIELD="${3:-}"
case "$FIELD" in
  pr_repo)  echo "test/repo" ;;
  prompt)   echo "Fix the widget" ;;
  charter)  echo "5" ;;
  *)        echo "" ;;
esac
exit 0
BOARDEOF
chmod +x "$CBHOME_E/board-gh.sh"

# crewboss-spawn.sh stub for RED-e
cat > "$CBHOME_E/crewboss-spawn.sh" <<'SPAWNEOF'
#!/usr/bin/env bash
exit 0
SPAWNEOF
chmod +x "$CBHOME_E/crewboss-spawn.sh"

# Pre-create fake git repo cache for executor path
CACHE_REPO_E="$CBHOME_E/repo-cache/test_repo.git"
git init --bare -q "$CACHE_REPO_E" 2>/dev/null
_etmp="$(mktemp -d)"
git clone -q "$CACHE_REPO_E" "$_etmp/work" 2>/dev/null
git -C "$_etmp/work" config user.email t@t 2>/dev/null
git -C "$_etmp/work" config user.name T 2>/dev/null
echo "init" > "$_etmp/work/README.md"
git -C "$_etmp/work" add -A 2>/dev/null
git -C "$_etmp/work" commit -qm init 2>/dev/null
git -C "$_etmp/work" push -q origin HEAD:refs/heads/main 2>/dev/null
# Also create charter/5 so the checkout can succeed
git -C "$_etmp/work" push -q origin HEAD:refs/heads/charter/5 2>/dev/null
rm -rf "$_etmp"

# Run prep-spawn with role=executor and a charter leaf
# task.prompt is written before git checkout, so we read it even if checkout fails
PATH="$BIN:$PATH" CB_HOME="$CBHOME_E" \
  bash "$PREP_SPAWN" 200 executor 2>/dev/null || true

TASK_PROMPT_E="$CBHOME_E/run/work/200/task.prompt"
[ -f "$TASK_PROMPT_E" ] \
  && ok "RED-e: task.prompt created for charter leaf executor" \
  || ko "RED-e: task.prompt NOT found at $TASK_PROMPT_E"

if [ -f "$TASK_PROMPT_E" ]; then
  grep -q "leaf/200-" "$TASK_PROMPT_E" \
    && ok "RED-e: prompt branch is leaf/200-<ts> (correct prefix for integrator)" \
    || ko "RED-e: prompt does NOT contain leaf/200- prefix (integrator won't find the PR)"

  ! grep -q "task/200-" "$TASK_PROMPT_E" \
    && ok "RED-e: prompt does NOT contain task/ prefix" \
    || ko "RED-e: prompt still mentions task/200- (old prefix — integrator mismatch bug)"
fi

# =============================================================================
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
