#!/usr/bin/env bash
# run-liveness.test.sh — liveness fix tests (issue #113).
# Class i: integration with gh/spawn stubs + throwaway bare git remote.
# Models real-world conditions the loop must survive:
#
# RED-a (CI longer than tick): REMOVED as obsolete (#176 Ф-A).
#   петля больше не опрашивает statusCheckRollup; verify-merged синхронен (один тик).
#   Механизм «CI длиннее тика» с box-native отсутствует.
#
# RED-b (PR-list read-after-write lag): leaf transitions to review, but gh pr list
#   returns empty for the first N calls (simulating GH lag). Without fix: loop exits idle
#   (a naive "liveness-by-PR-list" fix also fails this). With fix: liveness is by issue
#   STATE (status:review label), not PR list → loop waits → merge succeeds.
#
# RED-c (stale-guard, anti-livelock): leaf is already in status:review, NO PR ever
#   created. CB_REVIEW_STALE_TICKS=3. Without fix: livelock (loop runs to max-ticks
#   with no progress). With stale-guard: leaf → blocked with comment; loop exits cleanly.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
INTEGRATOR="${INTEGRATOR_OVERRIDE:-$HERE/../runtime/crewboss-integrator.sh}"
LAUNCHER="${LAUNCHER_OVERRIDE:-$HERE/../runtime/crewboss-launcher-gh.sh}"
BOARD_GH_SRC="$HERE/../../proto/r6/board-gh.sh"
LAUNCHABLE_SRC="$HERE/../../proto/r6/launchable.sh"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

# ── shared state (exported so stubs can read them) ────────────────────────────
REMOTE="$ROOT/remote.git"
SANDBOX="$ROOT/sb"
BOARD_STATE="$SANDBOX/board.json"
GH_LOG="$SANDBOX/gh.log"
PRDIR="$SANDBOX/prs"
export REMOTE SANDBOX BOARD_STATE GH_LOG PRDIR

BIN="$ROOT/bin"; mkdir -p "$BIN"

# ── board/log helpers ─────────────────────────────────────────────────────────
issue_state(){ jq -r --argjson n "$1" 'map(select(.number==$n))[0].state' "$BOARD_STATE"; }
has_label(){   [ "$(jq -r --argjson n "$1" 'map(select(.number==$n))[0].labels[]?.name' \
                   "$BOARD_STATE" | grep -c "^$2$")" -ge 1 ]; }
has_comment(){ jq -r --argjson n "$1" 'map(select(.number==$n))[0].comments[]?.body' \
                 "$BOARD_STATE" | grep -qi "$2"; }
pr_merged(){   [ -f "$PRDIR/merged-$1" ]; }
ghlog_has(){   grep -q "$1" "$GH_LOG" 2>/dev/null; }

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
  rm -rf "$SANDBOX"; mkdir -p "$SANDBOX" "$PRDIR"
  : > "$GH_LOG"
  setup_remote
  local cbhome="$1"
  rm -rf "$cbhome"; mkdir -p "$cbhome"
  cp "$BOARD_GH_SRC"  "$cbhome/board-gh.sh"
  cp "$LAUNCHABLE_SRC" "$cbhome/launchable.sh"
  chmod +x "$cbhome/board-gh.sh" "$cbhome/launchable.sh"
}

# ── gh stub (shared by all liveness tests) ────────────────────────────────────
# Flag files in PRDIR control per-test behaviour:
#   ci-flip-at-$n   : pending for first N statusCheckRollup calls, then success (RED-a)
#   ci-calls-$n     : counter of statusCheckRollup calls (written by this stub)
#   prlist-lag-$n   : skip PR for issue $n for this many pr-list calls (RED-b)
#   checks-$n       : static check status (success/failure/pending) if ci-flip-at-$n absent
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

  "pr list")
    head_filter=""; base_filter=""; state_filter="open"
    while [ $# -gt 0 ]; do
      case "$1" in
        --head)  head_filter="$2"; shift ;;
        --base)  base_filter="$2"; shift ;;
        --state) state_filter="$2"; shift ;;
        --json)  shift ;;
      esac
      shift
    done
    result="[]"
    for pf in "$PRDIR"/[0-9]*; do
      [ -f "$pf" ] || continue
      n="$(basename "$pf")"
      case "$n" in *[!0-9]*) continue ;; esac
      [ "$state_filter" = "open" ] && [ -f "$PRDIR/merged-$n" ] && continue
      # --state merged returns ONLY actually-merged PRs (models real gh; needed by #111 reconcile)
      [ "$state_filter" = "merged" ] && [ ! -f "$PRDIR/merged-$n" ] && continue
      # PR-list lag: skip this PR for the first N calls (RED-b simulation)
      lagfile="$PRDIR/prlist-lag-$n"
      if [ -f "$lagfile" ]; then
        lag="$(cat "$lagfile" 2>/dev/null || echo 0)"
        if [ "$lag" -gt 0 ]; then
          printf '%d' "$((lag-1))" > "$lagfile"
          continue
        fi
      fi
      h="$(cat "$PRDIR/head-$n" 2>/dev/null || echo "leaf/$n-1700000000")"
      b="$(cat "$PRDIR/base-$n" 2>/dev/null || echo main)"
      [ -n "$head_filter" ] && [ "$h" != "$head_filter" ] && continue
      [ -n "$base_filter" ] && [ "$b" != "$base_filter" ] && continue
      result="$(printf '%s' "$result" | jq --argjson n "$n" --arg h "$h" --arg b "$b" \
        '. + [{"number":($n|tonumber),"headRefName":$h,"baseRefName":$b,"state":"OPEN"}]')"
    done
    printf '%s\n' "$result" ;;

  "pr view")
    n="$1"; shift; json_fields=""
    while [ $# -gt 0 ]; do case "$1" in --json) json_fields="$2"; shift ;; esac; shift; done
    case "$json_fields" in
      statusCheckRollup)
        # Anti-фальш (#176): always return EMPTY rollup — loop no longer reads statusCheckRollup.
        # RED-a (ci-flip) removed as obsolete; verify-merged provides box-verdict.
        printf '{"statusCheckRollup":[]}\n' ;;
      mergeCommit)
        sha="$(cat "$PRDIR/merge-sha-$n" 2>/dev/null || echo "")"
        printf '{"mergeCommit":{"oid":"%s"}}\n' "$sha" ;;
      *)
        base="$(cat "$PRDIR/base-$n" 2>/dev/null || echo main)"
        st="$([ -f "$PRDIR/merged-$n" ] && echo MERGED || echo OPEN)"
        printf '{"number":%s,"baseRefName":"%s","state":"%s"}\n' "$n" "$base" "$st" ;;
    esac ;;

  "pr merge")
    n="$1"; shift
    base="$(cat "$PRDIR/base-$n" 2>/dev/null || echo charter/5)"
    pr_head="$(cat "$PRDIR/head-$n" 2>/dev/null || echo "leaf/$n-1700000000")"
    _td="$(mktemp -d)"
    git clone -q "$REMOTE" "$_td" 2>/dev/null
    git -C "$_td" config user.email t@t; git -C "$_td" config user.name T
    git -C "$_td" fetch -q origin "$base" "$pr_head" 2>/dev/null
    git -C "$_td" checkout -q -b "_merge_work" "origin/$base" 2>/dev/null
    git -C "$_td" merge --no-ff "origin/$pr_head" -m "Merge $pr_head into $base (#$n)" \
        >/dev/null 2>&1
    _sha="$(git -C "$_td" rev-parse HEAD)"
    git -C "$_td" push -q origin "_merge_work:refs/heads/$base" 2>/dev/null
    rm -rf "$_td"
    printf '%s' "$_sha" > "$PRDIR/merge-sha-$n"
    touch "$PRDIR/merged-$n"
    printf 'Merged pull request #%s (%s)\n' "$n" "$base"
    echo "pr merge #$n into $base sha=$_sha" >> "$GH_LOG" ;;

  "label create") ;;

  *) echo "gh-stub UNHANDLED: $obj $verb $*" >> "$GH_LOG" ;;
esac
exit 0
GHEOF
chmod +x "$BIN/gh"

# ── spawn stub: instant (writes status.json + pushes leaf branch + records PR) ──
# CI status for the leaf PR is controlled via PRDIR flag files set by each test.
SPAWN_STUB="$ROOT/spawn.sh"
cat > "$SPAWN_STUB" <<'SPEOF'
#!/usr/bin/env bash
ID="$1"
CB_HOME="${CB_HOME:-/tmp/cbnet}"
RUN="$CB_HOME/run"
mkdir -p "$RUN/work/$ID"
printf '{"phase":"done"}\n' > "$RUN/work/$ID/status.json"

BODY="$(jq -r --argjson n "$ID" 'map(select(.number==$n))[0].body // ""' "$BOARD_STATE" 2>/dev/null)"
C="$(printf '%s\n' "$BODY" | grep -oiE 'charter:[[:space:]]*#?[0-9]+' | head -1 | grep -oE '[0-9]+')"
CB="charter/$C"
[ -n "$C" ] || { echo "spawn: no charter for #$ID" >> "$SANDBOX/spawn.log"; exit 1; }

WA="$(mktemp -d)"
git clone -q "$REMOTE" "$WA" 2>/dev/null
git -C "$WA" config user.email t@t; git -C "$WA" config user.name T

( flock 9
  if ! git ls-remote --exit-code --heads "$REMOTE" "$CB" >/dev/null 2>&1; then
    main_sha="$(git -C "$WA" rev-parse "origin/main" 2>/dev/null || true)"
    git -C "$WA" push -q origin "$main_sha:refs/heads/$CB" 2>/dev/null || true
  fi
) 9>"$SANDBOX/charter-$C.lock"

git -C "$WA" fetch -q origin "$CB" 2>/dev/null
TS=1700000000
git -C "$WA" checkout -q -b "leaf/$ID-$TS" "origin/$CB" 2>/dev/null
printf 'work for #%s\n' "$ID" > "$WA/work-$ID.txt"
git -C "$WA" add -A
git -C "$WA" commit -qm "executor: closes #$ID" 2>/dev/null
git -C "$WA" push -q origin "leaf/$ID-$TS" 2>/dev/null

touch "$PRDIR/$ID"
printf '%s' "$CB" > "$PRDIR/base-$ID"
printf '%s' "leaf/$ID-$TS" > "$PRDIR/head-$ID"
# ci-flip-at-$ID is set by the test before the loop runs (RED-a); otherwise
# checks-$ID controls static CI status; default (absent) = success.

rm -rf "$WA"
echo "spawn: done #$ID (charter $C)" >> "$SANDBOX/spawn.log"
exit 0
SPEOF
chmod +x "$SPAWN_STUB"

# ── loop runner (captures stdout+stderr to a log file) ────────────────────────
run_loop(){
  local cbhome="$1" logfile="${2:-/dev/null}"; shift 2
  PATH="$BIN:$PATH" \
    CB_REPO="test/repo" \
    CB_HOME="$cbhome" \
    CB_SPAWN="$SPAWN_STUB" \
    CB_GIT_REMOTE="$REMOTE" \
    CB_INTEGRATOR="$INTEGRATOR" \
    CB_POLL=0 \
    CB_MAX_TICKS=40 \
    CB_IDLE_CONFIRM=2 \
    CB_MAX_PARALLEL=4 \
    CB_RETRY_CAP=3 \
    CREWBOSS_CHARTER= \
    env "$@" \
    bash "$LAUNCHER" run >"$logfile" 2>&1 || true
}

# =============================================================================
# RED-a: REMOVED (obsolete, #176 Ф-A)
# CI-polling-liveness (ci-flip-at-$n / statusCheckRollup multi-tick) отсутствует:
# петля не читает statusCheckRollup; verify-merged синхронен (один тик).
# =============================================================================
# RED-b: PR-list read-after-write lag
# =============================================================================
echo "== RED-b: PR-list lag — liveness by issue state (not PR list) prevents idle-exit =="

CBHOME_B="$ROOT/cbhome_b"
LOGFILE_B="$ROOT/loop_b.log"
reset_sandbox "$CBHOME_B"

cat > "$BOARD_STATE" <<'JSON'
[
  {"number":5,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],
   "body":"charter","comments":[]},
  {"number":10,"state":"OPEN","labels":[{"name":"type:agent"}],
   "body":"task\nCharter: #5\n## Acceptance (machine)\n- check: true","comments":[]}
]
JSON

# PR for issue #10 is invisible in pr-list for the first 3 calls (GH read-after-write lag).
# This simulates: spawn done→review, but gh pr list hasn't propagated the new PR yet.
# A naive liveness fix based on "open PR list" would also exit idle during this window.
# CB_REVIEW_STALE_TICKS default (10) >> lag (3) so stale-guard does NOT fire.
printf '3' > "$PRDIR/prlist-lag-10"

run_loop "$CBHOME_B" "$LOGFILE_B" "CB_REVIEW_STALE_TICKS=10"

pr_merged 10 \
  && ok "RED-b: PR #10 merged despite pr-list lag" \
  || ko "RED-b: PR #10 NOT merged — loop exited idle during pr-list lag window"

[ "$(issue_state 10)" = "CLOSED" ] \
  && ok "RED-b: #10 CLOSED despite pr-list lag" \
  || ko "RED-b: #10 not CLOSED — premature idle exit during lag"

grep -q "idle — run complete" "$LOGFILE_B" \
  && ok "RED-b: loop exited cleanly (idle — run complete)" \
  || ok "RED-b: loop finished (acceptable)"

grep -q "max ticks" "$LOGFILE_B" \
  && ko "RED-b: loop hit max-ticks (should have merged and exited cleanly)" \
  || ok "RED-b: loop did NOT hit max-ticks"

# =============================================================================
# RED-c: stale-guard — review-leaf without PR → blocked + loop self-exits
# =============================================================================
echo "== RED-c: stale-guard — review-leaf without PR becomes blocked; loop exits cleanly =="

CBHOME_C="$ROOT/cbhome_c"
LOGFILE_C="$ROOT/loop_c.log"
reset_sandbox "$CBHOME_C"

# Leaf already in status:review, NO PR in PRDIR (no spawn happened, no PR file).
# Without stale-guard: _loop_is_alive sees review-leaves={10} → livelock to max-ticks.
# With stale-guard: after CB_REVIEW_STALE_TICKS=3 ticks, leaf → blocked; review-leaves={}
# → _loop_is_alive returns false → idle-exit after CB_IDLE_CONFIRM ticks.
cat > "$BOARD_STATE" <<'JSON'
[
  {"number":5,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],
   "body":"charter","comments":[]},
  {"number":10,"state":"OPEN","labels":[{"name":"type:agent"},{"name":"status:review"}],
   "body":"task\nCharter: #5\n## Acceptance (machine)\n- check: true","comments":[]}
]
JSON

run_loop "$CBHOME_C" "$LOGFILE_C" "CB_REVIEW_STALE_TICKS=3" "CB_MAX_TICKS=20"

# Leaf must be blocked
has_label 10 "status:blocked" \
  && ok "RED-c: #10 has status:blocked (stale-guard triggered)" \
  || ko "RED-c: #10 NOT blocked — stale-guard missing"

# Leaf must NOT still be in status:review (label must be removed by stale-guard)
has_label 10 "status:review" \
  && ko "RED-c: #10 still has status:review after stale-guard (label not removed!)" \
  || ok "RED-c: status:review removed from #10 by stale-guard"

# Comment must mention the stale condition
has_comment 10 "stale" \
  && ok "RED-c: #10 has stale-guard comment" \
  || ko "RED-c: #10 missing stale-guard comment"

# Loop must have exited cleanly (idle), NOT hit max-ticks
grep -q "idle — run complete" "$LOGFILE_C" \
  && ok "RED-c: loop exited cleanly (idle — run complete, not max-ticks)" \
  || ko "RED-c: loop did not exit with idle — run complete"

grep -q "max ticks" "$LOGFILE_C" \
  && ko "RED-c: loop hit max-ticks — stale-guard did not terminate the livelock" \
  || ok "RED-c: loop did NOT hit max-ticks"

# =============================================================================
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
