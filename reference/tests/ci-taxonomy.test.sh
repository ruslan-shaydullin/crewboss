#!/usr/bin/env bash
# ci-taxonomy.test.sh — CI classification and try-merge exit-code taxonomy (issue #112).
# Class i + ii tests:
#
#   RED-a: empty CI rollup → status:blocked after CB_CI_EMPTY_TICKS ticks
#          ДО фикса: :140 (old) — вечный pending, лист молча висит в review
#   RED-b: StatusContext node (.state="SUCCESS") → classified as success → PR merged
#          ДО фикса: :143 (old) — SUCCESS-статус даёт вечный pending
#   RED-c: unit try-merge, --remote /nonexistent → exit code EXACTLY 2
#          ДО фикса: clone-провал даёт exit 1, неотличим от конфликта
#   RED-d: valid PR + green CI + broken CB_GIT_REMOTE → leaf stays status:review, NOT needs-rework
#          ДО фикса: инфра-провал роутится в needs-rework
#   RED-e: gh pr view fails N ticks (N > CB_CI_EMPTY_TICKS) → leaf NOT blocked, stays review
#          ДО фикса: gh-ошибка фабрикует пустой rollup, инкрементит счётчик, уводит в blocked
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
has_label(){ [ "$(jq -r --argjson n "$1" 'map(select(.number==$n))[0].labels[]?.name' \
                 "$BOARD_STATE" | grep -c "^$2$")" -ge 1 ]; }
no_label(){  ! has_label "$1" "$2"; }
issue_state(){ jq -r --argjson n "$1" 'map(select(.number==$n))[0].state' "$BOARD_STATE"; }
has_comment(){ jq -r --argjson n "$1" 'map(select(.number==$n))[0].comments[]?.body' \
                 "$BOARD_STATE" | grep -qi "$2"; }
pr_merged(){     [ -f "$PRDIR/merged-$1" ]; }
pr_not_merged(){ [ ! -f "$PRDIR/merged-$1" ]; }
ghlog_has(){ grep -q "$1" "$GH_LOG" 2>/dev/null; }

# ── git remote setup ─────────────────────────────────────────────────────────
# Creates bare remote with main, charter/5, and leaf/10-1700000000 branches.
setup_remote(){
  rm -rf "$REMOTE"; git init --bare -q "$REMOTE"
  local tmp; tmp="$(mktemp -d)"
  git clone -q "$REMOTE" "$tmp" 2>/dev/null
  git -C "$tmp" config user.email t@t; git -C "$tmp" config user.name T
  printf 'base\n' > "$tmp/README.md"
  git -C "$tmp" add -A; git -C "$tmp" commit -qm "init" 2>/dev/null
  git -C "$tmp" branch -M main 2>/dev/null || true
  git -C "$tmp" push -q origin HEAD:refs/heads/main 2>/dev/null
  # charter/5 branch (target for leaf PR)
  git -C "$tmp" checkout -q -b "charter/5" 2>/dev/null
  printf 'charter-work\n' >> "$tmp/README.md"
  git -C "$tmp" add -A; git -C "$tmp" commit -qm "charter/5 base" 2>/dev/null
  git -C "$tmp" push -q origin "charter/5" 2>/dev/null
  # leaf/10-1700000000 branch (PR head for issue #10)
  git -C "$tmp" checkout -q "origin/charter/5" -b "leaf/10-1700000000" 2>/dev/null
  printf 'leaf work for #10\n' > "$tmp/work-10.txt"
  git -C "$tmp" add -A; git -C "$tmp" commit -qm "leaf #10 work" 2>/dev/null
  git -C "$tmp" push -q origin "leaf/10-1700000000" 2>/dev/null
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
  # Pre-create PR #10: headRefName=leaf/10-1700000000, base=charter/5
  touch "$PRDIR/10"
  printf 'charter/5'          > "$PRDIR/base-10"
  printf 'leaf/10-1700000000' > "$PRDIR/head-10"
}

# Board: #10 already in status:review so the integrator processes it immediately
# (no spawn cycle needed).
REVIEW_BOARD='[
  {"number":5,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],
   "body":"the charter","comments":[]},
  {"number":10,"state":"OPEN","labels":[{"name":"type:agent"},{"name":"status:review"}],
   "body":"task A\nCharter: #5\n## Acceptance (machine)\n- check: true","comments":[]}
]'

# ── gh stub (extended for ci-taxonomy scenarios) ─────────────────────────────
# pr view --json statusCheckRollup reads $PRDIR/checks-$n:
#   success                 → CheckRun SUCCESS
#   failure                 → CheckRun FAILURE
#   pending                 → CheckRun IN_PROGRESS
#   empty                   → empty array [] (no CI checks registered)
#   status_context_success  → StatusContext {"state":"SUCCESS"} (legacy commit-status API)
#   gh_error                → exit 1 (simulate gh infra failure; logs to GH_LOG)
#   (anything else / absent)→ success (default)
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
          success)
            printf '{"statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}]}\n' ;;
          failure)
            printf '{"statusCheckRollup":[{"conclusion":"FAILURE","status":"COMPLETED"}]}\n' ;;
          pending)
            printf '{"statusCheckRollup":[{"conclusion":null,"status":"IN_PROGRESS"}]}\n' ;;
          empty)
            # Real gh response when no CI checks are registered on the PR
            printf '{"statusCheckRollup":[]}\n' ;;
          status_context_success)
            # Legacy GitHub commit-status API: StatusContext node with .state field
            printf '{"statusCheckRollup":[{"state":"SUCCESS"}]}\n' ;;
          gh_error)
            # Simulate a gh infra failure (network, token, etc.)
            echo "gh-error-rollup-$n" >> "$GH_LOG"
            exit 1 ;;
          *)
            printf '{"statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}]}\n' ;;
        esac ;;
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

  "label create") ;;   # no-op

  *) echo "gh-stub UNHANDLED: $obj $verb $*" >> "$GH_LOG" ;;
esac
exit 0
GHEOF
chmod +x "$BIN/gh"

# ── loop runner ───────────────────────────────────────────────────────────────
# extra_env overrides base settings (last assignment wins in eval'd env).
run_loop(){
  local cbhome="${1:-$ROOT/cbhome_default}"
  local extra_env="${2:-}"
  eval "PATH=\"$BIN:$PATH\" \
    CB_REPO=\"test/repo\" \
    CB_HOME=\"$cbhome\" \
    CB_GIT_REMOTE=\"$REMOTE\" \
    CB_INTEGRATOR=\"$INTEGRATOR\" \
    CB_POLL=0 \
    CB_MAX_TICKS=40 \
    CB_IDLE_CONFIRM=2 \
    CB_MAX_PARALLEL=2 \
    CB_RETRY_CAP=3 \
    $extra_env \
    bash \"$LAUNCHER\" run 2>/dev/null"
}

# =============================================================================
# RED-c (unit, class ii): try-merge with broken --remote → exit code EXACTLY 2
# =============================================================================
echo "== RED-c: try-merge infra error (broken remote) → exit 2 =="

BROKEN_REMOTE="$ROOT/does_not_exist_xyz"
try_exit_c=0
bash "$INTEGRATOR" try-merge "leaf/10-1700000000" "charter/5" \
     --remote "$BROKEN_REMOTE" 2>/dev/null || try_exit_c=$?

[ "$try_exit_c" -eq 2 ] \
  && ok "RED-c: try-merge broken remote → exit 2 (infra, not conflict)" \
  || ko "RED-c: expected exit 2, got $try_exit_c (was exit 1 before fix — indistinguishable from conflict)"

# Also verify that a real conflict still exits 1 (no regression)
REMOTE_C="$ROOT/remote_c.git"
git init --bare -q "$REMOTE_C"
_tc="$(mktemp -d)"
git clone -q "$REMOTE_C" "$_tc" 2>/dev/null
git -C "$_tc" config user.email t@t; git -C "$_tc" config user.name T
printf 'original\n' > "$_tc/shared.txt"
git -C "$_tc" add -A; git -C "$_tc" commit -qm "init" 2>/dev/null
git -C "$_tc" branch -M main 2>/dev/null || true
git -C "$_tc" push -q origin HEAD:refs/heads/main 2>/dev/null
_pre_sha="$(git -C "$_tc" rev-parse HEAD)"
git -C "$_tc" checkout -q -b "branch-a" 2>/dev/null
printf 'version-a\n' > "$_tc/shared.txt"
git -C "$_tc" add -A; git -C "$_tc" commit -qm "branch-a" 2>/dev/null
git -C "$_tc" push -q origin branch-a 2>/dev/null
git -C "$_tc" checkout -q main 2>/dev/null
git -C "$_tc" merge --no-ff branch-a -m "merge-a" >/dev/null 2>&1
git -C "$_tc" push -q origin main 2>/dev/null
git -C "$_tc" checkout -q -b "branch-b" "$_pre_sha" 2>/dev/null
printf 'version-b\n' > "$_tc/shared.txt"
git -C "$_tc" add -A; git -C "$_tc" commit -qm "branch-b" 2>/dev/null
git -C "$_tc" push -q origin branch-b 2>/dev/null
rm -rf "$_tc"

try_exit_conflict=0
bash "$INTEGRATOR" try-merge "branch-b" "main" --remote "$REMOTE_C" 2>/dev/null \
  || try_exit_conflict=$?
[ "$try_exit_conflict" -eq 1 ] \
  && ok "RED-c: real conflict still exits 1 (no regression)" \
  || ko "RED-c: real conflict exited $try_exit_conflict instead of 1"

# =============================================================================
# RED-a: empty CI rollup → status:blocked after CB_CI_EMPTY_TICKS ticks
# =============================================================================
echo "== RED-a: empty CI rollup policy — status:blocked after CB_CI_EMPTY_TICKS=2 ticks =="

CBHOME_A="$ROOT/cbhome_a"
reset_sandbox "$CBHOME_A"
printf '%s' "$REVIEW_BOARD" > "$BOARD_STATE"
# Activate the "empty rollup" branch of the stub (real gh response when no CI is configured)
printf 'empty' > "$PRDIR/checks-10"

# CB_CI_EMPTY_TICKS=2: after 2 ticks of empty rollup, leaf must be blocked.
# CB_IDLE_CONFIRM=2 is enough: tick-1 → ci_empty=1 (wait), tick-2 → ci_empty=2 (block+exit).
run_loop "$CBHOME_A" "CB_CI_EMPTY_TICKS=2"

has_label 10 "status:blocked" \
  && ok "RED-a: leaf #10 in status:blocked after empty rollup (≥CB_CI_EMPTY_TICKS=2 ticks)" \
  || ko "RED-a: leaf #10 NOT blocked — before fix loop hung forever in review with empty rollup"

has_comment 10 "нет CI" \
  && ok "RED-a: comment on #10 contains 'нет CI'" \
  || ko "RED-a: no 'нет CI' comment on #10 (blocked but human not notified?)"

pr_not_merged 10 \
  && ok "RED-a: PR #10 NOT merged (empty rollup must never trigger merge)" \
  || ko "RED-a: PR #10 was merged — empty rollup must not equal green"

[ "$(issue_state 10)" != "CLOSED" ] \
  && ok "RED-a: leaf #10 NOT closed (only human closes after blocking)" \
  || ko "RED-a: leaf #10 was closed (must not happen)"

# =============================================================================
# RED-b: StatusContext node (.state="SUCCESS") → classified as success → PR merged
# =============================================================================
echo "== RED-b: StatusContext .state=SUCCESS → success → PR merged =="

CBHOME_B="$ROOT/cbhome_b"
reset_sandbox "$CBHOME_B"
printf '%s' "$REVIEW_BOARD" > "$BOARD_STATE"
# Legacy GitHub commit-status: StatusContext with .state="SUCCESS" (no .status/.conclusion)
printf 'status_context_success' > "$PRDIR/checks-10"

run_loop "$CBHOME_B" ""

[ "$(issue_state 10)" = "CLOSED" ] \
  && ok "RED-b: leaf #10 CLOSED — StatusContext SUCCESS correctly triggered merge" \
  || ko "RED-b: leaf #10 NOT closed — before fix, StatusContext SUCCESS was classified as pending forever"

pr_merged 10 \
  && ok "RED-b: PR #10 merged (StatusContext SUCCESS = green)" \
  || ko "RED-b: PR #10 NOT merged — StatusContext SUCCESS should have triggered merge"

# =============================================================================
# RED-d: broken GIT_REMOTE → try-merge infra error (exit 2) → leaf stays review
# =============================================================================
echo "== RED-d: broken CB_GIT_REMOTE → leaf stays status:review, NOT needs-rework =="

CBHOME_D="$ROOT/cbhome_d"
reset_sandbox "$CBHOME_D"
printf '%s' "$REVIEW_BOARD" > "$BOARD_STATE"
# CI is green — the only failure is the broken remote (infra, not a real conflict)
printf 'success' > "$PRDIR/checks-10"

BROKEN_D="$ROOT/broken_remote_d"
# CB_GIT_REMOTE overrides the base REMOTE set in run_loop (last assignment wins in eval)
run_loop "$CBHOME_D" "CB_GIT_REMOTE=\"$BROKEN_D\""

has_label 10 "status:review" \
  && ok "RED-d: leaf #10 still in status:review (infra error → retry, not rework)" \
  || ko "RED-d: leaf #10 NOT in status:review"

no_label 10 "status:needs-rework" \
  && ok "RED-d: leaf #10 NOT in status:needs-rework (infra ≠ conflict)" \
  || ko "RED-d: leaf #10 was routed to needs-rework — before fix, exit-2 was treated as conflict"

has_comment 10 "Merge conflict" \
  && ko "RED-d: 'Merge conflict' comment on #10 — infra error must not generate conflict comment" \
  || ok "RED-d: no 'Merge conflict' comment on #10 (correct)"

pr_not_merged 10 \
  && ok "RED-d: PR #10 NOT merged (broken remote, expected)" \
  || ko "RED-d: PR #10 merged despite broken remote"

# =============================================================================
# RED-e: gh pr view infra failures NOT counted as empty rollup (F3-c / point 3)
# =============================================================================
echo "== RED-e: gh pr view failures NOT counted as empty-rollup ticks → leaf NOT blocked =="

CBHOME_E="$ROOT/cbhome_e"
reset_sandbox "$CBHOME_E"
printf '%s' "$REVIEW_BOARD" > "$BOARD_STATE"
# gh stub: exit 1 on every statusCheckRollup call for PR #10 (simulate infra flap)
printf 'gh_error' > "$PRDIR/checks-10"

# CB_CI_EMPTY_TICKS=2: threshold is 2 empty-rollup ticks.
# CB_IDLE_CONFIRM=6: loop runs 6 ticks → 6 gh errors >> 2 empty-rollup limit.
# Despite 6 errors exceeding the limit, the leaf must NOT be blocked:
# gh-errors must NOT increment the empty-rollup counter (point 3 of spec).
run_loop "$CBHOME_E" "CB_CI_EMPTY_TICKS=2 CB_IDLE_CONFIRM=6"

no_label 10 "status:blocked" \
  && ok "RED-e: leaf #10 NOT blocked — gh errors do NOT count as empty rollup" \
  || ko "RED-e: leaf #10 was blocked — before fix, gh errors fabricated empty rollup and incremented counter"

has_label 10 "status:review" \
  && ok "RED-e: leaf #10 still in status:review" \
  || ko "RED-e: leaf #10 not in status:review"

ghlog_has "gh-error-rollup-10" \
  && ok "RED-e: gh-error-rollup entries in log (infra errors logged as retry, not empty)" \
  || ko "RED-e: no gh-error-rollup entries in log (infra errors should be logged)"

pr_not_merged 10 \
  && ok "RED-e: PR #10 NOT merged (CI unreadable)" \
  || ko "RED-e: PR #10 merged despite gh errors reading CI"

# =============================================================================
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
