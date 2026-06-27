#!/usr/bin/env bash
# triage-bounce-evidence.test.sh — evidence comment before label-transition tests
# (charter #611, issue #793).
# 3 deterministic stub scenarios; no real network; gh calls and spawn scripts stubbed;
# no triage agent actually runs — verdict comments are injected into stub board state.
#
# Test 1 — plan-flaw: evidence comment posted before label transition
# Test 2 — approach-flaw: evidence comment posted before label transition
# Test 3 — idempotency: second invocation does not double-post
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

reset_board(){ rm -f "$GH_LOG"; cat > "$BOARD_STATE"; }

mk_cbhome(){
  local h="$1"; mkdir -p "$h"
  cp "$BOARD_GH_SRC" "$h/board-gh.sh"
  cp "$LAUNCHABLE_SRC" "$h/launchable.sh"
  chmod +x "$h/board-gh.sh" "$h/launchable.sh"
}

t_sget(){ cat "$1/run/state/$2/$3" 2>/dev/null || printf ''; }
t_sset(){
  mkdir -p "$1/run/state/$2"
  printf '%s' "$4" > "$1/run/state/$2/$3"
}

mk_dead_pid(){
  ( exit 0 ) &
  local p=$!
  wait "$p" 2>/dev/null
  printf '%s' "$p"
}

# Run one completion tick (CB_MAX_PARALLEL=0 prevents new claiming).
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
echo "== Test 1: plan-flaw — evidence comment posted before label transition =="
# ═══════════════════════════════════════════════════════════════════════════════
CBHOME_T1="$ROOT/cbhome_t1"
mk_cbhome "$CBHOME_T1"

reset_board << 'JSON'
[
  {"number":500,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:approved"}],
   "body":"charter 500","comments":[]},
  {"number":99,"state":"OPEN",
   "labels":[{"name":"type:agent"},{"name":"status:needs-triage"}],
   "body":"Charter: #500\n## Acceptance (machine)\n- check: true",
   "comments":[{"body":"## Triage (machine)\n{\"root\":\"plan-flaw\",\"evidence\":\"spec contradicts impl\",\"route\":\"needs-plan\"}"}]}
]
JSON

dead_pid_t1=$(mk_dead_pid)
t_sset "$CBHOME_T1" 99 kind "triage"
t_sset "$CBHOME_T1" 99 pid  "$dead_pid_t1"

run_completion_tick "$CBHOME_T1"

# Assert 1: charter #500 has a comment whose body contains <!-- triage-bounce -->
jq -r '[.[] | select(.number==500)][0].comments[]?.body' "$BOARD_STATE" \
  | grep -q "<!-- triage-bounce -->" \
  && ok "T1: plan-flaw — charter #500 has <!-- triage-bounce --> comment" \
  || ko "T1: plan-flaw — charter #500 missing <!-- triage-bounce --> comment"

# Assert 2: charter #500 has label status:needs-plan
has_label 500 "status:needs-plan" \
  && ok "T1: plan-flaw — charter #500 has label status:needs-plan" \
  || ko "T1: plan-flaw — charter #500 missing label status:needs-plan"

# Assert 3: comment #500 line appears before edit #500 +[status:needs-plan] in GH_LOG
_t1_comment_line=$(grep -n "comment #500" "$GH_LOG" | head -1 | cut -d: -f1)
_t1_edit_line=$(grep -n "edit #500.*+\[status:needs-plan\]" "$GH_LOG" | head -1 | cut -d: -f1)
[ -n "$_t1_comment_line" ] && [ -n "$_t1_edit_line" ] && [ "$_t1_comment_line" -lt "$_t1_edit_line" ] \
  && ok "T1: plan-flaw — comment #500 logged before edit #500 +[status:needs-plan] (ordering invariant)" \
  || ko "T1: plan-flaw — ordering invariant violated (comment_line=${_t1_comment_line:-MISSING}, edit_line=${_t1_edit_line:-MISSING})"

# ═══════════════════════════════════════════════════════════════════════════════
echo "== Test 2: approach-flaw — evidence comment posted before label transition =="
# ═══════════════════════════════════════════════════════════════════════════════
CBHOME_T2="$ROOT/cbhome_t2"
mk_cbhome "$CBHOME_T2"

reset_board << 'JSON'
[
  {"number":500,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:approved"}],
   "body":"charter 500","comments":[]},
  {"number":99,"state":"OPEN",
   "labels":[{"name":"type:agent"},{"name":"status:needs-triage"}],
   "body":"Charter: #500\n## Acceptance (machine)\n- check: true",
   "comments":[{"body":"## Triage (machine)\n{\"root\":\"approach-flaw\",\"evidence\":\"wrong architectural approach\",\"route\":\"needs-analysis\"}"}]}
]
JSON

dead_pid_t2=$(mk_dead_pid)
t_sset "$CBHOME_T2" 99 kind "triage"
t_sset "$CBHOME_T2" 99 pid  "$dead_pid_t2"

run_completion_tick "$CBHOME_T2"

# Assert 1: charter #500 has a comment whose body contains <!-- triage-bounce -->
jq -r '[.[] | select(.number==500)][0].comments[]?.body' "$BOARD_STATE" \
  | grep -q "<!-- triage-bounce -->" \
  && ok "T2: approach-flaw — charter #500 has <!-- triage-bounce --> comment" \
  || ko "T2: approach-flaw — charter #500 missing <!-- triage-bounce --> comment"

# Assert 2: charter #500 has label status:needs-analysis
has_label 500 "status:needs-analysis" \
  && ok "T2: approach-flaw — charter #500 has label status:needs-analysis" \
  || ko "T2: approach-flaw — charter #500 missing label status:needs-analysis"

# Assert 3: comment #500 line appears before edit #500 +[status:needs-analysis] in GH_LOG
_t2_comment_line=$(grep -n "comment #500" "$GH_LOG" | head -1 | cut -d: -f1)
_t2_edit_line=$(grep -n "edit #500.*+\[status:needs-analysis\]" "$GH_LOG" | head -1 | cut -d: -f1)
[ -n "$_t2_comment_line" ] && [ -n "$_t2_edit_line" ] && [ "$_t2_comment_line" -lt "$_t2_edit_line" ] \
  && ok "T2: approach-flaw — comment #500 logged before edit #500 +[status:needs-analysis] (ordering invariant)" \
  || ko "T2: approach-flaw — ordering invariant violated (comment_line=${_t2_comment_line:-MISSING}, edit_line=${_t2_edit_line:-MISSING})"

# ═══════════════════════════════════════════════════════════════════════════════
echo "== Test 3: idempotency — second invocation does not double-post =="
# ═══════════════════════════════════════════════════════════════════════════════
CBHOME_T3="$ROOT/cbhome_t3"
mk_cbhome "$CBHOME_T3"

reset_board << 'JSON'
[
  {"number":500,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:approved"}],
   "body":"charter 500","comments":[]},
  {"number":99,"state":"OPEN",
   "labels":[{"name":"type:agent"},{"name":"status:needs-triage"}],
   "body":"Charter: #500\n## Acceptance (machine)\n- check: true",
   "comments":[{"body":"## Triage (machine)\n{\"root\":\"plan-flaw\",\"evidence\":\"spec contradicts impl\",\"route\":\"needs-plan\"}"}]}
]
JSON

# Run 1: triage handler fires, evidence comment posted
dead_pid_t3a=$(mk_dead_pid)
t_sset "$CBHOME_T3" 99 kind "triage"
t_sset "$CBHOME_T3" 99 pid  "$dead_pid_t3a"
run_completion_tick "$CBHOME_T3"

# Re-arm for run 2: board state retained (evidence comment already present);
# re-seed kind=triage + fresh dead pid so the handler fires a second time.
rm -f "$GH_LOG"
dead_pid_t3b=$(mk_dead_pid)
t_sset "$CBHOME_T3" 99 kind "triage"
t_sset "$CBHOME_T3" 99 pid  "$dead_pid_t3b"
run_completion_tick "$CBHOME_T3"

# Assert: charter #500 has exactly ONE comment containing <!-- triage-bounce -->
_t3_bounce_count=$(jq \
  '[.[] | select(.number==500)][0].comments // []
   | [.[] | select(.body | contains("<!-- triage-bounce -->"))] | length' \
  "$BOARD_STATE")
[ "$_t3_bounce_count" -eq 1 ] \
  && ok "T3: idempotency — exactly 1 <!-- triage-bounce --> comment on charter #500 (count=$_t3_bounce_count)" \
  || ko "T3: idempotency — expected 1 <!-- triage-bounce --> comment, got $_t3_bounce_count"

# ═══════════════════════════════════════════════════════════════════════════════
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
