#!/usr/bin/env bash
# gate-repo-dir.test.sh — T4: CB_GATE_REPO_DIR absent → finale gate uses --remote (issue #150)
#
# Verifies that when CB_GATE_REPO_DIR is NOT set (production env after #150 fix),
# the charter finale gate clones the real charter/9001 branch via --remote and checks
# THAT tree — not the launcher's CWD.
#
# Case A (GREEN): marker string in launcher CWD, charter/9001 tree CLEAN
#                 → gate GREEN (--remote scanned clean branch, not dirty CWD) → PR created.
# Case B (RED):   marker in charter/9001 branch tree, launcher CWD CLEAN
#                 → gate RED  (--remote found marker in branch)               → PR blocked.
#
# Method: real crewboss-launcher-gh.sh driving the finale cycle (prec.: charter-finale.test.sh
#         run_finale(:257)); real crewboss-integrator.sh; local bare git remote; gh stub.
# Class T4: integration — real launcher + bare remote + isolated env + no CB_GATE_REPO_DIR.
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

# ── marker (split literal to avoid self-match when this file is gate-scanned) ──
MARKER="CREWBOSS_NO""GATE"

# ── shared state paths ─────────────────────────────────────────────────────────
REMOTE="$ROOT/remote.git"
SANDBOX="$ROOT/sb"
BOARD_STATE="$SANDBOX/board.json"
GH_LOG="$SANDBOX/gh.log"
PRDIR="$SANDBOX/prs"
export REMOTE SANDBOX BOARD_STATE GH_LOG PRDIR

BIN="$ROOT/bin"; mkdir -p "$BIN"

# ── helpers ────────────────────────────────────────────────────────────────────
charter_pr_created(){ grep -q "pr-create charter/9001" "$GH_LOG" 2>/dev/null; }
has_gate_red_comment(){
  jq -r '.[] | select(.number==9001) | .comments[]?.body' "$BOARD_STATE" 2>/dev/null \
    | grep -qi "gate RED"
}

# ── remote setup ───────────────────────────────────────────────────────────────
# charter/9001 is created as a descendant of main (checkout -b from main + one commit).
# #156 ancestor-check requires main to be an ancestor of charter/C; a non-descendant
# would be rejected before reaching the gate.
setup_remote(){
  rm -rf "$REMOTE"; git init --bare -q "$REMOTE"
  local tmp; tmp="$(mktemp -d)"
  git clone -q "$REMOTE" "$tmp" 2>/dev/null
  git -C "$tmp" config user.email t@t; git -C "$tmp" config user.name T
  printf 'base\n' > "$tmp/README.md"
  git -C "$tmp" add -A; git -C "$tmp" commit -qm "init" 2>/dev/null
  git -C "$tmp" push -q origin HEAD:refs/heads/main 2>/dev/null

  # charter/9001: descendant of main — clean tree (no markers)
  git -C "$tmp" checkout -q -b "charter/9001" 2>/dev/null
  printf 'leaf-work\n' > "$tmp/work.txt"
  git -C "$tmp" add -A; git -C "$tmp" commit -qm "charter/9001 work merged" 2>/dev/null
  git -C "$tmp" push -q origin "charter/9001" 2>/dev/null
  rm -rf "$tmp"
}

# Add a marker file to charter/9001 on the remote (used by Case B).
add_marker_to_branch(){
  local tmp; tmp="$(mktemp -d)"
  git clone -q "$REMOTE" "$tmp" 2>/dev/null
  git -C "$tmp" config user.email t@t; git -C "$tmp" config user.name T
  git -C "$tmp" checkout -q charter/9001 2>/dev/null
  printf '%s\n' "$MARKER" > "$tmp/gate-marker.sh"
  git -C "$tmp" add -A; git -C "$tmp" commit -qm "add marker to charter/9001" 2>/dev/null
  git -C "$tmp" push -q origin charter/9001 2>/dev/null
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

# Board: charter #9001 OPEN (approved), leaf #9002 already CLOSED — finale-ready state.
FINALE_BOARD='[
  {"number":9001,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],
   "body":"gate-repo-dir charter","comments":[]},
  {"number":9002,"state":"CLOSED","labels":[{"name":"type:agent"}],
   "body":"leaf A\nCharter: #9001","comments":[]}
]'

# ── gh stub ─────────────────────────────────────────────────────────────────────
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
  "auth token")
    printf 'FAKETOKEN\n' ;;

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
    # Default: CI success → gate-check returns green
    exit 0 ;;

  "label create") ;;   # no-op

  *) echo "gh-stub UNHANDLED: $obj $verb $*" >> "$GH_LOG" ;;
esac
exit 0
GHEOF
chmod +x "$BIN/gh"

# ── loop runner — CB_GATE_REPO_DIR intentionally NOT set ──────────────────────
# Production env contract (run-env.sh after #150 fix): CB_GATE_REPO_DIR is absent,
# so launcher:549-552 selects the --remote branch via CB_GIT_REMOTE.
# CB_GATE_REPO_DIR is NOT set here (or anywhere in this test env) — that is the fix.
# CREWBOSS_CHARTER is neutralised (=0 → no scope filter) so outer-env scope does not
# shadow charter/9001 (which may differ from CREWBOSS_CHARTER in CI).
run_finale(){
  local cbhome="$1" cwd="$2"
  (
    cd "$cwd"
    PATH="$BIN:$PATH" \
      CB_REPO="test/repo" \
      CB_HOME="$cbhome" \
      CB_GIT_REMOTE="$REMOTE" \
      CB_INTEGRATOR="$INTEGRATOR" \
      CREWBOSS_CHARTER=0 \
      CB_POLL=0 \
      CB_MAX_TICKS=10 \
      CB_IDLE_CONFIRM=2 \
      CB_MAX_PARALLEL=2 \
      CB_RETRY_CAP=2 \
      CB_FINALE_CHECKS_TIMEOUT=0 \
      CB_FINALE_CHECKS_POLL=0 \
      bash "$LAUNCHER" run 2>/dev/null
  )
}

# =============================================================================
# Case A: marker in launcher CWD, charter/9001 clean → gate GREEN (PR created)
# =============================================================================
echo "== Case A: marker in launcher CWD, charter/9001 clean → gate GREEN =="

CBHOME_A="$ROOT/cbhome_a"
CWD_A="$ROOT/cwd_a"; mkdir -p "$CWD_A"
reset_sandbox "$CBHOME_A"
printf '%s\n' "$FINALE_BOARD" > "$BOARD_STATE"

# CWD is dirty: has a file with the gate-bypass marker.
# Pre-fix (CB_GATE_REPO_DIR=.): gate would scan CWD → false RED.
# Post-fix (CB_GATE_REPO_DIR unset): gate clones charter/9001 via --remote → clean → GREEN.
printf '# dirty-cwd\n%s\n' "$MARKER" > "$CWD_A/dirty.sh"

run_finale "$CBHOME_A" "$CWD_A"

charter_pr_created \
  && ok "Case A: PR created — gate GREEN via --remote (clean branch, dirty CWD ignored)" \
  || ko "Case A: PR NOT created — gate appears to have scanned CWD (CB_GATE_REPO_DIR still set?)"

# =============================================================================
# Case B: marker in charter/9001 branch, CWD clean → gate RED (PR blocked)
# =============================================================================
echo "== Case B: marker in charter/9001 branch, CWD clean → gate RED =="

CBHOME_B="$ROOT/cbhome_b"
CWD_B="$ROOT/cwd_b"; mkdir -p "$CWD_B"
reset_sandbox "$CBHOME_B"
printf '%s\n' "$FINALE_BOARD" > "$BOARD_STATE"

# Push a marker file onto charter/9001 in the remote.
# --remote will clone this branch → marker found → gate RED.
add_marker_to_branch

run_finale "$CBHOME_B" "$CWD_B"

charter_pr_created \
  && ko "Case B: PR was created despite marker in charter/9001 branch" \
  || ok "Case B: PR NOT created — gate RED blocked it (marker found in remote branch)"

has_gate_red_comment \
  && ok "Case B: gate RED comment posted on charter #9001" \
  || ko "Case B: no gate RED comment on charter #9001"

# =============================================================================
echo
printf '=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
