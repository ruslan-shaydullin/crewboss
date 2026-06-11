#!/usr/bin/env bash
# Launcher INTEGRATION test — exercises crewboss-launcher.sh against a REAL throwaway git repo
# with `claude` and `gh` stubbed (no network, no billing, no real agents). Validates the parts
# the dry-run can't: real `git worktree` lifecycle, the claim -> launch -> handle_result -> label
# cycle, retry-cap routing, and — critically — the Batch-D data-loss fix (a transient `gh pr list`
# failure must NOT destroy an executor's committed work, because launch_one reuses the branch
# instead of force-resetting it with -B). Requires: jq, git, bash.
#
# Still NOT covered here (needs human hands / real infra): real `claude --agent executor` writing
# real code, and a live GitHub branch-protection merge. Those are the irreducibly-live remainder.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER="${LAUNCHER_OVERRIDE:-$HERE/../launcher/crewboss-launcher.sh}"   # override to test a variant (e.g. regression check)
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"; REPO="$ROOT/repo"; SANDBOX="$ROOT/sb"
export BOARD_STATE="$SANDBOX/board.json" GH_LOG="$SANDBOX/gh.log" PRDIR="$SANDBOX/prs" SANDBOX
mkdir -p "$BIN"

pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

# ── gh stub: mutates the stateful board JSON so labels/comments persist across cycles ─────
cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
obj="$1"; verb="$2"; shift 2
case "$obj $verb" in
  "issue list") cat "$BOARD_STATE" ;;                         # not used (we pass --board-file), but safe
  "issue edit")
    n="$1"; shift; add=""; rem=""
    while [ $# -gt 0 ]; do case "$1" in --add-label) add="$2"; shift;; --remove-label) rem="$2"; shift;; esac; shift; done
    jq --argjson n "$n" --arg add "$add" --arg rem "$rem" '
      map(if .number==$n then
            .labels = [ (.labels // [])[] | select($rem=="" or .name != $rem) ]
            | (if $add != "" and (([.labels[].name] | index($add)) | not) then .labels += [{name:$add}] else . end)
          else . end)' "$BOARD_STATE" > "$BOARD_STATE.t" && mv "$BOARD_STATE.t" "$BOARD_STATE"
    echo "edit #$n +[$add] -[$rem]" >> "$GH_LOG" ;;
  "issue comment")
    n="$1"; shift; body=""
    while [ $# -gt 0 ]; do [ "$1" = --body ] && body="$2"; shift; done
    jq --argjson n "$n" --arg b "$body" 'map(if .number==$n then .comments = ((.comments // []) + [{body:$b}]) else . end)' \
      "$BOARD_STATE" > "$BOARD_STATE.t" && mv "$BOARD_STATE.t" "$BOARD_STATE"
    echo "comment #$n: $body" >> "$GH_LOG" ;;
  "issue view")
    n="$1"; shift; jqf=""
    while [ $# -gt 0 ]; do case "$1" in --jq|-q) jqf="$2"; shift;; esac; shift; done
    o="$(jq --argjson n "$n" 'map(select(.number==$n))[0] // {}' "$BOARD_STATE")"
    if [ -n "$jqf" ]; then printf '%s' "$o" | jq -r "$jqf"; else printf '%s' "$o"; fi ;;
  "pr list")
    head=""; while [ $# -gt 0 ]; do [ "$1" = --head ] && head="$2"; shift; done
    n="${head#task/}"
    if [ -n "${PRLIST_TRANSIENT:-}" ] && [ ! -f "$SANDBOX/.prlist_$n" ]; then touch "$SANDBOX/.prlist_$n"; echo 0; exit 0; fi
    [ -f "$PRDIR/$n" ] && echo 1 || echo 0 ;;
  *) echo "stub gh UNHANDLED: $obj $verb $*" >> "$GH_LOG" ;;
esac
exit 0
GH
chmod +x "$BIN/gh"

# ── claude stub: plays an executor — commits unique work on the task branch, optionally "opens a PR" ──
cat > "$BIN/claude" <<'CL'
#!/usr/bin/env bash
n="$(git branch --show-current 2>/dev/null | sed 's#.*task/##')"
[ -n "$n" ] || n="$(basename "$PWD" | sed 's#task-##')"
c=$(( $(cat "$SANDBOX/.ccount" 2>/dev/null || echo 0) + 1 )); echo "$c" > "$SANDBOX/.ccount"
echo "run $c for #$n" >> "work-$n.txt"           # APPEND -> content differs each run; survives only if branch not reset
git add -A >/dev/null 2>&1; git commit -qm "executor run $c: closes #$n" >/dev/null 2>&1
case "${CLAUDE_BEHAVIOR:-success}" in
  success) touch "$PRDIR/$n" ;;                    # PR opened
  fail) exit 1 ;;                                  # crashed, no PR
esac
exit 0
CL
chmod +x "$BIN/claude"

reset(){ # fresh repo + sandbox per scenario (clean branches)
  rm -rf "$REPO" "$SANDBOX"; mkdir -p "$SANDBOX" "$PRDIR"
  git init -q "$REPO"; ( cd "$REPO"; git config user.email t@t; git config user.name t
    echo base > README.md; git add -A; git commit -qm init; git branch -M master ) >/dev/null 2>&1
}
board(){ cat > "$BOARD_STATE"; }   # board JSON on stdin
launch(){ # launch <behavior> <transient>
  ( cd "$REPO" && PATH="$BIN:$PATH" \
    CREWBOSS_WORKTREE_BASE="$SANDBOX/wt" CREWBOSS_KILL_SWITCH="$SANDBOX/kill" CREWBOSS_HEARTBEAT="$SANDBOX/beat" \
    CLAUDE_BEHAVIOR="$1" PRLIST_TRANSIENT="$2" \
    bash "$LAUNCHER" --once --board-file "$BOARD_STATE" ) >/dev/null 2>&1
}
has_label(){ [ "$(jq -r --argjson n "$1" 'map(select(.number==$n))[0].labels[]?.name' "$BOARD_STATE" | grep -c "^$2$")" -ge 1 ]; }
branch_file(){ git -C "$REPO" show "$1:$2" 2>/dev/null; }   # branch_file task/10 work-10.txt

# A launchable leaf: OPEN, body "Charter: #5", under an approved charter #5.
LEAF_BOARD='[
  {"number":5,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],"body":"charter","comments":[]},
  {"number":10,"state":"OPEN","labels":[],"body":"do it\nCharter: #5","comments":[]}
]'

echo "== predicate sanity: #10 is launchable =="
reset; printf '%s' "$LEAF_BOARD" > "$BOARD_STATE"
[ "$(bash "$HERE/../launcher/launchable.sh" < "$BOARD_STATE")" = "10" ] && ok "predicate -> 10" || ko "predicate did not yield 10"

echo "== scenario A: happy path — launch -> commit -> PR -> review =="
reset; printf '%s' "$LEAF_BOARD" > "$BOARD_STATE"
launch success ""
has_label 10 "status:review"                                  && ok "A: #10 -> status:review" || ko "A: #10 not review"
branch_file "task/10" "work-10.txt" | grep -q "run 1 for #10" && ok "A: executor work committed on task/10" || ko "A: no committed work on task/10"
[ -d "$SANDBOX/wt/task-10" ] && ko "A: worktree left behind" || ok "A: worktree cleaned up"

echo "== scenario B: DATA-LOSS FIX — transient gh-pr-list failure must NOT destroy committed work =="
reset; printf '%s' "$LEAF_BOARD" > "$BOARD_STATE"
launch success transient     # cycle 1: executor commits + opens PR, but pr-list lies (0) -> mis-classified -> retry
has_label 10 "status:in-progress" && ko "B: stuck in-progress after retry" || ok "B: un-claimed after transient mis-classify"
launch success transient     # cycle 2: leaf re-launchable; launch_one must REUSE task/10, not -B reset it
# the cycle-1 commit ("run 1") must still be on task/10 — proof the branch was not force-reset
branch_file "task/10" "work-10.txt" | grep -q "run 1 for #10" && ok "B: cycle-1 work SURVIVED the retry (no -B reset)" || ko "B: DATA LOSS — cycle-1 work gone (branch was reset)"
[ "$(branch_file "task/10" "work-10.txt" | grep -c 'for #10')" -ge 2 ] && ok "B: branch accumulated both runs (reuse, not reset)" || ko "B: branch did not accumulate (was reset)"
has_label 10 "status:review" && ok "B: #10 -> review once PR seen" || ko "B: #10 not review after recovery"

echo "== scenario C: executor fails twice -> retry-cap -> blocked =="
reset; printf '%s' "$LEAF_BOARD" > "$BOARD_STATE"
launch fail ""               # cycle 1: no PR -> retry 1/1
has_label 10 "status:blocked" && ko "C: blocked too early" || ok "C: retry before block"
launch fail ""               # cycle 2: still no PR, retry-cap reached -> blocked
has_label 10 "status:blocked" && ok "C: #10 -> status:blocked after retry-cap" || ko "C: #10 not blocked"

echo
echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
