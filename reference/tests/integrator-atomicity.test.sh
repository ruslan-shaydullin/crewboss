#!/usr/bin/env bash
# integrator-atomicity.test.sh — RED-a/b/c atomicity & reconcile tests (issue #111).
# Class i: integration with gh/claude stubs + throwaway bare git remote.
#
# RED-a  «failed merge → leaf NOT closed, int_done empty»
# RED-b  «merge ok, close fails once → leaf CLOSED by next tick, merge exactly once»
# RED-c  «reconcile: PR already MERGED before loop start → close without new merge»
#
# Requires: jq, git, bash, flock.
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

# ── shared exports (read by the gh stub via env) ──────────────────────────────
REMOTE="$ROOT/remote.git"
SANDBOX="$ROOT/sb"
BOARD_STATE="$SANDBOX/board.json"
GH_LOG="$SANDBOX/gh.log"
PRDIR="$SANDBOX/prs"
export REMOTE SANDBOX BOARD_STATE GH_LOG PRDIR

BIN="$ROOT/bin"; mkdir -p "$BIN"

# ── helpers ───────────────────────────────────────────────────────────────────
issue_state(){   jq -r --argjson n "$1" 'map(select(.number==$n))[0].state' "$BOARD_STATE"; }
has_comment(){   jq -r --argjson n "$1" 'map(select(.number==$n))[0].comments[]?.body' \
                   "$BOARD_STATE" | grep -qi "$2"; }
no_comment(){    ! has_comment "$1" "$2"; }
int_done_val(){  cat "$1/int_done" 2>/dev/null || echo ""; }
pr_merged(){     [ -f "$PRDIR/merged-$1" ]; }
pr_not_merged(){ [ ! -f "$PRDIR/merged-$1" ]; }
ghlog_count(){   grep -c "$1" "$GH_LOG" 2>/dev/null || echo 0; }
ghlog_has(){     grep -q  "$1" "$GH_LOG" 2>/dev/null; }

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

# ── setup_leaf_pr: push git branches + create PRDIR state ────────────────────
# Represents the state after spawn ran but before the integrator merges.
# Uses origin/main SHA explicitly (avoids bare-repo HEAD-ambiguity).
setup_leaf_pr(){
  local rid="${1:-10}" cid="${2:-5}"
  local cb="charter/$cid" leaf_head="leaf/$rid-1700000000"

  local tmp; tmp="$(mktemp -d)"
  git clone -q "$REMOTE" "$tmp" 2>/dev/null
  git -C "$tmp" config user.email t@t; git -C "$tmp" config user.name T
  # Fetch main explicitly so origin/main remote-tracking ref is available
  git -C "$tmp" fetch -q origin main 2>/dev/null

  # Push charter branch (same SHA as main — leaf will diverge from it)
  local main_sha; main_sha="$(git -C "$tmp" rev-parse origin/main 2>/dev/null)"
  git -C "$tmp" push -q origin "${main_sha}:refs/heads/${cb}" 2>/dev/null

  # Create leaf branch with a work commit and push it
  git -C "$tmp" fetch -q origin "${cb}" 2>/dev/null
  git -C "$tmp" checkout -q -b "${leaf_head}" "origin/${cb}" 2>/dev/null
  printf 'work for #%s\n' "$rid" > "$tmp/work-$rid.txt"
  git -C "$tmp" add -A
  git -C "$tmp" commit -qm "executor: closes #$rid" 2>/dev/null
  git -C "$tmp" push -q origin "${leaf_head}" 2>/dev/null
  rm -rf "$tmp"

  # PRDIR: PR exists, open (not merged yet), CI green
  touch "$PRDIR/$rid"
  printf '%s' "$leaf_head" > "$PRDIR/head-$rid"
  printf '%s' "$cb"        > "$PRDIR/base-$rid"
  printf 'success'         > "$PRDIR/checks-$rid"
}

# ── setup_merged_pr: like setup_leaf_pr but also merges leaf into charter ─────
# Represents a mid-run crash: merge succeeded, close-leaf never ran.
setup_merged_pr(){
  local rid="${1:-10}" cid="${2:-5}"
  local cb="charter/$cid" leaf_head="leaf/$rid-1700000000"

  setup_leaf_pr "$rid" "$cid"

  local tmp; tmp="$(mktemp -d)"
  git clone -q "$REMOTE" "$tmp" 2>/dev/null
  git -C "$tmp" config user.email t@t; git -C "$tmp" config user.name T

  # Fetch charter and leaf refs individually (FETCH_HEAD = last fetched)
  git -C "$tmp" fetch -q origin "${cb}" 2>/dev/null
  local cb_sha; cb_sha="$(git -C "$tmp" rev-parse FETCH_HEAD 2>/dev/null)"
  git -C "$tmp" fetch -q origin "${leaf_head}" 2>/dev/null
  local leaf_sha; leaf_sha="$(git -C "$tmp" rev-parse FETCH_HEAD 2>/dev/null)"

  # Merge leaf into charter and push
  git -C "$tmp" checkout -q -b "_merge_work" "${cb_sha}" 2>/dev/null
  git -C "$tmp" merge --no-ff "${leaf_sha}" \
      -m "Merge ${leaf_head} into ${cb} (#${rid})" >/dev/null 2>&1
  local sha; sha="$(git -C "$tmp" rev-parse _merge_work 2>/dev/null)"
  git -C "$tmp" push -q origin "_merge_work:refs/heads/${cb}" 2>/dev/null
  rm -rf "$tmp"

  # Mark PR as merged
  printf '%s' "$sha" > "$PRDIR/merge-sha-$rid"
  touch "$PRDIR/merged-$rid"
}

run_loop(){
  local cbhome="${1:-$ROOT/cbhome_default}"
  # Board has leaves in status:review — no new spawn needed; use noop stub
  PATH="$BIN:$PATH" \
    CB_REPO="test/repo" \
    CB_HOME="$cbhome" \
    CB_SPAWN="$ROOT/spawn-noop.sh" \
    CB_GIT_REMOTE="$REMOTE" \
    CB_INTEGRATOR="$INTEGRATOR" \
    CB_POLL=0 \
    CB_MAX_TICKS=30 \
    CB_IDLE_CONFIRM=2 \
    CB_MAX_PARALLEL=2 \
    CB_RETRY_CAP=3 \
    bash "$LAUNCHER" run 2>/dev/null
}

# ── no-op spawn stub ──────────────────────────────────────────────────────────
# Board already has leaves in status:review — no real spawning should be needed.
cat > "$ROOT/spawn-noop.sh" <<'NOOPEOF'
#!/usr/bin/env bash
ID="$1"
CB_HOME="${CB_HOME:-/tmp/cbnet}"
RUN="$CB_HOME/run"
mkdir -p "$RUN/work/$ID"
printf '{"phase":"done"}\n' > "$RUN/work/$ID/status.json"
exit 0
NOOPEOF
chmod +x "$ROOT/spawn-noop.sh"

# ══════════════════════════════════════════════════════════════════════════════
# gh stub — atomicity edition
#
# Extra features vs integrator-loop.test.sh stub:
#   - pr list --state merged: returns ONLY merged PRs (correct filter)
#   - pr merge:    honours $PRDIR/fail-merge-$n flag (exit 1, no merged marker)
#   - issue close: honours $SANDBOX/fail-close-once-$n flag (fail first call, succeed next)
# ══════════════════════════════════════════════════════════════════════════════
cat > "$BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
obj="$1"; verb="$2"; shift 2

# Strip -R/--repo and -L/--limit flags (with their values)
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
    # fail-close-once: fail first call, succeed on subsequent calls
    if [ -f "$SANDBOX/fail-close-once-$n" ]; then
      rm -f "$SANDBOX/fail-close-once-$n"
      echo "issue close #$n: FORCED FAIL (fail-once)" >> "$GH_LOG"
      exit 1
    fi
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
      is_merged="$( [ -f "$PRDIR/merged-$n" ] && echo 1 || echo 0 )"
      # Correct state filtering (unlike the loop test stub, merged means merged only)
      [ "$state_filter" = "open"   ] && [ "$is_merged" = "1" ] && continue
      [ "$state_filter" = "merged" ] && [ "$is_merged" = "0" ] && continue
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
        status="$(cat "$PRDIR/checks-$n" 2>/dev/null || echo success)"
        case "$status" in
          success) cr='[{"conclusion":"SUCCESS","status":"COMPLETED"}]' ;;
          failure) cr='[{"conclusion":"FAILURE","status":"COMPLETED"}]' ;;
          pending) cr='[{"conclusion":null,"status":"IN_PROGRESS"}]' ;;
          *)       cr='[]' ;;
        esac
        printf '{"statusCheckRollup":%s}\n' "$cr" ;;
      mergeCommit)
        sha="$(cat "$PRDIR/merge-sha-$n" 2>/dev/null || echo "")"
        printf '{"mergeCommit":{"oid":"%s"}}\n' "$sha" ;;
      *)
        # Handles --json state and any other single-field query
        base="$(cat "$PRDIR/base-$n" 2>/dev/null || echo main)"
        st="$([ -f "$PRDIR/merged-$n" ] && echo MERGED || echo OPEN)"
        printf '{"number":%s,"baseRefName":"%s","state":"%s"}\n' "$n" "$base" "$st" ;;
    esac ;;

  "pr merge")
    n="$1"; shift
    # fail-merge: flag file causes merge to return exit 1 without marking merged
    if [ -f "$PRDIR/fail-merge-$n" ]; then
      echo "pr merge #$n: FORCED FAIL (fail-merge)" >> "$GH_LOG"
      exit 1
    fi
    base="$(cat "$PRDIR/base-$n" 2>/dev/null || echo charter/5)"
    pr_head="$(cat "$PRDIR/head-$n" 2>/dev/null || echo "leaf/$n-1700000000")"
    _td="$(mktemp -d)"
    git clone -q "$REMOTE" "$_td" 2>/dev/null
    git -C "$_td" config user.email t@t; git -C "$_td" config user.name T
    git -C "$_td" fetch -q origin "$base" "$pr_head" 2>/dev/null
    git -C "$_td" checkout -q -b "_merge_work" "origin/$base" 2>/dev/null
    git -C "$_td" merge --no-ff "origin/$pr_head" \
        -m "Merge $pr_head into $base (#$n)" >/dev/null 2>&1
    _sha="$(git -C "$_td" rev-parse HEAD)"
    git -C "$_td" push -q origin "_merge_work:refs/heads/$base" 2>/dev/null
    rm -rf "$_td"
    printf '%s' "$_sha" > "$PRDIR/merge-sha-$n"
    touch "$PRDIR/merged-$n"
    printf 'Merged pull request #%s (%s)\n' "$n" "$base"
    echo "pr merge #$n into $base sha=$_sha" >> "$GH_LOG" ;;

  "label create") ;;   # no-op

  *) echo "gh-stub UNHANDLED: $obj $verb $*" >> "$GH_LOG" ;;
esac
exit 0
GHEOF
chmod +x "$BIN/gh"

# ── Board template: charter approved, leaf in status:review ──────────────────
BOARD_REVIEW='[
  {"number":5,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:approved"}],
   "body":"the charter","comments":[]},
  {"number":10,"state":"OPEN",
   "labels":[{"name":"type:agent"},{"name":"status:review"}],
   "body":"task A\nCharter: #5\n## Acceptance (machine)\n- check: true",
   "comments":[]}
]'

# =============================================================================
# RED-a: gh pr merge exits 1 → leaf NOT closed, int_done empty, no close comment
# BEFORE fix: || true on line 163 suppresses error; lines 166-169 unconditionally
#             close the issue → RED (leaf closed despite merge failure).
# AFTER fix:  merge_rc is checked; on failure, loop continues without close → GREEN.
# =============================================================================
echo "== RED-a: failed merge → leaf NOT closed =="

CBHOMEA="$ROOT/cbhomeA"
reset_sandbox "$CBHOMEA"
printf '%s' "$BOARD_REVIEW" > "$BOARD_STATE"

setup_leaf_pr 10 5              # push branches + create PRDIR (open, CI green)
touch "$PRDIR/fail-merge-10"    # force gh pr merge to exit 1

run_loop "$CBHOMEA"

pr_not_merged 10 \
  && ok "RED-a1: PR #10 NOT merged (merge failure honoured)" \
  || ko "RED-a1: PR #10 was merged despite forced failure"

[ "$(issue_state 10)" != "CLOSED" ] \
  && ok "RED-a2: issue #10 NOT closed (leaf protected)" \
  || ko "RED-a2: issue #10 was closed despite failed merge"

[ "$(int_done_val "$CBHOMEA/run/state/10")" != "merged" ] \
  && ok "RED-a3: int_done is empty (state not poisoned)" \
  || ko "RED-a3: int_done=merged despite merge failure"

no_comment 10 "Closed by integrator" \
  && ok "RED-a4: no 'Closed by integrator' comment on #10" \
  || ko "RED-a4: 'Closed by integrator' comment found despite merge failure"

# =============================================================================
# RED-b: merge ok, issue-close fails once → leaf CLOSED by next tick, no double-merge
# BEFORE fix: int_done set immediately after || true close (line 169); no retry for
#             close → leaf stays open forever.
# AFTER fix:  int_done only set after successful close; next tick finds PR in
#             merged_prs → reconcile close-leaf → GREEN.
# =============================================================================
echo "== RED-b: close fails once → leaf CLOSED on retry, merge exactly once =="

CBHOMEB="$ROOT/cbhomeB"
reset_sandbox "$CBHOMEB"
printf '%s' "$BOARD_REVIEW" > "$BOARD_STATE"

setup_leaf_pr 10 5                       # push branches + PRDIR (open, CI green)
touch "$SANDBOX/fail-close-once-10"      # gh issue close fails on first call only

run_loop "$CBHOMEB"

pr_merged 10 \
  && ok "RED-b1: PR #10 merged" \
  || ko "RED-b1: PR #10 not merged"

[ "$(issue_state 10)" = "CLOSED" ] \
  && ok "RED-b2: issue #10 CLOSED (close succeeded on retry)" \
  || ko "RED-b2: issue #10 NOT closed (retry did not happen)"

# Merge must be called exactly once (no double-merge via reconcile path)
merge_count="$(ghlog_count "pr merge #10")"
[ "$merge_count" -eq 1 ] \
  && ok "RED-b3: pr merge called exactly once (no double-merge)" \
  || ko "RED-b3: pr merge call count=$merge_count (expected 1)"

has_comment 10 "Closed by integrator" \
  && ok "RED-b4: 'Closed by integrator' comment present on #10" \
  || ko "RED-b4: 'Closed by integrator' comment missing on #10"

# =============================================================================
# RED-c: PR already MERGED before loop starts → reconcile close-leaf, no new merge
# BEFORE fix: "no open PR → skip" at lines 127-129; leaf stays open forever on
#             restart because the reconcile path did not exist.
# AFTER fix:  merged_prs snapshot finds the merged PR; close-leaf is called without
#             a new merge → GREEN.
# =============================================================================
echo "== RED-c: already-MERGED PR → reconcile close-leaf without new merge =="

CBHOMEC="$ROOT/cbhomeC"
reset_sandbox "$CBHOMEC"
printf '%s' "$BOARD_REVIEW" > "$BOARD_STATE"

# Pre-merge the PR before the loop starts (simulates: merge ran, close-leaf crashed)
setup_merged_pr 10 5

# Fresh CB_HOME: no int_done state, no open PR (already merged) — simulates restart
run_loop "$CBHOMEC"

[ "$(issue_state 10)" = "CLOSED" ] \
  && ok "RED-c1: issue #10 CLOSED via reconcile path" \
  || ko "RED-c1: issue #10 NOT closed (reconcile path missing)"

has_comment 10 "Closed by integrator" \
  && ok "RED-c2: 'Closed by integrator' comment present (reconcile ran close-leaf)" \
  || ko "RED-c2: 'Closed by integrator' comment missing (reconcile did not close)"

# No new pr merge call — reconcile MUST NOT re-merge an already-merged PR
ghlog_has "pr merge #10" \
  && ko "RED-c3: gh pr merge was called (should NOT be — PR was already merged)" \
  || ok "RED-c3: gh pr merge NOT called (correct — reconcile skips merge)"

# =============================================================================
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
