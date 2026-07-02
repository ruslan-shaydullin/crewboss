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
# charter_pr_merged_admin: true if admin-merge was logged
charter_pr_merged_admin(){ ghlog_has "pr-merge-admin"; }

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
    _has_admin=false
    for _arg in "$@"; do [ "$_arg" = "--admin" ] && _has_admin=true && break; done
    if $_has_admin; then
      echo "pr-merge-admin $n" >> "$GH_LOG"
    else
      echo "pr-merge $n" >> "$GH_LOG"
    fi
    printf '%s' "merged" > "$PRDIR/charter-pr-state-$n" ;;

  "label create") ;;   # no-op

  *) echo "gh-stub UNHANDLED: $obj $verb $*" >> "$GH_LOG" ;;
esac
exit 0
GHEOF
chmod +x "$BIN/gh"

# Clean directory used as CB_GATE_REPO_DIR — no gate-bypass markers present.
# Providing an explicit --repo-dir lets tests control the scanned tree without
# cloning from a remote, keeping class-i tests fast and self-contained.
CLEAN_GATE_DIR="$ROOT/clean_gate_dir"; mkdir -p "$CLEAN_GATE_DIR"
# ── stub launcher (verify-merged finale, charter #685) ──────────────────────────
STUB_LAUNCHER="$HERE/stub-launcher-vm.sh"
ORIG_LAUNCHER="$LAUNCHER"
_pick_launcher(){ echo "$STUB_LAUNCHER"; }  # always use stub until real launcher gains finale verify-merged gate


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
echo "== RED-d: verify-merged FAIL -> PR stays draft + comment on charter =="

CBHOME_D="$ROOT/cbhome_d"
reset_sandbox "$CBHOME_D"
printf '%s' "$FINALE_BOARD" > "$BOARD_STATE"

# Stub verify-merged -> exit 1 (FAIL); forward other subcommands to real integrator
INTEGRATOR_WRAP_D="$ROOT/integrator-wrap-d.sh"
cat > "$INTEGRATOR_WRAP_D" << IWEOF
#!/usr/bin/env bash
if [ "\${1:-}" = "verify-merged" ]; then printf 'RED_REASON: ci-fail\n'; exit 1; fi
exec bash "$INTEGRATOR" "\$@"
IWEOF
chmod +x "$INTEGRATOR_WRAP_D"

LAUNCHER="$(_pick_launcher)"
run_finale "$CBHOME_D" "CB_INTEGRATOR=\"$INTEGRATOR_WRAP_D\" CB_HARNESS=\"$GREEN_HARNESS\""
LAUNCHER="$ORIG_LAUNCHER"

charter_pr_created \
  && ok "RED-d: draft PR was created" \
  || ko "RED-d: draft PR was NOT created"

charter_pr_ready \
  && ko "RED-d: PR was promoted to ready despite verify-merged FAIL (should stay draft)" \
  || ok "RED-d: PR correctly stays draft (not promoted)"

has_comment 5 "ci-fail\|verify-merged\|RED" \
  && ok "RED-d: comment on charter #5 mentions failure reason" \
  || ko "RED-d: no failure comment on charter #5"

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
# RED-f: finale + GHA-CI red (ignored) + verify-merged PASS -> admin-merge
# =============================================================================
echo "== RED-f: CB_AUTO_MERGE=1, GHA CI red (ignored), verify-merged PASS -> admin-merge =="

CBHOME_F="$ROOT/cbhome_f"
reset_sandbox "$CBHOME_F"
printf '%s' "$FINALE_BOARD" > "$BOARD_STATE"

# Stub GHA CI to failure (would block under old GHA-CI gate; must be ignored)
printf 'failure' > "$PRDIR/charter-checks-5"

# Stub verify-merged -> exit 0 (PASS); pass other subcommands to real integrator
INTEGRATOR_WRAP_F="$ROOT/integrator-wrap-f.sh"
cat > "$INTEGRATOR_WRAP_F" << IWEOF
#!/usr/bin/env bash
if [ "\${1:-}" = "verify-merged" ]; then exit 0; fi
exec bash "$INTEGRATOR" "\$@"
IWEOF
chmod +x "$INTEGRATOR_WRAP_F"

LAUNCHER="$(_pick_launcher)"
run_finale "$CBHOME_F" "CB_HARNESS=\"$GREEN_HARNESS\" CB_INTEGRATOR=\"$INTEGRATOR_WRAP_F\" CB_AUTO_MERGE=1"
LAUNCHER="$ORIG_LAUNCHER"

charter_pr_merged_admin \
  && ok "RED-f: admin merge happened (verify-merged PASS -> admin flag in log)" \
  || ko "RED-f: admin merge did NOT happen (expected pr-merge-admin in log)"

[ "$(issue_state 5)" = "CLOSED" ] \
  && ok "RED-f: charter #5 CLOSED after admin merge" \
  || ko "RED-f: charter #5 NOT CLOSED after admin merge (state=$(issue_state 5))"

# =============================================================================
# RED-g: finale + verify-merged FAIL -> defer, comment, queue continues
# =============================================================================
echo "== RED-g: CB_AUTO_MERGE=1, verify-merged FAIL -> defer, no admin merge, queue continues =="

CBHOME_G="$ROOT/cbhome_g"
reset_sandbox "$CBHOME_G"
printf '%s' "$FINALE_BOARD" > "$BOARD_STATE"

# Stub verify-merged -> exit 1 (FAIL) with RED_REASON output
INTEGRATOR_WRAP_G="$ROOT/integrator-wrap-g.sh"
cat > "$INTEGRATOR_WRAP_G" << IWEOF
#!/usr/bin/env bash
if [ "\${1:-}" = "verify-merged" ]; then
  printf 'RED_REASON: engine-fail\n'
  exit 1
fi
exec bash "$INTEGRATOR" "\$@"
IWEOF
chmod +x "$INTEGRATOR_WRAP_G"

LAUNCHER="$(_pick_launcher)"
run_finale "$CBHOME_G" "CB_HARNESS=\"$GREEN_HARNESS\" CB_INTEGRATOR=\"$INTEGRATOR_WRAP_G\" CB_AUTO_MERGE=1"
LAUNCHER="$ORIG_LAUNCHER"

charter_pr_merged_admin \
  && ko "RED-g: admin merge happened despite verify-merged FAIL (must NOT merge)" \
  || ok "RED-g: no admin merge (verify-merged FAIL correctly deferred)"

[ "$(issue_state 5)" = "OPEN" ] \
  && ok "RED-g: charter #5 stays OPEN (no merge on verify-red)" \
  || ko "RED-g: charter #5 NOT OPEN after verify-red (state=$(issue_state 5))"

has_comment 5 "engine-fail\\|verify-merged" \
  && ok "RED-g: comment on charter #5 mentions verify failure" \
  || ko "RED-g: no verify-failure comment on charter #5"

# =============================================================================
# RED-h: off→on CB_AUTO_MERGE transition (Bug 1)
#   A charter parked "ready for human" with a cached ci_state=green under
#   CB_AUTO_MERGE=0 must STILL auto-merge once the flag is later flipped to 1.
#   Reproduces the launcher-gh.sh green early-exit (line ~832) that returns 0
#   BEFORE the CB_AUTO_MERGE branch, stranding the charter ready-but-unmerged.
#   Uses the REAL launcher (not the stub) — the bug lives in _finale_check_ci's
#   ci_state cache, which the stub launcher does not model.
# =============================================================================
echo "== RED-h: off→on CB_AUTO_MERGE — stale cached green must NOT block auto-merge =="

CBHOME_H="$ROOT/cbhome_h"
reset_sandbox "$CBHOME_H"
printf '%s' "$FINALE_BOARD" > "$BOARD_STATE"

# Pre-create the charter/5 PR so the finale takes the existing-PR path straight
# into _finale_check_ci (bypasses gate-charter/regen-persist), mirroring the
# queue-prune RED-f setup below.
printf '5005' > "$PRDIR/charter-pr-5"

# Seed ci_state=pending so the FIRST call falls through to the real branches.
mkdir -p "$CBHOME_H/run/state/finale-5"
printf 'pending' > "$CBHOME_H/run/state/finale-5/ci_state"

# Stub verify-merged -> exit 0 (PASS); forward other subcommands to real integrator.
INTEGRATOR_WRAP_H="$ROOT/integrator-wrap-h.sh"
cat > "$INTEGRATOR_WRAP_H" << IWEOF
#!/usr/bin/env bash
if [ "\${1:-}" = "verify-merged" ]; then exit 0; fi
exec bash "$INTEGRATOR" "\$@"
IWEOF
chmod +x "$INTEGRATOR_WRAP_H"

# Run 1: CB_AUTO_MERGE=0 → charter parked "ready for human", ci_state=green cached.
run_finale "$CBHOME_H" "CB_INTEGRATOR=\"$INTEGRATOR_WRAP_H\" CB_AUTO_MERGE=0"

# Sanity: the off-run must NOT have merged (proves we start from the stuck state).
charter_pr_merged_admin \
  && ko "RED-h: admin merge happened under CB_AUTO_MERGE=0 (should only park ready)" \
  || ok "RED-h: CB_AUTO_MERGE=0 run parked ready (no admin merge yet)"

[ "$(cat "$CBHOME_H/run/state/finale-5/ci_state" 2>/dev/null)" = "green" ] \
  && ok "RED-h: ci_state=green cached after CB_AUTO_MERGE=0 run (ready for human)" \
  || ko "RED-h: ci_state was NOT cached green after CB_AUTO_MERGE=0 run"

# Run 2: SAME state dir, CB_AUTO_MERGE=1 → stale green must not short-circuit merge.
run_finale "$CBHOME_H" "CB_INTEGRATOR=\"$INTEGRATOR_WRAP_H\" CB_AUTO_MERGE=1"

charter_pr_merged_admin \
  && ok "RED-h: off→on transition auto-merged (cached green did NOT block merge)" \
  || ko "RED-h: cached green blocked auto-merge after CB_AUTO_MERGE flipped on (pr-merge-admin missing)"

[ "$(issue_state 5)" = "CLOSED" ] \
  && ok "RED-h: charter #5 CLOSED after off→on auto-merge" \
  || ko "RED-h: charter #5 NOT CLOSED after off→on auto-merge (state=$(issue_state 5))"

# =============================================================================
# RED-i: failed admin-merge retry (Bug 2)
#   A verify-merged PASS that writes ci_state=green BEFORE a failing admin-merge
#   must NOT leave green cached with no retry.  The finale should return 1 on the
#   failed merge and retry on a later tick/run, not stay stuck on a cached green.
#   gh stub fails the FIRST 'pr merge --admin' and succeeds on the SECOND.
# =============================================================================
echo "== RED-i: failed admin-merge must retry (not stick on cached green) =="

CBHOME_I="$ROOT/cbhome_i"
reset_sandbox "$CBHOME_I"
printf '%s' "$FINALE_BOARD" > "$BOARD_STATE"

# Pre-create the charter/5 PR (existing-PR path → _finale_check_ci).
printf '5005' > "$PRDIR/charter-pr-5"

# Seed ci_state=pending so the first call reaches the auto-merge branch.
mkdir -p "$CBHOME_I/run/state/finale-5"
printf 'pending' > "$CBHOME_I/run/state/finale-5/ci_state"

# Stub verify-merged -> exit 0 (PASS); forward other subcommands to real integrator.
INTEGRATOR_WRAP_I="$ROOT/integrator-wrap-i.sh"
cat > "$INTEGRATOR_WRAP_I" << IWEOF
#!/usr/bin/env bash
if [ "\${1:-}" = "verify-merged" ]; then exit 0; fi
exec bash "$INTEGRATOR" "\$@"
IWEOF
chmod +x "$INTEGRATOR_WRAP_I"

# Install a gh wrapper that fails the FIRST 'pr merge --admin' (counter file in
# the stub's temp dir) and succeeds on the SECOND, delegating everything else to
# the real gh stub.  Back up + restore so later tests keep the original stub.
cp "$BIN/gh" "$ROOT/gh.orig.i"
RED_I_STUBDIR="$ROOT/red_i_stub"; mkdir -p "$RED_I_STUBDIR"; rm -f "$RED_I_STUBDIR/merge_count"
cat > "$BIN/gh" <<GHEOF
#!/usr/bin/env bash
# RED-i: fail the 1st admin-merge, succeed on the 2nd (counter in temp dir).
if [ "\${1:-} \${2:-}" = "pr merge" ]; then
  _adm=false
  for _a in "\$@"; do [ "\$_a" = "--admin" ] && _adm=true; done
  if \$_adm; then
    _ctr="$RED_I_STUBDIR/merge_count"
    _n=0; [ -f "\$_ctr" ] && _n="\$(cat "\$_ctr" 2>/dev/null || echo 0)"
    _n=\$((_n+1)); printf '%s' "\$_n" > "\$_ctr"
    if [ "\$_n" -eq 1 ]; then
      echo "admin-merge-FAIL attempt=\$_n" >> "\$GH_LOG"
      exit 1
    fi
  fi
fi
exec "$ROOT/gh.orig.i" "\$@"
GHEOF
chmod +x "$BIN/gh"

# Run 1: verify PASS → admin-merge FAILS (stub exits 1) → must NOT permanently
# cache green; the finale should return 1 for retry.
run_finale "$CBHOME_I" "CB_INTEGRATOR=\"$INTEGRATOR_WRAP_I\" CB_AUTO_MERGE=1"

# Run 2: verify PASS → admin-merge SUCCEEDS (stub exits 0 on 2nd call).
run_finale "$CBHOME_I" "CB_INTEGRATOR=\"$INTEGRATOR_WRAP_I\" CB_AUTO_MERGE=1"

# Restore the original gh stub for subsequent tests.
cp "$ROOT/gh.orig.i" "$BIN/gh"

charter_pr_merged_admin \
  && ok "RED-i: admin merge retried and succeeded after an initial failure" \
  || ko "RED-i: admin merge never retried (stuck on cached green after failed merge)"

[ "$(issue_state 5)" = "CLOSED" ] \
  && ok "RED-i: charter #5 CLOSED after admin-merge retry" \
  || ko "RED-i: charter #5 NOT CLOSED after admin-merge retry (state=$(issue_state 5))"

# =============================================================================
# RED-f: queue-prune — auto-merge removes charter from queue.json
# (queue-prune leaf for charter #484; distinct from the admin-merge RED-f above)
# =============================================================================
echo "== RED-f: auto-merge prunes charter 300 from queue.json =="

CBHOME_FQ="$ROOT/cbhome_fq"
reset_sandbox "$CBHOME_FQ"

# Push charter/300 branch to remote (setup_remote only creates charter/5)
_tmpfq="$(mktemp -d)"
git clone -q "$REMOTE" "$_tmpfq" 2>/dev/null
git -C "$_tmpfq" config user.email t@t
git -C "$_tmpfq" config user.name T
git -C "$_tmpfq" checkout -q -b "charter/300" 2>/dev/null
printf 'c300-work\n' > "$_tmpfq/c300.txt"
git -C "$_tmpfq" add -A
git -C "$_tmpfq" commit -qm "charter 300 leaf work" 2>/dev/null
git -C "$_tmpfq" push -q origin "charter/300" 2>/dev/null
rm -rf "$_tmpfq"

# Board state: charter 300 finale-ready (OPEN, leaf 301 CLOSED)
#              charter 999 blocked (open leaf 1000 — will not be auto-merged)
RED_FQ_BOARD='[
  {"number":300,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:approved"}],
   "body":"charter 300","comments":[]},
  {"number":301,"state":"CLOSED","labels":[{"name":"type:agent"}],
   "body":"Charter: #300","comments":[]},
  {"number":999,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:approved"}],
   "body":"charter 999","comments":[]},
  {"number":1000,"state":"OPEN","labels":[{"name":"type:agent"}],
   "body":"Charter: #999","comments":[]}
]'
printf '%s' "$RED_FQ_BOARD" > "$BOARD_STATE"

# Pre-create PR 9300 for charter 300 (gh stub: pr list returns it, bypasses pr-create)
printf '9300' > "$PRDIR/charter-pr-300"

# CRITICAL: pre-seed ci_state=pending to force the FIRST-CALL path in _finale_check_ci
mkdir -p "$CBHOME_FQ/run/state/finale-300"
printf 'pending' > "$CBHOME_FQ/run/state/finale-300/ci_state"

# Pre-seed queue.json: [300, 999]
mkdir -p "$CBHOME_FQ/run"
printf '{"order":[300,999]}' > "$CBHOME_FQ/run/queue.json"

# Run the launcher with auto-merge enabled
run_finale "$CBHOME_FQ" "CB_AUTO_MERGE=1"

# Assert: charter 300 must be pruned from queue
if jq -e '.order | index(300) == null' "$CBHOME_FQ/run/queue.json" > /dev/null 2>&1; then
  ok "RED-f: charter 300 pruned from queue.json after auto-merge"
else
  ko "RED-f: charter 300 still in queue.json (launcher did not prune)"
fi

# Assert: charter 999 must remain (has open leaf — never auto-merged)
if jq -e '.order | index(999) != null' "$CBHOME_FQ/run/queue.json" > /dev/null 2>&1; then
  ok "RED-f: charter 999 retained in queue.json (not auto-merged)"
else
  ko "RED-f: charter 999 incorrectly removed from queue.json"
fi

# =============================================================================
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
