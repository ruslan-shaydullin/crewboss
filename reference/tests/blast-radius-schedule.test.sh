#!/usr/bin/env bash
# blast-radius-schedule.test.sh — blast-radius scheduler gate (issue #262).
# Class integration-stub: gh file-board stub + REAL launcher (cmd_run, unscoped) +
# spawn stub that logs dispatches without git ops.
#
# Board: charter A (blast-radius:high, approved) with leaf A1 (#11);
#        charter B (blast-radius:low,  approved) with leaf B1 (#21);
#        charter C (blast-radius:low,  needs-plan, no leaves yet).
#
# RED-1: while A is OPEN → only A1 dispatched; B1/C NOT touched.
# RED-2: when A is CLOSED → B1 dispatched, C planned.
# GREEN-guard-1: board with no high charter → A1 and B1 both dispatched (parallel unchanged).
# GREEN-guard-2: scoped (CREWBOSS_CHARTER=20 = B) → gate no-op; B1 dispatched despite open high-A.
#
# Self-classification: integration-stub (drives real launcher loop) → EXCLUDED from per-leaf
# verify-merged suite. See reference/runtime/per-leaf-manifest. [#262]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER="${LAUNCHER_OVERRIDE:-$HERE/../runtime/crewboss-launcher-gh.sh}"
BOARD_GH_SRC="$HERE/../../proto/r6/board-gh.sh"
LAUNCHABLE_SRC="$HERE/../../proto/r6/launchable.sh"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

# ── shared exports ─────────────────────────────────────────────────────────────
export BOARD_STATE="$ROOT/board.json"
export GH_LOG="$ROOT/gh.log"

BIN="$ROOT/bin"; mkdir -p "$BIN"
CBHOME="$ROOT/cbhome"
SPAWN_LOG="$ROOT/spawn.log"
PLAN_LOG="$ROOT/plan.log"

mkdir -p "$CBHOME"
cp "$BOARD_GH_SRC"  "$CBHOME/board-gh.sh"
cp "$LAUNCHABLE_SRC" "$CBHOME/launchable.sh"
chmod +x "$CBHOME/board-gh.sh" "$CBHOME/launchable.sh"

# ── gh stub: stateful file-board ───────────────────────────────────────────────
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
    state_filter="all"
    while [ $# -gt 0 ]; do
      case "$1" in --state) state_filter="$2"; shift ;; --json) ;; esac; shift
    done
    if [ "$state_filter" = "open" ]; then
      jq '[.[] | select(.state=="OPEN")]' "$BOARD_STATE"
    else
      cat "$BOARD_STATE"
    fi ;;

  "issue view")
    n="$1"; shift
    jq --argjson n "$n" 'map(select(.number==$n))[0] // {}' "$BOARD_STATE" ;;

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
    echo "comment #$n: $body" >> "$GH_LOG" ;;

  "issue close")
    n="$1"
    jq --argjson n "$n" 'map(if .number==$n then .state="CLOSED" else . end)' \
      "$BOARD_STATE" > "$BOARD_STATE.t" && mv "$BOARD_STATE.t" "$BOARD_STATE"
    echo "close #$n" >> "$GH_LOG" ;;

  "pr list") printf '[]\n' ;;
  "pr view") printf '{"state":"OPEN","number":0}\n' ;;
  "label create") ;;

  *) echo "gh-stub UNHANDLED: $obj $verb $*" >> "$GH_LOG" ;;
esac
exit 0
GHEOF
chmod +x "$BIN/gh"

# ── spawn stub: logs "dispatch <id>" + writes status.json done ─────────────────
# (routes leaf to review on finish; no git ops needed — we only check dispatch log)
SPAWN_LOG_REF="$SPAWN_LOG"
CBHOME_REF="$CBHOME"
cat > "$ROOT/stub-spawn.sh" <<EOF
#!/usr/bin/env bash
id="\$1"
echo "dispatch \$id" >> "${SPAWN_LOG_REF}"
mkdir -p "${CBHOME_REF}/run/work/\$id"
printf '{"phase":"done"}' > "${CBHOME_REF}/run/work/\$id/status.json"
exit 0
EOF
chmod +x "$ROOT/stub-spawn.sh"

# ── plan-spawn stub: logs "plan <id>" + transitions charter to plan-review ─────
# Real tech-lead would add status:plan-review; we mutate the file-board directly
# via the gh stub so the launcher's kind=charter post-processing sees the new state.
PLAN_LOG_REF="$PLAN_LOG"
BIN_REF="$BIN"
cat > "$ROOT/stub-plan.sh" <<EOF
#!/usr/bin/env bash
id="\$1"
echo "plan \$id" >> "${PLAN_LOG_REF}"
# Transition charter to plan-review via gh stub (same labels as real tech-lead)
PATH="${BIN_REF}:\$PATH" gh issue edit "\$id" -R "test/repo" \
  --remove-label "status:needs-plan" --add-label "status:plan-review"
exit 0
EOF
chmod +x "$ROOT/stub-plan.sh"

# ── helpers ────────────────────────────────────────────────────────────────────
reset_state(){
  rm -rf "$CBHOME/run"
  rm -f "$SPAWN_LOG" "$GH_LOG" "$PLAN_LOG"
  touch "$SPAWN_LOG" "$GH_LOG" "$PLAN_LOG"
  cat > "$BOARD_STATE"   # board JSON on stdin
}

dispatched(){ grep -q "^dispatch $1$" "$SPAWN_LOG" 2>/dev/null; }
planned(){    grep -q "^plan $1$"     "$PLAN_LOG"  2>/dev/null; }

# ── loop runner: real launcher cmd_run, unscoped by default ───────────────────
# CREWBOSS_CHARTER= explicitly neutralises any inherited scope (leaf/charter env). [#238]
run_loop(){
  local logfile="${1:-/dev/null}"; shift || true
  PATH="$BIN:$PATH" \
    CB_REPO="test/repo" \
    CB_HOME="$CBHOME" \
    CB_SPAWN="$ROOT/stub-spawn.sh" \
    CB_PLAN_SPAWN="$ROOT/stub-plan.sh" \
    CB_POLL=0 \
    CB_MAX_TICKS=15 \
    CB_IDLE_CONFIRM=2 \
    CB_MAX_PARALLEL=4 \
    CB_RETRY_CAP=1 \
    CREWBOSS_CHARTER= \
    env "$@" \
    bash "$LAUNCHER" run >"$logfile" 2>&1 || true
}

# ── Board fixtures ─────────────────────────────────────────────────────────────
# Charter A (#10): blast-radius:high, approved  → leaf A1 (#11)
# Charter B (#20): blast-radius:low,  approved  → leaf B1 (#21)
# Charter C (#30): blast-radius:low,  needs-plan (no leaves yet)
HIGH_BOARD='[
  {"number":10,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"},{"name":"blast-radius:high"}],"body":"charter A"},
  {"number":11,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"leaf A1\nCharter: #10\n## Acceptance (machine)\n- check: true"},
  {"number":20,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"},{"name":"blast-radius:low"}],"body":"charter B"},
  {"number":21,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"leaf B1\nCharter: #20\n## Acceptance (machine)\n- check: true"},
  {"number":30,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:needs-plan"},{"name":"blast-radius:low"}],"body":"charter C"}
]'

# Same but charter A is CLOSED (blast-radius:high charter finished)
A_CLOSED_BOARD='[
  {"number":10,"state":"CLOSED","labels":[{"name":"type:charter"},{"name":"status:approved"},{"name":"blast-radius:high"}],"body":"charter A"},
  {"number":11,"state":"CLOSED","labels":[{"name":"type:agent"}],"body":"leaf A1\nCharter: #10\n## Acceptance (machine)\n- check: true"},
  {"number":20,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"},{"name":"blast-radius:low"}],"body":"charter B"},
  {"number":21,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"leaf B1\nCharter: #20\n## Acceptance (machine)\n- check: true"},
  {"number":30,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:needs-plan"},{"name":"blast-radius:low"}],"body":"charter C"}
]'

# No high charter: no blast-radius:high label on any charter
NO_HIGH_BOARD='[
  {"number":10,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"},{"name":"blast-radius:low"}],"body":"charter A"},
  {"number":11,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"leaf A1\nCharter: #10\n## Acceptance (machine)\n- check: true"},
  {"number":20,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"},{"name":"blast-radius:low"}],"body":"charter B"},
  {"number":21,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"leaf B1\nCharter: #20\n## Acceptance (machine)\n- check: true"}
]'

# =============================================================================
# RED-1: unscoped, A (blast-radius:high) OPEN → only A1 dispatched; B1/C held
# =============================================================================
echo "== RED-1: high-blast-radius charter serializes — only its leaf dispatched =="
LOGFILE_1="$ROOT/loop1.log"
reset_state <<< "$HIGH_BOARD"

run_loop "$LOGFILE_1"

dispatched 11 \
  && ok "RED-1a: leaf A1 (#11) dispatched (belongs to high charter)" \
  || ko "RED-1a: leaf A1 (#11) NOT dispatched — blast-radius gate broke A's own work"

dispatched 21 \
  && ko "RED-1b: leaf B1 (#21) dispatched while high charter A is open — serialization missing!" \
  || ok "RED-1b: leaf B1 (#21) held — other charter blocked while high charter open"

planned 30 \
  && ko "RED-1c: charter C (#30) was planned while high charter A is open — serialization missing!" \
  || ok "RED-1c: charter C (#30) held — plannable blocked while high charter open"

grep -q "blast-radius: serializing on #10" "$LOGFILE_1" \
  && ok "RED-1d: launcher logged blast-radius serialization on #10" \
  || ko "RED-1d: no blast-radius serialization log found"

# =============================================================================
# RED-2: A is CLOSED → B1 dispatched, C planned (normal parallel resumes)
# =============================================================================
echo "== RED-2: high charter closed → other charters resume dispatch =="
LOGFILE_2="$ROOT/loop2.log"
reset_state <<< "$A_CLOSED_BOARD"

run_loop "$LOGFILE_2"

dispatched 21 \
  && ok "RED-2a: leaf B1 (#21) dispatched after high charter A closed" \
  || ko "RED-2a: leaf B1 (#21) NOT dispatched — serialization not lifted after high charter closed"

planned 30 \
  && ok "RED-2b: charter C (#30) planned after high charter A closed" \
  || ko "RED-2b: charter C (#30) NOT planned — serialization not lifted after high charter closed"

grep -q "blast-radius: serializing" "$LOGFILE_2" \
  && ko "RED-2c: blast-radius serialization logged even though no high charter is open" \
  || ok "RED-2c: no blast-radius serialization log (high charter is closed — correct)"

# =============================================================================
# GREEN-guard-1: no high charter → A1 and B1 dispatched in parallel (unchanged behaviour)
# =============================================================================
echo "== GREEN-guard-1: no high charter → parallel dispatch unchanged =="
LOGFILE_G1="$ROOT/loopg1.log"
reset_state <<< "$NO_HIGH_BOARD"

run_loop "$LOGFILE_G1"

dispatched 11 \
  && ok "GREEN-guard-1a: A1 (#11) dispatched (no high charter — parallel normal)" \
  || ko "GREEN-guard-1a: A1 (#11) NOT dispatched — regression: blast-radius gate broke parallel"

dispatched 21 \
  && ok "GREEN-guard-1b: B1 (#21) dispatched (no high charter — parallel normal)" \
  || ko "GREEN-guard-1b: B1 (#21) NOT dispatched — regression: blast-radius gate broke parallel"

grep -q "blast-radius: serializing" "$LOGFILE_G1" \
  && ko "GREEN-guard-1c: blast-radius serialization logged with no high charter (false positive)" \
  || ok "GREEN-guard-1c: no blast-radius log (no high charter — correct)"

# =============================================================================
# GREEN-guard-2: scoped (CREWBOSS_CHARTER=20 = B) → gate is no-op; B1 dispatched
# =============================================================================
echo "== GREEN-guard-2: scoped mode → blast-radius gate no-op; B1 dispatched =="
LOGFILE_G2="$ROOT/loopg2.log"
reset_state <<< "$HIGH_BOARD"

run_loop "$LOGFILE_G2" "CREWBOSS_CHARTER=20"

dispatched 21 \
  && ok "GREEN-guard-2a: B1 (#21) dispatched in scoped mode (gate no-op)" \
  || ko "GREEN-guard-2a: B1 (#21) NOT dispatched — scoped mode should bypass blast-radius gate"

# A1 should NOT be dispatched (out-of-scope: launchable scoped to charter 20, not 10)
dispatched 11 \
  && ko "GREEN-guard-2b: A1 (#11) dispatched in scoped (CREWBOSS_CHARTER=20) run — scope violation" \
  || ok "GREEN-guard-2b: A1 (#11) not dispatched (scoped to charter 20, not 10)"

# =============================================================================
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
