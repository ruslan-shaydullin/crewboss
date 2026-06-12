#!/usr/bin/env bash
# charter-finale.test.sh — integration tests for the charter finale cycle (issue #93).
# Class i: integration with gh/git stubs + throwaway bare git remote.
# Drives crewboss-launcher-gh.sh run (poll loop) for the charter-finale path.
#
# RED-a: local gate RED (CB_HARNESS exit 1) → PR NOT created + comment on charter
# RED-b: gate green + CI success → draft PR created, promoted to ready, charter OPEN
# RED-c: idempotency — second tick with existing PR does NOT create a duplicate
# RED-d: gate green, draft PR created, gh pr checks = failure → PR stays draft + comment
# RED-e: anti-deadlock — default config (no CB_HARNESS); gh stub FAILS if pr checks
#        called before pr create; assert: draft PR created AND pr checks strictly after
#        pr create in call log.
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

# ── shared exports ────────────────────────────────────────────────────────────
REMOTE="$ROOT/remote.git"
SANDBOX="$ROOT/sb"
BOARD_STATE="$SANDBOX/board.json"
GH_LOG="$SANDBOX/gh.log"
PRDIR="$SANDBOX/prs"
export REMOTE SANDBOX BOARD_STATE GH_LOG PRDIR

BIN="$ROOT/bin"; mkdir -p "$BIN"

# ── helpers ───────────────────────────────────────────────────────────────────
has_comment(){ jq -r --argjson n "$1" \
  'map(select(.number==$n))[0].comments[]?.body' "$BOARD_STATE" \
  | grep -qi "$2"; }
issue_state(){ jq -r --argjson n "$1" \
  'map(select(.number==$n))[0].state' "$BOARD_STATE"; }
ghlog_has(){ grep -q "$1" "$GH_LOG" 2>/dev/null; }
# ghlog_first_of $pat: line number of first match
ghlog_first_of(){ grep -n "$1" "$GH_LOG" 2>/dev/null | head -1 | cut -d: -f1; }
# charter_pr_exists: true if gh pr create was logged for charter/5
charter_pr_created(){ ghlog_has "pr-create charter/5->main"; }
# charter_pr_ready: true if gh pr ready was called
charter_pr_ready(){ ghlog_has "pr-ready"; }
# charter_pr_draft: created but NOT made ready
charter_pr_draft_only(){ charter_pr_created && ! charter_pr_ready; }

setup_remote(){
  rm -rf "$REMOTE"; git init --bare -q "$REMOTE"
  local tmp; tmp="$(mktemp -d)"
  git clone -q "$REMOTE" "$tmp" 2>/dev/null
  git -C "$tmp" config user.email t@t; git -C "$tmp" config user.name T
  printf 'base\n' > "$tmp/README.md"
  git -C "$tmp" add -A; git -C "$tmp" commit -qm "init" 2>/dev/null
  git -C "$tmp" push -q origin HEAD:refs/heads/main 2>/dev/null

  # Create charter/5 branch ahead of main (simulate merged leaves)
  git -C "$tmp" checkout -q -b "charter/5" 2>/dev/null
  printf 'leaf-work\n' > "$tmp/leaf.txt"
  git -C "$tmp" add -A; git -C "$tmp" commit -qm "leaf work merged into charter/5" 2>/dev/null
  git -C "$tmp" push -q origin "charter/5" 2>/dev/null
  rm -rf "$tmp"
}

reset_sandbox(){
  rm -rf "$SANDBOX"; mkdir -p "$SANDBOX" "$PRDIR"
  : > "$GH_LOG"
  setup_remote
  local cbhome="$1"
  rm -rf "$cbhome"; mkdir -p "$cbhome"
  cp "$BOARD_GH_SRC"   "$cbhome/board-gh.sh"
  cp "$LAUNCHABLE_SRC" "$cbhome/launchable.sh"
  chmod +x "$cbhome/board-gh.sh" "$cbhome/launchable.sh"
}

# Board: charter #5 OPEN (approved), leaves #10 and #11 already CLOSED.
# This is the "finale" state: all work merged into charter/5, no open leaves.
FINALE_BOARD='[
  {"number":5,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],
   "body":"the charter","comments":[]},
  {"number":10,"state":"CLOSED","labels":[{"name":"type:agent"}],
   "body":"task A\nCharter: #5\n## Acceptance (machine)\n- check: true","comments":[]},
  {"number":11,"state":"CLOSED","labels":[{"name":"type:agent"}],
   "body":"task B\nCharter: #5\n## Acceptance (machine)\n- check: true","comments":[]}
]'

# ── gh stub ───────────────────────────────────────────────────────────────────
# Handles: issue list/view/edit/comment/close, pr list/create/checks/ready, label create.
# Charter-PR state:
#   $PRDIR/charter-pr-N       — PR number assigned to charter N
#   $PRDIR/charter-checks-N   — "success" | "failure" | "pending" (CI status)
#   $PRDIR/charter-pr-ready-P — exists if PR number P was promoted to ready
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
    jq --argjson n "$n" 'map(if .number==$n then .state="CLOSED" else . end)' \
      "$BOARD_STATE" > "$BOARD_STATE.t" && mv "$BOARD_STATE.t" "$BOARD_STATE"
    echo "close #$n" >> "$GH_LOG" ;;

  "pr list")
    head=""; base_filter=""; state_filter="open"
    while [ $# -gt 0 ]; do
      case "$1" in
        --head)  head="$2"; shift ;;
        --base)  base_filter="$2"; shift ;;
        --state) state_filter="$2"; shift ;;
        --json)  shift ;;
      esac; shift
    done
    echo "pr-list --head=${head} --base=${base_filter} --state=${state_filter}" >> "$GH_LOG"
    if printf '%s' "$head" | grep -q '^charter/'; then
      n="${head#charter/}"
      if [ -f "$PRDIR/charter-pr-$n" ] && [ "$state_filter" = "open" ]; then
        pr_num="$(cat "$PRDIR/charter-pr-$n")"
        printf '[{"number":%s,"baseRefName":"main","headRefName":"charter/%s"}]\n' "$pr_num" "$n"
      else
        echo "[]"
      fi
    else
      n="${head#task/}"
      if [ -f "$PRDIR/$n" ] && [ ! -f "$PRDIR/merged-$n" ] && [ "$state_filter" = "open" ]; then
        base="$(cat "$PRDIR/base-$n" 2>/dev/null || echo main)"
        printf '[{"number":%s,"baseRefName":"%s","state":"OPEN"}]\n' "$n" "$base"
      else
        echo "[]"
      fi
    fi ;;

  "pr create")
    draft=false; base="main"; head=""; title=""; body=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --draft)    draft=true ;;
        --base)     base="$2"; shift ;;
        --head)     head="$2"; shift ;;
        --title|-t) title="$2"; shift ;;
        --body|-b)  body="$2"; shift ;;
      esac; shift
    done
    echo "pr-create ${head}->${base} draft=${draft}" >> "$GH_LOG"
    if printf '%s' "$head" | grep -q '^charter/'; then
      charter_n="${head#charter/}"
      pr_num=$((5000 + charter_n))
      printf '%s' "$pr_num" > "$PRDIR/charter-pr-$charter_n"
      printf '%s' "draft" > "$PRDIR/charter-pr-state-$pr_num"
      printf 'https://github.com/test/repo/pull/%s\n' "$pr_num"
    fi ;;

  "pr ready")
    n="$1"
    echo "pr-ready $n" >> "$GH_LOG"
    touch "$PRDIR/charter-pr-ready-$n"
    printf '%s' "ready" > "$PRDIR/charter-pr-state-$n" ;;

  "pr checks")
    n="$1"
    echo "pr-checks $n" >> "$GH_LOG"
    # Anti-deadlock: fail if this PR was never created (no charter-pr-* file contains $n)
    charter_n=""
    for f in "$PRDIR"/charter-pr-[0-9]*; do
      [ -f "$f" ] || continue
      stored="$(cat "$f" 2>/dev/null)"
      if [ "$stored" = "$n" ]; then
        charter_n="${f##*/charter-pr-}"
        break
      fi
    done
    if [ -z "$charter_n" ]; then
      echo "ERROR-anti-deadlock: pr-checks called before pr-create for PR $n" >> "$GH_LOG"
      exit 1
    fi
    status="$(cat "$PRDIR/charter-checks-$charter_n" 2>/dev/null || echo success)"
    case "$status" in
      success) exit 0 ;;
      failure) printf 'X check: failed\n'; exit 1 ;;
      pending) printf '- check: pending\n'; exit 1 ;;
      *)       exit 1 ;;
    esac ;;

  "pr merge")
    n="$1"; shift
    echo "pr-merge $n" >> "$GH_LOG"
    printf '%s' "merged" > "$PRDIR/charter-pr-state-$n" ;;

  "label create") ;;   # no-op

  *) echo "gh-stub UNHANDLED: $obj $verb $*" >> "$GH_LOG" ;;
esac
exit 0
GHEOF
chmod +x "$BIN/gh"

# Clean directory used as CB_GATE_REPO_DIR — no CREWBOSS_NOGATE markers.
# (The working directory /work contains the string in crewboss-integrator.sh itself,
# which would cause marker-grep to fire.  Tests must point gate-charter at a clean dir.)
CLEAN_GATE_DIR="$ROOT/clean_gate_dir"; mkdir -p "$CLEAN_GATE_DIR"

# ── loop runner ───────────────────────────────────────────────────────────────
# No spawn — board is pre-settled (leaves already CLOSED). The loop is expected to:
#   - find no launchable issues → idle quickly
#   - run _charter_finale_cycle on each tick
run_finale(){
  local cbhome="$1"
  local extra_env="${2:-}"
  eval "PATH=\"$BIN:$PATH\" \
    CB_REPO=\"test/repo\" \
    CB_HOME=\"$cbhome\" \
    CB_GIT_REMOTE=\"$REMOTE\" \
    CB_INTEGRATOR=\"$INTEGRATOR\" \
    CB_GATE_REPO_DIR=\"$CLEAN_GATE_DIR\" \
    CB_POLL=0 \
    CB_MAX_TICKS=10 \
    CB_IDLE_CONFIRM=2 \
    CB_MAX_PARALLEL=2 \
    CB_RETRY_CAP=2 \
    CB_FINALE_CHECKS_TIMEOUT=0 \
    CB_FINALE_CHECKS_POLL=0 \
    $extra_env \
    bash \"$LAUNCHER\" run 2>/dev/null"
}

# =============================================================================
# RED-a: local gate RED → PR NOT created + comment on charter
# =============================================================================
echo "== RED-a: local gate RED (CB_HARNESS exit 1) — PR not created, comment on charter =="

CBHOME_A="$ROOT/cbhome_a"
reset_sandbox "$CBHOME_A"
printf '%s' "$FINALE_BOARD" > "$BOARD_STATE"

RED_HARNESS="$ROOT/harness-red.sh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$RED_HARNESS"; chmod +x "$RED_HARNESS"

run_finale "$CBHOME_A" "CB_HARNESS=\"$RED_HARNESS\""

charter_pr_created \
  && ko "RED-a: PR charter/5→main was created despite red gate" \
  || ok "RED-a: PR NOT created (gate blocked)"

has_comment 5 "gate RED" \
  && ok "RED-a: comment on charter #5 mentions gate RED reason" \
  || ko "RED-a: no gate-RED comment on charter #5"

# =============================================================================
# RED-b: gate green + CI success → draft PR created, promoted to ready, charter OPEN
# =============================================================================
echo "== RED-b: gate green + CI success → draft PR created then promoted =="

CBHOME_B="$ROOT/cbhome_b"
reset_sandbox "$CBHOME_B"
printf '%s' "$FINALE_BOARD" > "$BOARD_STATE"

GREEN_HARNESS="$ROOT/harness-green.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$GREEN_HARNESS"; chmod +x "$GREEN_HARNESS"
# CI checks stub: success for charter 5's PR (pr number = 5000+5 = 5005)
printf 'success' > "$PRDIR/charter-checks-5"

run_finale "$CBHOME_B" "CB_HARNESS=\"$GREEN_HARNESS\""

charter_pr_created \
  && ok "RED-b: draft PR charter/5→main created" \
  || ko "RED-b: draft PR was NOT created"

ghlog_has "draft=true" \
  && ok "RED-b: PR was created as draft" \
  || ko "RED-b: PR was NOT created as draft"

charter_pr_ready \
  && ok "RED-b: PR promoted from draft to ready (gh pr ready called)" \
  || ko "RED-b: PR was NOT promoted from draft (gh pr ready missing)"

# Charter #5 must remain OPEN (loop doesn't close it — only human does)
[ "$(issue_state 5)" = "OPEN" ] \
  && ok "RED-b: charter #5 remains OPEN (human closes after merge)" \
  || ko "RED-b: charter #5 was closed by loop (must not happen)"

has_comment 5 "human review" \
  && ok "RED-b: comment on charter #5 mentions human review" \
  || ko "RED-b: no human-review comment on charter #5"

# =============================================================================
# RED-c: idempotency — second tick with existing PR does NOT create a duplicate
# =============================================================================
echo "== RED-c: idempotency — second run does not duplicate the PR =="

CBHOME_C="$ROOT/cbhome_c"
reset_sandbox "$CBHOME_C"
printf '%s' "$FINALE_BOARD" > "$BOARD_STATE"
printf 'success' > "$PRDIR/charter-checks-5"

# First run: creates the PR
run_finale "$CBHOME_C" "CB_HARNESS=\"$GREEN_HARNESS\""

# Count how many pr-create calls happened after first run
create_count_1=$(grep -c "pr-create charter/5" "$GH_LOG" 2>/dev/null || echo 0)

# Second run: must find existing PR and NOT create another
run_finale "$CBHOME_C" "CB_HARNESS=\"$GREEN_HARNESS\""

create_count_2=$(grep -c "pr-create charter/5" "$GH_LOG" 2>/dev/null || echo 0)

[ "$create_count_1" -ge 1 ] \
  && ok "RED-c: first run created the PR (count=$create_count_1)" \
  || ko "RED-c: first run did NOT create a PR"

[ "$create_count_2" -eq "$create_count_1" ] \
  && ok "RED-c: second run did NOT create a duplicate PR (count unchanged=$create_count_2)" \
  || ko "RED-c: second run created a DUPLICATE PR (count grew from $create_count_1 to $create_count_2)"

# =============================================================================
# RED-d: gate green, CI failure → PR stays draft + comment on charter
# =============================================================================
echo "== RED-d: CI failure → PR stays draft, NOT promoted, comment on charter =="

CBHOME_D="$ROOT/cbhome_d"
reset_sandbox "$CBHOME_D"
printf '%s' "$FINALE_BOARD" > "$BOARD_STATE"
# Pre-set CI stub: failure for charter 5's PR
printf 'failure' > "$PRDIR/charter-checks-5"

run_finale "$CBHOME_D" "CB_HARNESS=\"$GREEN_HARNESS\""

charter_pr_created \
  && ok "RED-d: draft PR was created" \
  || ko "RED-d: draft PR was NOT created"

charter_pr_ready \
  && ko "RED-d: PR was promoted to ready despite CI failure (should stay draft)" \
  || ok "RED-d: PR correctly stays draft (not promoted)"

has_comment 5 "failed\|CI failed" \
  && ok "RED-d: comment on charter #5 mentions CI failure reason" \
  || ko "RED-d: no CI-failure comment on charter #5"

# =============================================================================
# RED-e: anti-deadlock — gh pr checks must NOT be called before gh pr create
# =============================================================================
echo "== RED-e: anti-deadlock — no CB_HARNESS; pr checks only after pr create =="

CBHOME_E="$ROOT/cbhome_e"
reset_sandbox "$CBHOME_E"
printf '%s' "$FINALE_BOARD" > "$BOARD_STATE"
# No CB_HARNESS set (default = marker-grep only)
# No markers in any files → gate passes
# CI checks can fail — we don't care about CI outcome for this test
# (PR creation order is what matters)

run_finale "$CBHOME_E"  # no CB_HARNESS

# Assert: draft PR was created (gate passed with just marker-grep)
charter_pr_created \
  && ok "RED-e: draft PR created (marker-grep only gate passed)" \
  || ko "RED-e: draft PR was NOT created (gate failed unexpectedly?)"

# Assert: NO anti-deadlock error in log (means pr checks was never called before pr create)
ghlog_has "ERROR-anti-deadlock" \
  && ko "RED-e: anti-deadlock error! pr checks was called before pr create" \
  || ok "RED-e: no anti-deadlock violation (pr checks not called before pr create)"

# Assert: call order — pr-create precedes first pr-checks in GH_LOG
create_line=$(ghlog_first_of "pr-create charter/5")
checks_line=$(ghlog_first_of "pr-checks")
if [ -n "$create_line" ] && [ -n "$checks_line" ] && [ "$create_line" -lt "$checks_line" ]; then
  ok "RED-e: pr-create (line $create_line) strictly before pr-checks (line $checks_line)"
elif [ -n "$create_line" ] && [ -z "$checks_line" ]; then
  # pr create happened but no pr checks (e.g. CI check path skipped) — still ok for anti-deadlock
  ok "RED-e: pr-create happened and pr-checks was never called before it"
else
  ko "RED-e: call order wrong — create_line='$create_line' checks_line='$checks_line'"
fi

# =============================================================================
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
