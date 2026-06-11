#!/usr/bin/env bash
# integrator.test.sh — integration tests for crewboss-integrator.sh (issue #70).
# Class b: stub gh/claude, throwaway git repo, stateful board-JSON.
#
# Scenarios:
#  (a) After merge of leaf #10 into charter/5, integrator closes #10 via gh CLI;
#      #11 (Depends-on: #10) becomes launchable on the next cycle.
#      RED: nobody closes the leaf today → dependents hang forever.
#  (b) Launcher with CREWBOSS_CHARTER=5 on a board with charters #5 and #6 plus
#      a cruft issue touches ONLY leaves of charter #5.
#      RED: no scoping → launcher takes the whole board.
#  (c) A harness stub that exits 1 (red) causes gate-charter to block the merge.
#      RED: gate did not exist; now it does and must block on a red harness.
#
# Requires: jq, git, bash.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
INTEGRATOR="${INTEGRATOR_OVERRIDE:-$HERE/../runtime/crewboss-integrator.sh}"
LAUNCHER="${LAUNCHER_OVERRIDE:-$HERE/../launcher/crewboss-launcher.sh}"
LAUNCHABLE="$HERE/../launcher/launchable.sh"
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"
SANDBOX="$ROOT/sb"
export BOARD_STATE="$SANDBOX/board.json"
export GH_LOG="$SANDBOX/gh.log"
export PRDIR="$SANDBOX/prs"
export SANDBOX
mkdir -p "$BIN"

pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

# ── gh stub: stateful board mutations ────────────────────────────────────────
cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
obj="$1"; verb="$2"; shift 2
# strip -R / --repo flags (not needed for the board file)
_args=(); while [ $# -gt 0 ]; do
  case "$1" in -R|--repo) shift ;; *) _args+=("$1") ;; esac; shift
done; set -- "${_args[@]+"${_args[@]}"}"

case "$obj $verb" in
  "issue close")
    n="$1"
    jq --argjson n "$n" 'map(if .number==$n then .state="CLOSED" else . end)' \
      "$BOARD_STATE" > "$BOARD_STATE.t" && mv "$BOARD_STATE.t" "$BOARD_STATE"
    echo "close #$n" >> "$GH_LOG" ;;
  "issue comment")
    n="$1"; shift; body=""
    while [ $# -gt 0 ]; do [ "$1" = --body ] && body="$2"; shift; done
    jq --argjson n "$n" --arg b "$body" \
      'map(if .number==$n then .comments=((.comments//[])+[{body:$b}]) else . end)' \
      "$BOARD_STATE" > "$BOARD_STATE.t" && mv "$BOARD_STATE.t" "$BOARD_STATE"
    echo "comment #$n: $body" >> "$GH_LOG" ;;
  "issue edit")
    n="$1"; shift; add=""; rem=""
    while [ $# -gt 0 ]; do case "$1" in
      --add-label) add="$2"; shift ;; --remove-label) rem="$2"; shift ;;
    esac; shift; done
    jq --argjson n "$n" --arg add "$add" --arg rem "$rem" '
      map(if .number==$n then
        .labels = [(.labels//[])[]]
          | (if $rem != "" then .labels=[(.labels[])|select(.name!=$rem)] else . end)
          | (if $add != "" and ([.labels[].name]|index($add))==null
             then .labels+=([{name:$add}]) else . end)
      else . end)' \
      "$BOARD_STATE" > "$BOARD_STATE.t" && mv "$BOARD_STATE.t" "$BOARD_STATE"
    echo "edit #$n +[$add] -[$rem]" >> "$GH_LOG" ;;
  "issue view")
    n="$1"; shift; jqf=""
    while [ $# -gt 0 ]; do case "$1" in --jq|-q) jqf="$2"; shift ;; esac; shift; done
    o="$(jq --argjson n "$n" 'map(select(.number==$n))[0]//{}'  "$BOARD_STATE")"
    if [ -n "$jqf" ]; then printf '%s' "$o" | jq -r "$jqf"; else printf '%s\n' "$o"; fi ;;
  "pr list")
    head=""; while [ $# -gt 0 ]; do [ "$1" = --head ] && head="$2"; shift; done
    n="${head#task/}"
    [ -f "$PRDIR/$n" ] && echo 1 || echo 0 ;;
  *) echo "stub gh UNHANDLED: $obj $verb $*" >> "$GH_LOG" ;;
esac
exit 0
GH
chmod +x "$BIN/gh"

# ── claude stub ───────────────────────────────────────────────────────────────
cat > "$BIN/claude" <<'CL'
#!/usr/bin/env bash
n="$(git branch --show-current 2>/dev/null | sed 's#.*task/##')"
[ -n "$n" ] || n="unknown"
echo "work for #$n" > "work-$n.txt"
git add -A >/dev/null 2>&1; git commit -qm "executor: closes #$n" >/dev/null 2>&1
touch "$PRDIR/$n"
exit 0
CL
chmod +x "$BIN/claude"

reset(){
  rm -rf "$SANDBOX"; mkdir -p "$SANDBOX" "$PRDIR"
  git init -q "$ROOT/repo" 2>/dev/null || true
  ( cd "$ROOT/repo" && git config user.email t@t && git config user.name T
    echo base > README.md; git add -A; git commit -qm init -q; git branch -M master
  ) >/dev/null 2>&1 || true
  cat > "$BOARD_STATE"
}
has_label(){ [ "$(jq -r --argjson n "$1" 'map(select(.number==$n))[0].labels[]?.name' \
  "$BOARD_STATE" | grep -c "^$2$")" -ge 1 ]; }
issue_state(){ jq -r --argjson n "$1" 'map(select(.number==$n))[0].state' "$BOARD_STATE"; }
launch(){ ( cd "$ROOT/repo" && PATH="$BIN:$PATH" \
  CREWBOSS_WORKTREE_BASE="$SANDBOX/wt" CREWBOSS_KILL_SWITCH="$SANDBOX/kill" \
  CREWBOSS_HEARTBEAT="$SANDBOX/beat" \
  bash "$LAUNCHER" --once --board-file "$BOARD_STATE" "$@" ) >/dev/null 2>&1; }

# ── scenario (a): integrator closes leaf; dependent becomes launchable ────────
echo "== (a): close-leaf unblocks dependent =="
TWO_LEAF_BOARD='[
  {"number":5,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],"body":"charter","comments":[]},
  {"number":10,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"task A\nCharter: #5","comments":[]},
  {"number":11,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"task B\nCharter: #5\nDepends-on: #10","comments":[]}
]'
reset <<< "$TWO_LEAF_BOARD"

# Before close: #11 NOT launchable (dep #10 still OPEN)
launchable_before="$(printf '%s' "$(cat "$BOARD_STATE")" | bash "$LAUNCHABLE")"
[ "$(printf '%s' "$launchable_before" | grep -c '^11$')" -eq 0 ] \
  && ok "(a) pre: #11 not launchable (dep #10 open)" \
  || ko "(a) pre: #11 should not be launchable yet"

# Run integrator: close leaf #10 with a fake merge-SHA
PATH="$BIN:$PATH" bash "$INTEGRATOR" close-leaf 10 --merge-sha "abc1234"

# #10 should now be CLOSED in board
[ "$(issue_state 10)" = "CLOSED" ] \
  && ok "(a) #10 CLOSED after integrator close-leaf" \
  || ko "(a) #10 still OPEN after integrator close-leaf"

# Comment with merge-SHA should be recorded
jq -r --argjson n 10 'map(select(.number==$n))[0].comments[].body' "$BOARD_STATE" \
  | grep -q "abc1234" \
  && ok "(a) merge-SHA in comment on #10" \
  || ko "(a) merge-SHA missing from comment"

# After close: #11 IS launchable
launchable_after="$(printf '%s' "$(cat "$BOARD_STATE")" | bash "$LAUNCHABLE")"
[ "$(printf '%s' "$launchable_after" | grep -c '^11$')" -ge 1 ] \
  && ok "(a) post: #11 launchable after #10 closed" \
  || ko "(a) post: #11 NOT launchable even after #10 closed"

# ── scenario (b): charter-scoped launcher ignores other charters and cruft ──
echo "== (b): CREWBOSS_CHARTER=5 scopes launcher to charter #5 only =="
MULTI_BOARD='[
  {"number":5,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],"body":"charter 5","comments":[]},
  {"number":6,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],"body":"charter 6","comments":[]},
  {"number":10,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"leaf of 5\nCharter: #5","comments":[]},
  {"number":11,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"leaf of 5b\nCharter: #5","comments":[]},
  {"number":20,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"leaf of 6\nCharter: #6","comments":[]},
  {"number":21,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"leaf of 6b\nCharter: #6","comments":[]},
  {"number":99,"state":"OPEN","labels":[],"body":"cruft — no Charter","comments":[]}
]'
reset <<< "$MULTI_BOARD"

# Verify all launchable without scope: expect 10,11,20,21
all_launchable="$(printf '%s' "$(cat "$BOARD_STATE")" | bash "$LAUNCHABLE" | tr '\n' ' ' | sed 's/ *$//')"
echo "  (b) all launchable (no scope): [$all_launchable]"

# Run launcher SCOPED to charter 5
CREWBOSS_CHARTER=5 launch

# Charter-5 leaves should be in-progress or review (touched)
has_label 10 "status:in-progress" || has_label 10 "status:review" \
  && ok "(b) #10 (charter 5) was touched by scoped launcher" \
  || ko "(b) #10 (charter 5) NOT touched by scoped launcher"

# Charter-6 leaves must NOT have been touched (still no in-progress/review label)
has_label 20 "status:in-progress" || has_label 20 "status:review" \
  && ko "(b) #20 (charter 6) was touched — scope violation!" \
  || ok "(b) #20 (charter 6) untouched — scope respected"

has_label 21 "status:in-progress" || has_label 21 "status:review" \
  && ko "(b) #21 (charter 6) was touched — scope violation!" \
  || ok "(b) #21 (charter 6) untouched — scope respected"

# Cruft issue #99 must not have been touched
has_label 99 "status:in-progress" || has_label 99 "status:review" \
  && ko "(b) #99 (cruft) was touched — scope violation!" \
  || ok "(b) #99 (cruft) untouched — scope respected"

# ── scenario (c): red harness blocks charter→main gate ──────────────────────
echo "== (c): red harness blocks gate-charter =="
TMPDIR_C="$(mktemp -d)"; trap 'rm -rf "$TMPDIR_C"' EXIT

# Stub harness: always exits 1 (RED)
RED_HARNESS="$TMPDIR_C/harness.sh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$RED_HARNESS"
chmod +x "$RED_HARNESS"

# Gate-charter with a red harness must exit non-zero
if PATH="$BIN:$PATH" bash "$INTEGRATOR" gate-charter 5 \
    --harness "$RED_HARNESS" \
    --repo-dir "$TMPDIR_C" >/dev/null 2>&1; then
  ko "(c) gate-charter returned 0 on red harness (should have blocked)"
else
  ok "(c) gate-charter blocked (non-zero exit) on red harness"
fi

# Stub harness: always exits 0 (GREEN) — gate should pass (no markers)
GREEN_HARNESS="$TMPDIR_C/harness-ok.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$GREEN_HARNESS"
chmod +x "$GREEN_HARNESS"

if PATH="$BIN:$PATH" bash "$INTEGRATOR" gate-charter 5 \
    --harness "$GREEN_HARNESS" \
    --repo-dir "$TMPDIR_C" >/dev/null 2>&1; then
  ok "(c) gate-charter passed (exit 0) on green harness + clean dir"
else
  ko "(c) gate-charter failed on green harness + clean dir (unexpected)"
fi

echo
echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
