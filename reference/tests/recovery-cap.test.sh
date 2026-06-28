#!/usr/bin/env bash
# recovery-cap.test.sh — recovery-cycle cap (CB_RECOVERY_CAP / recovery_n) for charter #612.
# 5 deterministic stub scenarios; no real network; gh calls and spawn scripts stubbed;
# no triage agent actually runs — verdict comments are injected into stub board state.
#
# T1 — cap-hit on plan-flaw (deferred path + variable-name verification)
# T2 — cap-hit on approach-flaw (deferred path)
# T3 — below cap, bounce proceeds (increment + needs-plan)
# T4 — queue skips deferred charter, advances to next
# T5 — loop never creates human-decision after cap-hit
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
export BOARD_STATE GH_LOG BIN
mkdir -p "$BIN" "$SANDBOX"

# ── gh stub (stateful board mutations + issue create support) ─────────────────
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
  "issue create")
    title=""; body=""; label=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --title|-t) title="$2"; shift ;;
        --body|-b)  body="$2";  shift ;;
        --label|-l) label="$2"; shift ;;
      esac
      shift
    done
    _max=$(jq 'map(.number) | max // 0' "$BOARD_STATE")
    _new=$((_max + 1))
    _labels_json="$(printf '%s\n' "$label" | jq -R 'select(length>0) | {name:.}' | jq -s .)"
    jq --argjson n "$_new" --arg t "$title" --arg b "$body" --argjson l "$_labels_json" \
      '. + [{number:$n, state:"OPEN", title:$t, body:$b, labels:$l, comments:[]}]' \
      "$BOARD_STATE" > "$BOARD_STATE.t" && mv "$BOARD_STATE.t" "$BOARD_STATE"
    printf '%s\n' "$_new"
    printf 'create #%s [%s]: %s\n' "$_new" "$label" "$title" >> "$GH_LOG" ;;
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

# Count issues with a given label
count_label_issues(){
  jq --arg l "$1" '[.[] | select(.labels[]?.name == $l)] | length' "$BOARD_STATE"
}

# reset board JSON and GH_LOG
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

# Run one completion tick (CB_MAX_PARALLEL=0 prevents new claiming).
# $1 = cbhome, $2 = CB_RECOVERY_CAP (default 2)
run_completion_tick(){
  local cbhome="$1" rcap="${2:-2}"
  PATH="$BIN:$PATH" \
    CB_REPO="test/repo" \
    CB_HOME="$cbhome" \
    CB_TRIAGE_PARSE="$TRIAGE_PARSE" \
    CB_POLL=0 \
    CB_MAX_TICKS=1 \
    CB_IDLE_CONFIRM=1 \
    CB_MAX_PARALLEL=0 \
    CB_RETRY_CAP=2 \
    CB_RECOVERY_CAP="$rcap" \
    CB_GIT_REMOTE="" \
    bash "$LAUNCHER" run 2>/dev/null
}

# ═══════════════════════════════════════════════════════════════════════════════
echo "== T1: cap-hit on plan-flaw (deferred path + variable-name verification) =="
# ═══════════════════════════════════════════════════════════════════════════════
# Seed: recovery_n=2, CB_RECOVERY_CAP=2, triage verdict plan-flaw.
# Expected: charter gets status:deferred (not status:needs-plan); evidence comment
# uses ${_troot:-unknown} (correct) — comment does NOT say "root: unknown".
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
t_sset "$CBHOME_T1" 99  kind       "triage"
t_sset "$CBHOME_T1" 99  pid        "$dead_pid_t1"
# Seed charter recovery_n=2 (at cap)
t_sset "$CBHOME_T1" 500 recovery_n "2"

run_completion_tick "$CBHOME_T1" 2

# T1.1: charter has status:deferred
has_label 500 "status:deferred" \
  && ok "T1.1: charter #500 has status:deferred (deferred path fired)" \
  || ko "T1.1: charter #500 missing status:deferred (deferred path did not fire)"

# T1.2: charter does NOT have status:needs-plan (bounce was skipped)
no_label 500 "status:needs-plan" \
  && ok "T1.2: charter #500 does NOT have status:needs-plan (bounce skipped)" \
  || ko "T1.2: charter #500 has status:needs-plan — bounce wrongly executed"

# T1.3: charter does NOT have status:approved (removed on deferred)
no_label 500 "status:approved" \
  && ok "T1.3: charter #500 does NOT have status:approved (removed on cap-hit)" \
  || ko "T1.3: charter #500 still has status:approved — label not removed"

# T1.4: no type:human-decision issue created
_t1_hd=$(count_label_issues "type:human-decision")
[ "${_t1_hd:-0}" -eq 0 ] \
  && ok "T1.4: no type:human-decision issue created" \
  || ko "T1.4: unexpected type:human-decision issue(s) found (count=${_t1_hd})"

# T1.5 [MANDATORY]: evidence comment does NOT contain "root: unknown"
# Proof that ${_troot:-unknown} (in-scope) was used, NOT ${root:-unknown} (unset→"unknown").
_t1_unknown_count=$(jq -r '[.[] | select(.number==500)][0].comments[]?.body' "$BOARD_STATE" \
  | grep -F "root: unknown" | wc -l | tr -d ' ')
_t1_comment_count=$(jq '[.[] | select(.number==500)][0].comments | length' "$BOARD_STATE")
if [ "${_t1_unknown_count:-0}" -gt 0 ]; then
  ko "T1.5 [MANDATORY]: evidence comment contains 'root: unknown' — wrong variable \${root:-unknown} used instead of \${_troot:-unknown}"
elif [ "${_t1_comment_count:-0}" -eq 0 ]; then
  ko "T1.5 [MANDATORY]: no evidence comment posted on charter #500 (deferred path missing comment)"
else
  ok "T1.5 [MANDATORY]: evidence comment does NOT contain 'root: unknown' (correct \${_troot:-unknown} used)"
fi

# ═══════════════════════════════════════════════════════════════════════════════
echo "== T2: cap-hit on approach-flaw =="
# ═══════════════════════════════════════════════════════════════════════════════
# Seed: recovery_n=2, CB_RECOVERY_CAP=2, triage verdict approach-flaw.
# Expected: charter gets status:deferred (not status:needs-analysis).
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
t_sset "$CBHOME_T2" 99  kind       "triage"
t_sset "$CBHOME_T2" 99  pid        "$dead_pid_t2"
# Seed charter recovery_n=2 (at cap: 2 -ge 2 is true → deferred path)
t_sset "$CBHOME_T2" 500 recovery_n "2"

run_completion_tick "$CBHOME_T2" 2

# T2.1: charter has status:deferred
has_label 500 "status:deferred" \
  && ok "T2.1: charter #500 has status:deferred (deferred path fired on approach-flaw)" \
  || ko "T2.1: charter #500 missing status:deferred"

# T2.2: charter does NOT have status:needs-analysis (bounce was skipped)
no_label 500 "status:needs-analysis" \
  && ok "T2.2: charter #500 does NOT have status:needs-analysis (bounce skipped)" \
  || ko "T2.2: charter #500 has status:needs-analysis — bounce wrongly executed"

# T2.3: charter does NOT have status:approved
no_label 500 "status:approved" \
  && ok "T2.3: charter #500 does NOT have status:approved (removed on cap-hit)" \
  || ko "T2.3: charter #500 still has status:approved"

# T2.4: no type:human-decision issue created
_t2_hd=$(count_label_issues "type:human-decision")
[ "${_t2_hd:-0}" -eq 0 ] \
  && ok "T2.4: no type:human-decision issue created" \
  || ko "T2.4: unexpected type:human-decision issue(s) found (count=${_t2_hd})"

# ═══════════════════════════════════════════════════════════════════════════════
echo "== T3: below cap — bounce proceeds and recovery_n increments =="
# ═══════════════════════════════════════════════════════════════════════════════
# Seed: recovery_n=0, CB_RECOVERY_CAP=2, triage verdict plan-flaw.
# Expected: charter gets status:needs-plan (bounce proceeds);
#           sget charter 500 recovery_n → "1" (incremented in else branch).
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

dead_pid_t3=$(mk_dead_pid)
t_sset "$CBHOME_T3" 99  kind       "triage"
t_sset "$CBHOME_T3" 99  pid        "$dead_pid_t3"
# Seed charter recovery_n=0 (below cap: 0 -ge 2 is false → bounce)
t_sset "$CBHOME_T3" 500 recovery_n "0"

run_completion_tick "$CBHOME_T3" 2

# T3.1: charter gets status:needs-plan (normal bounce path)
has_label 500 "status:needs-plan" \
  && ok "T3.1: charter #500 has status:needs-plan (bounce proceeds below cap)" \
  || ko "T3.1: charter #500 missing status:needs-plan — bounce did not execute"

# T3.2: charter does NOT get status:deferred
no_label 500 "status:deferred" \
  && ok "T3.2: charter #500 does NOT have status:deferred (cap not yet reached)" \
  || ko "T3.2: charter #500 incorrectly has status:deferred"

# T3.3: recovery_n incremented from 0 → 1
_t3_rn=$(t_sget "$CBHOME_T3" 500 recovery_n)
[ "${_t3_rn}" = "1" ] \
  && ok "T3.3: recovery_n for charter #500 = '1' (incremented from 0 in else branch)" \
  || ko "T3.3: recovery_n for charter #500 = '${_t3_rn:-empty}' (expected '1')"

# ═══════════════════════════════════════════════════════════════════════════════
echo "== T4: queue skips deferred charter, advances to next =="
# ═══════════════════════════════════════════════════════════════════════════════
# Queue order: [charter_A=#50, charter_B=#100]; charter_A has status:deferred.
# Expected: _q_head resolves to charter_B (#100) → leaf #101 is spawned.
#           charter_A's leaf (#51) is NOT spawned.
CBHOME_T4="$ROOT/cbhome_t4"
mk_cbhome "$CBHOME_T4"

SPAWN_LOG_T4="$ROOT/spawn_t4.log"
cat > "$ROOT/stub-spawn-t4.sh" << SPAWNEOF
#!/usr/bin/env bash
id="\$1"; role="\$2"
printf 'spawned %s %s\n' "\$id" "\${role:-exec}" >> "${SPAWN_LOG_T4}"
mkdir -p "${CBHOME_T4}/run/work/\$id"
printf '{"phase":"done"}' > "${CBHOME_T4}/run/work/\$id/status.json"
exit 0
SPAWNEOF
chmod +x "$ROOT/stub-spawn-t4.sh"

reset_board << 'JSON'
[
  {"number":50,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:approved"},{"name":"status:deferred"}],
   "body":"charter A (deferred)","comments":[]},
  {"number":51,"state":"OPEN",
   "labels":[{"name":"type:agent"}],
   "body":"Charter: #50\n## Acceptance (machine)\n- check: true",
   "comments":[]},
  {"number":100,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:approved"}],
   "body":"charter B (active)","comments":[]},
  {"number":101,"state":"OPEN",
   "labels":[{"name":"type:agent"}],
   "body":"Charter: #100\n## Acceptance (machine)\n- check: true",
   "comments":[]}
]
JSON

# Write queue.json: charter_A (50) first, charter_B (100) second
mkdir -p "$CBHOME_T4/run"
printf '{"order":[50,100]}' > "$CBHOME_T4/run/queue.json"

PATH="$BIN:$PATH" \
  CB_REPO="test/repo" \
  CB_HOME="$CBHOME_T4" \
  CB_SPAWN="$ROOT/stub-spawn-t4.sh" \
  CB_TRIAGE_PARSE="$TRIAGE_PARSE" \
  CB_POLL=0 \
  CB_MAX_TICKS=2 \
  CB_IDLE_CONFIRM=1 \
  CB_MAX_PARALLEL=5 \
  CB_RETRY_CAP=2 \
  CB_RECOVERY_CAP=2 \
  CB_GIT_REMOTE="" \
  bash "$LAUNCHER" run 2>/dev/null

# T4.1: leaf #101 (charter B) IS spawned — queue advanced past deferred A
grep -q "^spawned 101" "$SPAWN_LOG_T4" 2>/dev/null \
  && ok "T4.1: leaf #101 (charter B=#100) IS spawned — queue advanced past deferred charter A=#50" \
  || ko "T4.1: leaf #101 NOT spawned — queue did not advance past deferred charter A=#50"

# T4.2: leaf #51 (charter A, deferred) is NOT spawned
grep -q "^spawned 51" "$SPAWN_LOG_T4" 2>/dev/null \
  && ko "T4.2: leaf #51 (charter A=#50, deferred) was spawned — deferred not skipped by queue!" \
  || ok "T4.2: leaf #51 (charter A=#50, deferred) correctly NOT spawned"

# ═══════════════════════════════════════════════════════════════════════════════
echo "== T5: loop never creates type:human-decision after cap-hit =="
# ═══════════════════════════════════════════════════════════════════════════════
# After a cap-hit deferred path runs, assert zero issues with type:human-decision.
# This is an explicit guard: the deferred path must NOT spawn a human-decision issue.
CBHOME_T5="$ROOT/cbhome_t5"
mk_cbhome "$CBHOME_T5"

reset_board << 'JSON'
[
  {"number":500,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:approved"}],
   "body":"charter 500","comments":[]},
  {"number":99,"state":"OPEN",
   "labels":[{"name":"type:agent"},{"name":"status:needs-triage"}],
   "body":"Charter: #500\n## Acceptance (machine)\n- check: true",
   "comments":[{"body":"## Triage (machine)\n{\"root\":\"plan-flaw\",\"evidence\":\"recovery-cap-hit test\",\"route\":\"needs-plan\"}"}]}
]
JSON

dead_pid_t5=$(mk_dead_pid)
t_sset "$CBHOME_T5" 99  kind       "triage"
t_sset "$CBHOME_T5" 99  pid        "$dead_pid_t5"
# Seed charter recovery_n=2 (at cap)
t_sset "$CBHOME_T5" 500 recovery_n "2"

run_completion_tick "$CBHOME_T5" 2

# T5.1: charter has status:deferred (confirm cap-hit fired)
has_label 500 "status:deferred" \
  && ok "T5.1: charter #500 has status:deferred (cap-hit fired correctly)" \
  || ko "T5.1: charter #500 missing status:deferred (cap-hit did not fire)"

# T5.2: zero issues with label type:human-decision in board state
_t5_hd=$(count_label_issues "type:human-decision")
[ "${_t5_hd:-0}" -eq 0 ] \
  && ok "T5.2: zero type:human-decision issues exist after cap-hit (human-decision path not taken)" \
  || ko "T5.2: found ${_t5_hd} type:human-decision issue(s) — must be zero on cap-hit"

# T5.3: no gh issue create call in GH_LOG (belt-and-suspenders)
if [ -f "$GH_LOG" ] && grep -q "^create " "$GH_LOG" 2>/dev/null; then
  ko "T5.3: gh issue create was called after cap-hit (unexpected — check GH_LOG)"
else
  ok "T5.3: no gh issue create calls after cap-hit"
fi

# ═══════════════════════════════════════════════════════════════════════════════
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
