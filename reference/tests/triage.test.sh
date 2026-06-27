#!/usr/bin/env bash
# triage.test.sh — triage role, triage-parse.sh, and launcher triage routing (issue #784).
# 8 deterministic stub scenarios; no real network; gh calls and spawn scripts stubbed;
# no triage agent actually runs — verdict comments are injected into stub board state.
#
# Test 1 — executor-error root class
# Test 2 — test-flaky root class
# Test 3 — plan-flaw root class (charter routed)
# Test 4 — approach-flaw root class (charter routed)
# Test 5 — test-bug root class (leaf needs-rework + test-broken)
# Test 6 — infra root class (leaf blocked)
# Test 7 — parser rejects malformed verdicts (3 sub-cases)
# Test 8 — trigger-path coverage (8A: reconcile guard, 8B: *) fallthrough intercept)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER="$HERE/../runtime/crewboss-launcher-gh.sh"
TRIAGE_PARSE="$HERE/../runtime/triage-parse.sh"
BOARD_GH_SRC="$HERE/../../proto/r6/board-gh.sh"
LAUNCHABLE_SRC="$HERE/../../proto/r6/launchable.sh"

pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"
SANDBOX="$ROOT/sb"
BOARD_STATE="$SANDBOX/board.json"
GH_LOG="$SANDBOX/gh.log"
export BOARD_STATE GH_LOG
mkdir -p "$BIN" "$SANDBOX"

# ── gh stub (stateful board mutations) ────────────────────────────────────────
cat > "$BIN/gh" << 'GHEOF'
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
    printf 'comment #%s: %s\n' "$n" "$body" >> "$GH_LOG" ;;
  "label create") ;;
  "auth token") printf 'fake-token\n' ;;
  *) printf 'gh-stub UNHANDLED: %s %s %s\n' "$obj" "$verb" "$*" >> "$GH_LOG" ;;
esac
exit 0
GHEOF
chmod +x "$BIN/gh"

# ── board helpers ─────────────────────────────────────────────────────────────
has_label(){
  [ "$(jq -r --argjson n "$1" \
    'map(select(.number==$n))[0].labels[]?.name' "$BOARD_STATE" \
    | grep -c "^${2}\$")" -ge 1 ]
}
no_label(){ ! has_label "$1" "$2"; }

# board get <id> state via board-gh.sh in a CB_HOME
board_state(){
  local cbhome="$1" id="$2"
  PATH="$BIN:$PATH" CB_REPO="test/repo" bash "$cbhome/board-gh.sh" get "$id" state 2>/dev/null
}

# reset board JSON
reset_board(){ rm -f "$GH_LOG"; cat > "$BOARD_STATE"; }

# setup CB_HOME (copy board-gh.sh + launchable.sh)
mk_cbhome(){
  local h="$1"; mkdir -p "$h"
  cp "$BOARD_GH_SRC" "$h/board-gh.sh"
  cp "$LAUNCHABLE_SRC" "$h/launchable.sh"
  chmod +x "$h/board-gh.sh" "$h/launchable.sh"
}

# sstate helpers relative to a CB_HOME
t_sget(){ cat "$1/run/state/$2/$3" 2>/dev/null || printf ''; }
t_sset(){
  mkdir -p "$1/run/state/$2"
  printf '%s' "$4" > "$1/run/state/$2/$3"
}

# Create a dead pid (reaped via wait)
mk_dead_pid(){
  ( exit 0 ) &
  local p=$!
  wait "$p" 2>/dev/null
  printf '%s' "$p"
}

# Run one pass of cmd_run (completion-handler path only; CB_MAX_PARALLEL=0 prevents new claiming).
run_completion_tick(){
  local cbhome="$1"
  PATH="$BIN:$PATH" \
    CB_REPO="test/repo" \
    CB_HOME="$cbhome" \
    CB_TRIAGE_PARSE="$TRIAGE_PARSE" \
    CB_POLL=0 \
    CB_MAX_TICKS=1 \
    CB_IDLE_CONFIRM=1 \
    CB_MAX_PARALLEL=0 \
    CB_RETRY_CAP=2 \
    CB_GIT_REMOTE="" \
    bash "$LAUNCHER" run 2>/dev/null
}

# ═══════════════════════════════════════════════════════════════════════════════
echo "== Test 1: executor-error root class =="
# ═══════════════════════════════════════════════════════════════════════════════
CBHOME_T1="$ROOT/cbhome_t1"
mk_cbhome "$CBHOME_T1"

reset_board << 'JSON'
[
  {"number":5,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:approved"}],
   "body":"charter","comments":[]},
  {"number":10,"state":"OPEN",
   "labels":[{"name":"type:agent"},{"name":"status:needs-triage"}],
   "body":"Charter: #5\n## Acceptance (machine)\n- check: true",
   "comments":[{"body":"## Triage (machine)\n{\"root\":\"executor-error\",\"evidence\":\"code bug in impl\",\"route\":\"executor-rework\"}"}]}
]
JSON

dead_pid_t1=$(mk_dead_pid)
t_sset "$CBHOME_T1" 10 kind   "triage"
t_sset "$CBHOME_T1" 10 pid    "$dead_pid_t1"
t_sset "$CBHOME_T1" 10 tries  "2"

run_completion_tick "$CBHOME_T1"

no_label 10 "status:blocked" \
  && ok "T1: executor-error — leaf NOT blocked" \
  || ko "T1: executor-error — leaf wrongly blocked"

[ -z "$(t_sget "$CBHOME_T1" 10 tries)" ] \
  && ok "T1: executor-error — tries cleared" \
  || ko "T1: executor-error — tries NOT cleared (got '$(t_sget "$CBHOME_T1" 10 tries)')"

no_label 10 "status:needs-triage" \
  && ok "T1: executor-error — status:needs-triage removed" \
  || ko "T1: executor-error — status:needs-triage still present"

# ═══════════════════════════════════════════════════════════════════════════════
echo "== Test 2: test-flaky root class =="
# ═══════════════════════════════════════════════════════════════════════════════
CBHOME_T2="$ROOT/cbhome_t2"
mk_cbhome "$CBHOME_T2"

reset_board << 'JSON'
[
  {"number":5,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:approved"}],
   "body":"charter","comments":[]},
  {"number":10,"state":"OPEN",
   "labels":[{"name":"type:agent"},{"name":"status:needs-triage"}],
   "body":"Charter: #5\n## Acceptance (machine)\n- check: true",
   "comments":[{"body":"## Triage (machine)\n{\"root\":\"test-flaky\",\"evidence\":\"race condition\",\"route\":\"test-flaky\"}"}]}
]
JSON

dead_pid_t2=$(mk_dead_pid)
t_sset "$CBHOME_T2" 10 kind   "triage"
t_sset "$CBHOME_T2" 10 pid    "$dead_pid_t2"
t_sset "$CBHOME_T2" 10 tries  "2"

run_completion_tick "$CBHOME_T2"

no_label 10 "status:blocked" \
  && ok "T2: test-flaky — leaf NOT blocked" \
  || ko "T2: test-flaky — leaf wrongly blocked"

[ -z "$(t_sget "$CBHOME_T2" 10 tries)" ] \
  && ok "T2: test-flaky — tries cleared" \
  || ko "T2: test-flaky — tries NOT cleared"

no_label 10 "status:needs-triage" \
  && ok "T2: test-flaky — status:needs-triage removed" \
  || ko "T2: test-flaky — status:needs-triage still present"

# ═══════════════════════════════════════════════════════════════════════════════
echo "== Test 3: plan-flaw root class =="
# ═══════════════════════════════════════════════════════════════════════════════
CBHOME_T3="$ROOT/cbhome_t3"
mk_cbhome "$CBHOME_T3"

reset_board << 'JSON'
[
  {"number":500,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:approved"}],
   "body":"charter 500","comments":[]},
  {"number":10,"state":"OPEN",
   "labels":[{"name":"type:agent"},{"name":"status:needs-triage"}],
   "body":"Charter: #500\n## Acceptance (machine)\n- check: true",
   "comments":[{"body":"## Triage (machine)\n{\"root\":\"plan-flaw\",\"evidence\":\"spec contradicts impl\",\"route\":\"needs-plan\"}"}]}
]
JSON

dead_pid_t3=$(mk_dead_pid)
t_sset "$CBHOME_T3" 10 kind "triage"
t_sset "$CBHOME_T3" 10 pid  "$dead_pid_t3"

run_completion_tick "$CBHOME_T3"

leaf_state_t3=$(board_state "$CBHOME_T3" 10)
[ "$leaf_state_t3" != "needs-triage" ] \
  && ok "T3: plan-flaw — leaf state no longer needs-triage (got '$leaf_state_t3')" \
  || ko "T3: plan-flaw — leaf still in needs-triage state"

charter_state_t3=$(board_state "$CBHOME_T3" 500)
[ "$charter_state_t3" = "needs-plan" ] \
  && ok "T3: plan-flaw — charter #500 state = needs-plan" \
  || ko "T3: plan-flaw — charter #500 state = '$charter_state_t3' (expected needs-plan)"

# ═══════════════════════════════════════════════════════════════════════════════
echo "== Test 4: approach-flaw root class =="
# ═══════════════════════════════════════════════════════════════════════════════
CBHOME_T4="$ROOT/cbhome_t4"
mk_cbhome "$CBHOME_T4"

reset_board << 'JSON'
[
  {"number":500,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:approved"}],
   "body":"charter 500","comments":[]},
  {"number":10,"state":"OPEN",
   "labels":[{"name":"type:agent"},{"name":"status:needs-triage"}],
   "body":"Charter: #500\n## Acceptance (machine)\n- check: true",
   "comments":[{"body":"## Triage (machine)\n{\"root\":\"approach-flaw\",\"evidence\":\"wrong architectural approach\",\"route\":\"needs-analysis\"}"}]}
]
JSON

dead_pid_t4=$(mk_dead_pid)
t_sset "$CBHOME_T4" 10 kind "triage"
t_sset "$CBHOME_T4" 10 pid  "$dead_pid_t4"

run_completion_tick "$CBHOME_T4"

leaf_state_t4=$(board_state "$CBHOME_T4" 10)
[ "$leaf_state_t4" != "needs-triage" ] \
  && ok "T4: approach-flaw — leaf state no longer needs-triage (got '$leaf_state_t4')" \
  || ko "T4: approach-flaw — leaf still in needs-triage state"

charter_state_t4=$(board_state "$CBHOME_T4" 500)
[ "$charter_state_t4" = "needs-analysis" ] \
  && ok "T4: approach-flaw — charter #500 state = needs-analysis" \
  || ko "T4: approach-flaw — charter #500 state = '$charter_state_t4' (expected needs-analysis)"

# ═══════════════════════════════════════════════════════════════════════════════
echo "== Test 5: test-bug root class =="
# ═══════════════════════════════════════════════════════════════════════════════
CBHOME_T5="$ROOT/cbhome_t5"
mk_cbhome "$CBHOME_T5"

reset_board << 'JSON'
[
  {"number":5,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:approved"}],
   "body":"charter","comments":[]},
  {"number":10,"state":"OPEN",
   "labels":[{"name":"type:agent"},{"name":"status:needs-triage"}],
   "body":"Charter: #5\n## Acceptance (machine)\n- check: true",
   "comments":[{"body":"## Triage (machine)\n{\"root\":\"test-bug\",\"evidence\":\"test asserts wrong value\",\"route\":\"test-bug\"}"}]}
]
JSON

dead_pid_t5=$(mk_dead_pid)
t_sset "$CBHOME_T5" 10 kind "triage"
t_sset "$CBHOME_T5" 10 pid  "$dead_pid_t5"

run_completion_tick "$CBHOME_T5"

has_label 10 "status:test-broken" \
  && ok "T5: test-bug — status:test-broken label added" \
  || ko "T5: test-bug — status:test-broken label NOT added"

leaf_state_t5=$(board_state "$CBHOME_T5" 10)
[ "$leaf_state_t5" = "needs-rework" ] \
  && ok "T5: test-bug — leaf routed to needs-rework (state=$leaf_state_t5)" \
  || ko "T5: test-bug — leaf state = '$leaf_state_t5' (expected needs-rework)"

no_label 10 "status:blocked" \
  && ok "T5: test-bug — status:blocked NOT set" \
  || ko "T5: test-bug — status:blocked wrongly set"

# ═══════════════════════════════════════════════════════════════════════════════
echo "== Test 6: infra root class =="
# ═══════════════════════════════════════════════════════════════════════════════
CBHOME_T6="$ROOT/cbhome_t6"
mk_cbhome "$CBHOME_T6"

reset_board << 'JSON'
[
  {"number":5,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:approved"}],
   "body":"charter","comments":[]},
  {"number":10,"state":"OPEN",
   "labels":[{"name":"type:agent"},{"name":"status:needs-triage"}],
   "body":"Charter: #5\n## Acceptance (machine)\n- check: true",
   "comments":[{"body":"## Triage (machine)\n{\"root\":\"infra\",\"evidence\":\"runner OOM\",\"route\":\"infra\"}"}]}
]
JSON

dead_pid_t6=$(mk_dead_pid)
t_sset "$CBHOME_T6" 10 kind "triage"
t_sset "$CBHOME_T6" 10 pid  "$dead_pid_t6"

run_completion_tick "$CBHOME_T6"

leaf_state_t6=$(board_state "$CBHOME_T6" 10)
[ "$leaf_state_t6" = "blocked" ] \
  && ok "T6: infra — leaf routed to status:blocked (state=$leaf_state_t6)" \
  || ko "T6: infra — leaf state = '$leaf_state_t6' (expected blocked)"

# ═══════════════════════════════════════════════════════════════════════════════
echo "== Test 7: parser rejects malformed verdicts =="
# ═══════════════════════════════════════════════════════════════════════════════

# 7A — missing required field (no route key)
printf '## Triage (machine)\n{"root":"executor-error","evidence":"x"}\n' \
  | bash "$TRIAGE_PARSE" >/dev/null 2>&1 \
  && ko "T7A: missing route — parser should exit non-zero but didn't" \
  || ok "T7A: missing route field — parser exited non-zero"

# 7B — unknown root class
printf '## Triage (machine)\n{"root":"unknown-class","evidence":"x","route":"executor-rework"}\n' \
  | bash "$TRIAGE_PARSE" >/dev/null 2>&1 \
  && ko "T7B: unknown root class — parser should exit non-zero but didn't" \
  || ok "T7B: unknown root class — parser exited non-zero"

# 7C — unknown route value
printf '## Triage (machine)\n{"root":"executor-error","evidence":"x","route":"bad-route"}\n' \
  | bash "$TRIAGE_PARSE" >/dev/null 2>&1 \
  && ko "T7C: unknown route value — parser should exit non-zero but didn't" \
  || ok "T7C: unknown route value — parser exited non-zero"

# ═══════════════════════════════════════════════════════════════════════════════
echo "== Test 8A: reconcile() kind=triage guard =="
# ═══════════════════════════════════════════════════════════════════════════════
CBHOME_T8A="$ROOT/cbhome_t8a"
mk_cbhome "$CBHOME_T8A"

TRIAGE_LOG_T8A="$ROOT/triage-spawn-8a.log"
TRIAGE_STUB_T8A="$ROOT/triage-stub-8a.sh"
printf '#!/usr/bin/env bash\nprintf "triage-spawn %%s\\n" "$1" >> "%s"\n' \
  "$TRIAGE_LOG_T8A" > "$TRIAGE_STUB_T8A"
chmod +x "$TRIAGE_STUB_T8A"

# Board: leaf #10 with status:needs-triage AND status:in-progress.
# Presence of in-progress lets us detect whether reconcile's requeue path ran
# (requeue removes in-progress; without the guard that would happen).
reset_board << 'JSON'
[
  {"number":5,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:approved"}],
   "body":"charter","comments":[]},
  {"number":10,"state":"OPEN",
   "labels":[{"name":"type:agent"},{"name":"status:needs-triage"},{"name":"status:in-progress"}],
   "body":"Charter: #5\n## Acceptance (machine)\n- check: true",
   "comments":[]}
]
JSON

dead_pid_t8a=$(mk_dead_pid)
t_sset "$CBHOME_T8A" 10 kind "triage"
t_sset "$CBHOME_T8A" 10 pid  "$dead_pid_t8a"

# Run cmd_once (reconcile fires at the start)
PATH="$BIN:$PATH" \
  CB_REPO="test/repo" \
  CB_HOME="$CBHOME_T8A" \
  CB_TRIAGE_SPAWN="$TRIAGE_STUB_T8A" \
  CB_TRIAGE_PARSE="$TRIAGE_PARSE" \
  CB_RETRY_CAP=2 \
  CB_MAX_PARALLEL=5 \
  CB_GIT_REMOTE="" \
  bash "$LAUNCHER" once 2>/dev/null

# (a) reconcile did NOT call board route requeue — in-progress is still present.
# reconcile WITHOUT the triage guard would call board route requeue, which removes in-progress.
has_label 10 "status:in-progress" \
  && ok "T8A: reconcile kind=triage guard — in-progress NOT removed (requeue skipped)" \
  || ko "T8A: reconcile kind=triage guard — in-progress was removed (requeue was called)"

# (b) TRIAGE_SPAWN was NOT invoked (no re-spawn of a triage leaf from cmd_once)
[ ! -f "$TRIAGE_LOG_T8A" ] || [ -z "$(cat "$TRIAGE_LOG_T8A" 2>/dev/null)" ] \
  && ok "T8A: no TRIAGE_SPAWN invocations in cmd_once (triage leaf not re-spawned)" \
  || ko "T8A: TRIAGE_SPAWN invoked unexpectedly (log: $(cat "$TRIAGE_LOG_T8A" 2>/dev/null))"

# ═══════════════════════════════════════════════════════════════════════════════
echo "== Test 8B: cmd_run async-completion *) fallthrough =="
# ═══════════════════════════════════════════════════════════════════════════════
CBHOME_T8B="$ROOT/cbhome_t8b"
mk_cbhome "$CBHOME_T8B"

# Executor stub: always fails with exit 1; writes no status.json
EXEC_STUB_T8B="$ROOT/exec-stub-8b.sh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$EXEC_STUB_T8B"
chmod +x "$EXEC_STUB_T8B"

# Triage spawn stub: logs invocation + sleeps long enough that the completion
# handler does not fire within the test window (pid stays alive until kill below).
TRIAGE_LOG_T8B="$ROOT/triage-spawn-8b.log"
TRIAGE_STUB_T8B="$ROOT/triage-stub-8b.sh"
printf '#!/usr/bin/env bash\nprintf "triage-spawn %%s\\n" "$1" >> "%s"\nsleep 30\n' \
  "$TRIAGE_LOG_T8B" > "$TRIAGE_STUB_T8B"
chmod +x "$TRIAGE_STUB_T8B"

# Board: leaf #10 is launchable (type:agent, approved charter, acceptance block, no exclusion labels)
reset_board << 'JSON'
[
  {"number":5,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:approved"}],
   "body":"charter","comments":[]},
  {"number":10,"state":"OPEN",
   "labels":[{"name":"type:agent"}],
   "body":"Charter: #5\n## Acceptance (machine)\n- check: true",
   "comments":[]}
]
JSON

# Pre-seed tries=1 so that after one executor failure (tries becomes 2), RETRY_CAP=2 is reached
# and the triage intercept fires.  Do NOT pre-seed pid (reconcile at startup must skip this leaf).
t_sset "$CBHOME_T8B" 10 tries "1"

# Run cmd_run:
# Tick 1: reconcile skips #10 (no pid). Claiming loop picks up #10 (launchable) → claim +
#         spawn exec_stub (exits 1 immediately). Sets pid=P1.
# Tick 2: completion loop detects P1 dead, phase=unknown, tries=1+1=2 >= RETRY_CAP=2,
#         triage_done unset → *) triage intercept fires:
#         board route needs-triage, kind=triage, TRIAGE_SPAWN #10 &, pid=T1, continue
#         (continue skips sset pid "" at line ~1320).
# Ticks 3–10: T1 (triage stub sleeping 30s) alive → completion loop skips; max_ticks → exit.
PATH="$BIN:$PATH" \
  CB_REPO="test/repo" \
  CB_HOME="$CBHOME_T8B" \
  CB_SPAWN="$EXEC_STUB_T8B" \
  CB_TRIAGE_SPAWN="$TRIAGE_STUB_T8B" \
  CB_TRIAGE_PARSE="$TRIAGE_PARSE" \
  CB_POLL=0 \
  CB_MAX_TICKS=10 \
  CB_IDLE_CONFIRM=5 \
  CB_MAX_PARALLEL=5 \
  CB_RETRY_CAP=2 \
  CB_GIT_REMOTE="" \
  bash "$LAUNCHER" run 2>/dev/null

# Kill the sleeping triage stub before assertions so it doesn't linger
_tpid_t8b=$(t_sget "$CBHOME_T8B" 10 pid)
[ -n "$_tpid_t8b" ] && kill "$_tpid_t8b" 2>/dev/null || true

# (a) leaf transitions to status:needs-triage NOT status:blocked
has_label 10 "status:needs-triage" \
  && ok "T8B: *) fallthrough — leaf has status:needs-triage" \
  || ko "T8B: *) fallthrough — leaf missing status:needs-triage"

no_label 10 "status:blocked" \
  && ok "T8B: *) fallthrough — status:blocked NOT set" \
  || ko "T8B: *) fallthrough — status:blocked wrongly set"

# (b) spawn-stub log records a TRIAGE_SPAWN invocation for leaf #10
grep -q "triage-spawn 10" "$TRIAGE_LOG_T8B" 2>/dev/null \
  && ok "T8B: *) fallthrough — TRIAGE_SPAWN invoked for leaf #10" \
  || ko "T8B: *) fallthrough — TRIAGE_SPAWN NOT invoked (log: $(cat "$TRIAGE_LOG_T8B" 2>/dev/null))"

# (c) sget kind = triage
[ "$(t_sget "$CBHOME_T8B" 10 kind)" = "triage" ] \
  && ok "T8B: *) fallthrough — kind=triage" \
  || ko "T8B: *) fallthrough — kind='$(t_sget "$CBHOME_T8B" 10 kind)' (expected triage)"

# (d) sget pid non-empty — continue escaped sset pid "" at line ~1320
[ -n "$(t_sget "$CBHOME_T8B" 10 pid)" ] \
  && ok "T8B: *) fallthrough — pid non-empty (continue escaped sset pid \"\")" \
  || ko "T8B: *) fallthrough — pid empty (sset pid \"\" was NOT escaped by continue)"

# ═══════════════════════════════════════════════════════════════════════════════
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
