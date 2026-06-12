#!/usr/bin/env bash
# infra-false-green.test.sh — guard against infra false-green (#156)
#
# Scenario: charter/C is BEHIND main on the remote.
# Even though "suite of the stale tree" is green and b_sha != m_sha is true,
# the launcher MUST NOT create a finale PR (ancestor-check guards this),
# and the freshness script MUST fail (CI guard).
#
# Part 1 — launcher finale: real crewboss-launcher-gh.sh; charter/C behind main
#           → PR NOT created (launcher skips stale charter).
# Part 2 — freshness script: reference/bin/check-freshness.sh called from a git
#           worktree where HEAD is behind origin/main → must exit non-zero.
# Part 3 — ci.yml structural check: freshness job present + charter/* condition.
#
# Precondition (anti-reimplementation §anti-92): finale uses the REAL launcher,
# not a reimplementation of the ancestor logic; freshness uses the REAL shared
# script, not inline logic.
#
# Requires: jq, git, bash, flock
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER="${LAUNCHER_OVERRIDE:-$HERE/../runtime/crewboss-launcher-gh.sh}"
INTEGRATOR="${INTEGRATOR_OVERRIDE:-$HERE/../runtime/crewboss-integrator.sh}"
FRESHNESS_SCRIPT="${FRESHNESS_SCRIPT_OVERRIDE:-$HERE/../bin/check-freshness.sh}"
BOARD_GH_SRC="$HERE/../../proto/r6/board-gh.sh"
LAUNCHABLE_SRC="$HERE/../../proto/r6/launchable.sh"
CI_YML="$HERE/../../.github/workflows/ci.yml"

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
charter_pr_created(){ grep -q "pr-create charter/5" "$GH_LOG" 2>/dev/null; }

# ── remote setup: charter/5 BEHIND main ───────────────────────────────────────
# Timeline:
#   commit A → pushed to both main and charter/5
#   commit B → pushed to main ONLY (main advances; charter/5 stays at A)
# Result: charter/5 is 1 commit behind main; b_sha != m_sha is true (different SHAs),
# but main is NOT an ancestor of charter/5 — charter/5 is a strict subset.
setup_stale_remote(){
  rm -rf "$REMOTE"; git init --bare -q "$REMOTE"
  local tmp; tmp="$(mktemp -d)"
  git clone -q "$REMOTE" "$tmp" 2>/dev/null
  git -C "$tmp" config user.email t@t; git -C "$tmp" config user.name T

  # Commit A: base — goes to both main and charter/5
  printf 'base\n' > "$tmp/README.md"
  git -C "$tmp" add -A; git -C "$tmp" commit -qm "A: init" 2>/dev/null
  git -C "$tmp" push -q origin HEAD:refs/heads/main 2>/dev/null
  git -C "$tmp" push -q origin HEAD:refs/heads/charter/5 2>/dev/null

  # Commit B: main-only — main advances; charter/5 stays at A
  printf 'extra-main-work\n' > "$tmp/main-extra.txt"
  git -C "$tmp" add -A; git -C "$tmp" commit -qm "B: main extra (charter/5 now stale)" 2>/dev/null
  git -C "$tmp" push -q origin HEAD:refs/heads/main 2>/dev/null

  rm -rf "$tmp"
}

reset_sandbox(){
  rm -rf "$SANDBOX"; mkdir -p "$SANDBOX" "$PRDIR"
  : > "$GH_LOG"
  setup_stale_remote
  local cbhome="$1"
  rm -rf "$cbhome"; mkdir -p "$cbhome"
  cp "$BOARD_GH_SRC"   "$cbhome/board-gh.sh"
  cp "$LAUNCHABLE_SRC" "$cbhome/launchable.sh"
  chmod +x "$cbhome/board-gh.sh" "$cbhome/launchable.sh"
}

# Board: charter #5 OPEN (approved), leaves CLOSED — finale-ready state.
FINALE_BOARD='[
  {"number":5,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],
   "body":"the charter","comments":[]},
  {"number":10,"state":"CLOSED","labels":[{"name":"type:agent"}],
   "body":"task A\nCharter: #5\n## Acceptance (machine)\n- check: true","comments":[]},
  {"number":11,"state":"CLOSED","labels":[{"name":"type:agent"}],
   "body":"task B\nCharter: #5\n## Acceptance (machine)\n- check: true","comments":[]}
]'

# ── gh stub ───────────────────────────────────────────────────────────────────
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
      printf 'https://github.com/test/repo/pull/%s\n' "$pr_num"
    fi ;;

  "pr ready")
    n="$1"
    echo "pr-ready $n" >> "$GH_LOG"
    touch "$PRDIR/charter-pr-ready-$n" ;;

  "pr checks")
    n="$1"
    echo "pr-checks $n" >> "$GH_LOG"
    exit 0 ;;

  "pr merge")
    n="$1"; shift
    echo "pr-merge $n" >> "$GH_LOG" ;;

  "label create") ;;

  *) echo "gh-stub UNHANDLED: $obj $verb $*" >> "$GH_LOG" ;;
esac
exit 0
GHEOF
chmod +x "$BIN/gh"

# Clean gate dir: no markers → gate passes (not the variable under test here)
CLEAN_GATE_DIR="$ROOT/clean_gate_dir"; mkdir -p "$CLEAN_GATE_DIR"

# ── loop runner (same pattern as charter-finale.test.sh:run_finale) ──────────
run_finale(){
  local cbhome="$1"
  local extra_env="${2:-}"
  # Unset CREWBOSS_CHARTER so the launcher does not scope-filter charters (test uses charter #5)
  eval "PATH=\"$BIN:$PATH\" \
    CB_REPO=\"test/repo\" \
    CB_HOME=\"$cbhome\" \
    CB_GIT_REMOTE=\"$REMOTE\" \
    CB_INTEGRATOR=\"$INTEGRATOR\" \
    CB_GATE_REPO_DIR=\"$CLEAN_GATE_DIR\" \
    CREWBOSS_CHARTER=\"\" \
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

GREEN_HARNESS="$ROOT/harness-green.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$GREEN_HARNESS"; chmod +x "$GREEN_HARNESS"

# =============================================================================
# Part 1 — launcher finale: charter/C behind main → PR NOT created
# =============================================================================
echo "== Part 1: launcher finale with stale charter/5 (behind main) =="

CBHOME_1="$ROOT/cbhome_stale"
reset_sandbox "$CBHOME_1"
printf '%s' "$FINALE_BOARD" > "$BOARD_STATE"

# Verify the remote is indeed set up with charter/5 behind main (sanity)
b_sha=$(git ls-remote "$REMOTE" "refs/heads/charter/5" 2>/dev/null | awk '{print $1}' | head -1)
m_sha=$(git ls-remote "$REMOTE" "refs/heads/main"      2>/dev/null | awk '{print $1}' | head -1)
[ -n "$b_sha" ] && [ -n "$m_sha" ] && [ "$b_sha" != "$m_sha" ] \
  && ok "Part1-setup: remote has charter/5 (${b_sha:0:7}) != main (${m_sha:0:7}) — stale scenario confirmed" \
  || ko "Part1-setup: remote setup broken (b_sha='$b_sha' m_sha='$m_sha')"

# Run real launcher — gate is green (harness exits 0), so the ONLY guard is the ancestor check
run_finale "$CBHOME_1" "CB_HARNESS=\"$GREEN_HARNESS\""

charter_pr_created \
  && ko "Part1: PR charter/5→main was CREATED despite charter/5 being behind main (ancestor-check failed to block)" \
  || ok "Part1: PR NOT created — ancestor-check correctly blocked stale charter/5"

# =============================================================================
# Part 2 — freshness script: branch behind origin/main → exit non-zero
# =============================================================================
echo "== Part 2: freshness script rejects branch behind origin/main =="

FRESH_REMOTE="$ROOT/fresh-remote.git"
FRESH_CLONE="$ROOT/fresh-clone"
git init --bare -q "$FRESH_REMOTE"
fresh_tmp=$(mktemp -d)
git clone -q "$FRESH_REMOTE" "$fresh_tmp" 2>/dev/null
git -C "$fresh_tmp" config user.email t@t
git -C "$fresh_tmp" config user.name T

# Commit A: shared base
printf 'base\n' > "$fresh_tmp/README.md"
git -C "$fresh_tmp" add -A
git -C "$fresh_tmp" commit -qm "A: base" 2>/dev/null
git -C "$fresh_tmp" push -q origin HEAD:refs/heads/main 2>/dev/null

# Create charter/5 at commit A
git -C "$fresh_tmp" push -q origin HEAD:refs/heads/charter-check 2>/dev/null

# Commit B on main only → main now ahead
printf 'extra\n' > "$fresh_tmp/extra.txt"
git -C "$fresh_tmp" add -A
git -C "$fresh_tmp" commit -qm "B: main extra" 2>/dev/null
git -C "$fresh_tmp" push -q origin HEAD:refs/heads/main 2>/dev/null

# Clone fresh, checkout charter-check (at A), fetch to get origin/main at B
git clone -q "$FRESH_REMOTE" "$FRESH_CLONE" 2>/dev/null
git -C "$FRESH_CLONE" config user.email t@t
git -C "$FRESH_CLONE" config user.name T
git -C "$FRESH_CLONE" checkout -q charter-check 2>/dev/null
git -C "$FRESH_CLONE" fetch -q origin 2>/dev/null
rm -rf "$fresh_tmp"

# Call the REAL shared freshness script — must fail (branch is 1 commit behind)
fresh_rc=0
(cd "$FRESH_CLONE" && FRESHNESS_THRESHOLD=0 bash "$FRESHNESS_SCRIPT") 2>/dev/null || fresh_rc=$?
[ "$fresh_rc" -ne 0 ] \
  && ok "Part2: freshness script exits non-zero for branch behind origin/main (rc=$fresh_rc)" \
  || ko "Part2: freshness script PASSED for behind-main branch (should have failed)"

# Positive control: ahead-of-main branch should pass
fresh_rc_ahead=0
(cd "$FRESH_CLONE" && git checkout -q main 2>/dev/null && \
  FRESHNESS_THRESHOLD=0 bash "$FRESHNESS_SCRIPT") 2>/dev/null || fresh_rc_ahead=$?
[ "$fresh_rc_ahead" = "0" ] \
  && ok "Part2-positive: freshness script passes for branch at origin/main (rc=0)" \
  || ko "Part2-positive: freshness script failed for up-to-date branch (rc=$fresh_rc_ahead)"

rm -rf "$FRESH_CLONE" "$FRESH_REMOTE"

# =============================================================================
# Part 3 — ci.yml structural checks
# =============================================================================
echo "== Part 3: ci.yml freshness job structure =="

grep -q 'freshness' "$CI_YML" \
  && ok "Part3: ci.yml contains freshness job" \
  || ko "Part3: ci.yml does NOT contain freshness job"

grep -q "charter/" "$CI_YML" \
  && ok "Part3: ci.yml freshness job has charter/* condition" \
  || ko "Part3: ci.yml freshness job missing charter/* condition"

grep -q 'check-freshness' "$CI_YML" \
  && ok "Part3: ci.yml freshness job calls check-freshness script" \
  || ko "Part3: ci.yml freshness job does not call check-freshness script"

# =============================================================================
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = "0" ]
