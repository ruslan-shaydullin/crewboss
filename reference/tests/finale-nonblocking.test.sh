#!/usr/bin/env bash
# finale-nonblocking.test.sh — integration tests for F4 fix (issue #118).
# Class i: integration with gh/git stubs + throwaway bare git remote.
#
# RED-a (nonblocking tick): charter5 CI=pending, charter6 CI=success; both charters
#   processed in the same _charter_finale_cycle pass → assert that charter6 pr-ready
#   appears after exactly 1 charter5 CI poll (nonblocking interleave). Before fix:
#   blocking while-loop holds the whole tick until timeout — all charter5 polls come
#   before charter6 is ever touched.
#
# RED-b (dedup): charter5 CI=failure, existing PR, multiple ticks → assert exactly
#   one "CI failed" comment on the charter. Before fix: comment posted on every entry
#   into _finale_check_ci (once per tick since old code has no state).
#
# RED-c (liveness-link): charter5 CI pending first 3 polls then success, no other
#   work on board → assert loop does NOT idle-exit before PR is promoted; pr-ready in
#   log. Before fix: either idle-exit before promotion (no _finale_in_progress hook)
#   or blocking wait instead of per-tick polls.
#
# Regression: charter-finale.test.sh and run-liveness.test.sh (run separately).
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

# ── shared state ──────────────────────────────────────────────────────────────
REMOTE="$ROOT/remote.git"
SANDBOX="$ROOT/sb"
BOARD_STATE="$SANDBOX/board.json"
GH_LOG="$SANDBOX/gh.log"
PRDIR="$SANDBOX/prs"
export REMOTE SANDBOX BOARD_STATE GH_LOG PRDIR

BIN="$ROOT/bin"; mkdir -p "$BIN"

# ── helpers ───────────────────────────────────────────────────────────────────
has_comment(){ jq -r --argjson n "$1" \
  'map(select(.number==$n))[0].comments[]?.body' "$BOARD_STATE" | grep -qi "$2"; }
count_comments(){ jq --argjson n "$1" --arg p "$2" \
  '[map(select(.number==$n))[0].comments[]? | select(.body | test($p;"i"))] | length' \
  "$BOARD_STATE"; }
ghlog_has(){ grep -q "$1" "$GH_LOG" 2>/dev/null; }
# First line-number of a GH_LOG match
ghlog_line(){ grep -n "$1" "$GH_LOG" 2>/dev/null | head -1 | cut -d: -f1; }

# ── board templates ───────────────────────────────────────────────────────────
# Charter 5 only; leaf 10 already CLOSED.
BOARD_C5='[
  {"number":5,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],
   "body":"charter five","comments":[]},
  {"number":10,"state":"CLOSED","labels":[{"name":"type:agent"}],
   "body":"task A\nCharter: #5\n## Acceptance (machine)\n- check: true","comments":[]}
]'

# Charter 5 AND charter 6; all leaves CLOSED.
# Charter 5 listed first so _charter_finale_cycle processes it before charter 6.
BOARD_C5_C6='[
  {"number":5,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],
   "body":"charter five","comments":[]},
  {"number":10,"state":"CLOSED","labels":[{"name":"type:agent"}],
   "body":"task A\nCharter: #5\n## Acceptance (machine)\n- check: true","comments":[]},
  {"number":6,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],
   "body":"charter six","comments":[]},
  {"number":20,"state":"CLOSED","labels":[{"name":"type:agent"}],
   "body":"task B\nCharter: #6\n## Acceptance (machine)\n- check: true","comments":[]}
]'

# ── git remote ────────────────────────────────────────────────────────────────
setup_remote(){
  rm -rf "$REMOTE"; git init --bare -q "$REMOTE"
  local tmp; tmp="$(mktemp -d)"
  git clone -q "$REMOTE" "$tmp" 2>/dev/null
  git -C "$tmp" config user.email t@t; git -C "$tmp" config user.name T
  printf 'base\n' > "$tmp/README.md"
  git -C "$tmp" add -A; git -C "$tmp" commit -qm init 2>/dev/null
  git -C "$tmp" push -q origin HEAD:refs/heads/main 2>/dev/null

  # Create charter/5 and charter/6 branches ahead of main
  for branch in charter/5 charter/6; do
    git -C "$tmp" checkout -q main 2>/dev/null
    git -C "$tmp" checkout -q -b "$branch" 2>/dev/null
    printf 'leaf-work for %s\n' "$branch" > "$tmp/${branch//\//-}.txt"
    git -C "$tmp" add -A
    git -C "$tmp" commit -qm "leaves merged into $branch" 2>/dev/null
    git -C "$tmp" push -q origin "$branch" 2>/dev/null
  done
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

# ── gh stub ───────────────────────────────────────────────────────────────────
# Per-charter CI control files in PRDIR:
#   charter-checks-<N>   — static status: success | failure | pending
#   charter-flip-at-<N>  — pending for first N calls then success (RED-c)
#   charter-ci-calls-<N> — call counter written by this stub
#   charter-pr-<N>       — PR number assigned to charter N (written by pr-create)
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
    n="$1"; shift; adds=(); rems=()
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
            if ([.labels[].name] | index($a)) == null then .labels += [{name: $a}] else . end)
      else . end)' \
      "$BOARD_STATE" > "$BOARD_STATE.t" && mv "$BOARD_STATE.t" "$BOARD_STATE"
    printf 'edit #%s\n' "$n" >> "$GH_LOG" ;;

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
    echo "pr-list --head=${head} --state=${state_filter}" >> "$GH_LOG"
    if printf '%s' "$head" | grep -q '^charter/'; then
      n="${head#charter/}"
      if [ -f "$PRDIR/charter-pr-$n" ] && [ "$state_filter" = "open" ]; then
        pr_num="$(cat "$PRDIR/charter-pr-$n")"
        printf '[{"number":%s,"baseRefName":"main","headRefName":"charter/%s"}]\n' "$pr_num" "$n"
      else
        echo "[]"
      fi
    else
      # No leaf PRs in these tests
      echo "[]"
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
      printf 'https://github.com/test/repo/pull/%s\n' "$pr_num"
    fi ;;

  "pr ready")
    n="$1"
    echo "pr-ready $n" >> "$GH_LOG"
    touch "$PRDIR/charter-pr-ready-$n" ;;

  "pr checks")
    n="$1"
    echo "pr-checks $n" >> "$GH_LOG"
    # Anti-deadlock guard: fail if this PR was never created
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
    # Pending-then-success: charter-flip-at-<c>=K means pending for calls 1..K, success from K+1
    flipfile="$PRDIR/charter-flip-at-$charter_n"
    if [ -f "$flipfile" ]; then
      flip_at="$(cat "$flipfile")"
      callsfile="$PRDIR/charter-ci-calls-$charter_n"
      ci_calls=0; [ -f "$callsfile" ] && ci_calls="$(cat "$callsfile")"
      ci_calls=$((ci_calls+1))
      printf '%d' "$ci_calls" > "$callsfile"
      if [ "$ci_calls" -le "$flip_at" ]; then
        printf '%s\n' '- check: pending'; exit 1
      else
        exit 0
      fi
    fi
    # Static status (default: success)
    status="$(cat "$PRDIR/charter-checks-$charter_n" 2>/dev/null || echo success)"
    case "$status" in
      success) exit 0 ;;
      failure) printf 'X check: failed\n'; exit 1 ;;
      pending) printf '%s\n' '- check: pending'; exit 1 ;;
      *)       exit 1 ;;
    esac ;;

  "label create") ;; # no-op
  *) echo "gh-stub UNHANDLED: $obj $verb $*" >> "$GH_LOG" ;;
esac
exit 0
GHEOF
chmod +x "$BIN/gh"

# Empty gate-repo dir (no bypass markers → gate passes by default)
CLEAN_GATE_DIR="$ROOT/clean_gate_dir"; mkdir -p "$CLEAN_GATE_DIR"

# ── loop runner ───────────────────────────────────────────────────────────────
run_finale(){
  local cbhome="$1" logfile="${2:--}" extra_env="${3:-}"
  eval "PATH=\"$BIN:$PATH\" \
    CB_REPO=\"test/repo\" \
    CB_HOME=\"$cbhome\" \
    CB_GIT_REMOTE=\"$REMOTE\" \
    CB_INTEGRATOR=\"$INTEGRATOR\" \
    CB_GATE_REPO_DIR=\"$CLEAN_GATE_DIR\" \
    CB_POLL=0 \
    CB_MAX_TICKS=12 \
    CB_IDLE_CONFIRM=2 \
    CB_MAX_PARALLEL=2 \
    CB_RETRY_CAP=2 \
    CB_FINALE_CHECKS_TIMEOUT=0 \
    CB_FINALE_CHECKS_POLL=0 \
    $extra_env \
    bash \"$LAUNCHER\" run >\"$logfile\" 2>&1" || true
}

# =============================================================================
# RED-a: nonblocking tick — charter6 processed between charter5 CI polls
# =============================================================================
echo "== RED-a: nonblocking — charter6 promoted between charter5 CI polls =="

CBHOME_A="$ROOT/cbhome_a"
LOGFILE_A="$ROOT/loop_a.log"
reset_sandbox "$CBHOME_A"
printf '%s' "$BOARD_C5_C6" > "$BOARD_STATE"
# Charter 5: CI always pending; charter 6: CI success immediately
printf 'pending' > "$PRDIR/charter-checks-5"
printf 'success' > "$PRDIR/charter-checks-6"

run_finale "$CBHOME_A" "$LOGFILE_A" \
  "CB_FINALE_CHECKS_TIMEOUT=4 CB_FINALE_CHECKS_POLL=1 CB_MAX_TICKS=8 CB_IDLE_CONFIRM=2"

# Charter 6 must be promoted (pr-ready in log)
ghlog_has "pr-ready" \
  && ok "RED-a: charter6 PR was promoted (pr-ready in log)" \
  || ko "RED-a: charter6 PR was NOT promoted"

# Nonblocking interleave: exactly 1 pr-checks 5005 before the first pr-ready.
# Blocking old code would show 4+ pr-checks 5005 before pr-ready (blocking while loop).
ready_line=$(ghlog_line "pr-ready")
checks5_before=0
if [ -n "$ready_line" ]; then
  checks5_before=$(awk -v r="$ready_line" \
    'NR < r && /pr-checks 5005/{c++} END{print c+0}' "$GH_LOG")
fi
[ "$checks5_before" -eq 1 ] \
  && ok "RED-a: exactly 1 charter5 CI poll before charter6 promoted (nonblocking tick)" \
  || ko "RED-a: $checks5_before charter5 CI polls before charter6 promoted (expected 1 — blocking?)"

# Anti-deadlock: pr-checks never called before pr-create
ghlog_has "ERROR-anti-deadlock" \
  && ko "RED-a: anti-deadlock violation — pr-checks before pr-create" \
  || ok "RED-a: no anti-deadlock violation"

# =============================================================================
# RED-b: dedup — exactly one CI-fail comment per run regardless of tick count
# =============================================================================
echo "== RED-b: dedup — exactly 1 CI-fail comment despite multiple ticks =="

CBHOME_B="$ROOT/cbhome_b"
LOGFILE_B="$ROOT/loop_b.log"
reset_sandbox "$CBHOME_B"
printf '%s' "$BOARD_C5" > "$BOARD_STATE"
# Pre-seed an existing PR for charter 5 (simulates launcher seeing an already-created
# draft PR, e.g. from a previous run).  CI = failure.
printf '5005' > "$PRDIR/charter-pr-5"
printf 'failure' > "$PRDIR/charter-checks-5"

run_finale "$CBHOME_B" "$LOGFILE_B" \
  "CB_FINALE_CHECKS_TIMEOUT=0 CB_FINALE_CHECKS_POLL=0 CB_MAX_TICKS=6 CB_IDLE_CONFIRM=2"

# Exactly one CI-fail comment (dedup via $STATE)
fail_count=$(count_comments 5 "failed|CI failed")
[ "$fail_count" -eq 1 ] \
  && ok "RED-b: exactly 1 CI-fail comment on charter#5 (dedup working)" \
  || ko "RED-b: $fail_count CI-fail comments on charter#5 (expected exactly 1)"

# The comment must exist (not silenced entirely)
has_comment 5 "failed\|CI failed" \
  && ok "RED-b: CI-fail comment was posted (not silenced entirely)" \
  || ko "RED-b: no CI-fail comment at all on charter#5"

# =============================================================================
# RED-c: liveness-link — loop stays alive while finale pending; PR promoted
# =============================================================================
echo "== RED-c: liveness-link — loop alive during pending CI; PR promoted when green =="

CBHOME_C="$ROOT/cbhome_c"
LOGFILE_C="$ROOT/loop_c.log"
reset_sandbox "$CBHOME_C"
printf '%s' "$BOARD_C5" > "$BOARD_STATE"
# CI pending for first 3 polls (ci_calls 1-3), success at poll 4 (ci_calls >= 4).
printf '3' > "$PRDIR/charter-flip-at-5"

# CB_IDLE_CONFIRM=1: without _finale_in_progress the old blocking code would
# idle-exit after just 1 tick (the while-loop times out after CB_FINALE_CHECKS_TIMEOUT=3s,
# returning exit 2, then _loop_is_alive sees nothing and fires idle).  The new
# non-blocking code keeps idle_ticks=0 on every tick where ci_state=pending.
PATH="$BIN:$PATH" \
  CB_REPO="test/repo" \
  CB_HOME="$CBHOME_C" \
  CB_GIT_REMOTE="$REMOTE" \
  CB_INTEGRATOR="$INTEGRATOR" \
  CB_GATE_REPO_DIR="$CLEAN_GATE_DIR" \
  CB_POLL=0 \
  CB_MAX_TICKS=15 \
  CB_IDLE_CONFIRM=1 \
  CB_MAX_PARALLEL=2 \
  CB_RETRY_CAP=2 \
  CB_FINALE_CHECKS_TIMEOUT=3 \
  CB_FINALE_CHECKS_POLL=1 \
  bash "$LAUNCHER" run >"$LOGFILE_C" 2>&1 || true

# PR must be promoted
ghlog_has "pr-ready" \
  && ok "RED-c: PR promoted (pr-ready in log) — loop waited through pending ticks" \
  || ko "RED-c: PR NOT promoted — loop idle-exited before CI turned green"

# Loop must exit cleanly (not hit max-ticks)
grep -q "idle — run complete" "$LOGFILE_C" \
  && ok "RED-c: loop exited cleanly (idle — run complete)" \
  || ko "RED-c: loop did NOT exit with 'idle — run complete'"

grep -q "max ticks" "$LOGFILE_C" \
  && ko "RED-c: loop hit max-ticks (should have exited idle after promotion)" \
  || ok "RED-c: loop did NOT hit max-ticks"

# CI must have been polled at least 4 times (3 pending + 1 success)
ci_polls=$(cat "$PRDIR/charter-ci-calls-5" 2>/dev/null || echo 0)
[ "$ci_polls" -ge 4 ] \
  && ok "RED-c: CI polled $ci_polls times (≥4 — loop waited through all pending ticks)" \
  || ko "RED-c: CI polled only $ci_polls times (expected ≥4 — liveness-link missing?)"

# Anti-deadlock sanity (carried forward from charter-finale RED-e)
ghlog_has "ERROR-anti-deadlock" \
  && ko "RED-c: anti-deadlock violation — pr-checks before pr-create" \
  || ok "RED-c: no anti-deadlock violation"

# =============================================================================
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
