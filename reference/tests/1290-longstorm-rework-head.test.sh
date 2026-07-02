#!/usr/bin/env bash
# 1290-longstorm-rework-head.test.sh — charter #1290 / issue #1302 (qa-engineer test-writer leaf).
#
# The capstone case: a LONG RL-storm that outlasts the smoke-infra tick cap, on a
# leaf that is currently on a `rework/<rid>-*` head (the incident's exact shape —
# leaf #1281 was mid-rework when the core pool burned 04:31–05:31 UTC).
#
# Approved analysis intent (charter #1290, round-4 REVIEW: agreed):
#   * smoke-infra cap exhaustion swaps status:review -> status:deferred in the
#     INTEGRATOR itself (exit 2, ONE defer comment, leaf leaves `board review-leaves`).
#   * id extraction extended to `(leaf|rework)/<id>` at integrator :556 / :595 (so a
#     rework head is recognised — today `grep -oE 'leaf/([0-9]+)'` misses it).
#   * rework_n is NOT touched, there is NO exit-1, and NO RED comment is posted (this
#     is infra, not a code red).
#   * storm ends + next GREEN verify -> smoke_infra_ticks + flake_n counters cleared.
#
# HARNESS: drive the REAL cmd_verify_merged against bare-remote fixtures whose merged
# tree carries a smoke-runner.sh stub returning infra (exit 3). A PATH gh stub + a stub
# board let us observe the review->deferred swap and `board review-leaves`.
#
# CONVENTION (tests-first, runnable standalone / GREEN now):
#   * REGRESSION — below the cap, a rework-head infra tick is a retryable red (exit 3)
#     that bumps the smoke_infra_ticks counter and never confirms. Asserted NOW.
#   * NEW-behaviour — the review->deferred swap at cap and the next-green counter reset
#     are gated behind the `status:deferred` marker in the integrator. Before the P1
#     impl lands they SKIP (never a silent pass); once it lands they assert the full
#     defer contract.
#
# CLASSIFICATION: EXCLUDED in reference/runtime/per-leaf-manifest — drives the REAL
# cmd_verify_merged against bare-remote fixtures (recursive verify-merged) + a stub
# board; violates ALLOW purity, same precedent as 1109 / verify-merged-leaf-regen.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
INTEGRATOR="${INTEGRATOR_OVERRIDE:-$HERE/../runtime/crewboss-integrator.sh}"
BOARD_GH_SRC="$HERE/../../proto/r6/board-gh.sh"

pass=0; fail=0; skip=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }
sk(){ skip=$((skip+1)); printf 'SKIP %s\n' "$1"; }

# Feature probe: does the integrator carry the review->deferred smoke-infra swap?
DEFER_PRESENT=0
grep -q 'status:deferred' "$INTEGRATOR" 2>/dev/null && DEFER_PRESENT=1

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

RID=1302
BR="rework/${RID}-abc"
TG="charter/1290"

# ── seed_rework_remote <remote> <smoke_mode> ─────────────────────────────────────
# Bare remote: charter/1290 base + rework/1302-abc head. Merged tree has a passing
# ALLOW engine fixture, a no-op regen stub, and a smoke-runner.sh stub:
#   smoke_mode=infra -> exit 3 (SMOKE_REASON: infra:gh-403-board)
#   smoke_mode=green -> exit 0 (storm over)
seed_rework_remote() {
  local remote="$1" smoke="$2" tmp
  rm -rf "$remote"; git init --bare -q "$remote"
  tmp="$(mktemp -d)"
  git clone -q "$remote" "$tmp" 2>/dev/null
  git -C "$tmp" config user.email t@t; git -C "$tmp" config user.name T
  mkdir -p "$tmp/reference/bin" "$tmp/reference/tests" "$tmp/reference/runtime"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/reference/bin/regen-manifest.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/reference/tests/acceptance-block.test.sh"
  if [ "$smoke" = "green" ]; then
    printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/reference/runtime/smoke-runner.sh"
  else
    printf '#!/usr/bin/env bash\nprintf "SMOKE_REASON: infra:gh-403-board\\n"\nexit 3\n' \
      > "$tmp/reference/runtime/smoke-runner.sh"
  fi
  chmod +x "$tmp/reference/bin/regen-manifest.sh" "$tmp/reference/tests/acceptance-block.test.sh" \
           "$tmp/reference/runtime/smoke-runner.sh"
  printf 'base\n' > "$tmp/README.md"
  git -C "$tmp" add -A; git -C "$tmp" commit -qm base 2>/dev/null
  git -C "$tmp" push -q origin "HEAD:refs/heads/$TG" 2>/dev/null
  printf 'rework change\n' > "$tmp/rework.txt"
  git -C "$tmp" add -A; git -C "$tmp" commit -qm rework 2>/dev/null
  git -C "$tmp" push -q origin "HEAD:refs/heads/$BR" 2>/dev/null
  rm -rf "$tmp"
}

# run_vm <cache> <remote> [extra env-prefixed args...] -> RC + VM_OUT (RED_REASON on stdout)
run_vm() {
  local cache="$1" remote="$2"; shift 2; RC=0
  VM_OUT="$("$@" CB_VERIFY_CACHE="$cache" CB_VERIFY_CONFIRM_N=2 \
    bash "$INTEGRATOR" verify-merged "$BR" "$TG" --remote "$remote" 2>/dev/null)" || RC=$?
}
ticks_file() { ls "$1"/*.smoke_infra_ticks 2>/dev/null | head -1; }
ticks_val()  { local f; f="$(ticks_file "$1")"; [ -n "$f" ] && cat "$f" 2>/dev/null || echo 0; }

# ═══════════════════════════════════════════════════════════════════════════════
echo "== T1 (REGRESSION): rework-head infra tick below cap -> exit 3, counter bumps =="
# ═══════════════════════════════════════════════════════════════════════════════
C1="$ROOT/c1"; R1="$ROOT/r1.git"
seed_rework_remote "$R1" infra
run_vm "$C1" "$R1" env
[ "$RC" -eq 3 ] \
  && ok "T1: rework-head smoke-infra below cap -> exit 3 (retryable, not confirmed)" \
  || ko "T1: rework-head smoke-infra expected exit 3, got $RC (out: $VM_OUT)"
[ "$(ticks_val "$C1")" = "1" ] \
  && ok "T1: smoke_infra_ticks counter bumped to 1" \
  || ko "T1: smoke_infra_ticks expected 1, got $(ticks_val "$C1")"
printf '%s\n' "$VM_OUT" | grep -q '^RED_REASON:' \
  && ko "T1: infra tick wrongly emitted a RED_REASON (must be silent infra, not a code red)" \
  || ok "T1: infra tick emitted NO RED_REASON (infra != code red)"

# ═══════════════════════════════════════════════════════════════════════════════
echo "== T2 (NEW): storm outlasts the cap -> review->deferred swap on the rework head =="
# ═══════════════════════════════════════════════════════════════════════════════
if [ "$DEFER_PRESENT" -ne 1 ]; then
  sk "T2: status:deferred swap not present in integrator — P1 impl pending; defer-swap assertions skipped"
else
  BIN="$ROOT/bin"; mkdir -p "$BIN"
  BOARD_STATE="$ROOT/board.json"; GH_LOG="$ROOT/gh.log"
  export BOARD_STATE GH_LOG
  # Stateful gh stub (issue edit/comment/list/view) so the integrator's swap is observable.
  cat > "$BIN/gh" << 'GHEOF'
#!/usr/bin/env bash
obj="$1"; verb="$2"; shift 2
_args=()
while [ $# -gt 0 ]; do case "$1" in -R|--repo|-L|--limit) shift ;; *) _args+=("$1") ;; esac; shift; done
set -- "${_args[@]+"${_args[@]}"}"
case "$obj $verb" in
  "issue list") cat "$BOARD_STATE" ;;
  "issue view")
    n="$1"; shift; jqf=""
    while [ $# -gt 0 ]; do case "$1" in --jq|-q) jqf="$2"; shift ;; --json) shift ;; esac; shift; done
    o="$(jq --argjson n "$n" 'map(select(.number==$n))[0] // {}' "$BOARD_STATE")"
    if [ -n "$jqf" ]; then printf '%s' "$o" | jq -r "$jqf"; else printf '%s\n' "$o"; fi ;;
  "issue edit")
    n="$1"; shift; adds=(); rems=()
    while [ $# -gt 0 ]; do case "$1" in --add-label) adds+=("$2"); shift ;; --remove-label) rems+=("$2"); shift ;; esac; shift; done
    adds_json="$(printf '%s\n' "${adds[@]+"${adds[@]}"}" | jq -R . | jq -s .)"
    rems_json="$(printf '%s\n' "${rems[@]+"${rems[@]}"}" | jq -R . | jq -s .)"
    jq --argjson n "$n" --argjson adds "$adds_json" --argjson rems "$rems_json" '
      map(if .number == $n then
        .labels = [(.labels // [])[] | select(.name as $nm | ($rems | index($nm)) == null)]
        | reduce $adds[] as $a (.; if ([.labels[].name] | index($a)) == null then .labels += [{name: $a}] else . end)
      else . end)' "$BOARD_STATE" > "$BOARD_STATE.t" && mv "$BOARD_STATE.t" "$BOARD_STATE" ;;
  "issue comment")
    n="$1"; shift; body=""
    while [ $# -gt 0 ]; do case "$1" in --body|-b) body="$2"; shift ;; esac; shift; done
    jq --argjson n "$n" --arg b "$body" 'map(if .number==$n then .comments=((.comments//[])+[{body:$b}]) else . end)' \
      "$BOARD_STATE" > "$BOARD_STATE.t" && mv "$BOARD_STATE.t" "$BOARD_STATE"
    printf 'comment #%s: %s\n' "$n" "$body" >> "$GH_LOG" ;;
  "label create") ;;
  "auth token") printf 'fake-token\n' ;;
  *) : ;;
esac
exit 0
GHEOF
  chmod +x "$BIN/gh"
  cp "$BOARD_GH_SRC" "$ROOT/board-gh.sh"; chmod +x "$ROOT/board-gh.sh"

  # Board: charter #1290 + leaf #1302 in status:review (awaiting integrator merge).
  cat > "$BOARD_STATE" << 'JSON'
[
  {"number":1290,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],"body":"charter","comments":[]},
  {"number":1302,"state":"OPEN","labels":[{"name":"type:agent"},{"name":"status:review"}],
   "body":"Charter: #1290\n## Acceptance (machine)\n- check: true","comments":[]}
]
JSON

  has_label(){ [ "$(jq -r --argjson n "$1" 'map(select(.number==$n))[0].labels[]?.name' "$BOARD_STATE" | grep -c "^${2}\$")" -ge 1 ]; }
  comment_count(){ jq -r --argjson n "$1" 'map(select(.number==$n))[0].comments | length' "$BOARD_STATE"; }

  C2="$ROOT/c2"; R2="$ROOT/r2.git"
  seed_rework_remote "$R2" infra
  # Drive ticks up to the cap (SMOKE_INFRA_MAX_TICKS=5). Same cache dir -> counter persists.
  LAST_RC=0
  for _i in 1 2 3 4 5; do
    run_vm "$C2" "$R2" env PATH="$BIN:$PATH" CB_REPO="test/repo"
    LAST_RC="$RC"
  done

  [ "$LAST_RC" -eq 2 ] \
    && ok "T2: cap reached -> exit 2 (infra defer, NOT exit 1 blocked)" \
    || ko "T2: cap-reached expected exit 2, got $LAST_RC"
  has_label 1302 "status:deferred" \
    && ok "T2: leaf swapped to status:deferred" \
    || ko "T2: leaf NOT deferred (labels: $(jq -c 'map(select(.number==1302))[0].labels' "$BOARD_STATE"))"
  ! has_label 1302 "status:review" \
    && ok "T2: status:review REMOVED from the leaf" \
    || ko "T2: status:review still present on the leaf"
  # Absent from board review-leaves
  _rl="$(PATH="$BIN:$PATH" CB_REPO="test/repo" bash "$ROOT/board-gh.sh" review-leaves 2>/dev/null)"
  printf '%s\n' "$_rl" | grep -qx '1302' \
    && ko "T2: leaf #1302 STILL selected by board review-leaves (got: $_rl)" \
    || ok "T2: leaf #1302 ABSENT from board review-leaves selection"
  # Exactly one defer comment
  [ "$(comment_count 1302)" = "1" ] \
    && ok "T2: EXACTLY ONE defer comment posted" \
    || ko "T2: expected exactly 1 defer comment, got $(comment_count 1302)"
  # No RED comment / RED_REASON to the leaf
  printf '%s\n' "$VM_OUT" | grep -q '^RED_REASON:' \
    && ko "T2: RED_REASON emitted on defer (must NOT confirm a code red)" \
    || ok "T2: no RED_REASON on defer (infra, not code red)"

  # ── T3 (NEW): storm ends -> next GREEN verify clears smoke_infra_ticks + flake_n ──
  echo "== T3 (NEW): next green verify clears smoke_infra_ticks + flake_n =="
  C3="$ROOT/c3"; R3="$ROOT/r3.git"
  seed_rework_remote "$R3" green
  # Resolve the cache key this remote will use and pre-seed BOTH stale counters.
  _ls="$(git ls-remote "$R3" "refs/heads/$BR" | awk '{print $1}')"
  _bs="$(git ls-remote "$R3" "refs/heads/$TG" | awk '{print $1}')"
  mkdir -p "$C3"
  printf '4' > "$C3/${_ls}_${_bs}.smoke_infra_ticks"
  printf '3' > "$C3/${_ls}_${_bs}.flake_n"
  run_vm "$C3" "$R3" env PATH="$BIN:$PATH" CB_REPO="test/repo"
  [ "$RC" -eq 0 ] \
    && ok "T3: storm over -> green verify exit 0" \
    || ko "T3: green verify expected exit 0, got $RC"
  [ ! -f "$C3/${_ls}_${_bs}.smoke_infra_ticks" ] \
    && ok "T3: smoke_infra_ticks cleared on next green" \
    || ko "T3: smoke_infra_ticks NOT cleared (val=$(cat "$C3/${_ls}_${_bs}.smoke_infra_ticks" 2>/dev/null))"
  [ ! -f "$C3/${_ls}_${_bs}.flake_n" ] \
    && ok "T3: flake_n cleared on next green" \
    || ko "T3: flake_n NOT cleared (val=$(cat "$C3/${_ls}_${_bs}.flake_n" 2>/dev/null))"
fi

# ═══════════════════════════════════════════════════════════════════════════════
echo
printf 'passed=%d failed=%d skipped=%d\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ]
