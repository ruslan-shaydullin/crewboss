#!/usr/bin/env bash
# finale-hygiene.test.sh — CONTRACT test suite for charter #1291 (finale-hygiene).
#
# Written BEFORE any implementation merges (qa-owned; executors are gate-blocked
# from tests/ and *.test.*). This exact path is referenced by four downstream
# acceptance blocks — renaming is FORBIDDEN.
#
# Extends the harness patterns of charter-finale.test.sh / finale-autorebase.test.sh:
#   * stub `gh` + throwaway bare git remote
#   * drives the REAL launcher (`bash "$LAUNCHER" run`) for the finale path
#   * harness counts failures; success == `[ "$fail" = 0 ]`
#
# ── Feature-detection skip-guards (mandatory) ────────────────────────────────
# The suite MUST exit 0 on bare main (before implementation merges), with any
# not-yet-implemented group reported as SKIP (never PASS). Each group self-
# activates by detecting its implementation marker in the deployed runtime, so
# the tests turn live automatically when the implementation PR merges:
#   * P1/P2 group : grep -q CB_FINALE_CONFLICT_CAP reference/runtime/crewboss-launcher-gh.sh
#   * P3 group    : grep -q _cb_role_guard         reference/runtime/crewboss-launcher-gh.sh
#                   (_cb_role_guard is the NORMATIVE guard function name — rename forbidden)
#   * P4 group    : grep -q taxonomy               reference/runtime/crewboss-doctor.sh
#
# Requires: jq, git, bash, flock.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
INTEGRATOR="${INTEGRATOR_OVERRIDE:-$HERE/../runtime/crewboss-integrator.sh}"
LAUNCHER="${LAUNCHER_OVERRIDE:-$HERE/../runtime/crewboss-launcher-gh.sh}"
DOCTOR="${DOCTOR_OVERRIDE:-$HERE/../runtime/crewboss-doctor.sh}"
BOARD_GH_SRC="$HERE/../../proto/r6/board-gh.sh"
LAUNCHABLE_SRC="$HERE/../../proto/r6/launchable.sh"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0; skips=0
ok(){   pass=$((pass+1));   printf 'ok    %s\n' "$1"; }
ko(){   fail=$((fail+1));   printf 'FAIL  %s\n' "$1"; }
skip(){ skips=$((skips+1)); printf 'SKIP  %s\n' "$1"; }

# ── implementation-marker detectors (self-activation) ────────────────────────
launcher_has_conflict_cap(){ grep -q 'CB_FINALE_CONFLICT_CAP' "$LAUNCHER" 2>/dev/null; }
launcher_has_role_guard(){   grep -q '_cb_role_guard'         "$LAUNCHER" 2>/dev/null; }
doctor_has_taxonomy(){       grep -q 'taxonomy'               "$DOCTOR"    2>/dev/null; }

# ── shared harness state ─────────────────────────────────────────────────────
REMOTE="$ROOT/remote.git"
SANDBOX="$ROOT/sb"
BOARD_STATE="$SANDBOX/board.json"
GH_LOG="$SANDBOX/gh.log"
PRDIR="$SANDBOX/prs"
export REMOTE SANDBOX BOARD_STATE GH_LOG PRDIR
BIN="$ROOT/bin"; mkdir -p "$BIN"
CLEAN_GATE_DIR="$ROOT/clean_gate_dir"; mkdir -p "$CLEAN_GATE_DIR"

# ── helpers ──────────────────────────────────────────────────────────────────
ghlog_has(){ grep -q "$1" "$GH_LOG" 2>/dev/null; }
pr_created5(){ ghlog_has "pr-create charter/5->main"; }
has_label(){ [ "$(jq -r --argjson n "$1" 'map(select(.number==$n))[0].labels[]?.name' \
               "$BOARD_STATE" 2>/dev/null | grep -c "^$2$")" -ge 1 ]; }
has_comment(){ jq -r --argjson n "$1" 'map(select(.number==$n))[0].comments[]?.body' \
               "$BOARD_STATE" 2>/dev/null | grep -qi "$2"; }

# add a label to charter #5 in $BOARD_STATE
add_charter5_label(){ jq --arg l "$1" \
  'map(if .number==5 then .labels += [{name:$l}] else . end)' \
  "$BOARD_STATE" > "$BOARD_STATE.t" && mv "$BOARD_STATE.t" "$BOARD_STATE"; }
# remove a label from charter #5
rm_charter5_label(){ jq --arg l "$1" \
  'map(if .number==5 then .labels = [(.labels[]|select(.name!=$l))] else . end)' \
  "$BOARD_STATE" > "$BOARD_STATE.t" && mv "$BOARD_STATE.t" "$BOARD_STATE"; }

# Board: charter #5 OPEN+approved, leaf #10 CLOSED → finale-ready.
FINALE_BOARD='[
  {"number":5,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],
   "body":"charter five","comments":[]},
  {"number":10,"state":"CLOSED","labels":[{"name":"type:agent"}],
   "body":"task A\nCharter: #5\n## Acceptance (machine)\n- check: true","comments":[]}
]'

# ── gh stub (charter-finale / finale-autorebase lineage) ─────────────────────
write_gh_stub(){
cat > "$BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
obj="$1"; verb="$2"; shift 2
_args=()
while [ $# -gt 0 ]; do
  case "$1" in -R|--repo|-L|--limit) shift ;; *) _args+=("$1") ;; esac; shift
done
set -- "${_args[@]+"${_args[@]}"}"
case "$obj $verb" in
  "issue list") cat "$BOARD_STATE" ;;
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
    head=""; state_filter="open"
    while [ $# -gt 0 ]; do
      case "$1" in
        --head)  head="$2"; shift ;;
        --base)  shift ;;
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
      else echo "[]"; fi
    else echo "[]"; fi ;;
  "pr create")
    draft=false; base="main"; head=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --draft) draft=true ;;
        --base)  base="$2"; shift ;;
        --head)  head="$2"; shift ;;
        --title|-t|--body|-b) shift ;;
      esac; shift
    done
    echo "pr-create ${head}->${base} draft=${draft}" >> "$GH_LOG"
    if printf '%s' "$head" | grep -q '^charter/'; then
      charter_n="${head#charter/}"
      pr_num=$((5000 + charter_n))
      printf '%s' "$pr_num" > "$PRDIR/charter-pr-$charter_n"
      printf 'https://github.com/test/repo/pull/%s\n' "$pr_num"
    fi ;;
  "pr ready") echo "pr-ready $1" >> "$GH_LOG"; touch "$PRDIR/charter-pr-ready-$1" ;;
  "pr checks")
    n="$1"; echo "pr-checks $n" >> "$GH_LOG"
    charter_n=""
    for f in "$PRDIR"/charter-pr-[0-9]*; do
      [ -f "$f" ] || continue
      [ "$(cat "$f" 2>/dev/null)" = "$n" ] && { charter_n="${f##*/charter-pr-}"; break; }
    done
    if [ -z "$charter_n" ]; then
      echo "ERROR-anti-deadlock: pr-checks called before pr-create for PR $n" >> "$GH_LOG"; exit 1
    fi
    status="$(cat "$PRDIR/charter-checks-$charter_n" 2>/dev/null || echo success)"
    case "$status" in success) exit 0 ;; failure) exit 1 ;; pending) exit 1 ;; *) exit 1 ;; esac ;;
  "pr merge") echo "pr-merge $1" >> "$GH_LOG" ;;
  "label create") ;;
  *) echo "gh-stub UNHANDLED: $obj $verb $*" >> "$GH_LOG" ;;
esac
exit 0
GHEOF
chmod +x "$BIN/gh"
}

# ── git remote fixtures ──────────────────────────────────────────────────────
_new_remote(){ rm -rf "$REMOTE"; git init --bare -q "$REMOTE"; }
_clone_tmp(){
  local t; t="$(mktemp -d)"
  git clone -q "$REMOTE" "$t" 2>/dev/null
  git -C "$t" config user.email t@t; git -C "$t" config user.name T
  printf '%s' "$t"
}
# charter/5 branches from main tip then adds work → main IS ancestor (clean, ahead).
remote_ahead(){
  _new_remote; local t; t="$(_clone_tmp)"
  printf 'base\n' > "$t/README.md"; git -C "$t" add -A; git -C "$t" commit -qm init
  git -C "$t" push -q origin HEAD:refs/heads/main
  git -C "$t" checkout -q -b charter/5
  printf 'leaf\n' > "$t/leaf.txt"; git -C "$t" add -A; git -C "$t" commit -qm "charter/5 work"
  git -C "$t" push -q origin charter/5
  rm -rf "$t"
}
# main advances AFTER charter/5 branched, no file overlap → behind, clean autorebase.
remote_behind_clean(){
  _new_remote; local t; t="$(_clone_tmp)"
  printf 'base\n' > "$t/README.md"; git -C "$t" add -A; git -C "$t" commit -qm init
  git -C "$t" push -q origin HEAD:refs/heads/main
  git -C "$t" checkout -q -b charter/5
  printf 'leaf\n' > "$t/leaf.txt"; git -C "$t" add -A; git -C "$t" commit -qm "charter/5 work"
  git -C "$t" push -q origin charter/5
  git -C "$t" checkout -q main
  printf 'main extra\n' > "$t/main-extra.txt"; git -C "$t" add -A; git -C "$t" commit -qm "main extra"
  git -C "$t" push -q origin main
  rm -rf "$t"
}
# main & charter/5 both edit shared.txt → real, non-manifest conflict on rebase.
remote_diverged_conflict(){
  _new_remote; local t; t="$(_clone_tmp)"
  printf 'base\n' > "$t/README.md"; printf 'original\n' > "$t/shared.txt"
  git -C "$t" add -A; git -C "$t" commit -qm init
  git -C "$t" push -q origin HEAD:refs/heads/main
  git -C "$t" checkout -q -b charter/5
  printf 'charter version\n' > "$t/shared.txt"; printf 'leaf\n' > "$t/leaf.txt"
  git -C "$t" add -A; git -C "$t" commit -qm "charter/5 work"
  git -C "$t" push -q origin charter/5
  git -C "$t" checkout -q main
  printf 'main version\n' > "$t/shared.txt"
  git -C "$t" add -A; git -C "$t" commit -qm "main edits shared"
  git -C "$t" push -q origin main
  rm -rf "$t"
}
# only main; charter/5 was recycled/deleted by the operator (per #306/#291).
remote_deleted_branch(){
  _new_remote; local t; t="$(_clone_tmp)"
  printf 'base\n' > "$t/README.md"; git -C "$t" add -A; git -C "$t" commit -qm init
  git -C "$t" push -q origin HEAD:refs/heads/main
  rm -rf "$t"
}
delete_charter5_on_remote(){
  local t; t="$(_clone_tmp)"
  git -C "$t" push -q origin --delete charter/5 2>/dev/null || true
  rm -rf "$t"
}

reset_sandbox(){
  rm -rf "$SANDBOX"; mkdir -p "$SANDBOX" "$PRDIR"; : > "$GH_LOG"
  local cbhome="$1"; rm -rf "$cbhome"; mkdir -p "$cbhome"
  cp "$BOARD_GH_SRC"   "$cbhome/board-gh.sh"
  cp "$LAUNCHABLE_SRC" "$cbhome/launchable.sh"
  chmod +x "$cbhome/board-gh.sh" "$cbhome/launchable.sh"
}

# run_finale <cbhome> <logfile> <extra_env> <path_prefix> <max_ticks>
run_finale(){
  local cbhome="$1" logfile="${2:-/dev/null}" extra_env="${3:-}" pathpre="${4:-}" maxt="${5:-12}"
  eval "env -u CREWBOSS_CHARTER -u CHARTER_SCOPE \
    PATH=\"${pathpre}$BIN:$PATH\" \
    CB_REPO=\"test/repo\" \
    CB_HOME=\"$cbhome\" \
    CB_GIT_REMOTE=\"$REMOTE\" \
    CB_INTEGRATOR=\"$INTEGRATOR\" \
    CB_GATE_REPO_DIR=\"$CLEAN_GATE_DIR\" \
    CB_POLL=0 CB_MAX_TICKS=$maxt CB_IDLE_CONFIRM=2 CB_MAX_PARALLEL=2 CB_RETRY_CAP=2 \
    CB_FINALE_CHECKS_TIMEOUT=0 CB_FINALE_CHECKS_POLL=0 \
    $extra_env \
    bash \"$LAUNCHER\" run >\"$logfile\" 2>&1" || true
}

# =============================================================================
# GROUP P1 + P2 — finale park semantics & fetch-cache
# marker: CB_FINALE_CONFLICT_CAP in the launcher
# =============================================================================
echo "== GROUP P1/P2: finale park semantics + fetch-cache (marker: CB_FINALE_CONFLICT_CAP) =="
if launcher_has_conflict_cap; then
  write_gh_stub

  # ── P1.0 positive control: clean finale-ready charter DOES create a PR ──────
  CBH="$ROOT/p1_0"; reset_sandbox "$CBH"; remote_ahead
  printf '%s' "$FINALE_BOARD" > "$BOARD_STATE"
  run_finale "$CBH" "$ROOT/p1_0.log"
  pr_created5 \
    && ok "P1.0 control: finale-ready charter (no veto) creates PR" \
    || ko "P1.0 control: finale-ready charter did NOT create PR (harness broken)"

  # ── P1.1 bare `hold` label → skipped (live operator veto) ──────────────────
  CBH="$ROOT/p1_1"; reset_sandbox "$CBH"; remote_ahead
  printf '%s' "$FINALE_BOARD" > "$BOARD_STATE"; add_charter5_label "hold"
  run_finale "$CBH" "$ROOT/p1_1.log"
  pr_created5 \
    && ko "P1.1: charter with bare 'hold' label was NOT skipped (PR created)" \
    || ok "P1.1: charter with bare 'hold' label is skipped (operator veto honored)"

  # ── P1.2 status:hold label → skipped (separate fixture) ────────────────────
  CBH="$ROOT/p1_2"; reset_sandbox "$CBH"; remote_ahead
  printf '%s' "$FINALE_BOARD" > "$BOARD_STATE"; add_charter5_label "status:hold"
  run_finale "$CBH" "$ROOT/p1_2.log"
  pr_created5 \
    && ko "P1.2: charter with 'status:hold' was NOT skipped (PR created)" \
    || ok "P1.2: charter with 'status:hold' is skipped"

  # ── P1.3 status:needs-conflict-resolution → parked, NO retry ───────────────
  CBH="$ROOT/p1_3"; reset_sandbox "$CBH"; remote_ahead
  printf '%s' "$FINALE_BOARD" > "$BOARD_STATE"; add_charter5_label "status:needs-conflict-resolution"
  run_finale "$CBH" "$ROOT/p1_3.log"
  pr_created5 \
    && ko "P1.3: parked charter (status:needs-conflict-resolution) still processed (PR created)" \
    || ok "P1.3: status:needs-conflict-resolution is consumed → charter parked, no retry"

  # ── P1.4 consecutive-conflict counter caps at CB_FINALE_CONFLICT_CAP then parks ─
  #   cap=2: tick1 conflict (no label) → tick2 conflict == cap (label+park).
  #   Remove label (un-park, counter resets): tick3 conflict → NOT re-parked;
  #   tick4 conflict == cap → re-parked.
  CBH="$ROOT/p1_4"; reset_sandbox "$CBH"; remote_diverged_conflict
  printf '%s' "$FINALE_BOARD" > "$BOARD_STATE"
  CAPENV='CB_FINALE_CONFLICT_CAP=2'
  run_finale "$CBH" "$ROOT/p1_4t1.log" "$CAPENV" "" 1
  has_label 5 "status:needs-conflict-resolution" \
    && ko "P1.4: charter parked after only 1 conflict (cap=2 not respected)" \
    || ok "P1.4: 1 conflict < cap(2) → not yet parked"
  run_finale "$CBH" "$ROOT/p1_4t2.log" "$CAPENV" "" 1
  has_label 5 "status:needs-conflict-resolution" \
    && ok "P1.4: counter reached cap(2) → status:needs-conflict-resolution set + parked" \
    || ko "P1.4: counter did NOT cap at 2 (charter never parked)"
  # un-park: operator removes the label → counter must reset
  rm_charter5_label "status:needs-conflict-resolution"
  run_finale "$CBH" "$ROOT/p1_4t3.log" "$CAPENV" "" 1
  has_label 5 "status:needs-conflict-resolution" \
    && ko "P1.4: un-park did NOT reset counter (re-parked after a single conflict)" \
    || ok "P1.4: removing the label un-parks and resets the counter"
  run_finale "$CBH" "$ROOT/p1_4t4.log" "$CAPENV" "" 1
  has_label 5 "status:needs-conflict-resolution" \
    && ok "P1.4: counter re-caps after un-park → re-parked at cap" \
    || ko "P1.4: counter did not re-cap after un-park"

  # ── P2.1 fetch-cache: NO `git clone --bare` per tick after warm-up ─────────
  GITBIN="$ROOT/gitbin"; mkdir -p "$GITBIN"
  REALGIT="$(command -v git)"
  CLONE_BARE_LOG="$ROOT/clone_bare.log"; : > "$CLONE_BARE_LOG"
  cat > "$GITBIN/git" <<GITEOF
#!/usr/bin/env bash
_is_clone=0; _is_bare=0
[ "\${1:-}" = "clone" ] && _is_clone=1
for a in "\$@"; do [ "\$a" = "--bare" ] && _is_bare=1; done
[ "\$_is_clone" = 1 ] && [ "\$_is_bare" = 1 ] && echo bare-clone >> "$CLONE_BARE_LOG"
exec "$REALGIT" "\$@"
GITEOF
  chmod +x "$GITBIN/git"
  CBH="$ROOT/p2_1"; reset_sandbox "$CBH"; remote_ahead
  printf '%s' "$FINALE_BOARD" > "$BOARD_STATE"
  run_finale "$CBH" "$ROOT/p2_1.log" "" "$GITBIN:" 3
  _nbare=$(grep -c bare-clone "$CLONE_BARE_LOG" 2>/dev/null || echo 0)
  [ "$_nbare" -eq 0 ] \
    && ok "P2.1: ancestor-check uses fetch-cache — 0 'git clone --bare' across ticks" \
    || ko "P2.1: ancestor-check still bare-clones ($_nbare 'git clone --bare' calls)"

  # ── P2.2 ancestry verdicts identical to old behavior ───────────────────────
  CBH="$ROOT/p2_2a"; reset_sandbox "$CBH"; remote_ahead
  printf '%s' "$FINALE_BOARD" > "$BOARD_STATE"; run_finale "$CBH" "$ROOT/p2_2a.log"
  pr_created5 \
    && ok "P2.2 ahead: main-is-ancestor → PR created" \
    || ko "P2.2 ahead: verdict changed (no PR for an ahead charter)"
  CBH="$ROOT/p2_2b"; reset_sandbox "$CBH"; remote_behind_clean
  printf '%s' "$FINALE_BOARD" > "$BOARD_STATE"; run_finale "$CBH" "$ROOT/p2_2b.log"
  pr_created5 \
    && ok "P2.2 behind-clean: rebased then PR created" \
    || ko "P2.2 behind-clean: verdict changed (no PR after clean rebase)"
  CBH="$ROOT/p2_2c"; reset_sandbox "$CBH"; remote_diverged_conflict
  printf '%s' "$FINALE_BOARD" > "$BOARD_STATE"; run_finale "$CBH" "$ROOT/p2_2c.log"
  pr_created5 \
    && ko "P2.2 diverged: PR created despite real conflict (verdict changed)" \
    || ok "P2.2 diverged: real conflict → no PR (verdict preserved)"

  # ── P2.3 deleted-branch fixture: cache prunes stale ref, does NOT error ─────
  CBH="$ROOT/p2_3"; reset_sandbox "$CBH"; remote_ahead
  printf '%s' "$FINALE_BOARD" > "$BOARD_STATE"
  run_finale "$CBH" "$ROOT/p2_3a.log"        # warm the cache (charter/5 present)
  delete_charter5_on_remote                  # operator recycles the zombie branch
  run_finale "$CBH" "$ROOT/p2_3b.log"        # second tick: stale cached ref must be pruned
  if grep -qiE 'fatal:|couldn.t find remote ref|unknown revision|bad revision' "$ROOT/p2_3b.log"; then
    ko "P2.3: deleted/recycled branch caused a hard git error (cache did not prune)"
  else
    ok "P2.3: recycled zombie branch handled — cache prunes stale ref, no hard error"
  fi
else
  skip "P1 park semantics — CB_FINALE_CONFLICT_CAP not in launcher (not implemented yet)"
  skip "P1 conflict-cap (CB_FINALE_CONFLICT_CAP) park/un-park — not implemented yet"
  skip "P2 fetch-cache — no bare-clone per tick — not implemented yet"
  skip "P2 ancestry verdicts identical (ahead/behind/diverged) — not implemented yet"
  skip "P2 deleted-branch fetch-cache prune — not implemented yet"
fi

# =============================================================================
# GROUP P3 — role-presence guard (_cb_role_guard)
# marker: _cb_role_guard in the launcher
# =============================================================================
echo "== GROUP P3: role-presence guard (marker: _cb_role_guard) =="
if launcher_has_role_guard; then
  # Isolate the launcher's function library (strip the trailing CLI dispatch) so
  # _cb_role_guard can be exercised directly, then route to a role that CANNOT
  # exist in any catalog root (team/roles, gov, repo .claude/agents).
  STRIP="$ROOT/launcher-funcs.sh"
  awk '/^case "\$\{1:-once\}" in/{exit} {print}' "$LAUNCHER" > "$STRIP"

  P3HOME="$ROOT/p3home"; mkdir -p "$P3HOME/run/state"
  P3OUT="$ROOT/p3.out"; P3CMT="$ROOT/p3.comments"; P3BOARD="$ROOT/p3.board-ops"
  : > "$P3OUT"; : > "$P3CMT"; : > "$P3BOARD"
  MISSING_ROLE="zzz-nonexistent-role-abc123"

  P3RUN="$ROOT/p3-runner.sh"
  cat > "$P3RUN" <<P3EOF
#!/usr/bin/env bash
set +u
export CB_HOME="$P3HOME" CB_REPO="test/repo" CB_GIT_REMOTE=""
# stub gh: record any issue comment (the loud, retryable refusal names the role)
gh(){ if [ "\${1:-} \${2:-}" = "issue comment" ]; then shift 2; printf 'comment %s\n' "\$*" >> "$P3CMT"; fi; return 0; }
# stub board: any status-mutation attempt is recorded (must NOT happen — item stays retryable)
board(){ printf 'board %s\n' "\$*" >> "$P3BOARD"; return 0; }
source "$STRIP" >/dev/null 2>&1 || true
if declare -f _cb_role_guard >/dev/null 2>&1; then
  _cb_role_guard 42 "$MISSING_ROLE" > "$P3OUT" 2>&1
  echo "rc=\$?" >> "$P3OUT"
else
  echo "NO_GUARD_FN" > "$P3OUT"; echo "rc=127" >> "$P3OUT"
fi
P3EOF
  chmod +x "$P3RUN"
  timeout 30 bash "$P3RUN" >/dev/null 2>&1 || true

  _p3rc="$(grep -o 'rc=[0-9]*' "$P3OUT" | tail -1 | cut -d= -f2)"; _p3rc="${_p3rc:-127}"

  if grep -q NO_GUARD_FN "$P3OUT"; then
    ko "P3: _cb_role_guard not defined after sourcing launcher functions"
  else
    ok "P3: _cb_role_guard is defined and callable"
  fi
  [ "$_p3rc" != "0" ] \
    && ok "P3: absent role → guard returns non-zero (refuses, not a silent success)" \
    || ko "P3: absent role → guard returned 0 (silent death path)"
  { grep -qi "$MISSING_ROLE" "$P3OUT" || grep -qi "$MISSING_ROLE" "$P3CMT"; } \
    && ok "P3: refusal is LOUD — the missing role name is named (log/comment)" \
    || ko "P3: refusal did not name the missing role"
  grep -qi "$MISSING_ROLE" "$P3CMT" \
    && ok "P3: an issue comment names the missing role (visible on the board)" \
    || ko "P3: no issue comment naming the missing role"
  grep -qiE '\broute\b|status:' "$P3BOARD" \
    && ko "P3: guard mutated item status (must leave it in-place, retryable)" \
    || ok "P3: item left in current status (retryable — no silent session death)"
else
  skip "P3 role-presence guard (_cb_role_guard) — not implemented yet"
fi

# =============================================================================
# GROUP P4 — doctor label-taxonomy lint (report-only)
# marker: taxonomy in crewboss-doctor.sh
# =============================================================================
echo "== GROUP P4: doctor taxonomy lint (marker: taxonomy) =="
if doctor_has_taxonomy; then
  write_gh_stub
  P4HOME="$ROOT/p4home"; mkdir -p "$P4HOME"   # no manifest → drift check skipped
  rm -rf "$SANDBOX"; mkdir -p "$SANDBOX" "$PRDIR"; : > "$GH_LOG"
  # Board with a spread of labels:
  #   status:approved / status:review → canonical taxonomy (must PASS)
  #   hold                            → canonical live veto (must NOT be flagged)
  #   status:hold                     → orphan (empty desc, zero consumers) → FLAG
  #   status:frobnicate               → unknown status:*-shaped label       → FLAG
  cat > "$BOARD_STATE" <<'LB'
[
  {"number":5,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],"body":"c","comments":[]},
  {"number":6,"state":"OPEN","labels":[{"name":"status:review"}],"body":"r","comments":[]},
  {"number":7,"state":"OPEN","labels":[{"name":"hold"}],"body":"veto","comments":[]},
  {"number":8,"state":"OPEN","labels":[{"name":"status:hold"}],"body":"orphan","comments":[]},
  {"number":9,"state":"OPEN","labels":[{"name":"status:frobnicate"}],"body":"unknown","comments":[]}
]
LB
  _before="$(sha256sum "$BOARD_STATE" | awk '{print $1}')"
  P4OUT="$ROOT/p4.out"
  env -u CB_API_PORT PATH="$BIN:$PATH" CB_REPO="test/repo" CB_HOME="$P4HOME" \
    bash "$DOCTOR" --lint-labels > "$P4OUT" 2>&1 || true
  _after="$(sha256sum "$BOARD_STATE" | awk '{print $1}')"

  grep -Eq 'LINT-FLAG:[[:space:]]*status:hold( |$)' "$P4OUT" \
    && ok "P4: orphan 'status:hold' is flagged" \
    || ko "P4: orphan 'status:hold' was NOT flagged"
  grep -Eq 'LINT-FLAG:[[:space:]]*status:frobnicate( |$)' "$P4OUT" \
    && ok "P4: unknown 'status:frobnicate' (status:*-shaped) is flagged" \
    || ko "P4: unknown 'status:frobnicate' was NOT flagged"
  grep -Eq 'LINT-FLAG:[[:space:]]*hold( |$)' "$P4OUT" \
    && ko "P4: bare 'hold' was flagged (it is the canonical live veto, not a typo)" \
    || ok "P4: bare 'hold' is NOT flagged (canonical veto preserved)"
  grep -Eq 'LINT-FLAG:[[:space:]]*status:approved( |$)' "$P4OUT" \
    && ko "P4: canonical 'status:approved' was flagged (taxonomy label must pass)" \
    || ok "P4: canonical 'status:approved' passes"
  grep -Eq 'LINT-FLAG:[[:space:]]*status:review( |$)' "$P4OUT" \
    && ko "P4: canonical 'status:review' was flagged (taxonomy label must pass)" \
    || ok "P4: canonical 'status:review' passes"
  [ "$_before" = "$_after" ] \
    && ok "P4: lint is report-only — board state not mutated" \
    || ko "P4: lint MUTATED the board (must be report-only)"
else
  skip "P4 doctor taxonomy lint — 'taxonomy' not in crewboss-doctor.sh (not implemented yet)"
fi

# =============================================================================
echo
printf 'passed=%d failed=%d skipped=%d\n' "$pass" "$fail" "$skips"
[ "$fail" = 0 ]
