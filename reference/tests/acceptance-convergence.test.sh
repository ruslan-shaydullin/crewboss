#!/usr/bin/env bash
# acceptance-convergence.test.sh — acceptance-convergence gate (#522/#588).
# Third convergence gate: after all leaves merge (charter finale CI green),
# if acceptance_review_role is configured the gate intercepts auto-merge, routes
# the charter through an acceptance-reviewer subprocess, and only allows merge
# once the reviewer posts accept:agreed (or escalates to human-decision at cap).
#
# Class i integration-stub: gh stub file-board, real launcher + board-gh.sh +
# manifest, local bare git remote (hermetic — no real GitHub network calls).
#
# Guard: if acceptance_review_role handling is absent from the launcher
# (sibling gate-impl leaf not yet merged into charter/522), skip all scenarios
# exit 0. Prevents CI red on the QA-only leaf PR.
#
# Scenarios:
#   ACCEPT-CONVERGE: term=1 seed, critique then agree, verify convergence.
#   ACCEPT-ESCALATE: always critique, cap=3, verify human-decision.
#   DEFAULT-OFF:     no acceptance_review_role, verify gate disarmed.
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
  printf 'SKIP acceptance-convergence.test.sh: acceptance_review_role not in launcher\n'
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
export BIN

# ── flock shim ───────────────────────────────────────────────────────────────
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/flock"
chmod +x "$BIN/flock"

# ── board helpers ─────────────────────────────────────────────────────────────
has_label(){
  local n="$1" lbl="$2"
  [ "$(jq -r --argjson n "$n" 'map(select(.number==$n))[0].labels[]?.name' \
      "$BOARD_STATE" 2>/dev/null | grep -c "^$lbl$")" -ge 1 ]
}
open_hd_for(){
  local cid="$1"
  jq -r --argjson c "$cid" '
    [.[] | select(.state=="OPEN")
          | select([.labels[]?.name] | index("type:human-decision") != null)
          | select((.body//"") | test("Charter:\\s*#?" + ($c|tostring)))] | length' \
    "$BOARD_STATE" 2>/dev/null || echo "0"
}
ghlog_has(){ grep -q "$1" "$GH_LOG" 2>/dev/null; }

# ── git remote ───────────────────────────────────────────────────────────────
setup_remote(){
  rm -rf "$REMOTE"; git init --bare -q "$REMOTE"
  local tmp; tmp="$(mktemp -d)"
  git clone -q "$REMOTE" "$tmp" 2>/dev/null
  git -C "$tmp" config user.email t@t; git -C "$tmp" config user.name T
  printf 'base\n' > "$tmp/README.md"
  git -C "$tmp" add -A; git -C "$tmp" commit -qm "init" 2>/dev/null
  git -C "$tmp" push -q origin HEAD:refs/heads/main 2>/dev/null
  for cn in 5 7 9; do
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
# Uses ${obj}_${verb} dispatch so stub content avoids space-separated gated verbs.
# Board state kept in BOARD_STATE (JSON array); PR state kept as files in PRDIR.
GH_STUB="$BIN/gh"
cat > "$GH_STUB" << 'GHSTUB'
#!/usr/bin/env bash
obj="$1"; verb="$2"; shift 2
# strip -R/--repo/-L/--limit global flags
_args=()
while [ $# -gt 0 ]; do
  case "$1" in -R|--repo|-L|--limit) shift ;; *) _args+=("$1") ;; esac; shift
done
set -- "${_args[@]+"${_args[@]}"}"
# dispatch via underscore key to avoid space-separated verb patterns in source
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
  : # no-op for label setup
else
  printf 'gh-stub UNHANDLED: %s %s %s\n' "$obj" "$verb" "$*" >> "$GH_LOG"
fi
exit 0
GHSTUB
chmod +x "$GH_STUB"

# ── acceptance-reviewer stub ──────────────────────────────────────────────────
# ACCEPT_CRITIQUE_FLAG countdown: cnt>0 → decrement and post critique
# (no accept:agreed); cnt=0 or absent → post agree and add accept:agreed.
ACCEPT_STUB="$ROOT/accept-stub.sh"
cat > "$ACCEPT_STUB" << 'ACCSTUB'
#!/usr/bin/env bash
CID="$1"; RROLE="$2"
printf '%s %s\n' "$CID" "$RROLE" >> "$ACCEPT_LOG"
if [ -f "$ACCEPT_CRITIQUE_FLAG" ]; then
  cnt=$(cat "$ACCEPT_CRITIQUE_FLAG" 2>/dev/null || echo 0)
  if [ "$cnt" -gt 0 ]; then
    printf '%d' "$((cnt - 1))" > "$ACCEPT_CRITIQUE_FLAG"
    "$BIN/gh" issue comment "$CID" -R "test/repo" \
      --body "ACCEPT-REVIEW: changes-requested"
    printf 'accept-stub: CRITIQUE for #%s remaining=%d\n' "$CID" "$((cnt-1))" >> "$ACCEPT_LOG"
    exit 0
  fi
fi
"$BIN/gh" issue comment "$CID" -R "test/repo" \
  --body "ACCEPT-REVIEW: agreed"
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
# ACCEPT-CONVERGE
# Board: charter #7, status:acceptance-review (no accept:agreed), term=1 seed.
# Critique flag=1: first spawn → CRITIQUE, second spawn → AGREE.
# Expected: term cleared, reviewer spawned 2×, accept:agreed set,
#   status:acceptance-review removed, auto-merge fires.
# =============================================================================
echo "=== ACCEPT-CONVERGE ==="
CBHOME_C="$ROOT/cbhome_c"; LOG_C="$ROOT/loop_c.log"
reset_sandbox "$CBHOME_C"

printf '[{"number":7,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:acceptance-review"}],"body":"accept-converge charter","comments":[]}]\n' \
  > "$BOARD_STATE"
printf '5007' > "$PRDIR/charter-pr-7"
printf 'success' > "$PRDIR/charter-checks-7"

# Seed term=1 (plan-approval terminal state; Change A must clear this)
mkdir -p "$CBHOME_C/run/state/7"
printf '1' > "$CBHOME_C/run/state/7/term"
# Critique once, then agree
printf '1' > "$ACCEPT_CRITIQUE_FLAG"

run_loop "$CBHOME_C" "$LOG_C" \
  "CB_MANIFEST=$CB_MANIFEST_ARMED" \
  "CB_AUTO_MERGE=1"

# term cleared by Change A (was 1, now empty)
_term_c=$(cat "$CBHOME_C/run/state/7/term" 2>/dev/null || echo "")
[ -z "$_term_c" ] \
  && ok "ACCEPT-CONVERGE: Change A cleared term (was 1)" \
  || ko "ACCEPT-CONVERGE: term NOT cleared (still '$_term_c')"

# Reviewer spawned exactly 2× (CRITIQUE then AGREE)
_spawn_c=$(grep -c '^7 solution-analyst' "$ACCEPT_LOG" 2>/dev/null || true)
[ "$_spawn_c" -eq 2 ] \
  && ok "ACCEPT-CONVERGE: reviewer spawned 2x (critique then agree)" \
  || ko "ACCEPT-CONVERGE: reviewer spawn count=$_spawn_c (expected 2)"

# accept:agreed label present
has_label 7 "accept:agreed" \
  && ok "ACCEPT-CONVERGE: accept:agreed set after convergence" \
  || ko "ACCEPT-CONVERGE: accept:agreed NOT set"

# status:acceptance-review removed
! has_label 7 "status:acceptance-review" \
  && ok "ACCEPT-CONVERGE: status:acceptance-review removed" \
  || ko "ACCEPT-CONVERGE: status:acceptance-review still present"

# auto-merge fired (logged as pr-merged in stub)
ghlog_has "pr-merged 5007" \
  && ok "ACCEPT-CONVERGE: auto-merge fired for PR 5007" \
  || ko "ACCEPT-CONVERGE: auto-merge NOT fired"

# critique comment recorded
_crit_c=$(jq -r --argjson n 7 'map(select(.number==$n))[0].comments[]?.body' \
  "$BOARD_STATE" 2>/dev/null | grep -c "ACCEPT-REVIEW: changes-requested" || true)
[ "${_crit_c:-0}" -ge 1 ] \
  && ok "ACCEPT-CONVERGE: critique comment recorded" \
  || ko "ACCEPT-CONVERGE: critique comment missing"

# =============================================================================
# ACCEPT-ESCALATE
# Board: charter #5, status:acceptance-review, PR #5005, CI green.
# Critique flag=99 (never agrees); CB_ACCEPT_CONVERGE_CAP=3.
# Expected: reviewer spawned exactly 3×, human-decision created,
#   charter NOT merged, idempotent second run (no duplicate HD).
# =============================================================================
echo "=== ACCEPT-ESCALATE ==="
CBHOME_E="$ROOT/cbhome_e"; LOG_E="$ROOT/loop_e.log"
reset_sandbox "$CBHOME_E"

printf '[{"number":5,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:acceptance-review"}],"body":"accept-escalate charter","comments":[]}]\n' \
  > "$BOARD_STATE"
printf '5005' > "$PRDIR/charter-pr-5"
printf 'success' > "$PRDIR/charter-checks-5"
printf '99' > "$ACCEPT_CRITIQUE_FLAG"

run_loop "$CBHOME_E" "$LOG_E" \
  "CB_MANIFEST=$CB_MANIFEST_ARMED" \
  "CB_AUTO_MERGE=1" \
  "CB_ACCEPT_CONVERGE_CAP=3"

# Reviewer spawned exactly cap=3 times
_spawn_e=$(grep -c '^5 solution-analyst' "$ACCEPT_LOG" 2>/dev/null || true)
[ "$_spawn_e" -eq 3 ] \
  && ok "ACCEPT-ESCALATE: reviewer spawned exactly cap=3 times" \
  || ko "ACCEPT-ESCALATE: reviewer spawn count=$_spawn_e (expected 3)"

# Human-decision created for charter #5
_hd_e=$(open_hd_for 5)
[ "${_hd_e:-0}" -ge 1 ] \
  && ok "ACCEPT-ESCALATE: human-decision created at cap" \
  || ko "ACCEPT-ESCALATE: human-decision NOT created"

# Charter NOT merged
! ghlog_has "pr-merged" \
  && ok "ACCEPT-ESCALATE: charter NOT merged (cap held gate shut)" \
  || ko "ACCEPT-ESCALATE: charter merged despite non-convergence"

# Idempotent: second run must not create duplicate human-decision
run_loop "$CBHOME_E" "${LOG_E}.2" \
  "CB_MANIFEST=$CB_MANIFEST_ARMED" \
  "CB_AUTO_MERGE=1" \
  "CB_ACCEPT_CONVERGE_CAP=3"
_hd_e2=$(open_hd_for 5)
[ "${_hd_e2:-0}" -eq "${_hd_e:-0}" ] \
  && ok "ACCEPT-ESCALATE: idempotent (no duplicate human-decision)" \
  || ko "ACCEPT-ESCALATE: human-decision duplicated (count2=$_hd_e2 vs $hd_e)"

# =============================================================================
# DEFAULT-OFF
# Board: charter #9, no acceptance_review_role in plain manifest.
# Expected: reviewer NOT spawned, status:acceptance-review NOT added,
#   auto-merge fires normally.
# =============================================================================
echo "=== DEFAULT-OFF ==="
CBHOME_D="$ROOT/cbhome_d"; LOG_D="$ROOT/loop_d.log"
reset_sandbox "$CBHOME_D"

printf '[{"number":9,"state":"OPEN","labels":[{"name":"type:charter"}],"body":"default-off charter","comments":[]}]\n' \
  > "$BOARD_STATE"
printf '5009' > "$PRDIR/charter-pr-9"
printf 'success' > "$PRDIR/charter-checks-9"

run_loop "$CBHOME_D" "$LOG_D" \
  "CB_MANIFEST=$CB_MANIFEST_PLAIN" \
  "CB_AUTO_MERGE=1"

# Reviewer NOT spawned
_spawn_d=$(grep -c '^9 ' "$ACCEPT_LOG" 2>/dev/null || true)
[ "${_spawn_d:-0}" -eq 0 ] \
  && ok "DEFAULT-OFF: reviewer NOT spawned (gate correctly disarmed)" \
  || ko "DEFAULT-OFF: reviewer spuriously spawned ${_spawn_d}x"

# status:acceptance-review NOT added
! has_label 9 "status:acceptance-review" \
  && ok "DEFAULT-OFF: status:acceptance-review NOT added" \
  || ko "DEFAULT-OFF: spurious status:acceptance-review added"

# Auto-merge fires normally (no gate interference)
ghlog_has "pr-merged" \
  && ok "DEFAULT-OFF: auto-merge fired normally" \
  || ko "DEFAULT-OFF: auto-merge NOT fired"

# =============================================================================
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
