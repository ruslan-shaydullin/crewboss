#!/usr/bin/env bash
# ci-taxonomy.test.sh — CI classification and try-merge exit-code taxonomy (issue #112).
# Class i + ii tests:
#
#   RED-b (box-verdict): empty statusCheckRollup + box verify-merged pass → PR merged
#          (#176 Ф-A: statusCheckRollup больше не читается; зелёность = engine на merged-дереве)
#   RED-c: unit try-merge, --remote /nonexistent → exit code EXACTLY 2
#          ДО фикса: clone-провал даёт exit 1, неотличим от конфликта
#   RED-d: broken CB_GIT_REMOTE → try-merge infra error (exit 2) → leaf stays status:review, NOT needs-rework
#          ДО фикса: инфра-провал роутится в needs-rework
#
# RED-a (empty rollup → blocked) и RED-e (gh-error → not-blocked) убраны как obsolete (#176):
#   после Ф-A петля не читает statusCheckRollup; путь empty-rollup→blocked отсутствует;
#   verify-merged всегда даёт детерминированный вердикт (находка #6 закрыта).
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

# ── gh stub (ci-taxonomy scenarios) ──────────────────────────────────────────
# pr view --json statusCheckRollup always returns EMPTY array [] (anti-фальш, #176):
#   петля больше не читает statusCheckRollup; зелёность от verify-merged (box-вердикт).
#   Пустой rollup гарантирует, что слияние идёт от box-вердикта, не от GHA.
#
# gh_error flag in $PRDIR/checks-$n: → exit 1 on statusCheckRollup (retained for RED-d
#   broken-remote scenario where the loop never reaches statusCheckRollup anyway).
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
        # Anti-фальш (#176): always return EMPTY rollup — loop no longer reads it.
        # Merge decision comes from verify-merged (box-verdict), not GHA.
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
    CREWBOSS_CHARTER= \
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
# RED-b (box-verdict, class 1): empty statusCheckRollup + verify-merged pass → PR merged
# (#176 Ф-A: петля не читает rollup; зелёность = engine на merged-дереве; пустой rollup антифальш)
# leaf-ветка несёт только work-10.txt (без reference/tests/) → merged-дерево пусто
# → verify-merged empty-suite = pass (nullglob, #174) → лист СЛИТ.
# =============================================================================
echo "== RED-b: box-verdict — empty rollup + engine pass → PR merged =="

CBHOME_B="$ROOT/cbhome_b"
reset_sandbox "$CBHOME_B"
printf '%s' "$REVIEW_BOARD" > "$BOARD_STATE"
# gh stub returns empty statusCheckRollup (always, anti-фальш).
# leaf/10-1700000000 уже в remote (setup_remote создаёт), несёт только work-10.txt —
# без reference/tests/ → merged-дерево пусто → verify-merged empty-suite pass.

run_loop "$CBHOME_B" ""

[ "$(issue_state 10)" = "CLOSED" ] \
  && ok "RED-b: leaf #10 CLOSED — box-verdict pass (empty suite) triggered merge" \
  || ko "RED-b: leaf #10 NOT closed — box-verdict should have triggered merge on empty suite"

pr_merged 10 \
  && ok "RED-b: PR #10 merged (box-verdict pass = green)" \
  || ko "RED-b: PR #10 NOT merged — verify-merged empty-suite should be pass"

# =============================================================================
# RED-d: broken GIT_REMOTE → try-merge infra error (exit 2) → leaf stays review
# =============================================================================
echo "== RED-d: broken CB_GIT_REMOTE → leaf stays status:review, NOT needs-rework =="

CBHOME_D="$ROOT/cbhome_d"
reset_sandbox "$CBHOME_D"
printf '%s' "$REVIEW_BOARD" > "$BOARD_STATE"
# Broken remote → try-merge exit 2 (infra) → leaf stays review (no CI read needed)

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
# RED-e: REMOVED (obsolete, #176 Ф-A)
# gh-error на чтение rollup — беспредметен: петля больше не читает statusCheckRollup.
# =============================================================================
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
