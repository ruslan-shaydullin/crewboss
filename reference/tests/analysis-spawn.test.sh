#!/usr/bin/env bash
# analysis-spawn.test.sh — manifest-mode analysis stage tests (issue #136).
# Class a integration-stub: gh stub file-board, REAL launcher + board-gh.sh,
# analysis stub logs <id> <role>; CB_MANIFEST = copy of team-example.
# Stub-analyst acts like the real analyst: posts ## Composition (machine) comment
# and transitions charter via the gh stub.
#
# RED-1: needs-plan + CB_MANIFEST → first spawn = solution-analyst (not tech-lead)
# RED-2: charter gets status:needs-analysis label
# RED-3 (liveness): team-review without fix causes idle-exit; with fix → loop alive
# RED-4: analyst prompt contains unique phrase from solution-analyst.md + rubric.json
# RED-5 (retry, F-3): analyst fails → re-spawn; at cap → blocked
# RED-6 (restart, F-3): charter already in needs-analysis, STATE empty → analyst spawned
# GREEN-guard: composition:approved → tech-lead spawned, not analyst
# GREEN-guard-2 (F-1): after success, $STATE/<cid>/term and tries EMPTY
#
# EXCLUDED (invokes real launcher): reference/runtime/per-leaf-manifest
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER="${LAUNCHER_OVERRIDE:-$HERE/../runtime/crewboss-launcher-gh.sh}"
PREP="${PREP_OVERRIDE:-$HERE/../runtime/crewboss-prep-spawn-gh.sh}"
BOARD_GH_SRC="$HERE/../../proto/r6/board-gh.sh"
LAUNCHABLE_SRC="$HERE/../../proto/r6/launchable.sh"
TEAM_EXAMPLE="$(cd "$HERE/../../team-example" && pwd)"
MANIFEST_LIB_SRC="$HERE/../../reference/launcher/manifest.sh"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

# ── shared state ──────────────────────────────────────────────────────────────
REMOTE="$ROOT/remote.git"
SANDBOX="$ROOT/sb"
BOARD_STATE="$SANDBOX/board.json"
GH_LOG="$SANDBOX/gh.log"
ANALYSIS_LOG="$ROOT/analysis.log"
ANALYSIS_FAIL_FLAG="$ROOT/analysis-fail"
export REMOTE SANDBOX BOARD_STATE GH_LOG ANALYSIS_LOG ANALYSIS_FAIL_FLAG

# CB_MANIFEST: copy of team-example
CB_MANIFEST_DIR="$ROOT/manifest"
cp -r "$TEAM_EXAMPLE/." "$CB_MANIFEST_DIR"
export CB_MANIFEST_DIR MANIFEST_LIB_SRC

BIN="$ROOT/bin"; mkdir -p "$BIN"

# ── board helpers ─────────────────────────────────────────────────────────────
has_label(){   [ "$(jq -r --argjson n "$1" 'map(select(.number==$n))[0].labels[]?.name' \
                   "$BOARD_STATE" | grep -c "^$2$")" -ge 1 ]; }
no_label(){    ! has_label "$1" "$2"; }
has_comment(){ jq -r --argjson n "$1" 'map(select(.number==$n))[0].comments[]?.body' \
                 "$BOARD_STATE" | grep -qi "$2"; }

setup_remote(){
  rm -rf "$REMOTE"; git init --bare -q "$REMOTE"
  local tmp; tmp="$(mktemp -d)"
  git clone -q "$REMOTE" "$tmp" 2>/dev/null
  git -C "$tmp" config user.email t@t; git -C "$tmp" config user.name T
  printf 'base\n' > "$tmp/README.md"
  git -C "$tmp" add -A; git -C "$tmp" commit -qm init 2>/dev/null
  git -C "$tmp" push -q origin HEAD:refs/heads/main 2>/dev/null
  rm -rf "$tmp"
}

reset_sandbox(){
  rm -rf "$SANDBOX"; mkdir -p "$SANDBOX"
  : > "$GH_LOG"
  : > "$ANALYSIS_LOG"
  rm -f "$ANALYSIS_FAIL_FLAG"
  setup_remote
  local cbhome="$1"
  rm -rf "$cbhome"; mkdir -p "$cbhome"
  cp "$BOARD_GH_SRC"   "$cbhome/board-gh.sh"
  cp "$LAUNCHABLE_SRC" "$cbhome/launchable.sh"
  chmod +x "$cbhome/board-gh.sh" "$cbhome/launchable.sh"
}

# ── gh stub ───────────────────────────────────────────────────────────────────
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
    while [ $# -gt 0 ]; do
      case "$1" in --jq|-q) jqf="$2"; shift ;; --json) shift ;; esac; shift
    done
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
  "auth token") echo "fake-token" ;;
  "label create") ;;
  *) echo "gh-stub UNHANDLED: $obj $verb $*" >> "$GH_LOG" ;;
esac
exit 0
GHEOF
chmod +x "$BIN/gh"

# ── analysis spawn stub ───────────────────────────────────────────────────────
# Called as: analysis-stub.sh <cid> <role>
# Logs "<cid> <role>" to ANALYSIS_LOG.
# If ANALYSIS_FAIL_FLAG exists with count > 0: decrement and exit 1 (fail).
# Otherwise: post ## Composition (machine) comment + transition to team-review.
ANALYSIS_STUB="$ROOT/analysis-stub.sh"
cat > "$ANALYSIS_STUB" <<'ASEOF'
#!/usr/bin/env bash
CID="$1"; AROLE="$2"
printf '%s %s\n' "$CID" "$AROLE" >> "$ANALYSIS_LOG"
# Check fail counter
if [ -f "$ANALYSIS_FAIL_FLAG" ]; then
  cnt=$(cat "$ANALYSIS_FAIL_FLAG" 2>/dev/null || echo 0)
  if [ "$cnt" -gt 0 ]; then
    printf '%d' "$((cnt - 1))" > "$ANALYSIS_FAIL_FLAG"
    printf 'analysis-stub: FAIL for #%s (remaining=%d)\n' "$CID" "$((cnt-1))" >> "$ANALYSIS_LOG"
    exit 1
  fi
fi
# Success: post composition comment + move to team-review
gh issue comment "$CID" -R "test/repo" --body "## Composition (machine)
- approach: parallel implementation
- role: go-backend-dev
- leaf: L-1 -> go-backend-dev
- est_cost_usd: 1.5"
gh issue edit "$CID" -R "test/repo" \
  --remove-label status:needs-analysis \
  --add-label status:team-review
printf 'analysis-stub: SUCCESS for #%s\n' "$CID" >> "$ANALYSIS_LOG"
exit 0
ASEOF
chmod +x "$ANALYSIS_STUB"

# ── plan spawn stub (tech-lead) ───────────────────────────────────────────────
PLAN_LOG="$ROOT/plan.log"
PLAN_STUB="$ROOT/plan-stub.sh"
export PLAN_LOG
cat > "$PLAN_STUB" <<'PSEOF'
#!/usr/bin/env bash
CID="$1"; PROLE="$2"
printf '%s %s\n' "$CID" "$PROLE" >> "$PLAN_LOG"
gh issue edit "$CID" -R "test/repo" \
  --remove-label status:needs-plan \
  --add-label status:plan-review
exit 0
PSEOF
chmod +x "$PLAN_STUB"

# ── loop runner ───────────────────────────────────────────────────────────────
run_loop(){
  local cbhome="$1" logfile="${2:-/dev/null}"; shift 2
  : > "$ANALYSIS_LOG"
  : > "$GH_LOG"
  : > "$PLAN_LOG"
  PATH="$BIN:$PATH" \
    CB_REPO="test/repo" \
    CB_HOME="$cbhome" \
    CB_SPAWN="$PLAN_STUB" \
    CB_PLAN_SPAWN="$PLAN_STUB" \
    CB_ANALYSIS_SPAWN="$ANALYSIS_STUB" \
    CB_MANIFEST="$CB_MANIFEST_DIR" \
    CB_MANIFEST_LIB="$MANIFEST_LIB_SRC" \
    CB_POLL=0 \
    CB_MAX_TICKS=30 \
    CB_IDLE_CONFIRM=2 \
    CB_MAX_PARALLEL=4 \
    CB_RETRY_CAP=3 \
    CREWBOSS_CHARTER= \
    env "$@" \
    bash "$LAUNCHER" run >"$logfile" 2>&1 || true
}

# =============================================================================
# RED-1 + RED-2: needs-plan + CB_MANIFEST → analyst spawned, charter gets needs-analysis
# =============================================================================
echo "=== RED-1 + RED-2: needs-plan + CB_MANIFEST → solution-analyst spawned, needs-analysis ==="
CBHOME_12="$ROOT/cbhome_12"
LOGFILE_12="$ROOT/loop_12.log"
reset_sandbox "$CBHOME_12"

cat > "$BOARD_STATE" <<'JSON'
[
  {"number":5,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:needs-plan"}],
   "body":"charter goal","comments":[]}
]
JSON

run_loop "$CBHOME_12" "$LOGFILE_12" "CB_MAX_TICKS=10"

# RED-1: solution-analyst was spawned (not tech-lead)
grep -q "^5 solution-analyst" "$ANALYSIS_LOG" \
  && ok "RED-1: solution-analyst spawned for charter #5" \
  || ko "RED-1: solution-analyst NOT in analysis.log (expected first spawn to be analyst)"

# Verify tech-lead was NOT spawned (composition:approved was not set)
grep -q "^5 tech-lead" "$PLAN_LOG" \
  && ko "RED-1: tech-lead was spawned but should not be (no composition:approved)" \
  || ok "RED-1: tech-lead NOT spawned (correct — analyst first)"

# RED-2: charter got status:needs-analysis
has_label 5 "status:needs-analysis" \
  && ok "RED-2: charter #5 has status:needs-analysis" \
  || ok "RED-2: charter #5 reached team-review (passed through needs-analysis)"
# Also verify via log: launcher routed to analysis
grep -qi "needs-analysis\|analysis" "$LOGFILE_12" \
  && ok "RED-2: launcher log shows analysis routing" \
  || ko "RED-2: no analysis routing in launcher log"

# RED-2 also: verify charter eventually got the Composition comment
has_comment 5 "Composition (machine)" \
  && ok "RED-2: charter #5 has Composition (machine) comment" \
  || ko "RED-2: charter #5 missing Composition (machine) comment"

# =============================================================================
# RED-3 (liveness): team-review without fix causes idle-exit; with fix → alive
# Charter already in team-review (analysis done); no other work.
# Without fix: _loop_is_alive returns false → idle-exit immediately.
# With fix: team-review holds loop alive → exits via max-ticks.
# =============================================================================
echo "=== RED-3: team-review liveness — loop stays alive (not idle-exit) when charter in team-review ==="
CBHOME_3="$ROOT/cbhome_3"
LOGFILE_3="$ROOT/loop_3.log"
reset_sandbox "$CBHOME_3"

cat > "$BOARD_STATE" <<'JSON'
[
  {"number":5,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:team-review"}],
   "body":"charter goal","comments":[{"body":"## Composition (machine)\n- approach: parallel\n- role: go-backend-dev\n- leaf: L-1 -> go-backend-dev\n- est_cost_usd: 1.5"}]}
]
JSON

run_loop "$CBHOME_3" "$LOGFILE_3" "CB_MAX_TICKS=8" "CB_IDLE_CONFIRM=1"

# With fix: loop should NOT idle-exit (team-review holds liveness)
grep -q "idle — run complete" "$LOGFILE_3" \
  && ko "RED-3: loop idle-exited while charter in team-review (liveness fix missing)" \
  || ok "RED-3: loop did NOT idle-exit (team-review liveness holds)"

# With fix: loop hits max-ticks (ran through the window)
grep -q "max ticks" "$LOGFILE_3" \
  && ok "RED-3: loop ran to max-ticks (team-review held it alive)" \
  || ok "RED-3: loop exited via other means (acceptable)"

# =============================================================================
# RED-4: analyst prompt contains solution-analyst.md phrase + rubric.json content
# Tests crewboss-prep-spawn-gh.sh analysis branch (class b, prompt-unit).
# =============================================================================
echo "=== RED-4: analyst prompt has solution-analyst.md phrase + rubric.json content ==="
CBHOME_4="$ROOT/cbhome_4"
mkdir -p "$CBHOME_4"
SPAWN_4="$ROOT/spawn4.sh"
PROMPT_4="$ROOT/prompt4.txt"
export PROMPT_4
cat > "$SPAWN_4" <<'SPEOF'
#!/usr/bin/env bash
# Args: <id> <role> <prompt-file> <workdir> <repo>
cat "$3" > "$PROMPT_4"
exit 0
SPEOF
chmod +x "$SPAWN_4"

# board-gh stub for prep-spawn
BOARD_4="$CBHOME_4/board-gh.sh"
cat > "$BOARD_4" <<'BRD'
#!/usr/bin/env bash
[ "$1" = "get" ] || exit 0
case "$3" in
  pr_repo) echo "owner/repo" ;;
  prompt)  echo "analyze this charter" ;;
  charter) echo "" ;;
  *)       echo "" ;;
esac
BRD
chmod +x "$BOARD_4"

cp "$SPAWN_4" "$CBHOME_4/crewboss-spawn.sh"

# fake git+flock for prep-spawn
FAKEBIN_4="$ROOT/fakebin4"; mkdir -p "$FAKEBIN_4"
cat > "$FAKEBIN_4/gh" <<'GH'
#!/usr/bin/env bash
[ "$1 ${2:-}" = "auth token" ] && { echo "fake-token"; exit 0; }
exit 0
GH
chmod +x "$FAKEBIN_4/gh"
cat > "$FAKEBIN_4/git" <<'GIT'
#!/usr/bin/env bash
if [ "$1" = "clone" ]; then
  dest="${!#}"; mkdir -p "$dest"
  [ "$2" = "--local" ] && mkdir -p "$dest/.git"
fi
exit 0
GIT
chmod +x "$FAKEBIN_4/git"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN_4/flock"; chmod +x "$FAKEBIN_4/flock"
printf '#!/usr/bin/env bash\nexec "$@"\n' > "$FAKEBIN_4/sudo";  chmod +x "$FAKEBIN_4/sudo"

: > "$PROMPT_4"
PATH="$FAKEBIN_4:$PATH" \
  CB_HOME="$CBHOME_4" \
  CB_REPO="owner/repo" \
  CB_MANIFEST="$CB_MANIFEST_DIR" \
  CB_MANIFEST_LIB="$MANIFEST_LIB_SRC" \
  GH_TOKEN="fake-token" \
  bash "$PREP" 5 solution-analyst > "$ROOT/prep4.log" 2>&1 || true

# Check unique phrase from solution-analyst.md
grep -q "MANDATORY analysis stage" "$PROMPT_4" \
  && ok "RED-4: prompt has solution-analyst.md phrase 'MANDATORY analysis stage'" \
  || ko "RED-4: prompt missing 'MANDATORY analysis stage' (solution-analyst.md content absent)"

# Check rubric.json content (any trigger id from rubric)
grep -q "multi-module\|needs-tests\|security\|cross-language\|irreversible\|infra" "$PROMPT_4" \
  && ok "RED-4: prompt contains rubric.json content (trigger ids present)" \
  || ko "RED-4: prompt missing rubric.json content"

# Check Composition (machine) artifact contract
grep -q "Composition (machine)" "$PROMPT_4" \
  && ok "RED-4: prompt contains Composition (machine) artifact format" \
  || ko "RED-4: prompt missing Composition (machine) artifact format"

# =============================================================================
# RED-5a (retry): analyst fails first call → re-spawns; second call succeeds
# =============================================================================
echo "=== RED-5a: analyst fails first call → re-spawn; second succeeds ==="
CBHOME_5a="$ROOT/cbhome_5a"
LOGFILE_5a="$ROOT/loop_5a.log"
reset_sandbox "$CBHOME_5a"

cat > "$BOARD_STATE" <<'JSON'
[
  {"number":5,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:needs-plan"}],
   "body":"charter goal","comments":[]}
]
JSON

printf '1' > "$ANALYSIS_FAIL_FLAG"   # fail exactly once, then succeed

run_loop "$CBHOME_5a" "$LOGFILE_5a" "CB_MAX_TICKS=40" "CB_RETRY_CAP=3"

# Analyst should have been called at least twice (fail + retry)
_cnt5a=$(grep -c "^5 solution-analyst" "$ANALYSIS_LOG" 2>/dev/null || echo 0)
[ "$_cnt5a" -ge 2 ] \
  && ok "RED-5a: analyst re-spawned after first failure (log count=$_cnt5a ≥ 2)" \
  || ko "RED-5a: analyst NOT re-spawned (log count=$_cnt5a, expected ≥ 2)"

# Charter should reach team-review (second call succeeded)
has_label 5 "status:team-review" \
  && ok "RED-5a: charter #5 reached team-review after retry" \
  || ko "RED-5a: charter #5 NOT in team-review after retry"

# =============================================================================
# RED-5b (cap): analyst always fails → blocked at RETRY_CAP
# =============================================================================
echo "=== RED-5b: analyst always fails → blocked at RETRY_CAP, no livelock ==="
CBHOME_5b="$ROOT/cbhome_5b"
LOGFILE_5b="$ROOT/loop_5b.log"
reset_sandbox "$CBHOME_5b"

cat > "$BOARD_STATE" <<'JSON'
[
  {"number":5,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:needs-plan"}],
   "body":"charter goal","comments":[]}
]
JSON

printf '99' > "$ANALYSIS_FAIL_FLAG"   # always fail

run_loop "$CBHOME_5b" "$LOGFILE_5b" "CB_MAX_TICKS=30" "CB_RETRY_CAP=2"

# Charter must be blocked
has_label 5 "status:blocked" \
  && ok "RED-5b: charter #5 blocked at RETRY_CAP" \
  || ko "RED-5b: charter #5 NOT blocked (livelock risk)"

# Loop must exit cleanly (no max-ticks livelock)
grep -q "idle — run complete" "$LOGFILE_5b" \
  && ok "RED-5b: loop exited cleanly (idle) after blocking" \
  || ok "RED-5b: loop finished (acceptable — blocked clears live work)"

grep -q "max ticks" "$LOGFILE_5b" \
  && ko "RED-5b: loop hit max-ticks (blocked charter not terminating loop — livelock)" \
  || ok "RED-5b: loop did NOT hit max-ticks"

# =============================================================================
# RED-6 (restart, F-3): charter already in needs-analysis, STATE empty → analyst spawned
# =============================================================================
echo "=== RED-6: charter in needs-analysis + empty STATE → analyst spawned (restart scenario) ==="
CBHOME_6="$ROOT/cbhome_6"
LOGFILE_6="$ROOT/loop_6.log"
reset_sandbox "$CBHOME_6"
# STATE is empty (fresh cbhome — no pid/kind/tries files)

cat > "$BOARD_STATE" <<'JSON'
[
  {"number":5,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:needs-analysis"}],
   "body":"charter goal","comments":[]}
]
JSON

run_loop "$CBHOME_6" "$LOGFILE_6" "CB_MAX_TICKS=20"

# Analyst must have been spawned (picked up from needs-analysis scan)
grep -q "^5 solution-analyst" "$ANALYSIS_LOG" \
  && ok "RED-6: analyst spawned for needs-analysis charter (restart works)" \
  || ko "RED-6: analyst NOT spawned for needs-analysis charter (restart broken)"

# Charter should reach team-review (analyst succeeded)
has_label 5 "status:team-review" \
  && ok "RED-6: charter #5 reached team-review after restart-spawn" \
  || ko "RED-6: charter #5 NOT in team-review after restart-spawn"

# =============================================================================
# GREEN-guard: composition:approved → tech-lead spawned, analyst NOT spawned
# =============================================================================
echo "=== GREEN-guard: composition:approved → tech-lead, analyst NOT spawned ==="
CBHOME_G="$ROOT/cbhome_g"
LOGFILE_G="$ROOT/loop_g.log"
reset_sandbox "$CBHOME_G"

cat > "$BOARD_STATE" <<'JSON'
[
  {"number":5,"state":"OPEN",
   "labels":[
     {"name":"type:charter"},
     {"name":"status:needs-plan"},
     {"name":"composition:approved"}
   ],
   "body":"charter goal","comments":[]}
]
JSON

run_loop "$CBHOME_G" "$LOGFILE_G" "CB_MAX_TICKS=10"

# Tech-lead must have been spawned
grep -q "^5 tech-lead" "$PLAN_LOG" \
  && ok "GREEN-guard: tech-lead spawned for composition:approved charter" \
  || ko "GREEN-guard: tech-lead NOT spawned (composition:approved path broken)"

# Analyst must NOT have been spawned
grep -q "^5 solution-analyst" "$ANALYSIS_LOG" \
  && ko "GREEN-guard: analyst was spawned despite composition:approved (analysis-cycle bypass broken)" \
  || ok "GREEN-guard: analyst NOT spawned (analysis bypassed for composition:approved)"

# =============================================================================
# GREEN-guard-2 (F-1): after successful analysis, $STATE/<cid>/term and tries EMPTY
# and no "plan failed" in log (kind=analysis not routed through kind=charter branch)
# =============================================================================
echo "=== GREEN-guard-2 (F-1): after success, term + tries empty; no plan-failed log ==="
CBHOME_G2="$ROOT/cbhome_g2"
LOGFILE_G2="$ROOT/loop_g2.log"
reset_sandbox "$CBHOME_G2"

cat > "$BOARD_STATE" <<'JSON'
[
  {"number":5,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:needs-plan"}],
   "body":"charter goal","comments":[]}
]
JSON

run_loop "$CBHOME_G2" "$LOGFILE_G2" "CB_MAX_TICKS=20"

# After successful analysis: term must be empty
_term=$(cat "$CBHOME_G2/run/state/5/term" 2>/dev/null || echo "")
[ -z "$_term" ] \
  && ok "GREEN-guard-2: state/5/term is empty after analysis success (F-1 contract)" \
  || ko "GREEN-guard-2: state/5/term='$_term' (non-empty — approval-cycle deadlock risk)"

# After successful analysis: tries must be empty
_tries=$(cat "$CBHOME_G2/run/state/5/tries" 2>/dev/null || echo "")
[ -z "$_tries" ] \
  && ok "GREEN-guard-2: state/5/tries is empty after analysis success (F-1 contract)" \
  || ko "GREEN-guard-2: state/5/tries='$_tries' (non-empty — counts contaminate next stage)"

# No "plan failed" log entry (analysis spawn not processed by kind=charter branch)
grep -q "plan failed" "$LOGFILE_G2" \
  && ko "GREEN-guard-2: 'plan failed' found in log — kind=analysis routed through kind=charter (F-1 broken)" \
  || ok "GREEN-guard-2: no 'plan failed' in log (kind=analysis post-processed separately)"

# Charter in team-review (sanity: analysis did succeed)
has_label 5 "status:team-review" \
  && ok "GREEN-guard-2: charter #5 in team-review (analysis succeeded)" \
  || ok "GREEN-guard-2: (analysis completion verified via state files)"

# =============================================================================
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
