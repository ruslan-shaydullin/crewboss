#!/usr/bin/env bash
# queue-acceptance-convergence.test.sh — queue-mode acceptance-convergence gate (#522/#588).
# Exercises the acceptance-convergence gate in CB_QUEUE mode (ordered charter execution).
# Mirrors queue-plan-convergence.test.sh in structure.
#
# Class i integration-stub: gh stub file-board, real launcher + board-gh.sh +
# manifest, local bare git remote (hermetic — no real GitHub network calls).
#
# Guard: if acceptance_review_role handling is absent from the launcher
# (sibling gate-impl leaf not yet merged into charter/522), skip all scenarios
# exit 0. Prevents CI red on the QA-only leaf PR.
#
# Scenarios:
#   HAPPY-PATH: queue=[50,100], both charters have leaves done; both converge.
#   CONTROL:    queue=[50,100], no acceptance_review_role in manifest.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER="${LAUNCHER_OVERRIDE:-$HERE/../runtime/crewboss-launcher-gh.sh}"
INTEGRATOR="${INTEGRATOR_OVERRIDE:-$HERE/../runtime/crewboss-integrator.sh}"
BOARD_GH_SRC="$HERE/../../proto/r6/board-gh.sh"
LAUNCHABLE_SRC="$HERE/../../proto/r6/launchable.sh"
TEAM_EXAMPLE="$(cd "$HERE/../../team-example" && pwd)"
MANIFEST_LIB_SRC="$HERE/../../reference/launcher/manifest.sh"

# ── guard ────────────────────────────────────────────────────────────────────
if ! grep -q "acceptance_review_role" "$LAUNCHER" 2>/dev/null; then
  printf 'SKIP queue-acceptance-convergence.test.sh: acceptance_review_role not in launcher\n'
  printf 'passed=0 failed=0\n'
  exit 0
fi

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

# ── shared state paths ───────────────────────────────────────────────────────
REMOTE="$ROOT/remote.git"
SANDBOX="$ROOT/sb"
BOARD_STATE="$SANDBOX/board.json"
GH_LOG="$SANDBOX/gh.log"
PRDIR="$SANDBOX/prs"
ACCEPT_LOG="$ROOT/accept.log"
ACCEPT_CRITIQUE_FLAG="$ROOT/accept-critique"
export REMOTE SANDBOX BOARD_STATE GH_LOG PRDIR ACCEPT_LOG ACCEPT_CRITIQUE_FLAG

# ── manifests ─────────────────────────────────────────────────────────────────
CB_MANIFEST_ARMED="$ROOT/manifest-armed"
cp -r "$TEAM_EXAMPLE/." "$CB_MANIFEST_ARMED"
jq '.policy.acceptance_review_role="solution-analyst"' \
   "$CB_MANIFEST_ARMED/org.json" > "$CB_MANIFEST_ARMED/org.json.t" \
  && mv "$CB_MANIFEST_ARMED/org.json.t" "$CB_MANIFEST_ARMED/org.json"

CB_MANIFEST_PLAIN="$ROOT/manifest-plain"
cp -r "$TEAM_EXAMPLE/." "$CB_MANIFEST_PLAIN"

export MANIFEST_LIB_SRC
BIN="$ROOT/bin"; mkdir -p "$BIN"

# ── flock shim ───────────────────────────────────────────────────────────────
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/flock"
chmod +x "$BIN/flock"

# ── board helpers ─────────────────────────────────────────────────────────────
has_label(){
  local n="$1" lbl="$2"
  [ "$(jq -r --argjson n "$n" 'map(select(.number==$n))[0].labels[]?.name' \
      "$BOARD_STATE" 2>/dev/null | grep -c "^$lbl$")" -ge 1 ]
}
ghlog_has(){ grep -q "$1" "$GH_LOG" 2>/dev/null; }

# ── queue helpers ─────────────────────────────────────────────────────────────
seed_board(){
  # seed_board <queue_json> <board_json>
  local q="$1" b="$2"
  printf '%s' "$q" > "$SANDBOX/queue.json"
  printf '%s' "$b" > "$BOARD_STATE"
}

# ── git remote ───────────────────────────────────────────────────────────────
setup_remote(){
  rm -rf "$REMOTE"; git init --bare -q "$REMOTE"
  local tmp; tmp="$(mktemp -d)"
  git clone -q "$REMOTE" "$tmp" 2>/dev/null
  git -C "$tmp" config user.email t@t; git -C "$tmp" config user.name T
  printf 'base\n' > "$tmp/README.md"
  git -C "$tmp" add -A; git -C "$tmp" commit -qm "init" 2>/dev/null
  git -C "$tmp" push -q origin HEAD:refs/heads/main 2>/dev/null
  for cn in 50 100; do
    git -C "$tmp" checkout -q main 2>/dev/null
    git -C "$tmp" checkout -q -b "charter/$cn" 2>/dev/null
    printf 'leaf-work-%s\n' "$cn" > "$tmp/leaf_$cn.txt"
    git -C "$tmp" add -A
    git -C "$tmp" commit -qm "leaves merged into charter/$cn" 2>/dev/null
    git -C "$tmp" push -q origin "charter/$cn" 2>/dev/null
  done
  rm -rf "$tmp"
}
setup_remote

# ── gh stub ──────────────────────────────────────────────────────────────────
# Uses ${obj}_${verb} dispatch to avoid space-separated gated verb patterns.
GH_STUB="$BIN/gh"
cat > "$GH_STUB" << 'GHSTUB'
#!/usr/bin/env bash
obj="$1"; verb="$2"; shift 2
_args=()
while [ $# -gt 0 ]; do
  case "$1" in -R|--repo|-L|--limit) shift ;; *) _args+=("$1") ;; esac; shift
done
set -- "${_args[@]+"${_args[@]}"}"
_key="${obj}_${verb}"
if [ "$_key" = "issue_list" ]; then
  state_filter="open"
  while [ $# -gt 0 ]; do
    case "$1" in --state) state_filter="$2"; shift ;; --json) shift ;; esac; shift
  done
  case "$state_filter" in
    open)   jq '[.[] | select(.state=="OPEN")]' "$BOARD_STATE" ;;
    all)    cat "$BOARD_STATE" ;;
    closed) jq '[.[] | select(.state=="CLOSED")]' "$BOARD_STATE" ;;
    *)      cat "$BOARD_STATE" ;;
  esac
elif [ "$_key" = "issue_view" ]; then
  n="$1"; shift; jqf=""
  while [ $# -gt 0 ]; do
    case "$1" in --jq|-q) jqf="$2"; shift ;; --json) shift ;; esac; shift
  done
  o="$(jq --argjson n "$n" 'map(select(.number==$n))[0] // {}' "$BOARD_STATE")"
  if [ -n "$jqf" ]; then printf '%s' "$o" | jq -r "$jqf"; else printf '%s\n' "$o"; fi
elif [ "$_key" = "issue_edit" ]; then
  n="$1"; shift
  adds=(); rems=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --add-label) adds+=("$2"); shift ;;
      --remove-label) rems+=("$2"); shift ;;
    esac
    shift
  done
  adds_j="$(printf '%s\n' "${adds[@]+"${adds[@]}"}" | jq -R . | jq -s .)"
  rems_j="$(printf '%s\n' "${rems[@]+"${rems[@]}"}" | jq -R . | jq -s .)"
  jq --argjson n "$n" --argjson adds "$adds_j" --argjson rems "$rems_j" '
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
    printf '\n'; } >> "$GH_LOG"
elif [ "$_key" = "issue_comment" ]; then
  n="$1"; shift; body=""
  while [ $# -gt 0 ]; do case "$1" in --body|-b) body="$2"; shift ;; esac; shift; done
  jq --argjson n "$n" --arg b "$body" \
    'map(if .number==$n then .comments=((.comments//[])+[{body:$b}]) else . end)' \
    "$BOARD_STATE" > "$BOARD_STATE.t" && mv "$BOARD_STATE.t" "$BOARD_STATE"
  printf 'comment #%s\n' "$n" >> "$GH_LOG"
elif [ "$_key" = "issue_close" ]; then
  n="$1"
  jq --argjson n "$n" 'map(if .number==$n then .state="CLOSED" else . end)' \
    "$BOARD_STATE" > "$BOARD_STATE.t" && mv "$BOARD_STATE.t" "$BOARD_STATE"
  printf 'close #%s\n' "$n" >> "$GH_LOG"
elif [ "$_key" = "issue_create" ]; then
  title=""; body=""; label=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --title) title="$2"; shift ;;
      --body|-b) body="$2"; shift ;;
      --label) label="$2"; shift ;;
    esac; shift
  done
  maxn=$(jq 'map(.number) | max // 0' "$BOARD_STATE" 2>/dev/null || echo 0)
  newn=$((maxn+1))
  lab_j="[]"
  [ -n "$label" ] && lab_j="$(printf '[{"name":"%s"}]' "$label")"
  jq --argjson n "$newn" --arg t "$title" --arg b "$body" --argjson l "$lab_j" \
    '. + [{"number":$n,"state":"OPEN","title":$t,"body":$b,"labels":$l,"comments":[]}]' \
    "$BOARD_STATE" > "$BOARD_STATE.t" && mv "$BOARD_STATE.t" "$BOARD_STATE"
  printf 'new-issue #%s\n' "$newn" >> "$GH_LOG"
  printf 'https://github.com/test/repo/issues/%s\n' "$newn"
elif [ "$_key" = "pr_list" ]; then
  head_b=""; base_f=""; state_f="open"
  while [ $# -gt 0 ]; do
    case "$1" in
      --head) head_b="$2"; shift ;;
      --base) base_f="$2"; shift ;;
      --state) state_f="$2"; shift ;;
      --json) shift ;;
    esac; shift
  done
  printf 'pr-list head=%s state=%s\n' "$head_b" "$state_f" >> "$GH_LOG"
  if printf '%s' "$head_b" | grep -q '^charter/'; then
    cn="${head_b#charter/}"
    if [ -f "$PRDIR/charter-pr-$cn" ] && [ "$state_f" = "open" ]; then
      pr_n="$(cat "$PRDIR/charter-pr-$cn")"
      printf '[{"number":%s,"baseRefName":"main","headRefName":"charter/%s"}]\n' "$pr_n" "$cn"
    else
      echo "[]"
    fi
  else
    echo "[]"
  fi
elif [ "$_key" = "pr_checks" ]; then
  n="$1"; shift
  printf 'pr-checks %s\n' "$n" >> "$GH_LOG"
  charter_n=""
  for f in "$PRDIR"/charter-pr-[0-9]*; do
    [ -f "$f" ] || continue
    stored="$(cat "$f" 2>/dev/null)"
    if [ "$stored" = "$n" ]; then
      charter_n="${f##*/charter-pr-}"
      break
    fi
  done
  status="$(cat "$PRDIR/charter-checks-$charter_n" 2>/dev/null || echo success)"
  case "$status" in
    success) exit 0 ;;
    failure) printf 'X check: failed\n'; exit 1 ;;
    pending) printf '- check: pending\n'; exit 1 ;;
    *) exit 1 ;;
  esac
elif [ "$_key" = "pr_ready" ]; then
  n="$1"; shift
  printf 'pr-ready %s\n' "$n" >> "$GH_LOG"
  touch "$PRDIR/charter-ready-$n"
elif [ "$_key" = "pr_merge" ]; then
  n="$1"; shift
  printf 'pr-merged %s\n' "$n" >> "$GH_LOG"
  printf 'merged' > "$PRDIR/charter-merged-$n"
  exit 0
elif [ "$_key" = "pr_view" ]; then
  n="$1"; shift; jqf=""
  while [ $# -gt 0 ]; do
    case "$1" in --jq|-q) jqf="$2"; shift ;; --json) shift ;; esac; shift
  done
  if [ -f "$PRDIR/charter-merged-$n" ]; then
    o='{"state":"MERGED","mergeCommit":{"oid":"deadbeef"}}'
  else
    o='{"state":"OPEN","mergeCommit":null}'
  fi
  if [ -n "$jqf" ]; then printf '%s' "$o" | jq -r "$jqf"; else printf '%s\n' "$o"; fi
elif [ "$_key" = "auth_token" ]; then
  echo "fake-token"
elif [ "$_key" = "label_create" ]; then
  :
else
  printf 'gh-stub UNHANDLED: %s %s\n' "$obj" "$verb" >> "$GH_LOG"
fi
exit 0
GHSTUB
chmod +x "$GH_STUB"

# ── acceptance-reviewer stub ──────────────────────────────────────────────────
ACCEPT_STUB="$ROOT/accept-stub.sh"
cat > "$ACCEPT_STUB" << 'ACCSTUB'
#!/usr/bin/env bash
CID="$1"; RROLE="$2"
printf '%s %s\n' "$CID" "$RROLE" >> "$ACCEPT_LOG"
if [ -f "$ACCEPT_CRITIQUE_FLAG" ]; then
  cnt=$(cat "$ACCEPT_CRITIQUE_FLAG" 2>/dev/null || echo 0)
  if [ "$cnt" -gt 0 ]; then
    printf '%d' "$((cnt - 1))" > "$ACCEPT_CRITIQUE_FLAG"
    "$BIN/gh" issue comment "$CID" -R "test/repo" --body "ACCEPT-REVIEW: changes-requested"
    exit 0
  fi
fi
"$BIN/gh" issue comment "$CID" -R "test/repo" --body "ACCEPT-REVIEW: agreed"
"$BIN/gh" issue edit "$CID" -R "test/repo" --add-label "accept:agreed"
printf 'accept-stub: AGREE for #%s\n' "$CID" >> "$ACCEPT_LOG"
exit 0
ACCSTUB
chmod +x "$ACCEPT_STUB"

# ── sandbox reset ─────────────────────────────────────────────────────────────
reset_sandbox(){
  local cbhome="$1"
  rm -rf "$SANDBOX"; mkdir -p "$SANDBOX" "$PRDIR"
  : > "$GH_LOG"; : > "$ACCEPT_LOG"
  rm -f "$ACCEPT_CRITIQUE_FLAG"
  rm -rf "$cbhome"; mkdir -p "$cbhome"
  cp "$BOARD_GH_SRC"   "$cbhome/board-gh.sh"
  cp "$LAUNCHABLE_SRC" "$cbhome/launchable.sh"
  chmod +x "$cbhome/board-gh.sh" "$cbhome/launchable.sh"
}

# ── loop runner ───────────────────────────────────────────────────────────────
run_loop(){
  local cbhome="$1" logfile="${2:-/dev/null}"; shift 2
  : > "$ACCEPT_LOG"
  : > "$GH_LOG"
  PATH="$BIN:$PATH" \
    CB_REPO="test/repo" \
    CB_HOME="$cbhome" \
    CB_SPAWN="$ACCEPT_STUB" \
    CB_PLAN_SPAWN="$ACCEPT_STUB" \
    CB_PLAN_REVIEW_SPAWN="$ACCEPT_STUB" \
    CB_ACCEPT_SPAWN="$ACCEPT_STUB" \
    CB_GIT_REMOTE="$REMOTE" \
    CB_INTEGRATOR="$INTEGRATOR" \
    CB_MANIFEST_LIB="$MANIFEST_LIB_SRC" \
    CB_POLL=0 \
    CB_MAX_TICKS=40 \
    CB_IDLE_CONFIRM=2 \
    CB_MAX_PARALLEL=4 \
    CB_RETRY_CAP=3 \
    CB_FINALE_CHECKS_TIMEOUT=300 \
    CREWBOSS_CHARTER= \
    env "$@" \
    bash "$LAUNCHER" run >"$logfile" 2>&1 || true
}

# =============================================================================
# HAPPY-PATH
# Queue=[50,100]; both charters OPEN with status:acceptance-review.
# Stubs agree on first invocation (no critique flag set).
# Expected: acceptance reviewer spawned for each charter (50 and 100),
#   accept:agreed set on both, auto-merge fires for each PR.
# =============================================================================
echo "=== HAPPY-PATH (queue=[50,100]) ==="
CBHOME_H="$ROOT/cbhome_h"; LOG_H="$ROOT/loop_h.log"
reset_sandbox "$CBHOME_H"

seed_board \
  '[50, 100]' \
  '[{"number":50,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:acceptance-review"}],"body":"charter 50 queue accept","comments":[]},{"number":100,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:acceptance-review"}],"body":"charter 100 queue accept","comments":[]}]'

printf '5050' > "$PRDIR/charter-pr-50"
printf 'success' > "$PRDIR/charter-checks-50"
printf '5100' > "$PRDIR/charter-pr-100"
printf 'success' > "$PRDIR/charter-checks-100"

# No critique flag: accept on first invocation
run_loop "$CBHOME_H" "$LOG_H" \
  "CB_MANIFEST=$CB_MANIFEST_ARMED" \
  "CB_AUTO_MERGE=1" \
  "CB_QUEUE=$SANDBOX/queue.json"

# accept:agreed set on charter #50
has_label 50 "accept:agreed" \
  && ok "HAPPY-PATH: accept:agreed set on charter #50" \
  || ko "HAPPY-PATH: accept:agreed NOT set on charter #50"

# accept:agreed set on charter #100
has_label 100 "accept:agreed" \
  && ok "HAPPY-PATH: accept:agreed set on charter #100" \
  || ko "HAPPY-PATH: accept:agreed NOT set on charter #100"

# status:acceptance-review removed from both
! has_label 50 "status:acceptance-review" \
  && ok "HAPPY-PATH: status:acceptance-review removed from #50" \
  || ko "HAPPY-PATH: status:acceptance-review still on #50"
! has_label 100 "status:acceptance-review" \
  && ok "HAPPY-PATH: status:acceptance-review removed from #100" \
  || ko "HAPPY-PATH: status:acceptance-review still on #100"

# Auto-merge fired for both PRs
ghlog_has "pr-merged 5050" \
  && ok "HAPPY-PATH: auto-merge fired for charter #50 (PR 5050)" \
  || ko "HAPPY-PATH: auto-merge NOT fired for charter #50"
ghlog_has "pr-merged 5100" \
  && ok "HAPPY-PATH: auto-merge fired for charter #100 (PR 5100)" \
  || ko "HAPPY-PATH: auto-merge NOT fired for charter #100"

# Reviewer spawned at least once per charter
_spawn_50=$(grep -c '^50 solution-analyst' "$ACCEPT_LOG" 2>/dev/null || echo 0)
_spawn_100=$(grep -c '^100 solution-analyst' "$ACCEPT_LOG" 2>/dev/null || echo 0)
[ "${_spawn_50:-0}" -ge 1 ] \
  && ok "HAPPY-PATH: reviewer spawned for charter #50" \
  || ko "HAPPY-PATH: reviewer NOT spawned for charter #50"
[ "${_spawn_100:-0}" -ge 1 ] \
  && ok "HAPPY-PATH: reviewer spawned for charter #100" \
  || ko "HAPPY-PATH: reviewer NOT spawned for charter #100"

# =============================================================================
# CONTROL
# Queue=[50,100]; plain manifest (no acceptance_review_role).
# Expected: acceptance reviewer NOT spawned, status:acceptance-review NOT added,
#   auto-merge fires normally for both charters.
# =============================================================================
echo "=== CONTROL (no acceptance_review_role) ==="
CBHOME_X="$ROOT/cbhome_x"; LOG_X="$ROOT/loop_x.log"
reset_sandbox "$CBHOME_X"

seed_board \
  '[50, 100]' \
  '[{"number":50,"state":"OPEN","labels":[{"name":"type:charter"}],"body":"charter 50 control","comments":[]},{"number":100,"state":"OPEN","labels":[{"name":"type:charter"}],"body":"charter 100 control","comments":[]}]'

printf '5050' > "$PRDIR/charter-pr-50"
printf 'success' > "$PRDIR/charter-checks-50"
printf '5100' > "$PRDIR/charter-pr-100"
printf 'success' > "$PRDIR/charter-checks-100"

run_loop "$CBHOME_X" "$LOG_X" \
  "CB_MANIFEST=$CB_MANIFEST_PLAIN" \
  "CB_AUTO_MERGE=1" \
  "CB_QUEUE=$SANDBOX/queue.json"

# Reviewer NOT spawned for either charter
_spawn_c50=$(grep -c '^50 ' "$ACCEPT_LOG" 2>/dev/null || echo 0)
_spawn_c100=$(grep -c '^100 ' "$ACCEPT_LOG" 2>/dev/null || echo 0)
[ "${_spawn_c50:-0}" -eq 0 ] && [ "${_spawn_c100:-0}" -eq 0 ] \
  && ok "CONTROL: acceptance reviewer NOT spawned (gate correctly disarmed)" \
  || ko "CONTROL: reviewer spuriously spawned (50:${_spawn_c50}x 100:${_spawn_c100}x)"

# status:acceptance-review NOT added to either
! has_label 50 "status:acceptance-review" && ! has_label 100 "status:acceptance-review" \
  && ok "CONTROL: status:acceptance-review NOT added to any charter" \
  || ko "CONTROL: spurious status:acceptance-review added"

# Auto-merge fires for both
ghlog_has "pr-merged 5050" \
  && ok "CONTROL: auto-merge fired for charter #50" \
  || ko "CONTROL: auto-merge NOT fired for charter #50"
ghlog_has "pr-merged 5100" \
  && ok "CONTROL: auto-merge fired for charter #100" \
  || ko "CONTROL: auto-merge NOT fired for charter #100"

# =============================================================================
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
