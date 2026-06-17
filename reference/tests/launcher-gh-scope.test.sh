#!/usr/bin/env bash
# launcher-gh-scope.test.sh — charter-scope integration tests for the CANONICAL launcher.
#
# Tests RED-a, RED-b, RED-c (issue #89).
# Class i: integration with stubs (stateful board-JSON + gh stub + CB_SPAWN stub).
# Precedents: reference/tests/launcher-integration.test.sh (gh-stub + stateful board-JSON).
#
# RED-a: CREWBOSS_CHARTER=5 → canonical launcher spawns ONLY leaves of charter #5;
#        charter-6 leaves and cruft remain untouched.
# RED-b: no CREWBOSS_CHARTER → leaves of BOTH charters are spawned (regression lock).
# RED-c: CREWBOSS_CHARTER=5 with charter #6 as needs-plan (plannable) → charter #6 is
#        NOT decomposed/planned; scoped run ignores out-of-scope plannable charters.
#        Control: same board without CREWBOSS_CHARTER → charter #6 IS spawned for planning.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
LAUNCHER="$HERE/../runtime/crewboss-launcher-gh.sh"
BOARD_GH_SRC="$REPO_ROOT/proto/r6/board-gh.sh"
LAUNCHABLE_SRC="$REPO_ROOT/proto/r6/launchable.sh"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"
CBHOME="$ROOT/cbhome"
SPAWN_LOG="$ROOT/spawn.log"

export BOARD_STATE="$ROOT/board.json"
export GH_LOG="$ROOT/gh.log"

mkdir -p "$BIN" "$CBHOME"

# Install board-gh.sh and launchable.sh (canonical proto/r6 versions) into CBHOME
cp "$BOARD_GH_SRC"  "$CBHOME/board-gh.sh"
cp "$LAUNCHABLE_SRC" "$CBHOME/launchable.sh"
chmod +x "$CBHOME/board-gh.sh" "$CBHOME/launchable.sh"

pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

# ── gh stub: stateful board JSON mutations ─────────────────────────────────
cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
obj="$1"; verb="$2"; shift 2
# strip -R/--repo and -L flags (with their values)
_args=()
while [ $# -gt 0 ]; do
  case "$1" in
    -R|--repo) shift ;;
    -L)        shift ;;
    *) _args+=("$1") ;;
  esac
  shift
done
set -- "${_args[@]+"${_args[@]}"}"

case "$obj $verb" in
  "issue list")
    state="all"
    while [ $# -gt 0 ]; do
      case "$1" in --state) state="$2"; shift ;; esac; shift
    done
    if [ "$state" = "open" ]; then
      jq '[.[] | select(.state == "OPEN")]' "$BOARD_STATE"
    else
      cat "$BOARD_STATE"
    fi ;;
  "issue view")
    n="$1"
    jq --argjson n "$n" '[.[] | select(.number==$n)][0] // {}' "$BOARD_STATE" ;;
  "issue edit")
    n="$1"; shift; add=""; rem=""
    while [ $# -gt 0 ]; do case "$1" in
      --add-label)    add="$2"; shift ;;
      --remove-label) rem="$2"; shift ;;
    esac; shift; done
    jq --argjson n "$n" --arg add "$add" --arg rem "$rem" '
      map(if .number==$n then
        .labels = [(.labels // [])[]]
          | (if $rem != "" then .labels = [(.labels[]) | select(.name != $rem)] else . end)
          | (if $add != "" and ([.labels[].name] | index($add)) == null
             then .labels += [{name: $add}] else . end)
      else . end)' \
      "$BOARD_STATE" > "$BOARD_STATE.t" && mv "$BOARD_STATE.t" "$BOARD_STATE"
    echo "edit #$n +[$add] -[$rem]" >> "$GH_LOG" ;;
  "label create") true ;;
  *) echo "stub gh UNHANDLED: $obj $verb $*" >> "$GH_LOG" ;;
esac
exit 0
GH
chmod +x "$BIN/gh"

# ── spawn stub: records calls, writes status.json (phase=done) for run-loop routing ──
SPAWN_LOG_PATH="$SPAWN_LOG"
CBHOME_PATH="$CBHOME"
cat > "$ROOT/stub-spawn.sh" << EOF
#!/usr/bin/env bash
id="\$1"; role="\$2"
echo "spawned \$id \$role" >> "${SPAWN_LOG_PATH}"
mkdir -p "${CBHOME_PATH}/run/work/\$id"
printf '{"phase":"done"}' > "${CBHOME_PATH}/run/work/\$id/status.json"
exit 0
EOF
chmod +x "$ROOT/stub-spawn.sh"

# ── helpers ─────────────────────────────────────────────────────────────────
reset_state(){
  rm -rf "$CBHOME/run"
  rm -f "$SPAWN_LOG" "$GH_LOG"
  touch "$SPAWN_LOG" "$GH_LOG"
  cat > "$BOARD_STATE"   # board JSON on stdin
}

has_label(){
  [ "$(jq -r --argjson n "$1" \
    'map(select(.number==$n))[0].labels[]?.name' "$BOARD_STATE" \
    | grep -c "^$2$")" -ge 1 ]
}

spawned(){
  # spawned <id>: true if any spawn call for issue $1 appears in SPAWN_LOG
  grep -q "^spawned $1 " "$SPAWN_LOG" 2>/dev/null
}

run_launcher(){
  # run_launcher <subcommand> [VAR=value ...]
  local sub="${1:-once}"; shift || true
  (
    export CB_REPO="test/repo"
    export CB_HOME="$CBHOME"
    export CB_SPAWN="$ROOT/stub-spawn.sh"
    export CB_MAX_PARALLEL=10
    export CB_RETRY_CAP=2
    export CB_POLL=0
    export CB_IDLE_CONFIRM=1
    export CB_MAX_TICKS=20
    # Prevent integrator stale-guard from moving review leaves to blocked during
    # short test runs (default threshold=10 ticks fires before CB_MAX_TICKS=20).
    export CB_REVIEW_STALE_TICKS=999
    # Isolate from caller's environment: unset vars the launcher reads from env
    # so that unscoped tests are not accidentally scoped by the parent process,
    # and non-CB_SPAWN spawn scripts (plan, analysis, etc.) default to CB_SPAWN.
    unset CREWBOSS_CHARTER CB_PLAN_SPAWN CB_ANALYSIS_SPAWN CB_APPROVAL_SPAWN CB_CONFLICT_SPAWN CB_REWORK_SPAWN
    # Apply extra env overrides (e.g. CREWBOSS_CHARTER=5)
    for kv in "$@"; do export "${kv?}"; done
    PATH="$BIN:$PATH" bash "$LAUNCHER" "$sub"
  ) >/dev/null 2>&1
}

# ── Board fixtures ───────────────────────────────────────────────────────────
# RED-a / RED-b: charters #5 and #6 (both approved), two leaves each, plus cruft
SCOPE_BOARD='[
  {"number":5,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],"body":"charter 5"},
  {"number":6,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],"body":"charter 6"},
  {"number":10,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"leaf A\nCharter: #5\n## Acceptance (machine)\n- check: true"},
  {"number":11,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"leaf B\nCharter: #5\n## Acceptance (machine)\n- check: true"},
  {"number":20,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"leaf C\nCharter: #6\n## Acceptance (machine)\n- check: true"},
  {"number":21,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"leaf D\nCharter: #6\n## Acceptance (machine)\n- check: true"},
  {"number":99,"state":"OPEN","labels":[],"body":"cruft — no charter ref"}
]'

# RED-c: charter #5 approved with leaves, charter #6 needs-plan (plannable)
PLANNABLE_BOARD='[
  {"number":5,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],"body":"charter 5"},
  {"number":6,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:needs-plan"}],"body":"charter 6"},
  {"number":10,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"leaf A\nCharter: #5\n## Acceptance (machine)\n- check: true"},
  {"number":11,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"leaf B\nCharter: #5\n## Acceptance (machine)\n- check: true"}
]'

# ── RED-a: CREWBOSS_CHARTER=5 → only charter-5 leaves touched ───────────────
echo "== RED-a: scoped run (CREWBOSS_CHARTER=5) touches only charter-5 leaves =="
reset_state <<< "$SCOPE_BOARD"
run_launcher once CREWBOSS_CHARTER=5

# Charter-5 leaves must have been claimed/routed (review = successful launch)
has_label 10 "status:review" \
  && ok "RED-a: #10 (charter 5) spawned by scoped launcher" \
  || ko "RED-a: #10 (charter 5) NOT spawned — scope filter missing"

has_label 11 "status:review" \
  && ok "RED-a: #11 (charter 5) spawned by scoped launcher" \
  || ko "RED-a: #11 (charter 5) NOT spawned — scope filter missing"

# Charter-6 leaves must NOT have been touched (no in-progress or review)
has_label 20 "status:in-progress" || has_label 20 "status:review" \
  && ko "RED-a: #20 (charter 6) touched — scope violation!" \
  || ok "RED-a: #20 (charter 6) untouched — scope respected"

has_label 21 "status:in-progress" || has_label 21 "status:review" \
  && ko "RED-a: #21 (charter 6) touched — scope violation!" \
  || ok "RED-a: #21 (charter 6) untouched — scope respected"

# Cruft issue must not have been touched
has_label 99 "status:in-progress" || has_label 99 "status:review" \
  && ko "RED-a: #99 (cruft) touched — scope violation!" \
  || ok "RED-a: #99 (cruft) untouched — scope respected"

# ── RED-b: no CREWBOSS_CHARTER → both charters' leaves touched (regression lock) ──
echo "== RED-b: unscoped run touches leaves of both charters =="
reset_state <<< "$SCOPE_BOARD"
run_launcher once   # no CREWBOSS_CHARTER

has_label 10 "status:review" \
  && ok "RED-b: #10 (charter 5) spawned (unscoped)" \
  || ko "RED-b: #10 (charter 5) NOT spawned (unexpected — regression!)"

has_label 20 "status:review" \
  && ok "RED-b: #20 (charter 6) spawned (unscoped — both charters expected)" \
  || ko "RED-b: #20 (charter 6) NOT spawned — regression: unscoped should touch all charters"

# ── RED-c: CREWBOSS_CHARTER=5 → charter-6 (needs-plan) NOT spawned for planning ──
echo "== RED-c: scoped run does NOT plan charter-6 (needs-plan, out of scope) =="
reset_state <<< "$PLANNABLE_BOARD"
run_launcher run CREWBOSS_CHARTER=5

# Charter-5 leaves should have been spawned
has_label 10 "status:review" \
  && ok "RED-c: #10 (charter-5 leaf) spawned by scoped run" \
  || ko "RED-c: #10 (charter-5 leaf) NOT spawned — unexpected"

# Charter-6 (needs-plan) must NOT have been spawned for planning
spawned 6 \
  && ko "RED-c: charter #6 was spawned for planning — plannable scope violation!" \
  || ok "RED-c: charter #6 NOT spawned — plannable scope respected"

# ── RED-c control: no scope → charter-6 IS spawned for planning ──────────────
echo "== RED-c control: unscoped run DOES spawn charter-6 for planning =="
reset_state <<< "$PLANNABLE_BOARD"
run_launcher run   # no CREWBOSS_CHARTER

spawned 6 \
  && ok "RED-c control: charter #6 spawned for planning (unscoped — expected)" \
  || ko "RED-c control: charter #6 NOT spawned even without scope (regression!)"

echo
echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
