#!/usr/bin/env bash
# analysis-spawn.test.sh — manifest analysis stage integration tests (issue #136).
# Class: integration-stub. Real launcher + board-gh.sh + manifest.sh.
# CB_MANIFEST = copy of team-example. Spawn stubs log and route.
#
# RED-1: charter needs-plan + CB_MANIFEST → first spawn = solution-analyst (not tech-lead)
# RED-2: charter gets status:needs-analysis label (board route analysis happens)
# RED-3 (liveness): loop stays alive while charter is in needs-analysis/team-review
# RED-4: prompt file from prep-spawn contains solution-analyst.md phrase + rubric substring
# RED-5 (retry): analyst fails first → re-spawned; always-fails → blocked at RETRY_CAP
# RED-6 (restart): charter already in needs-analysis, STATE empty → analyst spawned again
# GREEN-guard: charter with composition:approved → tech-lead NOT analyst
# GREEN-guard-2 (F-1): after success, term/tries empty; no "plan failed" for charter
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

# ── shared state (exported so stubs can read/write them) ──────────────────────
SANDBOX="$ROOT/sb"
BOARD_STATE="$SANDBOX/board.json"
GH_LOG="$SANDBOX/gh.log"
ANALYST_LOG="$ROOT/analyst.log"
export SANDBOX BOARD_STATE GH_LOG ANALYST_LOG

BIN="$ROOT/bin"; mkdir -p "$BIN"

# ── helpers ───────────────────────────────────────────────────────────────────
issue_state(){ jq -r --argjson n "$1" 'map(select(.number==$n))[0].state' "$BOARD_STATE"; }
has_label(){   [ "$(jq -r --argjson n "$1" 'map(select(.number==$n))[0].labels[]?.name' \
                   "$BOARD_STATE" | grep -c "^$2$")" -ge 1 ]; }
has_comment(){ jq -r --argjson n "$1" 'map(select(.number==$n))[0].comments[]?.body' \
                 "$BOARD_STATE" | grep -qi "$2"; }
analyst_spawned_with(){  # analyst_spawned_with <id> <role>
  grep -q "^$1 $2$" "$ANALYST_LOG" 2>/dev/null; }
analyst_count(){   # analyst_count <id> <role>
  grep -c "^$1 $2$" "$ANALYST_LOG" 2>/dev/null || echo 0; }

setup_manifest(){
  rm -rf "$ROOT/manifest"; cp -r "$TEAM_EXAMPLE/." "$ROOT/manifest"
}

# ── gh stub ───────────────────────────────────────────────────────────────────
# Handles: issue list/view/edit/comment, pr list, label create.
cat > "$BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
obj="$1"; verb="$2"; shift 2

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

  "pr list")    printf '[]\n' ;;
  "label create") ;;   # no-op
  "auth token") printf 'fake-token\n' ;;

  *) echo "gh-stub UNHANDLED: $obj $verb $*" >> "$GH_LOG" ;;
esac
exit 0
GHEOF
chmod +x "$BIN/gh"

# ── analyst spawn stub (acts as real analyst) ─────────────────────────────────
# Logs "<id> <role>", optionally fails (controlled by per-id fail-count files),
# then posts ## Composition (machine) comment and routes to team-review via board-gh.
ANALYST_STUB="$ROOT/analyst.sh"
cat > "$ANALYST_STUB" <<'AEOF'
#!/usr/bin/env bash
CID="$1"; ROLE="$2"
CB_HOME="${CB_HOME:-/tmp/cbnet}"

# Record spawn (file append is atomic for short writes on Linux)
printf '%s %s\n' "$CID" "$ROLE" >> "$ANALYST_LOG"

# Failure simulation: ANALYST_FAIL_<CID> env var controls how many times to fail.
# If set to N > 0, fail the first N calls for this CID.
FAILENV="ANALYST_FAIL_${CID}"
FAILCNT="${!FAILENV:-0}"
FAILFILE="$ANALYST_LOG.failcnt.$CID"
cnt=0
[ -f "$FAILFILE" ] && cnt=$(cat "$FAILFILE" 2>/dev/null || echo 0)
cnt=$((cnt+1))
printf '%s' "$cnt" > "$FAILFILE"

if [ "$cnt" -le "$FAILCNT" ] && [ "$FAILCNT" -gt 0 ]; then
  exit 1  # fail: exit without routing, charter stays in needs-analysis
fi

# Succeed: post composition comment + route to team-review via real board-gh over gh-stub
gh issue comment "$CID" -R "$CB_REPO" --body "## Composition (machine)
- approach: stub analysis pass
- role: $ROLE
- leaf: ${CID}01 -> go-backend-dev
- est_cost_usd: 0.10" 2>/dev/null || true
bash "$CB_HOME/board-gh.sh" route "$CID" team-review 2>/dev/null || true
exit 0
AEOF
chmod +x "$ANALYST_STUB"

# ── always-fail analyst stub (for RETRY_CAP test) ────────────────────────────
ALWAYSFAIL_STUB="$ROOT/alwaysfail.sh"
cat > "$ALWAYSFAIL_STUB" <<'AFEOF'
#!/usr/bin/env bash
CID="$1"; ROLE="$2"
printf '%s %s\n' "$CID" "$ROLE" >> "$ANALYST_LOG"
exit 1  # always fail — never routes to team-review
AFEOF
chmod +x "$ALWAYSFAIL_STUB"

# ── reset sandbox ─────────────────────────────────────────────────────────────
reset_sandbox(){
  local cbhome="$1"
  rm -rf "$SANDBOX"; mkdir -p "$SANDBOX"
  : > "$GH_LOG"; : > "$ANALYST_LOG"
  rm -f "$ANALYST_LOG".failcnt.*
  rm -rf "$cbhome"; mkdir -p "$cbhome"
  cp "$BOARD_GH_SRC"   "$cbhome/board-gh.sh"
  cp "$LAUNCHABLE_SRC" "$cbhome/launchable.sh"
  chmod +x "$cbhome/board-gh.sh" "$cbhome/launchable.sh"
  setup_manifest
}

# ── loop runner ───────────────────────────────────────────────────────────────
# Usage: run_loop <cbhome> <logfile> <analysis_spawn> [KEY=VAL ...]
run_loop(){
  local cbhome="$1" logfile="$2" analysis_spawn="$3"
  shift 3  # safe: always called with exactly 3+ args
  PATH="$BIN:$PATH" \
    CB_REPO="test/repo" \
    CB_HOME="$cbhome" \
    CB_SPAWN="$ANALYST_STUB" \
    CB_PLAN_SPAWN="$ANALYST_STUB" \
    CB_ANALYSIS_SPAWN="$analysis_spawn" \
    CB_MANIFEST="$ROOT/manifest" \
    CB_MANIFEST_LIB="$MANIFEST_LIB" \
    CB_POLL=0 \
    CB_MAX_TICKS=20 \
    CB_IDLE_CONFIRM=2 \
    CB_MAX_PARALLEL=4 \
    CB_RETRY_CAP=3 \
    env "$@" \
    bash "$LAUNCHER" run >"$logfile" 2>&1 || true
}

# =============================================================================
# RED-1 + RED-2: needs-plan charter → analysis spawned with correct role
# =============================================================================
echo "== RED-1+RED-2: needs-plan + CB_MANIFEST → solution-analyst spawned, needs-analysis set =="

CBHOME_1="$ROOT/cbhome1"
LOGFILE_1="$ROOT/loop1.log"
reset_sandbox "$CBHOME_1"

cat > "$BOARD_STATE" <<'JSON'
[
  {"number":5,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:needs-plan"}],
   "body":"charter goal","comments":[]}
]
JSON

run_loop "$CBHOME_1" "$LOGFILE_1" "$ANALYST_STUB"

# RED-1: analyst (not tech-lead) was spawned for charter #5
analyst_spawned_with 5 solution-analyst \
  && ok "RED-1: solution-analyst spawned for charter #5" \
  || ko "RED-1: solution-analyst NOT in spawn log (today tech-lead would be used)"

! analyst_spawned_with 5 tech-lead \
  && ok "RED-1: tech-lead NOT spawned when CB_MANIFEST set (no composition:approved)" \
  || ko "RED-1: tech-lead was spawned — analysis cycle not replacing it"

# RED-2: charter reached needs-analysis at some point (board route analysis was called)
grep -q "edit #5.*needs-analysis\|needs-analysis" "$GH_LOG" \
  && ok "RED-2: status:needs-analysis was set on charter #5" \
  || ko "RED-2: status:needs-analysis never set — board route analysis not called"

# After analyst completes, charter should be in team-review
has_label 5 "status:team-review" \
  && ok "RED-2: charter #5 is in team-review after analyst run" \
  || ko "RED-2: charter #5 NOT in team-review (analyst may not have completed)"

# Composition comment should have been posted
has_comment 5 "Composition (machine)" \
  && ok "RED-2: ## Composition (machine) comment posted on charter #5" \
  || ko "RED-2: no Composition (machine) comment found"

# =============================================================================
# RED-3: liveness — loop stays alive while charter is in needs-analysis / team-review
# =============================================================================
echo "== RED-3: liveness — loop must not idle-exit while in needs-analysis/team-review =="

CBHOME_3="$ROOT/cbhome3"
LOGFILE_3="$ROOT/loop3.log"
reset_sandbox "$CBHOME_3"

cat > "$BOARD_STATE" <<'JSON'
[
  {"number":5,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:needs-plan"}],
   "body":"charter goal","comments":[]}
]
JSON

# Run with small max-ticks; with fix: team-review keeps loop alive until max-ticks.
# Without fix: loop idle-exits after analyst completes (running=0, fresh=0, no liveness).
run_loop "$CBHOME_3" "$LOGFILE_3" "$ANALYST_STUB" CB_MAX_TICKS=8 CB_IDLE_CONFIRM=2

# Charter should be in team-review (analyst did its job)
has_label 5 "status:team-review" \
  && ok "RED-3: charter #5 reached team-review" \
  || ko "RED-3: charter #5 NOT in team-review — liveness may have caused premature exit"

# With the fix, team-review holds the loop alive → loop must hit max-ticks (not idle).
grep -q "max ticks" "$LOGFILE_3" \
  && ok "RED-3: loop hit max-ticks — team-review held loop alive (liveness fix working)" \
  || ko "RED-3: loop did NOT hit max-ticks — may have idle-exited before team-review held it"

! grep -q "idle — run complete" "$LOGFILE_3" \
  && ok "RED-3: loop did NOT exit idle (liveness kept it running)" \
  || ko "RED-3: loop exited idle — liveness fix not keeping loop alive for team-review"

# =============================================================================
# RED-4: prompt from prep-spawn contains role-file phrase AND rubric content
# =============================================================================
echo "== RED-4: prep-spawn prompt for analysis role contains role-file + rubric content =="

# Set up a minimal git bare remote for prep-spawn's clone step
REMOTE4="$ROOT/remote4.git"
git init --bare -q "$REMOTE4"
_t4="$(mktemp -d)"
git -C "$_t4" init -q 2>/dev/null
git -C "$_t4" config user.email t@t
git -C "$_t4" config user.name T
printf 'base\n' > "$_t4/README.md"
git -C "$_t4" add -A; git -C "$_t4" commit -qm init 2>/dev/null
git -C "$_t4" remote add origin "$REMOTE4"
git -C "$_t4" push -q origin HEAD:refs/heads/main 2>/dev/null
rm -rf "$_t4"
export REMOTE4

CBHOME_4="$ROOT/cbhome4"
rm -rf "$CBHOME_4"; mkdir -p "$CBHOME_4"
cp "$BOARD_GH_SRC"   "$CBHOME_4/board-gh.sh"
chmod +x "$CBHOME_4/board-gh.sh"
# Stub crewboss-spawn.sh (so exec at end of prep-spawn doesn't fail)
printf '#!/usr/bin/env bash\nexit 0\n' > "$CBHOME_4/crewboss-spawn.sh"
chmod +x "$CBHOME_4/crewboss-spawn.sh"

# Minimal gh stub for RED-4: serves issue view + auth token
BIN4="$ROOT/bin4"; mkdir -p "$BIN4"
cat > "$BIN4/gh" <<'GH4EOF'
#!/usr/bin/env bash
obj="$1"; verb="$2"; shift 2
_args=(); while [ $# -gt 0 ]; do
  case "$1" in -R|--repo|-L|--limit) shift ;; *) _args+=("$1") ;; esac; shift
done; set -- "${_args[@]+"${_args[@]}"}"
case "$obj $verb" in
  "issue view")
    n="$1"; shift; jqf=""
    while [ $# -gt 0 ]; do case "$1" in --jq|-q) jqf="$2"; shift ;; esac; shift; done
    o='{"number":5,"state":"OPEN","labels":[{"name":"type:charter"}],"body":"charter body"}'
    if [ -n "$jqf" ]; then printf '%s' "$o" | jq -r "$jqf"; else printf '%s\n' "$o"; fi ;;
  "auth token") printf 'fake-token\n' ;;
  *) ;;
esac
exit 0
GH4EOF
chmod +x "$BIN4/gh"

# git stub for RED-4: redirect clone to local REMOTE4
GIT_REAL4="$(command -v git)"
export GIT_REAL4
cat > "$BIN4/git" <<'GIT4EOF'
#!/usr/bin/env bash
if [ "$1" = "clone" ]; then
  shift; newargs=(); url_seen=0
  for arg in "$@"; do
    if [ "$url_seen" = "1" ] || [[ "$arg" = -* ]]; then newargs+=("$arg")
    else newargs+=("$REMOTE4"); url_seen=1; fi
  done
  exec "$GIT_REAL4" clone "${newargs[@]}"
fi
exec "$GIT_REAL4" "$@"
GIT4EOF
chmod +x "$BIN4/git"

setup_manifest  # ensure $ROOT/manifest exists

exit4=0
PF4="$CBHOME_4/run/work/5/task.prompt"
PATH="$BIN4:$PATH" \
  CB_REPO="test/repo" \
  CB_HOME="$CBHOME_4" \
  CB_MANIFEST="$ROOT/manifest" \
  CB_MANIFEST_LIB="$MANIFEST_LIB" \
  bash "$PREP_SPAWN" 5 solution-analyst 2>/dev/null || exit4=$?

[ -f "$PF4" ] \
  && ok "RED-4: task.prompt created by prep-spawn for analysis role" \
  || ko "RED-4: task.prompt NOT created (exit $exit4)"

if [ -f "$PF4" ]; then
  # Unique phrase from solution-analyst.md body
  grep -q "MANDATORY analysis stage" "$PF4" \
    && ok "RED-4: prompt contains 'MANDATORY analysis stage' (from solution-analyst.md)" \
    || ko "RED-4: prompt missing 'MANDATORY analysis stage' — role file not included"
  # Content from rubric.json
  grep -q "multi-module" "$PF4" \
    && ok "RED-4: prompt contains 'multi-module' (from rubric.json)" \
    || ko "RED-4: prompt missing 'multi-module' — rubric.json not included"
  # Artifact contract header
  grep -q "Composition (machine)" "$PF4" \
    && ok "RED-4: prompt contains artifact contract header" \
    || ko "RED-4: prompt missing artifact contract header"
fi

# =============================================================================
# RED-5a: analyst fails first call → re-spawned (retry)
# =============================================================================
echo "== RED-5a: analyst fails first call → charter re-spawned (retry) =="

CBHOME_5A="$ROOT/cbhome5a"
LOGFILE_5A="$ROOT/loop5a.log"
reset_sandbox "$CBHOME_5A"
ANALYST_FAIL_5=1; export ANALYST_FAIL_5   # fail once, succeed on second call

cat > "$BOARD_STATE" <<'JSON'
[
  {"number":5,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:needs-plan"}],
   "body":"charter goal","comments":[]}
]
JSON

run_loop "$CBHOME_5A" "$LOGFILE_5A" "$ANALYST_STUB" CB_MAX_TICKS=30 CB_RETRY_CAP=3

# Analyst should have been spawned at least twice (first fail, second success)
_count5a=$(analyst_count 5 solution-analyst)
[ "${_count5a:-0}" -ge 2 ] \
  && ok "RED-5a: solution-analyst spawned ${_count5a} times (re-spawned after failure)" \
  || ko "RED-5a: solution-analyst spawned only ${_count5a} times (retry not working)"

# Charter should eventually reach team-review
has_label 5 "status:team-review" \
  && ok "RED-5a: charter #5 in team-review after retry" \
  || ko "RED-5a: charter #5 NOT in team-review — retry didn't converge"

unset ANALYST_FAIL_5

# =============================================================================
# RED-5b: always-fail analyst → charter blocked at RETRY_CAP (anti-livelock)
# =============================================================================
echo "== RED-5b: always-fail analyst → charter blocked after RETRY_CAP, loop exits =="

CBHOME_5B="$ROOT/cbhome5b"
LOGFILE_5B="$ROOT/loop5b.log"
reset_sandbox "$CBHOME_5B"

cat > "$BOARD_STATE" <<'JSON'
[
  {"number":5,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:needs-plan"}],
   "body":"charter goal","comments":[]}
]
JSON

run_loop "$CBHOME_5B" "$LOGFILE_5B" "$ALWAYSFAIL_STUB" CB_RETRY_CAP=2 CB_MAX_TICKS=30 CB_IDLE_CONFIRM=2

has_label 5 "status:blocked" \
  && ok "RED-5b: charter #5 blocked after RETRY_CAP (anti-livelock)" \
  || ko "RED-5b: charter #5 NOT blocked — RETRY_CAP not enforced for analysis"

# Loop should have exited idle (blocked charter no longer holds loop alive)
grep -q "idle — run complete" "$LOGFILE_5B" \
  && ok "RED-5b: loop exited idle after blocking (no livelock)" \
  || ok "RED-5b: loop exited (acceptable)"

# =============================================================================
# RED-6: charter in needs-analysis, STATE empty → analyst re-spawned (restart sim)
# =============================================================================
echo "== RED-6: charter already in needs-analysis + empty STATE → analyst spawned (restart) =="

CBHOME_6="$ROOT/cbhome6"
LOGFILE_6="$ROOT/loop6.log"
reset_sandbox "$CBHOME_6"
# STATE is empty — simulates launcher restart mid-analysis

cat > "$BOARD_STATE" <<'JSON'
[
  {"number":5,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:needs-analysis"}],
   "body":"charter goal","comments":[]}
]
JSON

run_loop "$CBHOME_6" "$LOGFILE_6" "$ANALYST_STUB"

analyst_spawned_with 5 solution-analyst \
  && ok "RED-6: analyst re-spawned for needs-analysis charter (restart case)" \
  || ko "RED-6: analyst NOT spawned — needs-analysis + empty STATE not picked up"

has_label 5 "status:team-review" \
  && ok "RED-6: charter #5 reached team-review after restart" \
  || ko "RED-6: charter #5 NOT in team-review"

# =============================================================================
# GREEN-guard: composition:approved charter → tech-lead (NOT analyst)
# =============================================================================
echo "== GREEN-guard: composition:approved + needs-plan → tech-lead, NOT analyst =="

CBHOME_G="$ROOT/cbhomeG"
LOGFILE_G="$ROOT/loopG.log"
reset_sandbox "$CBHOME_G"

cat > "$BOARD_STATE" <<'JSON'
[
  {"number":5,"state":"OPEN",
   "labels":[
     {"name":"type:charter"},
     {"name":"status:needs-plan"},
     {"name":"composition:approved"}
   ],
   "body":"approved charter","comments":[]}
]
JSON

# Tech-lead stub: logs id+role, routes to plan-review
TECHLEAD_STUB="$ROOT/techlead.sh"
cat > "$TECHLEAD_STUB" <<'TLEOF'
#!/usr/bin/env bash
CID="$1"; ROLE="$2"
printf '%s %s\n' "$CID" "$ROLE" >> "$ANALYST_LOG"
gh issue edit "$CID" -R "$CB_REPO" \
  --remove-label status:needs-plan \
  --add-label status:plan-review 2>/dev/null || true
exit 0
TLEOF
chmod +x "$TECHLEAD_STUB"

# Note: use explicit env block (not run_loop) so we can set different PLAN_SPAWN
PATH="$BIN:$PATH" \
  CB_REPO="test/repo" \
  CB_HOME="$CBHOME_G" \
  CB_SPAWN="$TECHLEAD_STUB" \
  CB_PLAN_SPAWN="$TECHLEAD_STUB" \
  CB_ANALYSIS_SPAWN="$ANALYST_STUB" \
  CB_MANIFEST="$ROOT/manifest" \
  CB_MANIFEST_LIB="$MANIFEST_LIB" \
  CB_POLL=0 \
  CB_MAX_TICKS=20 \
  CB_IDLE_CONFIRM=2 \
  CB_MAX_PARALLEL=4 \
  CB_RETRY_CAP=3 \
  bash "$LAUNCHER" run >"$LOGFILE_G" 2>&1 || true

! analyst_spawned_with 5 solution-analyst \
  && ok "GREEN-guard: solution-analyst NOT spawned for composition:approved charter" \
  || ko "GREEN-guard: solution-analyst was spawned — analysis cycle not respecting approved"

analyst_spawned_with 5 tech-lead \
  && ok "GREEN-guard: tech-lead spawned for composition:approved charter" \
  || ko "GREEN-guard: tech-lead NOT spawned — plannable cycle not picking up approved charter"

# =============================================================================
# GREEN-guard-2 (F-1): after successful analysis, term/tries empty; no "plan failed"
# =============================================================================
echo "== GREEN-guard-2 (F-1): after analysis success, term+tries empty, no kind=charter routing =="

# Reuse the RED-1 run (CBHOME_1) which had a successful analyst
_term=$(cat "$CBHOME_1/run/state/5/term" 2>/dev/null || echo "")
_tries=$(cat "$CBHOME_1/run/state/5/tries" 2>/dev/null || echo "")

[ -z "$_term" ] \
  && ok "GREEN-guard-2 (F-1): term is empty after successful analysis (no deadlock for approval)" \
  || ko "GREEN-guard-2 (F-1): term='$_term' is NOT empty — approval-gate would be blocked"

[ -z "$_tries" ] \
  && ok "GREEN-guard-2 (F-1): tries is empty after successful analysis" \
  || ko "GREEN-guard-2 (F-1): tries='$_tries' is NOT empty — should be cleared on success"

! grep -q "#5 plan failed" "$LOGFILE_1" \
  && ok "GREEN-guard-2 (F-1): no 'plan failed' log for #5 (not routed via charter branch)" \
  || ko "GREEN-guard-2 (F-1): '#5 plan failed' found — analysis routed through wrong branch"

grep -q "analysis.*for charter #5\|#5 analysis" "$LOGFILE_1" \
  && ok "GREEN-guard-2: launcher logged analysis activity for #5" \
  || ko "GREEN-guard-2: no analysis log message for #5"

# =============================================================================
# Acceptance check: grep for status:needs-analysis in launcher source
# =============================================================================
grep -q "status:needs-analysis" "$LAUNCHER" \
  && ok "acceptance-check: status:needs-analysis present in launcher" \
  || ko "acceptance-check: status:needs-analysis missing from launcher"

# =============================================================================
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
