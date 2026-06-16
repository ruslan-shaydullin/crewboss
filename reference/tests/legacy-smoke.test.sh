#!/usr/bin/env bash
# legacy-smoke.test.sh — characterization pin (HD-1, charter #131).
# Verifies: WITHOUT CB_MANIFEST the launcher behaves byte-for-byte same as now:
#   same spawn sequence (tech-lead → executor), same label transitions,
#   same executor prompt (hard-rules with leaf/<id>- and charter/<C>).
# GREEN on current main by design; RED if any Ф1 manifest-leaf touches the legacy path.
#
# Stand: gh-stub (file-board) + REAL board-gh.sh + REAL launcher run (no CB_MANIFEST);
#   tech-lead-stub logs call and moves charter to plan-review then approved;
#   executor-stub logs call, writes task.prompt (same logic as crewboss-prep-spawn-gh.sh),
#   and sets status.json phase=done.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER="${LAUNCHER_OVERRIDE:-$HERE/../runtime/crewboss-launcher-gh.sh}"
BOARD_GH_SRC="$HERE/../../proto/r6/board-gh.sh"
LAUNCHABLE_SRC="$HERE/../../proto/r6/launchable.sh"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

# ── shared state (exported so stubs can read them) ────────────────────────────
SANDBOX="$ROOT/sb"; mkdir -p "$SANDBOX"
BOARD_STATE="$SANDBOX/board.json"
GH_LOG="$SANDBOX/gh.log"
SPAWN_LOG="$SANDBOX/spawn.log"
CBHOME="$ROOT/cbhome"
export SANDBOX BOARD_STATE GH_LOG SPAWN_LOG CBHOME

BIN="$ROOT/bin"; mkdir -p "$BIN"

# ── gh stub (file-board) ──────────────────────────────────────────────────────
# Handles: issue list/view/edit/comment/close, label create.
# BOARD_STATE and GH_LOG must be exported.
cat > "$BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
obj="$1"; verb="$2"; shift 2

# Strip -R/--repo and -L/--limit flags (with their values)
_args=()
while [ $# -gt 0 ]; do
  case "$1" in -R|--repo|-L|--limit) shift ;; *) _args+=("$1") ;; esac; shift
done
set -- "${_args[@]+"${_args[@]}"}"

case "$obj $verb" in
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

  "label create") ;;  # no-op

  *) echo "gh-stub UNHANDLED: $obj $verb $*" >> "$GH_LOG" ;;
esac
exit 0
GHEOF
chmod +x "$BIN/gh"

# ── Board fixture: charter needs-plan + leaf with acceptance block ────────────
cat > "$BOARD_STATE" <<'JSON'
[
  {"number":5,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:needs-plan"}],
   "body":"the charter goal","comments":[]},
  {"number":10,"state":"OPEN",
   "labels":[{"name":"type:agent"}],
   "body":"task A\nCharter: #5\n## Acceptance (machine)\n- check: true",
   "comments":[]}
]
JSON
: > "$GH_LOG"
: > "$SPAWN_LOG"

# ── cbhome: real board-gh.sh + launchable.sh ─────────────────────────────────
mkdir -p "$CBHOME"
cp "$BOARD_GH_SRC"  "$CBHOME/board-gh.sh"
cp "$LAUNCHABLE_SRC" "$CBHOME/launchable.sh"
chmod +x "$CBHOME/board-gh.sh" "$CBHOME/launchable.sh"
BOARD="$CBHOME/board-gh.sh"

# ── tech-lead spawn stub ──────────────────────────────────────────────────────
# Called as: <stub> <charter_id> tech-lead
# Logs the call; moves charter to plan-review then approved (simulates tech-lead + boss).
TECH_LEAD_STUB="$ROOT/tech-lead.sh"
cat > "$TECH_LEAD_STUB" <<'TLEOF'
#!/usr/bin/env bash
ID="$1"; ROLE="$2"
printf '%s %s\n' "$ID" "$ROLE" >> "$SPAWN_LOG"
# Tech-lead: move charter to plan-review
gh issue edit "$ID" -R "test/repo" \
  --add-label status:plan-review --remove-label status:needs-plan 2>/dev/null || true
# Boss: approve immediately (simulates human sign-off in the same step)
gh issue edit "$ID" -R "test/repo" \
  --add-label status:approved --remove-label status:plan-review 2>/dev/null || true
TLEOF
chmod +x "$TECH_LEAD_STUB"

# ── executor spawn stub ───────────────────────────────────────────────────────
# Called as: <stub> <leaf_id> <role>
# Logs the call; writes task.prompt using the same logic as crewboss-prep-spawn-gh.sh
# (charter-aware hard-rules); writes status.json phase=done so launcher routes to review.
EXEC_STUB="$ROOT/exec.sh"
cat > "$EXEC_STUB" <<'EXEOF'
#!/usr/bin/env bash
ID="$1"; ROLE="$2"
printf '%s %s\n' "$ID" "$ROLE" >> "$SPAWN_LOG"
BOARD_CMD="$CBHOME/board-gh.sh"
RUN="$CBHOME/run"
mkdir -p "$RUN/work/$ID"

CHARTER=$(CB_REPO="test/repo" bash "$BOARD_CMD" get "$ID" charter 2>/dev/null || true)
CB="charter/$CHARTER"
TS=1700000000
BRANCH="leaf/$ID-$TS"
PR_REPO="test/repo"
TASK_BODY=$(CB_REPO="test/repo" bash "$BOARD_CMD" get "$ID" prompt 2>/dev/null || true)

# Same prompt template as crewboss-prep-spawn-gh.sh lines 42-49 (charter-leaf case)
PROMPT="You are the executor for issue #$ID in repo $PR_REPO.
Hard rules for THIS run:
- You are ALREADY on branch \`$BRANCH\`, based on the charter integration branch \`$CB\` (NOT main). Sibling leaves of charter #$CHARTER may already be merged into \`$CB\`. Commit your work on THIS branch. Do NOT create or switch to any other branch.
- When the work is done and the verification gate is green, push this branch (\`git push -u origin HEAD\`) and open ONE pull request: \`gh pr create --base $CB --title '<short>' --body 'Closes #$ID'\`. The PR base MUST be \`$CB\`, NOT main. Then STOP — do not merge, do not touch other issues.
- This issue is self-contained; everything you need is below.

---- TASK (issue #$ID) ----
$TASK_BODY"

printf '%s\n' "$PROMPT" > "$RUN/work/$ID/task.prompt"
printf '{"phase":"done"}\n' > "$RUN/work/$ID/status.json"
EXEOF
chmod +x "$EXEC_STUB"

# ── Assert functions (used by both main test and negative control) ────────────

# assert_spawn_order <log>:
#   line 1 = "<n> tech-lead"   (charter planning)
#   line 2 = "<n> executor"    (leaf execution)
#   total = exactly 2 lines, nothing more
assert_spawn_order(){
  local log="$1" n line1 line2 role1 role2
  [ -f "$log" ] || return 1
  n=$(wc -l < "$log" 2>/dev/null); n="${n// /}"
  [ "$n" -eq 2 ] || return 1
  line1=$(sed -n '1p' "$log")
  line2=$(sed -n '2p' "$log")
  role1=$(printf '%s' "$line1" | awk '{print $2}')
  role2=$(printf '%s' "$line2" | awk '{print $2}')
  [ "$role1" = "tech-lead" ] || return 1
  [ "$role2" = "executor"  ] || return 1
  return 0
}

# assert_no_bad_labels <ghlog>:
#   The GH_LOG must never show status:needs-analysis, status:team-review,
#   or composition:approved being added to any issue (manifest-path labels).
assert_no_bad_labels(){
  local ghlog="$1"
  [ -f "$ghlog" ] || return 0
  grep -qE '\+\[.*(status:needs-analysis|status:team-review|composition:approved)' \
       "$ghlog" 2>/dev/null && return 1
  return 0
}

# assert_prompt_clean <prompt_file> <leaf_id> <charter_id>:
#   Prompt must NOT contain "manifest" / "CB_MANIFEST" (manifest-path indicators).
#   Prompt MUST contain hard-rules with branch leaf/<lid>- and base charter/<cid>.
assert_prompt_clean(){
  local pf="$1" lid="$2" cid="$3"
  [ -f "$pf" ] || return 1
  grep -qi 'manifest\|CB_MANIFEST' "$pf" && return 1
  grep -q "leaf/$lid-" "$pf" || return 1
  grep -q "charter/$cid" "$pf" || return 1
  return 0
}

# ── MAIN TEST ────────────────────────────────────────────────────────────────
echo "== MAIN: legacy path smoke (no CB_MANIFEST) =="

PATH="$BIN:$PATH" \
  CB_REPO="test/repo" \
  CB_HOME="$CBHOME" \
  CB_SPAWN="$EXEC_STUB" \
  CB_PLAN_SPAWN="$TECH_LEAD_STUB" \
  CB_REWORK_SPAWN="/bin/false" \
  CB_GIT_REMOTE="" \
  CB_POLL=0 \
  CB_MAX_TICKS=20 \
  CB_IDLE_CONFIRM=2 \
  CB_MAX_PARALLEL=2 \
  bash "$LAUNCHER" run 2>/dev/null

# Poll: check leaf state via board-gh get state (not raw JSON, not sleep)
LEAF_STATE=$(PATH="$BIN:$PATH" CB_REPO="test/repo" bash "$BOARD" get 10 state 2>/dev/null \
             || echo "unknown")

# ── MAIN-1: spawn log exactly [<charter> tech-lead; <leaf> executor], nothing else ──
assert_spawn_order "$SPAWN_LOG" \
  && ok "MAIN-1: spawn log exactly [charter tech-lead; leaf executor] — correct sequence" \
  || ko "MAIN-1: spawn log wrong: $(tr '\n' '|' < "$SPAWN_LOG" 2>/dev/null || echo '(missing)')"

# ── MAIN-2: no manifest-path labels in board history ──────────────────────────
assert_no_bad_labels "$GH_LOG" \
  && ok "MAIN-2: no manifest labels (needs-analysis/team-review/composition:approved) in board history" \
  || ko "MAIN-2: manifest label found in GH_LOG ($(grep -E 'needs-analysis|team-review|composition:approved' "$GH_LOG" 2>/dev/null | head -1 || echo '?'))"

# ── MAIN-3: prompt file — no manifest; has real hard-rules ────────────────────
PROMPT_FILE="$CBHOME/run/work/10/task.prompt"
assert_prompt_clean "$PROMPT_FILE" 10 5 \
  && ok "MAIN-3: task.prompt has no manifest/CB_MANIFEST; contains leaf/10- and charter/5 hard-rules" \
  || ko "MAIN-3: task.prompt failed clean check (head: $(head -6 "$PROMPT_FILE" 2>/dev/null | tr '\n' '|' || echo '(missing)'))"

# ── MAIN-4: leaf reached status:review (integrator is out of scope) ───────────
[ "$LEAF_STATE" = "review" ] \
  && ok "MAIN-4: leaf #10 reached status:review" \
  || ko "MAIN-4: leaf #10 state='$LEAF_STATE' (expected review)"

# ── NEGATIVE CONTROL ─────────────────────────────────────────────────────────
# Mandatory: show the detector CAN go red — proves the pin is not vacuously true.
echo "== NEGATIVE CONTROL: detector must fire on corrupted data =="

# Case NC-1: spawn log with wrong first-spawn role (solution-analyst instead of tech-lead)
NEG_SPAWN_LOG="$SANDBOX/neg-spawn.log"
printf '5 solution-analyst\n10 executor\n' > "$NEG_SPAWN_LOG"

assert_spawn_order "$NEG_SPAWN_LOG" \
  && ko "NC-1: detector should have FAILED for first-spawn role=solution-analyst" \
  || ok "NC-1: detector correctly rejected wrong first-spawn role (solution-analyst)"

# Case NC-2: GH_LOG contains a manifest-path label addition (status:needs-analysis)
NEG_GH_LOG="$SANDBOX/neg-gh.log"
printf 'edit #5 +[status:needs-analysis]\n' > "$NEG_GH_LOG"

assert_no_bad_labels "$NEG_GH_LOG" \
  && ko "NC-2: detector should have FAILED for status:needs-analysis in GH_LOG" \
  || ok "NC-2: detector correctly rejected bad label (status:needs-analysis)"

# ── Summary ───────────────────────────────────────────────────────────────────
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
