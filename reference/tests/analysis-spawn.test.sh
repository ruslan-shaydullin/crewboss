#!/usr/bin/env bash
# analysis-spawn.test.sh — manifest analysis stage integration tests (issue #136).
# Class i: integration-stub. Real launcher + board-gh.sh over gh-stub file-board;
# ANALYSIS_SPAWN stub journals <id> <role> and optionally routes the charter;
# CB_MANIFEST = copy of team-example; labels follow labels-setup.sh canon;
# poll by board-gh get state — no sleep.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER="${LAUNCHER_OVERRIDE:-$HERE/../runtime/crewboss-launcher-gh.sh}"
PREP_SPAWN="${PREP_SPAWN_OVERRIDE:-$HERE/../runtime/crewboss-prep-spawn-gh.sh}"
BOARD_GH_SRC="$HERE/../../proto/r6/board-gh.sh"
LAUNCHABLE_SRC="$HERE/../../proto/r6/launchable.sh"
MANIFEST_LIB="$HERE/../launcher/manifest.sh"
TEAM_EXAMPLE="$(cd "$HERE/../../team-example" && pwd)"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

# ── shared state (exported so stubs can read them) ──────────────────────────
SANDBOX="$ROOT/sb"
BOARD_STATE="$SANDBOX/board.json"
GH_LOG="$SANDBOX/gh.log"
PRDIR="$SANDBOX/prs"
export SANDBOX BOARD_STATE GH_LOG PRDIR

BIN="$ROOT/bin"; mkdir -p "$BIN"

# ── helpers ──────────────────────────────────────────────────────────────────
has_label(){ [ "$(jq -r --argjson n "$1" 'map(select(.number==$n))[0].labels[]?.name' \
                 "$BOARD_STATE" | grep -c "^$2$")" -ge 1 ]; }
has_comment(){ jq -r --argjson n "$1" 'map(select(.number==$n))[0].comments[]?.body' \
                 "$BOARD_STATE" | grep -qi "$2"; }
board_state(){ CB_REPO="test/repo" bash "$1/board-gh.sh" get "$2" state 2>/dev/null || echo "unknown"; }
analysis_log_count(){ local n; n=$(grep -c "^$1 " "$SANDBOX/analysis.log" 2>/dev/null) || n=0; echo "$n"; }
plan_log_count(){     local n; n=$(grep -c "^$1 " "$SANDBOX/plan.log"     2>/dev/null) || n=0; echo "$n"; }
ghlog_has(){ grep -q "$1" "$GH_LOG" 2>/dev/null; }

# ── gh stub (file-board) ─────────────────────────────────────────────────────
cat > "$BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
obj="$1"; verb="$2"; shift 2
_args=()
while [ $# -gt 0 ]; do
  case "$1" in -R|--repo|-L|--limit) shift ;; *) _args+=("$1") ;; esac; shift
done
set -- "${_args[@]+"${_args[@]}"}"
case "$obj $verb" in
  "auth token") printf 'fake-token\n' ;;

  "issue list")
    cat "$BOARD_STATE" ;;

  "issue view")
    n="$1"; shift; jqf=""
    while [ $# -gt 0 ]; do case "$1" in --jq|-q) jqf="$2"; shift ;; esac; shift; done
    o="$(jq --argjson n "$n" 'map(select(.number==$n))[0] // {}' "$BOARD_STATE")"
    if [ -n "$jqf" ]; then printf '%s' "$o" | jq -r "$jqf"; else printf '%s\n' "$o"; fi ;;

  "issue edit")
    n="$1"; shift; adds=(); rems=()
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
    echo "comment #$n" >> "$GH_LOG" ;;

  "issue close")
    n="$1"
    jq --argjson n "$n" 'map(if .number==$n then .state="CLOSED" else . end)' \
      "$BOARD_STATE" > "$BOARD_STATE.t" && mv "$BOARD_STATE.t" "$BOARD_STATE" ;;

  "pr list")    printf '[]\n' ;;
  "label create") ;;
  *) echo "gh-stub UNHANDLED: $obj $verb $*" >> "$GH_LOG" ;;
esac
exit 0
GHEOF
chmod +x "$BIN/gh"

# ── cbhome setup ─────────────────────────────────────────────────────────────
setup_cbhome(){
  local cbhome="$1"
  rm -rf "$cbhome"; mkdir -p "$cbhome"
  cp "$BOARD_GH_SRC"   "$cbhome/board-gh.sh"
  cp "$LAUNCHABLE_SRC" "$cbhome/launchable.sh"
  chmod +x "$cbhome/board-gh.sh" "$cbhome/launchable.sh"
}

reset_sandbox(){
  rm -rf "$SANDBOX"; mkdir -p "$SANDBOX" "$PRDIR"
  : > "$GH_LOG"
  : > "$SANDBOX/analysis.log"
  : > "$SANDBOX/plan.log"
}

# ── analysis spawn stub ───────────────────────────────────────────────────────
# On success: posts ## Composition (machine) comment + routes to team-review.
# On failure: logs but does not route (charter stays in needs-analysis).
# Failure injection: $SANDBOX/analysis-fail-$ID = N → fail N times before succeeding.
ANALYSIS_STUB="$ROOT/analysis-stub.sh"
cat > "$ANALYSIS_STUB" <<'AEOF'
#!/usr/bin/env bash
ID="$1"; ROLE="$2"
printf '%s %s\n' "$ID" "$ROLE" >> "$SANDBOX/analysis.log"
FAIL_FILE="$SANDBOX/analysis-fail-$ID"
if [ -f "$FAIL_FILE" ]; then
  CNT=$(cat "$FAIL_FILE" 2>/dev/null || echo 0)
  if [ "$CNT" -gt 0 ]; then
    printf '%d' "$((CNT-1))" > "$FAIL_FILE"
    exit 0  # exit 0 but no board transition → launcher sees failure (state != team-review)
  fi
fi
CB_HOME="${CB_HOME:-/tmp/cbnet}"
CB_REPO_USE="${CB_REPO:-test/repo}"
COMP="## Composition (machine)
- approach: parallel execution
- role: go-backend-dev
- role: qa-engineer
- leaf: L-1 -> go-backend-dev
- leaf: L-2 -> qa-engineer
- est_cost_usd: 0.5"
gh issue comment "$ID" -R "$CB_REPO_USE" --body "$COMP"
CB_REPO="$CB_REPO_USE" bash "$CB_HOME/board-gh.sh" route "$ID" team-review
exit 0
AEOF
chmod +x "$ANALYSIS_STUB"

# ── plan (tech-lead) spawn stub ───────────────────────────────────────────────
PLAN_STUB="$ROOT/plan-stub.sh"
cat > "$PLAN_STUB" <<'PEOF'
#!/usr/bin/env bash
ID="$1"; ROLE="$2"
printf '%s %s\n' "$ID" "$ROLE" >> "$SANDBOX/plan.log"
CB_HOME="${CB_HOME:-/tmp/cbnet}"
CB_REPO_USE="${CB_REPO:-test/repo}"
CB_REPO="$CB_REPO_USE" bash "$CB_HOME/board-gh.sh" route "$ID" plan-review
exit 0
PEOF
chmod +x "$PLAN_STUB"

# ── manifest copy ─────────────────────────────────────────────────────────────
MANIFEST_DIR="$ROOT/manifest"
cp -r "$TEAM_EXAMPLE/." "$MANIFEST_DIR"

# ── loop runner ───────────────────────────────────────────────────────────────
run_loop(){
  local cbhome="$1" logfile="${2:-/dev/null}"; shift 2
  PATH="$BIN:$PATH" \
    CB_REPO="test/repo" \
    CB_HOME="$cbhome" \
    CB_SPAWN="$PLAN_STUB" \
    CB_PLAN_SPAWN="$PLAN_STUB" \
    CB_ANALYSIS_SPAWN="$ANALYSIS_STUB" \
    CB_MANIFEST="$MANIFEST_DIR" \
    CB_MANIFEST_LIB="$MANIFEST_LIB" \
    CB_POLL=0 \
    CB_MAX_TICKS=40 \
    CB_IDLE_CONFIRM=2 \
    CB_MAX_PARALLEL=4 \
    CB_RETRY_CAP=3 \
    CREWBOSS_CHARTER= \
    env "$@" \
    bash "$LAUNCHER" run >"$logfile" 2>&1 || true
}

# =============================================================================
# RED-1: needs-plan charter + CB_MANIFEST → first spawn is solution-analyst
# =============================================================================
echo "== RED-1: needs-plan + CB_MANIFEST → solution-analyst spawned (not tech-lead) =="
CBHOME_1="$ROOT/cbhome1"; setup_cbhome "$CBHOME_1"; reset_sandbox
cat > "$BOARD_STATE" <<'JSON'
[
  {"number":10,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:needs-plan"}],
   "body":"charter goal","comments":[]}
]
JSON
LOGFILE_1="$ROOT/loop1.log"
run_loop "$CBHOME_1" "$LOGFILE_1"
analysis_count=$(analysis_log_count 10)
plan_count=$(plan_log_count 10)
[ "$analysis_count" -ge 1 ] \
  && ok "RED-1: solution-analyst spawned for charter #10" \
  || ko "RED-1: solution-analyst NOT spawned (analysis.log count=$analysis_count; log: $(tail -5 "$LOGFILE_1"))"
# Verify the spawned role is the one from org.json (solution-analyst)
grep -q "^10 solution-analyst" "$SANDBOX/analysis.log" 2>/dev/null \
  && ok "RED-1: role is solution-analyst (from org.json)" \
  || ko "RED-1: role mismatch — expected solution-analyst (log: $(cat "$SANDBOX/analysis.log" 2>/dev/null))"
[ "$plan_count" -eq 0 ] \
  && ok "RED-1: tech-lead NOT spawned before analysis" \
  || ko "RED-1: tech-lead was spawned — analysis guard missing"

# =============================================================================
# RED-2: needs-plan → charter transitions to status:needs-analysis
# =============================================================================
echo "== RED-2: needs-plan → charter gets status:needs-analysis before analyst spawn =="
CBHOME_2="$ROOT/cbhome2"; setup_cbhome "$CBHOME_2"; reset_sandbox
cat > "$BOARD_STATE" <<'JSON'
[
  {"number":10,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:needs-plan"}],
   "body":"charter goal","comments":[]}
]
JSON
# Make analysis stub fail so we can observe the intermediate state
printf '99' > "$SANDBOX/analysis-fail-10"
LOGFILE_2="$ROOT/loop2.log"
run_loop "$CBHOME_2" "$LOGFILE_2" "CB_MAX_TICKS=3"
has_label 10 "status:needs-analysis" \
  && ok "RED-2: charter #10 transitioned to status:needs-analysis" \
  || ko "RED-2: charter #10 does NOT have status:needs-analysis (labels: $(jq -r '[map(select(.number==10))[0].labels[].name]' "$BOARD_STATE" 2>/dev/null))"

# =============================================================================
# RED-3 (liveness): loop stays alive while analyst is in flight (team-review later)
# =============================================================================
echo "== RED-3: loop stays alive in needs-analysis and team-review states =="
CBHOME_3="$ROOT/cbhome3"; setup_cbhome "$CBHOME_3"; reset_sandbox
cat > "$BOARD_STATE" <<'JSON'
[
  {"number":10,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:needs-plan"}],
   "body":"charter goal","comments":[]}
]
JSON
LOGFILE_3="$ROOT/loop3.log"
run_loop "$CBHOME_3" "$LOGFILE_3"
# Analysis stub succeeded → charter should be in team-review
has_label 10 "status:team-review" \
  && ok "RED-3: charter #10 reached team-review (analyst ran before any idle exit)" \
  || ko "RED-3: charter #10 NOT in team-review — loop exited idle prematurely (log: $(tail -5 "$LOGFILE_3"))"
# team-review liveness: loop must NOT exit idle while charter waits for human approval
grep -q "idle — run complete" "$LOGFILE_3" \
  && ko "RED-3: loop exited idle — team-review liveness missing (loop should stay alive in team-review)" \
  || ok "RED-3: loop did not exit idle (team-review liveness holds loop alive correctly)"

# =============================================================================
# RED-4: prompt for analysis role contains solution-analyst.md text + rubric.json text
# =============================================================================
echo "== RED-4: prep-spawn generates prompt with role body + rubric for analysis role =="
# Unit test: run prep-spawn directly with ROLE=solution-analyst
CBHOME_4="$ROOT/cbhome4"; setup_cbhome "$CBHOME_4"
PROMPT_SAVED_4="$ROOT/prompt4.txt"
REMOTE_4="$ROOT/remote4.git"
git init --bare -q "$REMOTE_4"
_t4="$(mktemp -d)"
git -C "$_t4" init -q
git -C "$_t4" config user.email t@t; git -C "$_t4" config user.name T
printf 'base\n' > "$_t4/README.md"
git -C "$_t4" add -A; git -C "$_t4" commit -qm init 2>/dev/null
git -C "$_t4" remote add origin "$REMOTE_4"
git -C "$_t4" push -q origin HEAD:refs/heads/main 2>/dev/null || true
rm -rf "$_t4"
CHARTER_JSON_4='{"number":10,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:needs-analysis"}],"body":"charter goal.","comments":[]}'
export REMOTE_4 CHARTER_JSON_4 PROMPT_SAVED_4

# spawn stub: saves prompt file
cat > "$CBHOME_4/crewboss-spawn.sh" << 'SPAWNEOF'
#!/usr/bin/env bash
cat "$3" > "$PROMPT_SAVED_4"
exit 0
SPAWNEOF
chmod +x "$CBHOME_4/crewboss-spawn.sh"

# gh stub for prep-spawn unit test (auth token + board get)
GIT_REAL_4="$(command -v git)"
BIN4="$ROOT/bin4"; mkdir -p "$BIN4"
export GIT_REAL_4 BIN4
cat > "$BIN4/gh" << 'GH4EOF'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "auth token") printf 'fake-token\n'; exit 0 ;;
  "issue view")
    printf '%s\n' "$CHARTER_JSON_4"; exit 0 ;;
esac
exit 0
GH4EOF
chmod +x "$BIN4/gh"
cat > "$BIN4/git" << 'GIT4EOF'
#!/usr/bin/env bash
args=()
for arg in "$@"; do
  if printf '%s\n' "$arg" | grep -q '^https://github\.com/'; then
    args+=("$REMOTE_4")
  else
    args+=("$arg")
  fi
done
exec "$GIT_REAL_4" "${args[@]}"
GIT4EOF
chmod +x "$BIN4/git"

: > "$PROMPT_SAVED_4"
PATH="$BIN4:$PATH" \
  CB_HOME="$CBHOME_4" \
  CB_REPO="test/repo" \
  CB_MANIFEST="$MANIFEST_DIR" \
  CB_MANIFEST_LIB="$MANIFEST_LIB" \
  GH_TOKEN="fake-token" \
  bash "$PREP_SPAWN" 10 solution-analyst > "$ROOT/prep4.log" 2>&1 || true

# Unique phrase from team-example/roles/solution-analyst.md body
grep -q "MANDATORY analysis stage" "$PROMPT_SAVED_4" \
  && ok "RED-4: prompt contains solution-analyst.md unique phrase" \
  || ko "RED-4: prompt missing solution-analyst.md text (log: $(tail -5 "$ROOT/prep4.log"); prompt: $(head -5 "$PROMPT_SAVED_4"))"
# Substring from rubric.json (e.g. trigger id)
grep -q "multi-module" "$PROMPT_SAVED_4" \
  && ok "RED-4: prompt contains rubric.json content (multi-module trigger)" \
  || ko "RED-4: prompt missing rubric.json content"
# Artifact contract
grep -q "Composition (machine)" "$PROMPT_SAVED_4" \
  && ok "RED-4: prompt contains artifact contract header" \
  || ko "RED-4: prompt missing artifact contract"

# =============================================================================
# RED-5a: analyst fails once → re-spawned (journal has cid TWICE)
# =============================================================================
echo "== RED-5a: analyst fails first → re-spawned on retry =="
CBHOME_5a="$ROOT/cbhome5a"; setup_cbhome "$CBHOME_5a"; reset_sandbox
cat > "$BOARD_STATE" <<'JSON'
[
  {"number":10,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:needs-plan"}],
   "body":"charter goal","comments":[]}
]
JSON
# Fail once, then succeed
printf '1' > "$SANDBOX/analysis-fail-10"
LOGFILE_5a="$ROOT/loop5a.log"
run_loop "$CBHOME_5a" "$LOGFILE_5a"
cnt5a=$(analysis_log_count 10)
[ "$cnt5a" -ge 2 ] \
  && ok "RED-5a: analyst re-spawned after failure (journal count=$cnt5a ≥ 2)" \
  || ko "RED-5a: analyst NOT re-spawned (journal count=$cnt5a; log: $(tail -5 "$LOGFILE_5a"))"
# Charter should end up in team-review (second spawn succeeded)
has_label 10 "status:team-review" \
  && ok "RED-5a: charter #10 in team-review after retry" \
  || ko "RED-5a: charter #10 not in team-review after retry"

# =============================================================================
# RED-5b: analyst always fails → blocked at RETRY_CAP
# =============================================================================
echo "== RED-5b: analyst always fails → charter blocked at RETRY_CAP =="
CBHOME_5b="$ROOT/cbhome5b"; setup_cbhome "$CBHOME_5b"; reset_sandbox
cat > "$BOARD_STATE" <<'JSON'
[
  {"number":10,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:needs-plan"}],
   "body":"charter goal","comments":[]}
]
JSON
# Fail many times (more than RETRY_CAP=2)
printf '999' > "$SANDBOX/analysis-fail-10"
LOGFILE_5b="$ROOT/loop5b.log"
run_loop "$CBHOME_5b" "$LOGFILE_5b" "CB_RETRY_CAP=2"
has_label 10 "status:blocked" \
  && ok "RED-5b: charter #10 blocked after RETRY_CAP" \
  || ko "RED-5b: charter #10 NOT blocked — livelock to max-ticks? (log: $(tail -5 "$LOGFILE_5b"))"
# After blocking, status:needs-analysis must not hold the loop alive (blocked exclusion)
grep -q "idle — run complete" "$LOGFILE_5b" \
  && ok "RED-5b: loop exited idle cleanly after blocking" \
  || ko "RED-5b: loop did NOT exit idle — status:needs-analysis+blocked livelock (max-ticks: $(grep -c 'max ticks' "$LOGFILE_5b" 2>/dev/null || echo 0))"

# =============================================================================
# RED-6 (restart): charter in needs-analysis, STATE empty → analyst spawned again
# =============================================================================
echo "== RED-6: charter already in needs-analysis + empty STATE → analyst re-spawned =="
CBHOME_6="$ROOT/cbhome6"; setup_cbhome "$CBHOME_6"; reset_sandbox
# Charter already in needs-analysis (launcher restarted mid-analysis)
cat > "$BOARD_STATE" <<'JSON'
[
  {"number":10,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:needs-analysis"}],
   "body":"charter goal","comments":[]}
]
JSON
# STATE is empty (fresh launcher restart — no pid/term files)
LOGFILE_6="$ROOT/loop6.log"
run_loop "$CBHOME_6" "$LOGFILE_6"
cnt6=$(analysis_log_count 10)
[ "$cnt6" -ge 1 ] \
  && ok "RED-6: analyst spawned for needs-analysis charter after restart" \
  || ko "RED-6: analyst NOT spawned for needs-analysis charter (log: $(tail -5 "$LOGFILE_6"))"
has_label 10 "status:team-review" \
  && ok "RED-6: charter reached team-review after restart-spawn" \
  || ko "RED-6: charter not in team-review after restart (labels: $(jq -r '[map(select(.number==10))[0].labels[].name]' "$BOARD_STATE" 2>/dev/null))"

# =============================================================================
# GREEN-guard: charter with composition:approved → tech-lead, NOT analyst
# =============================================================================
echo "== GREEN-guard: composition:approved → tech-lead spawned, analyst NOT spawned =="
CBHOME_G="$ROOT/cbhomeG"; setup_cbhome "$CBHOME_G"; reset_sandbox
cat > "$BOARD_STATE" <<'JSON'
[
  {"number":10,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:needs-plan"},{"name":"composition:approved"}],
   "body":"charter goal","comments":[]}
]
JSON
LOGFILE_G="$ROOT/loopG.log"
run_loop "$CBHOME_G" "$LOGFILE_G"
plan_cnt_g=$(plan_log_count 10)
ana_cnt_g=$(analysis_log_count 10)
[ "$ana_cnt_g" -eq 0 ] \
  && ok "GREEN-guard: analyst NOT spawned for composition:approved charter" \
  || ko "GREEN-guard: analyst was spawned — guard missing (analysis.log: $(cat "$SANDBOX/analysis.log" 2>/dev/null))"
[ "$plan_cnt_g" -ge 1 ] \
  && ok "GREEN-guard: tech-lead spawned for composition:approved charter" \
  || ko "GREEN-guard: tech-lead NOT spawned — plannable guard too broad"

# =============================================================================
# GREEN-guard-2 (F-1): after successful analysis, term and tries are empty; no "plan failed"
# =============================================================================
echo "== GREEN-guard-2 (F-1): after success, term/tries empty; no plan-failed log entry =="
# Reuse cbhome1 (RED-1) run which succeeded
STATE_DIR="$CBHOME_1/run/state"
term_val=$(cat "$STATE_DIR/10/term" 2>/dev/null || echo "")
tries_val=$(cat "$STATE_DIR/10/tries" 2>/dev/null || echo "")
[ -z "$term_val" ] \
  && ok "GREEN-guard-2: \$STATE/10/term is empty after successful analysis" \
  || ko "GREEN-guard-2: \$STATE/10/term='$term_val' (should be empty; F-1 contract violated)"
[ -z "$tries_val" ] \
  && ok "GREEN-guard-2: \$STATE/10/tries is empty after successful analysis" \
  || ko "GREEN-guard-2: \$STATE/10/tries='$tries_val' (should be empty; F-1 contract violated)"
grep -q "plan failed" "$LOGFILE_1" \
  && ko "GREEN-guard-2: 'plan failed' found in loop log — analysis spawn fell into charter branch" \
  || ok "GREEN-guard-2: no 'plan failed' in log — analysis routing is separate from charter"

# =============================================================================
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
