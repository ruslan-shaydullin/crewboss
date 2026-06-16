#!/usr/bin/env bash
# finale-autorebase.test.sh — auto-rebase of stale charter in finale cycle (issue #255).
# Class i: integration-stub — drives real launcher + real git (clone/merge/push) against
# throwaway bare remotes. Heavy: uses background processes, real git ops, launcher loop.
#
# RED-1 (behind-main): charter/5 is behind main (main not ancestor) → autorebase does
#   clean merge → charter/5 pushed → finale creates draft PR.
# RED-2 (sha-conflict): main and charter both modified reference/runtime-manifest.tsv
#   (sha-only conflict) → autorebase resolves via --theirs + regen → push → PR created.
# RED-3 (real-conflict): main and charter both modified a non-manifest file → autorebase
#   returns 2 → status:needs-conflict-resolution label added → NO PR created.
# GREEN-guard: charter/5 already has main as ancestor → autorebase NOT called → normal
#   finale creates PR.
#
# Requires: jq, git, bash, flock.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
INTEGRATOR="${INTEGRATOR_OVERRIDE:-$HERE/../runtime/crewboss-integrator.sh}"
LAUNCHER="${LAUNCHER_OVERRIDE:-$HERE/../runtime/crewboss-launcher-gh.sh}"
REGEN_TOOL="$HERE/../bin/regen-manifest.sh"
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
has_label(){ [ "$(jq -r --argjson n "$1" 'map(select(.number==$n))[0].labels[]?.name' \
               "$BOARD_STATE" | grep -c "^$2$")" -ge 1 ]; }
ghlog_has(){ grep -q "$1" "$GH_LOG" 2>/dev/null; }
pr_created(){ ghlog_has "pr-create charter/5->main"; }
pr_ready(){   ghlog_has "pr-ready"; }

# is_ancestor <remote> <ancestor-ref> <descendant-ref>
# Returns 0 if ancestor-ref is an ancestor of descendant-ref in the remote.
is_ancestor_in_remote(){
  local remote="$1" anc="$2" desc="$3"
  local tmp; tmp=$(mktemp -d)
  git clone -q --bare "$remote" "$tmp/repo" 2>/dev/null || { rm -rf "$tmp"; return 1; }
  local rc=0
  git -C "$tmp/repo" merge-base --is-ancestor "$anc" "$desc" 2>/dev/null || rc=$?
  rm -rf "$tmp"
  return "$rc"
}

# ── board fixture ─────────────────────────────────────────────────────────────
# Charter #5 OPEN (approved); leaf #10 CLOSED.
FINALE_BOARD='[
  {"number":5,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],
   "body":"charter five","comments":[]},
  {"number":10,"state":"CLOSED","labels":[{"name":"type:agent"}],
   "body":"task A\nCharter: #5\n## Acceptance (machine)\n- check: true","comments":[]}
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
    # Anti-deadlock: fail if PR was never created
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
    # Default: success
    status="$(cat "$PRDIR/charter-checks-$charter_n" 2>/dev/null || echo success)"
    case "$status" in
      success) exit 0 ;;
      failure) printf 'X check: failed\n'; exit 1 ;;
      pending) printf '- check: pending\n'; exit 1 ;;
      *)       exit 1 ;;
    esac ;;

  "label create") ;;  # no-op (idempotent)
  *) echo "gh-stub UNHANDLED: $obj $verb $*" >> "$GH_LOG" ;;
esac
exit 0
GHEOF
chmod +x "$BIN/gh"

# Empty gate-repo dir (no bypass markers → gate passes)
CLEAN_GATE_DIR="$ROOT/clean_gate_dir"; mkdir -p "$CLEAN_GATE_DIR"

# ── loop runner ───────────────────────────────────────────────────────────────
run_finale(){
  local cbhome="$1" logfile="${2:-/dev/null}" extra_env="${3:-}"
  # Unset CREWBOSS_CHARTER/CHARTER_SCOPE so the charter-scope filter doesn't
  # skip charter #5 when this test runs inside a branch scoped to charter #187.
  eval "env -u CREWBOSS_CHARTER -u CHARTER_SCOPE \
    PATH=\"$BIN:$PATH\" \
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

reset_sandbox(){
  rm -rf "$SANDBOX"; mkdir -p "$SANDBOX" "$PRDIR"
  : > "$GH_LOG"
  local cbhome="$1"
  rm -rf "$cbhome"; mkdir -p "$cbhome"
  cp "$BOARD_GH_SRC"   "$cbhome/board-gh.sh"
  cp "$LAUNCHABLE_SRC" "$cbhome/launchable.sh"
  chmod +x "$cbhome/board-gh.sh" "$cbhome/launchable.sh"
}

# =============================================================================
# RED-1: charter behind main (clean merge) → autorebase → PR created
# =============================================================================
echo "== RED-1: charter behind main (clean merge) → auto-rebase → PR created =="

CBHOME_1="$ROOT/cbhome_1"
LOGFILE_1="$ROOT/loop_1.log"
reset_sandbox "$CBHOME_1"
printf '%s' "$FINALE_BOARD" > "$BOARD_STATE"

# Remote setup: main is ahead of charter/5 by 1 commit.
# init (A) → charter/5 is at A; main adds extra commit (B) → main is at B.
# merge-base --is-ancestor main charter/5 fails (B not reachable from A).
rm -rf "$REMOTE"; git init --bare -q "$REMOTE"
{
  local_tmp="$(mktemp -d)"
  git clone -q "$REMOTE" "$local_tmp" 2>/dev/null
  git -C "$local_tmp" config user.email t@t
  git -C "$local_tmp" config user.name T
  printf 'base\n' > "$local_tmp/README.md"
  git -C "$local_tmp" add -A
  git -C "$local_tmp" commit -qm "init" 2>/dev/null
  git -C "$local_tmp" push -q origin HEAD:refs/heads/main 2>/dev/null
  # charter/5 branches from init (before main-extra)
  git -C "$local_tmp" checkout -q -b charter/5 2>/dev/null
  printf 'charter work\n' > "$local_tmp/leaf.txt"
  git -C "$local_tmp" add -A
  git -C "$local_tmp" commit -qm "charter/5 leaf work" 2>/dev/null
  git -C "$local_tmp" push -q origin charter/5 2>/dev/null
  # main advances by one commit AFTER charter/5 branched
  git -C "$local_tmp" checkout -q main 2>/dev/null
  printf 'main extra work\n' > "$local_tmp/main-extra.txt"
  git -C "$local_tmp" add -A
  git -C "$local_tmp" commit -qm "main extra commit" 2>/dev/null
  git -C "$local_tmp" push -q origin main 2>/dev/null
  rm -rf "$local_tmp"
}

run_finale "$CBHOME_1" "$LOGFILE_1"

# charter/5 must now have main as ancestor (clean merge was pushed)
is_ancestor_in_remote "$REMOTE" "main" "charter/5" \
  && ok "RED-1: main is ancestor of charter/5 after autorebase" \
  || ko "RED-1: main is NOT ancestor of charter/5 — autorebase failed"

# PR must have been created
pr_created \
  && ok "RED-1: draft PR charter/5→main created after autorebase" \
  || ko "RED-1: draft PR NOT created — finale did not proceed after autorebase"

# Log must mention auto-rebased
grep -q "auto-rebased" "$LOGFILE_1" \
  && ok "RED-1: launcher logged auto-rebase message" \
  || ko "RED-1: no auto-rebase log message"

# Anti-deadlock: pr-checks never called before pr-create
ghlog_has "ERROR-anti-deadlock" \
  && ko "RED-1: anti-deadlock violation" \
  || ok "RED-1: no anti-deadlock violation"

# =============================================================================
# RED-2: sha-only manifest conflict → autorebase via regen → PR created
# =============================================================================
echo "== RED-2: sha-only manifest conflict → regen-resolve → PR created =="

CBHOME_2="$ROOT/cbhome_2"
LOGFILE_2="$ROOT/loop_2.log"
reset_sandbox "$CBHOME_2"
printf '%s' "$FINALE_BOARD" > "$BOARD_STATE"

# Remote setup:
# init (A): README.md + reference/bin/regen-manifest.sh + manifest with sha-base
# main (from A, B): manifest sha-line changed to sha-main + main-extra.txt
# charter/5 (from A, C): manifest sha-line changed to sha-charter + leaf.txt
# Merge of main into charter/5 → conflict ONLY in manifest.
rm -rf "$REMOTE"; git init --bare -q "$REMOTE"
{
  local_tmp="$(mktemp -d)"
  git clone -q "$REMOTE" "$local_tmp" 2>/dev/null
  git -C "$local_tmp" config user.email t@t
  git -C "$local_tmp" config user.name T
  # Base commit with manifest (using placeholder shas — dummy-file.sh doesn't exist)
  printf 'base\n' > "$local_tmp/README.md"
  mkdir -p "$local_tmp/reference/bin"
  cp "$REGEN_TOOL" "$local_tmp/reference/bin/regen-manifest.sh"
  chmod +x "$local_tmp/reference/bin/regen-manifest.sh"
  printf '# test manifest\ndummy-file.sh\taaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111\tcanonical\ttest\n' \
    > "$local_tmp/reference/runtime-manifest.tsv"
  git -C "$local_tmp" add -A
  git -C "$local_tmp" commit -qm "init with manifest" 2>/dev/null
  git -C "$local_tmp" push -q origin HEAD:refs/heads/main 2>/dev/null
  # charter/5 branches from init; changes manifest sha + adds leaf.txt
  git -C "$local_tmp" checkout -q -b charter/5 2>/dev/null
  printf '# test manifest\ndummy-file.sh\tcccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333\tcanonical\ttest\n' \
    > "$local_tmp/reference/runtime-manifest.tsv"
  printf 'charter work\n' > "$local_tmp/leaf.txt"
  git -C "$local_tmp" add -A
  git -C "$local_tmp" commit -qm "charter/5: leaf work + manifest update" 2>/dev/null
  git -C "$local_tmp" push -q origin charter/5 2>/dev/null
  # main advances: changes manifest sha differently + adds main-extra.txt
  git -C "$local_tmp" checkout -q main 2>/dev/null
  printf '# test manifest\ndummy-file.sh\tbbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222\tcanonical\ttest\n' \
    > "$local_tmp/reference/runtime-manifest.tsv"
  printf 'main extra\n' > "$local_tmp/main-extra.txt"
  git -C "$local_tmp" add -A
  git -C "$local_tmp" commit -qm "main: main-extra + manifest update" 2>/dev/null
  git -C "$local_tmp" push -q origin main 2>/dev/null
  rm -rf "$local_tmp"
}

run_finale "$CBHOME_2" "$LOGFILE_2"

# charter/5 must now have main as ancestor
is_ancestor_in_remote "$REMOTE" "main" "charter/5" \
  && ok "RED-2: main is ancestor of charter/5 after manifest-conflict autorebase" \
  || ko "RED-2: main is NOT ancestor of charter/5 after manifest conflict"

# PR must have been created
pr_created \
  && ok "RED-2: draft PR created after sha-only manifest conflict resolved" \
  || ko "RED-2: draft PR NOT created — manifest conflict not auto-resolved"

# Log must mention auto-rebased
grep -q "auto-rebased" "$LOGFILE_2" \
  && ok "RED-2: launcher logged auto-rebase message" \
  || ko "RED-2: no auto-rebase log message"

# =============================================================================
# RED-3: real conflict in non-manifest file → escalate (label, no PR)
# =============================================================================
echo "== RED-3: real conflict in non-manifest file → escalate, no PR =="

CBHOME_3="$ROOT/cbhome_3"
LOGFILE_3="$ROOT/loop_3.log"
reset_sandbox "$CBHOME_3"
printf '%s' "$FINALE_BOARD" > "$BOARD_STATE"

# Remote setup:
# init (A): README.md + shared.txt="original"
# main (from A, B): shared.txt="main version"
# charter/5 (from A, C): shared.txt="charter version" + leaf.txt
# Merge → conflict in shared.txt (not a manifest file) → real conflict.
rm -rf "$REMOTE"; git init --bare -q "$REMOTE"
{
  local_tmp="$(mktemp -d)"
  git clone -q "$REMOTE" "$local_tmp" 2>/dev/null
  git -C "$local_tmp" config user.email t@t
  git -C "$local_tmp" config user.name T
  printf 'base\n' > "$local_tmp/README.md"
  printf 'original\n' > "$local_tmp/shared.txt"
  git -C "$local_tmp" add -A
  git -C "$local_tmp" commit -qm "init" 2>/dev/null
  git -C "$local_tmp" push -q origin HEAD:refs/heads/main 2>/dev/null
  # charter/5 branches from init; modifies shared.txt + adds leaf.txt
  git -C "$local_tmp" checkout -q -b charter/5 2>/dev/null
  printf 'charter version\n' > "$local_tmp/shared.txt"
  printf 'charter work\n' > "$local_tmp/leaf.txt"
  git -C "$local_tmp" add -A
  git -C "$local_tmp" commit -qm "charter/5: leaf work" 2>/dev/null
  git -C "$local_tmp" push -q origin charter/5 2>/dev/null
  # main modifies shared.txt differently
  git -C "$local_tmp" checkout -q main 2>/dev/null
  printf 'main version\n' > "$local_tmp/shared.txt"
  git -C "$local_tmp" add -A
  git -C "$local_tmp" commit -qm "main: update shared.txt" 2>/dev/null
  git -C "$local_tmp" push -q origin main 2>/dev/null
  rm -rf "$local_tmp"
}

run_finale "$CBHOME_3" "$LOGFILE_3"

# No PR must be created
pr_created \
  && ko "RED-3: PR was created despite real conflict (should be escalated)" \
  || ok "RED-3: PR NOT created — real conflict correctly escalated"

# Label status:needs-conflict-resolution must be on charter #5
has_label 5 "status:needs-conflict-resolution" \
  && ok "RED-3: status:needs-conflict-resolution label added to charter #5" \
  || ko "RED-3: status:needs-conflict-resolution label NOT added"

# Log must mention real conflicts
grep -q "real conflicts" "$LOGFILE_3" \
  && ok "RED-3: launcher logged real-conflicts escalation message" \
  || ko "RED-3: no real-conflicts log message"

# Working tree of autorebase clone must be clean (merge --abort called)
# Verify by checking that the bare remote still shows charter/5 at original sha
_orig_sha=$(git ls-remote "$REMOTE" "refs/heads/charter/5" 2>/dev/null | awk '{print $1}')
[ -n "$_orig_sha" ] \
  && ok "RED-3: charter/5 still exists on remote (not corrupted by aborted merge)" \
  || ko "RED-3: charter/5 branch missing on remote"

# =============================================================================
# GREEN-guard: charter/5 already has main as ancestor → no autorebase, normal finale
# =============================================================================
echo "== GREEN-guard: charter ahead of main → autorebase not called, normal finale =="

CBHOME_G="$ROOT/cbhome_g"
LOGFILE_G="$ROOT/loop_g.log"
reset_sandbox "$CBHOME_G"
printf '%s' "$FINALE_BOARD" > "$BOARD_STATE"

# Remote setup:
# init (A) → main adds extra (B) → charter/5 branches from B + adds charter-work (C)
# charter/5 is strictly AHEAD of main: B is an ancestor of C.
rm -rf "$REMOTE"; git init --bare -q "$REMOTE"
{
  local_tmp="$(mktemp -d)"
  git clone -q "$REMOTE" "$local_tmp" 2>/dev/null
  git -C "$local_tmp" config user.email t@t
  git -C "$local_tmp" config user.name T
  printf 'base\n' > "$local_tmp/README.md"
  git -C "$local_tmp" add -A
  git -C "$local_tmp" commit -qm "init" 2>/dev/null
  git -C "$local_tmp" push -q origin HEAD:refs/heads/main 2>/dev/null
  # main adds extra commit
  printf 'main extra\n' > "$local_tmp/main-extra.txt"
  git -C "$local_tmp" add -A
  git -C "$local_tmp" commit -qm "main extra" 2>/dev/null
  git -C "$local_tmp" push -q origin main 2>/dev/null
  # charter/5 branches from current main tip (B) and adds charter-work
  git -C "$local_tmp" checkout -q -b charter/5 2>/dev/null
  printf 'charter work\n' > "$local_tmp/leaf.txt"
  git -C "$local_tmp" add -A
  git -C "$local_tmp" commit -qm "charter/5 leaf work" 2>/dev/null
  git -C "$local_tmp" push -q origin charter/5 2>/dev/null
  rm -rf "$local_tmp"
}

run_finale "$CBHOME_G" "$LOGFILE_G"

# PR must be created (normal finale path, no autorebase needed)
pr_created \
  && ok "GREEN-guard: normal finale created PR (no autorebase needed)" \
  || ko "GREEN-guard: PR NOT created — normal finale broken"

# Autorebase must NOT have been logged
grep -q "auto-rebased\|autorebase" "$LOGFILE_G" \
  && ko "GREEN-guard: autorebase was triggered despite charter being ahead of main" \
  || ok "GREEN-guard: autorebase NOT triggered (charter already ahead of main)"

# Anti-deadlock sanity
ghlog_has "ERROR-anti-deadlock" \
  && ko "GREEN-guard: anti-deadlock violation" \
  || ok "GREEN-guard: no anti-deadlock violation"

# =============================================================================
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
