#!/usr/bin/env bash
# 1049-recovery-parse.test.sh — charter #1049 (recovery-escalation) / issue #1123 (qa-engineer leaf).
#
# Synthetic unit/contract proof of the recovery-escalation feature. These tests OWN the
# contract surface; implementation leaves (#1120/#1121/#1122) are forbidden from editing
# test files. Modeled on reference/tests/1109-verify-merged-rich-reason.test.sh (fixture-
# driven, set -u, pass/fail counters, exit-on-fail) and the stub-board launcher harness of
# reference/tests/recovery-cap.test.sh (stateful gh stub + board-gh.sh + launchable.sh).
#
# Sections (charter #1049 acceptance):
#   T1 Parser contract  — recovery-parse.sh: valid multi-step plan -> TSV rows + terminal
#                         row; malformed JSON / empty plan / unknown route / missing
#                         terminal each rejected (non-zero exit).
#   T2 Escalation routing — triage no-verdict -> status:needs-recovery + kind=recovery,
#                         NOT straight-to-status:blocked.
#   T3 Cursor state machine — step0 RED advances the cursor and dispatches step1's route;
#                         a GREEN step honors terminal=merge and clears recovery state.
#   T4 Plan exhaustion  — cursor past plan length -> status:deferred + evidence, NEVER
#                         status:blocked / no human-halt anywhere.
#   T5 RED_REASON absent — graceful fall-through: NO manager spawn (manager is blind, #1110).
#
# The LIVE cross-TICK reproduction (the charter's "Проверено вживую" bullet / prior review
# фикс #2) lives in the sibling 1049-recovery-cross-tick-live.test.sh — synthetic scenarios
# alone do NOT satisfy that gate.
#
# Fixture-creation pattern: temp-name then mv (no redirect onto test-file paths, #523 ITA).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER="${LAUNCHER_OVERRIDE:-$HERE/../runtime/crewboss-launcher-gh.sh}"
RECOVERY_PARSE="${RECOVERY_PARSE_OVERRIDE:-$HERE/../runtime/recovery-parse.sh}"
TRIAGE_PARSE="$HERE/../runtime/triage-parse.sh"
BOARD_GH_SRC="$HERE/../../proto/r6/board-gh.sh"
LAUNCHABLE_SRC="$HERE/../../proto/r6/launchable.sh"

pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }
skip(){ printf 'skip %s\n' "$1"; }

# recovery-parse.sh requires jq; the launcher harness needs jq too. Skip cleanly (exit 0)
# rather than emit a false failure for an environmental gap (live-test precedent).
if ! command -v jq >/dev/null 2>&1; then
  skip "jq unavailable — skipping recovery-parse contract suite (environmental)"
  printf 'passed=%d failed=%d\n' "$pass" "$fail"
  exit 0
fi

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"; pkill -P $$ 2>/dev/null; true' EXIT
BIN="$ROOT/bin"; SANDBOX="$ROOT/sb"
BOARD_STATE="$SANDBOX/board.json"; GH_LOG="$SANDBOX/gh.log"; PR_JSON="$SANDBOX/pr.json"
export BOARD_STATE GH_LOG BIN PR_JSON
mkdir -p "$BIN" "$SANDBOX"
printf '[]' > "$PR_JSON"

# ══════════════════════════════════════════════════════════════════════════════
# T1: PARSER CONTRACT — recovery-parse.sh
# ══════════════════════════════════════════════════════════════════════════════
echo "== T1: parser contract (recovery-parse.sh) =="

# Build a ## Recovery (machine) block on stdin; capture TSV + exit code.
parse_block(){ printf '%s\n' "$1" | bash "$RECOVERY_PARSE"; }

# --- T1.1 valid multi-step plan -> correct TSV rows + terminal row ---
VALID_PLAN='## Recovery (machine)
[{"action":"update-assert","target":"acceptance-block","route":"executor-rework"},{"action":"flip-bug","target":"role-spawn","route":"test-bug"}]
terminal: merge'

T1_RC=0
T1_OUT="$(parse_block "$VALID_PLAN")" || T1_RC=$?
[ "$T1_RC" -eq 0 ] \
  && ok "T1.1: valid multi-step plan -> exit 0" \
  || ko "T1.1: valid plan rejected (exit $T1_RC)"

# Row 0: idx=0 route=executor-rework ; Row 1: idx=1 route=test-bug ; terminal=merge.
_r0_route="$(printf '%s\n' "$T1_OUT" | awk -F'\t' '$1=="0"{print $4}')"
_r1_route="$(printf '%s\n' "$T1_OUT" | awk -F'\t' '$1=="1"{print $4}')"
_term="$(printf '%s\n' "$T1_OUT" | awk -F'\t' '$1=="terminal"{print $2}')"
_nsteps="$(printf '%s\n' "$T1_OUT" | awk -F'\t' '$1 ~ /^[0-9]+$/' | wc -l | tr -d ' ')"

[ "$_nsteps" -eq 2 ] \
  && ok "T1.2: emitted exactly 2 step rows" \
  || ko "T1.2: expected 2 step rows, got $_nsteps"
[ "$_r0_route" = "executor-rework" ] && [ "$_r1_route" = "test-bug" ] \
  && ok "T1.3: step routes preserved in order (executor-rework, test-bug)" \
  || ko "T1.3: step routes wrong (got '$_r0_route','$_r1_route')"
[ "$_term" = "merge" ] \
  && ok "T1.4: terminal row carries directive (merge)" \
  || ko "T1.4: terminal row wrong (got '$_term')"

# --- T1.5 malformed JSON -> reject ---
BAD_JSON='## Recovery (machine)
[{"action":"x","route":"executor-rework"  <<< not json
terminal: merge'
_rc=0; parse_block "$BAD_JSON" >/dev/null 2>&1 || _rc=$?
[ "$_rc" -ne 0 ] \
  && ok "T1.5: malformed JSON rejected (non-zero exit $_rc)" \
  || ko "T1.5: malformed JSON wrongly accepted (exit 0)"

# --- T1.6 empty plan array -> reject ---
EMPTY_PLAN='## Recovery (machine)
[]
terminal: merge'
_rc=0; parse_block "$EMPTY_PLAN" >/dev/null 2>&1 || _rc=$?
[ "$_rc" -ne 0 ] \
  && ok "T1.6: empty plan array rejected (non-zero exit $_rc)" \
  || ko "T1.6: empty plan wrongly accepted (exit 0)"

# --- T1.7 unknown / non-recovery route -> reject ---
BAD_ROUTE='## Recovery (machine)
[{"action":"x","target":"y","route":"deploy-to-prod"}]
terminal: merge'
_rc=0; parse_block "$BAD_ROUTE" >/dev/null 2>&1 || _rc=$?
[ "$_rc" -ne 0 ] \
  && ok "T1.7: unknown route rejected (non-zero exit $_rc)" \
  || ko "T1.7: unknown route wrongly accepted (exit 0)"

# --- T1.8 missing terminal directive -> reject ---
NO_TERMINAL='## Recovery (machine)
[{"action":"x","target":"y","route":"executor-rework"}]'
_rc=0; parse_block "$NO_TERMINAL" >/dev/null 2>&1 || _rc=$?
[ "$_rc" -ne 0 ] \
  && ok "T1.8: missing terminal directive rejected (non-zero exit $_rc)" \
  || ko "T1.8: missing terminal wrongly accepted (exit 0)"

# ══════════════════════════════════════════════════════════════════════════════
# Launcher harness (stub board + completion-detect tick) for T2–T5.
# ══════════════════════════════════════════════════════════════════════════════

# ── gh stub: stateful board mutations + pr list/view/merge for the recovery path ──
GHSTUB="$(mktemp)"
cat > "$GHSTUB" << 'GHEOF'
#!/usr/bin/env bash
obj="$1"; verb="$2"; shift 2 2>/dev/null || true
_args=()
while [ $# -gt 0 ]; do
  case "$1" in -R|--repo|-L|--limit) shift ;; *) _args+=("$1") ;; esac; shift
done
set -- "${_args[@]+"${_args[@]}"}"
case "$obj $verb" in
  "issue list") cat "$BOARD_STATE" ;;
  "issue view")
    n="$1"; shift; jqf=""
    while [ $# -gt 0 ]; do case "$1" in --jq|-q) jqf="$2"; shift ;; --json) shift ;; esac; shift; done
    o="$(jq --argjson n "$n" 'map(select(.number==$n))[0] // {}' "$BOARD_STATE")"
    if [ -n "$jqf" ]; then printf '%s' "$o" | jq -r "$jqf"; else printf '%s\n' "$o"; fi ;;
  "issue edit")
    n="$1"; shift; adds=(); rems=()
    while [ $# -gt 0 ]; do
      case "$1" in --add-label) adds+=("$2"); shift ;; --remove-label) rems+=("$2"); shift ;; esac; shift
    done
    adds_json="$(printf '%s\n' "${adds[@]+"${adds[@]}"}" | jq -R . | jq -s .)"
    rems_json="$(printf '%s\n' "${rems[@]+"${rems[@]}"}" | jq -R . | jq -s .)"
    jq --argjson n "$n" --argjson adds "$adds_json" --argjson rems "$rems_json" '
      map(if .number == $n then
        .labels = [(.labels // [])[] | select(.name as $nm | ($rems | index($nm)) == null)]
        | reduce $adds[] as $a (.;
            if ([.labels[].name] | index($a)) == null then .labels += [{name: $a}] else . end)
      else . end)' "$BOARD_STATE" > "$BOARD_STATE.t" && mv "$BOARD_STATE.t" "$BOARD_STATE"
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
    title=""; label=""
    while [ $# -gt 0 ]; do case "$1" in --title|-t) title="$2"; shift ;; --label|-l) label="$2"; shift ;; --body|-b) shift ;; esac; shift; done
    _max=$(jq 'map(.number) | max // 0' "$BOARD_STATE"); _new=$((_max + 1))
    _lj="$(printf '%s\n' "$label" | jq -R 'select(length>0) | {name:.}' | jq -s .)"
    jq --argjson n "$_new" --arg t "$title" --argjson l "$_lj" \
      '. + [{number:$n, state:"OPEN", title:$t, labels:$l, comments:[]}]' \
      "$BOARD_STATE" > "$BOARD_STATE.t" && mv "$BOARD_STATE.t" "$BOARD_STATE"
    printf '%s\n' "$_new"; printf 'create #%s [%s]: %s\n' "$_new" "$label" "$title" >> "$GH_LOG" ;;
  "issue close") printf 'close #%s\n' "${1:-?}" >> "$GH_LOG" ;;
  "pr list") cat "$PR_JSON" 2>/dev/null || printf '[]' ;;
  "pr view") printf '{"state":"OPEN","mergeCommit":null}\n' ;;
  "pr merge") printf 'merge %s\n' "${1:-?}" >> "$GH_LOG" ;;
  "pr comment"|"pr close") : ;;
  "label create") ;;
  "auth token") printf 'fake-token\n' ;;
  *) printf 'gh-stub UNHANDLED: %s %s %s\n' "$obj" "$verb" "$*" >> "$GH_LOG" ;;
esac
exit 0
GHEOF
mv "$GHSTUB" "$BIN/gh"
chmod +x "$BIN/gh"

has_label(){ [ "$(jq -r --argjson n "$1" 'map(select(.number==$n))[0].labels[]?.name' "$BOARD_STATE" | grep -c "^${2}\$")" -ge 1 ]; }
no_label(){ ! has_label "$1" "$2"; }
count_label_issues(){ jq --arg l "$1" '[.[] | select(.labels[]?.name == $l)] | length' "$BOARD_STATE"; }
reset_board(){ rm -f "$GH_LOG"; printf '[]' > "$PR_JSON"; cat > "$BOARD_STATE"; }

mk_cbhome(){
  local h="$1"; mkdir -p "$h"
  cp "$BOARD_GH_SRC" "$h/board-gh.sh"; cp "$LAUNCHABLE_SRC" "$h/launchable.sh"
  chmod +x "$h/board-gh.sh" "$h/launchable.sh"
}
t_sget(){ cat "$1/run/state/$2/$3" 2>/dev/null || printf ''; }
t_sset(){ mkdir -p "$1/run/state/$2"; printf '%s' "$4" > "$1/run/state/$2/$3"; }
mk_dead_pid(){ ( exit 0 ) & local p=$!; wait "$p" 2>/dev/null; printf '%s' "$p"; }
# Write a status.json with the given phase for a leaf under CB_HOME/run/work/<id>/.
mk_status(){ mkdir -p "$1/run/work/$2"; printf '{"phase":"%s"}' "$3" > "$1/run/work/$2/status.json"; }

# run_tick <cbhome> [extra env KEY=VAL ...] : one completion tick, no new claiming.
run_tick(){
  local cbhome="$1"; shift
  PATH="$BIN:$PATH" \
    CB_REPO="test/repo" CB_HOME="$cbhome" \
    CB_TRIAGE_PARSE="$TRIAGE_PARSE" \
    CB_POLL=0 CB_MAX_TICKS=1 CB_IDLE_CONFIRM=1 CB_MAX_PARALLEL=0 \
    CB_RETRY_CAP=2 CB_RECOVERY_CAP=2 CB_RECOVERY_LEAD_CAP=1 \
    env "$@" bash "$LAUNCHER" run 2>/dev/null
}

# ══════════════════════════════════════════════════════════════════════════════
# T2: ESCALATION ROUTING — triage no-verdict -> needs-recovery + kind=recovery
# ══════════════════════════════════════════════════════════════════════════════
echo "== T2: escalation routing (triage no-verdict -> recovery, NOT blocked) =="
CBHOME_T2="$ROOT/cb_t2"; mk_cbhome "$CBHOME_T2"
SPAWN_LOG_T2="$ROOT/recspawn_t2.log"; : > "$SPAWN_LOG_T2"
RS2="$(mktemp)"
cat > "$RS2" << SP
#!/usr/bin/env bash
printf 'recovery-spawn %s %s\n' "\$1" "\${2:-?}" >> "$SPAWN_LOG_T2"
exit 0
SP
mv "$RS2" "$ROOT/recspawn.sh"; chmod +x "$ROOT/recspawn.sh"

reset_board << 'JSON'
[
  {"number":700,"state":"OPEN",
   "labels":[{"name":"type:agent"},{"name":"status:needs-triage"}],
   "body":"Charter: #1049","comments":[]}
]
JSON
dp2=$(mk_dead_pid)
t_sset "$CBHOME_T2" 700 kind "triage"
t_sset "$CBHOME_T2" 700 pid "$dp2"
t_sset "$CBHOME_T2" 700 red_reason "acceptance-block: FAIL stale assert on charter/1049"
mk_status "$CBHOME_T2" 700 done

run_tick "$CBHOME_T2" CB_RECOVERY_SPAWN="$ROOT/recspawn.sh"
sleep 0.3

has_label 700 "status:needs-recovery" \
  && ok "T2.1: leaf #700 routed to status:needs-recovery (escalated)" \
  || ko "T2.1: leaf #700 missing status:needs-recovery"
no_label 700 "status:blocked" \
  && ok "T2.2: leaf #700 NOT straight-to status:blocked" \
  || ko "T2.2: leaf #700 wrongly has status:blocked (escalation skipped)"
[ "$(t_sget "$CBHOME_T2" 700 kind)" = "recovery" ] \
  && ok "T2.3: run-state kind=recovery (cross-TICK state machine engaged)" \
  || ko "T2.3: kind != recovery (got '$(t_sget "$CBHOME_T2" 700 kind)')"
[ "$(t_sget "$CBHOME_T2" 700 recovery_lead_n)" = "1" ] \
  && ok "T2.4: recovery_lead_n incremented to 1 (bounded escalation)" \
  || ko "T2.4: recovery_lead_n != 1 (got '$(t_sget "$CBHOME_T2" 700 recovery_lead_n)')"
grep -q "^recovery-spawn 700 recovery-lead" "$SPAWN_LOG_T2" \
  && ok "T2.5: recovery-lead manager was spawned" \
  || ko "T2.5: recovery-lead manager NOT spawned"

# ══════════════════════════════════════════════════════════════════════════════
# T3: CURSOR STATE MACHINE — step0 RED advances cursor; GREEN honors terminal=merge
# ══════════════════════════════════════════════════════════════════════════════
echo "== T3a: step0 RED advances the cursor and dispatches step1's route =="
CBHOME_T3="$ROOT/cb_t3"; mk_cbhome "$CBHOME_T3"
# Two-step plan, terminal=merge, built by the REAL parser (format-faithful).
PLAN_2STEP="$(parse_block '## Recovery (machine)
[{"action":"update-assert","target":"acceptance-block","route":"executor-rework"},{"action":"flip","target":"role-spawn","route":"executor-rework"}]
terminal: merge')"

reset_board << 'JSON'
[
  {"number":710,"state":"OPEN",
   "labels":[{"name":"type:agent"},{"name":"status:needs-recovery"}],
   "body":"Charter: #1049","comments":[]}
]
JSON
dp3=$(mk_dead_pid)
t_sset "$CBHOME_T3" 710 kind "recovery"
t_sset "$CBHOME_T3" 710 pid "$dp3"
t_sset "$CBHOME_T3" 710 recovery_plan "$PLAN_2STEP"
t_sset "$CBHOME_T3" 710 recovery_cursor "0"
mk_status "$CBHOME_T3" 710 done
# CB_GIT_REMOTE unset -> _recovery_reverify returns RED:no-remote -> RED path (advance).
run_tick "$CBHOME_T3" CB_GIT_REMOTE=""

[ "$(t_sget "$CBHOME_T3" 710 recovery_cursor)" = "1" ] \
  && ok "T3a.1: step0 RED advanced recovery_cursor 0 -> 1" \
  || ko "T3a.1: recovery_cursor not advanced (got '$(t_sget "$CBHOME_T3" 710 recovery_cursor)')"
has_label 710 "status:needs-rework" \
  && ok "T3a.2: step1 route (executor-rework) dispatched -> status:needs-rework" \
  || ko "T3a.2: step1 route not dispatched (no status:needs-rework)"
no_label 710 "status:blocked" \
  && ok "T3a.3: no status:blocked during cursor advance" \
  || ko "T3a.3: status:blocked wrongly written during cursor advance"

echo "== T3b: GREEN step honors terminal=merge and clears recovery state =="
CBHOME_T3B="$ROOT/cb_t3b"; mk_cbhome "$CBHOME_T3B"
# Stub integrator: verify-merged GREEN (exit 0) so _recovery_reverify -> GREEN;
# try-merge infra (exit 2) so the integrator keeps the leaf in review (no real merge).
IG="$(mktemp)"
cat > "$IG" << 'IEOF'
#!/usr/bin/env bash
case "${1:-}" in verify-merged) exit 0 ;; try-merge) exit 2 ;; *) exit 0 ;; esac
IEOF
mv "$IG" "$ROOT/int_green.sh"; chmod +x "$ROOT/int_green.sh"
PLAN_1MERGE="$(parse_block '## Recovery (machine)
[{"action":"update-assert","target":"acceptance-block","route":"executor-rework"}]
terminal: merge')"

reset_board << 'JSON'
[
  {"number":720,"state":"OPEN",
   "labels":[{"name":"type:agent"},{"name":"status:needs-recovery"}],
   "body":"Charter: #1049","comments":[]}
]
JSON
# PR snapshot so _recovery_reverify finds an open PR to (stub-)verify.
cat > "$PR_JSON" << 'PRJ'
[{"number":9001,"headRefName":"leaf/720-1700000000","baseRefName":"charter/1049"}]
PRJ
dp3b=$(mk_dead_pid)
t_sset "$CBHOME_T3B" 720 kind "recovery"
t_sset "$CBHOME_T3B" 720 pid "$dp3b"
t_sset "$CBHOME_T3B" 720 recovery_plan "$PLAN_1MERGE"
t_sset "$CBHOME_T3B" 720 recovery_cursor "0"
mk_status "$CBHOME_T3B" 720 done
run_tick "$CBHOME_T3B" CB_GIT_REMOTE="dummy-remote" CB_INTEGRATOR="$ROOT/int_green.sh"

[ -z "$(t_sget "$CBHOME_T3B" 720 kind)" ] \
  && ok "T3b.1: GREEN+terminal=merge cleared kind (recovery state released)" \
  || ko "T3b.1: kind not cleared (got '$(t_sget "$CBHOME_T3B" 720 kind)')"
[ "$(t_sget "$CBHOME_T3B" 720 term)" = "1" ] \
  && ok "T3b.2: term=1 set (recovery run finalized)" \
  || ko "T3b.2: term != 1 (got '$(t_sget "$CBHOME_T3B" 720 term)')"
has_label 720 "status:review" \
  && ok "T3b.3: leaf handed to integrator via status:review (merge-bound)" \
  || ko "T3b.3: leaf not in status:review after GREEN merge directive"
no_label 720 "status:blocked" \
  && ok "T3b.4: GREEN/merge path never wrote status:blocked" \
  || ko "T3b.4: status:blocked wrongly written on GREEN/merge path"

# ══════════════════════════════════════════════════════════════════════════════
# T4: PLAN EXHAUSTION — cursor past plan length -> deferred + evidence, NO blocked
# ══════════════════════════════════════════════════════════════════════════════
echo "== T4: plan exhaustion -> status:deferred + evidence (NEVER blocked/human-halt) =="
CBHOME_T4="$ROOT/cb_t4"; mk_cbhome "$CBHOME_T4"
PLAN_1STEP="$(parse_block '## Recovery (machine)
[{"action":"update-assert","target":"acceptance-block","route":"executor-rework"}]
terminal: merge')"

reset_board << 'JSON'
[
  {"number":730,"state":"OPEN",
   "labels":[{"name":"type:agent"},{"name":"status:needs-recovery"}],
   "body":"Charter: #1049","comments":[]}
]
JSON
dp4=$(mk_dead_pid)
t_sset "$CBHOME_T4" 730 kind "recovery"
t_sset "$CBHOME_T4" 730 pid "$dp4"
t_sset "$CBHOME_T4" 730 recovery_plan "$PLAN_1STEP"
# cursor already at plan length (1): RED reverify advances to 2, dispatch -> exhaustion.
t_sset "$CBHOME_T4" 730 recovery_cursor "1"
mk_status "$CBHOME_T4" 730 done
run_tick "$CBHOME_T4" CB_GIT_REMOTE=""

has_label 730 "status:deferred" \
  && ok "T4.1: exhausted plan -> status:deferred" \
  || ko "T4.1: leaf not deferred on exhaustion"
no_label 730 "status:blocked" \
  && ok "T4.2: NO status:blocked on exhaustion (never human-halt)" \
  || ko "T4.2: status:blocked wrongly written on exhaustion"
_t4_evi=$(jq -r '[.[] | select(.number==730)][0].comments[]?.body' "$BOARD_STATE" | grep -c -i 'recovery' || true)
[ "${_t4_evi:-0}" -ge 1 ] \
  && ok "T4.3: evidence comment posted on deferral" \
  || ko "T4.3: no evidence comment on deferral"
_t4_hd=$(count_label_issues "type:human-decision")
[ "${_t4_hd:-0}" -eq 0 ] \
  && ok "T4.4: no type:human-decision issue created anywhere" \
  || ko "T4.4: unexpected type:human-decision issue(s) (count=${_t4_hd})"

# ══════════════════════════════════════════════════════════════════════════════
# T5: RED_REASON ABSENT — graceful fall-through, NO manager spawn (#1110)
# ══════════════════════════════════════════════════════════════════════════════
echo "== T5: RED_REASON absent -> graceful fall-through (no manager spawn) =="
CBHOME_T5="$ROOT/cb_t5"; mk_cbhome "$CBHOME_T5"
SPAWN_LOG_T5="$ROOT/recspawn_t5.log"; : > "$SPAWN_LOG_T5"
RS5="$(mktemp)"
cat > "$RS5" << SP
#!/usr/bin/env bash
printf 'recovery-spawn %s %s\n' "\$1" "\${2:-?}" >> "$SPAWN_LOG_T5"
exit 0
SP
mv "$RS5" "$ROOT/recspawn5.sh"; chmod +x "$ROOT/recspawn5.sh"

reset_board << 'JSON'
[
  {"number":740,"state":"OPEN",
   "labels":[{"name":"type:agent"},{"name":"status:needs-triage"}],
   "body":"Charter: #1049","comments":[]}
]
JSON
dp5=$(mk_dead_pid)
t_sset "$CBHOME_T5" 740 kind "triage"
t_sset "$CBHOME_T5" 740 pid "$dp5"
# NO red_reason set -> manager is blind (#1110) -> escalation declines, no spawn.
t_sset "$CBHOME_T5" 740 red_reason ""
mk_status "$CBHOME_T5" 740 done
run_tick "$CBHOME_T5" CB_RECOVERY_SPAWN="$ROOT/recspawn5.sh"
sleep 0.3

[ ! -s "$SPAWN_LOG_T5" ] \
  && ok "T5.1: no recovery-lead manager spawned when RED_REASON absent" \
  || ko "T5.1: manager wrongly spawned without RED_REASON ($(cat "$SPAWN_LOG_T5"))"
no_label 740 "status:needs-recovery" \
  && ok "T5.2: leaf NOT escalated to status:needs-recovery without RED_REASON" \
  || ko "T5.2: leaf wrongly escalated without RED_REASON"
[ "$(t_sget "$CBHOME_T5" 740 kind)" != "recovery" ] \
  && ok "T5.3: kind never flipped to recovery (graceful fall-through)" \
  || ko "T5.3: kind became recovery despite absent RED_REASON"

# ══════════════════════════════════════════════════════════════════════════════
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
