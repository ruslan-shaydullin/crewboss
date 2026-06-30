#!/usr/bin/env bash
# 1049-recovery-cross-tick-live.test.sh — charter #1049 / issue #1123 (qa-engineer leaf).
#
# LIVE tier — the charter's "Проверено вживую" bullet and the prior review's фикс #2.
# Synthetic stub scenarios (1049-recovery-parse.test.sh) alone do NOT satisfy this gate.
#
# This is NOT a single-process mock: it drives >= 2 REAL launcher ticks (separate
# `crewboss-launcher-gh.sh run` invocations sharing one CB_HOME) against a REAL bare git
# remote, with a REAL failing engine-test PROCESS producing a REAL `RED_REASON`, and
# HARD-asserts the cross-TICK recovery state machine of charter #1049:
#
#   The stuck-leaf reproduction (stale-regression-test example): triage cannot resolve the
#   leaf with one route, so the launcher escalates to recovery-lead, ingests the manager's
#   `## Recovery (machine)` plan, and executes it step-by-step ACROSS tick boundaries:
#     tick A — ingest plan+cursor, dispatch step0 (update the stale assert)   [cursor=0]
#     tick B — re-verify step0 (still RED), advance the cursor, dispatch step1 [cursor 0->1]
#     tick C — re-verify (assert now fixed) GREEN -> honor terminal=merge -> review
#
#   HARD assertions:
#     * recovery_plan / recovery_cursor PERSIST via sset/sget BETWEEN separate launcher
#       processes (read back with `sget` after each invocation; the cursor advances across
#       the tick boundary 0 -> 1).
#     * The terminal is merge-or-deferred (here: merge -> status:review, integrator-bound).
#     * NO status:blocked is EVER written; no human gate (type:human-*) is ever created.
#
# Modeled on reference/tests/1109-verify-merged-rich-reason-live.test.sh (real bare remote,
# real failing process, set -u, pass/fail counters, exit-on-fail) and the stub-board harness
# of reference/tests/recovery-cap.test.sh (board-gh.sh + launchable.sh + a stateful gh stub).
#
# Guard: requires real `git` (+ jq). If absent the live tier SKIPs (exit 0) — a constrained
# sandbox must not produce a false failure for an environmental gap (live-test precedent).
#
# Fixture-creation pattern: temp-name then mv (no redirect onto test-file paths, #523 ITA).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER="${LAUNCHER_OVERRIDE:-$HERE/../runtime/crewboss-launcher-gh.sh}"
RECOVERY_PARSE="$HERE/../runtime/recovery-parse.sh"
TRIAGE_PARSE="$HERE/../runtime/triage-parse.sh"
INTEGRATOR="$HERE/../runtime/crewboss-integrator.sh"
BOARD_GH_SRC="$HERE/../../proto/r6/board-gh.sh"
LAUNCHABLE_SRC="$HERE/../../proto/r6/launchable.sh"

pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }
skip(){ printf 'skip %s\n' "$1"; }

if ! command -v git >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  skip "live: git/jq unavailable — skipping real cross-TICK recovery tier (environmental)"
  printf 'passed=%d failed=%d\n' "$pass" "$fail"
  exit 0
fi

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"; pkill -P $$ 2>/dev/null; true' EXIT
BIN="$ROOT/bin"; SANDBOX="$ROOT/sb"
BOARD_STATE="$SANDBOX/board.json"; GH_LOG="$SANDBOX/gh.log"; PR_JSON="$SANDBOX/pr.json"
export BOARD_STATE GH_LOG BIN PR_JSON
mkdir -p "$BIN" "$SANDBOX"
printf '[]' > "$PR_JSON"

LEAF=1130
LEAF_BRANCH="leaf/${LEAF}-1700000000"
TARGET_BRANCH="charter/1049"
REMOTE="$ROOT/remote.git"
CBHOME="$ROOT/cbnet"
VCACHE="$ROOT/vcache"
RED_TOKEN="stale-regression"

# ── REAL failing/passing engine-test fixture (ALLOW basename so verify-merged runs it) ──
# acceptance-block is ALLOW in reference/runtime/per-leaf-manifest, so the per-leaf
# verify-merged filter actually executes it on the merged tree.
write_accept_test() {
  local dir="$1" mode="$2" f
  f="$(mktemp)"
  if [ "$mode" = "fail" ]; then
    {
      printf '#!/usr/bin/env bash\n'
      printf 'echo "running acceptance-block checks..."\n'
      printf 'printf "%%s\\n" "FAIL %s: stale assert expects old shape, got charter/1049 drift" >&2\n' "$RED_TOKEN"
      printf 'exit 1\n'
    } > "$f"
  else
    {
      printf '#!/usr/bin/env bash\n'
      printf 'echo "running acceptance-block checks..."\n'
      printf 'echo "ok acceptance-block: assert updated for charter/1049"\n'
      printf 'exit 0\n'
    } > "$f"
  fi
  mkdir -p "$dir/reference/tests"
  mv "$f" "$dir/reference/tests/acceptance-block.test.sh"
  chmod +x "$dir/reference/tests/acceptance-block.test.sh"
}

# Push the leaf branch's acceptance-block test in the requested mode (fail|pass).
# Simulates the recovery executor editing the stale assert between ticks (the spawn is
# stubbed; the real git push stands in for the executor's commit).
push_leaf_mode() {
  local mode="$1" d
  d="$(mktemp -d)"
  git clone -q "$REMOTE" "$d" 2>/dev/null
  git -C "$d" config user.email t@t; git -C "$d" config user.name T
  git -C "$d" checkout -q "$LEAF_BRANCH" 2>/dev/null
  write_accept_test "$d" "$mode"
  git -C "$d" add -A
  git -C "$d" commit -qm "acceptance-block ($mode)" 2>/dev/null
  git -C "$d" push -q origin "$LEAF_BRANCH" 2>/dev/null
  rm -rf "$d"
}

# ── Build the real bare remote: charter/1049 base + leaf branch (failing test) ──
git init --bare -q "$REMOTE"
TMP="$(mktemp -d)"
git clone -q "$REMOTE" "$TMP" 2>/dev/null
git -C "$TMP" config user.email t@t; git -C "$TMP" config user.name T
mkdir -p "$TMP/reference/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/reference/bin/regen-manifest.sh"
chmod +x "$TMP/reference/bin/regen-manifest.sh"
printf 'base\n' > "$TMP/README.md"
git -C "$TMP" add -A
git -C "$TMP" commit -qm base 2>/dev/null
git -C "$TMP" push -q origin "HEAD:refs/heads/${TARGET_BRANCH}" 2>/dev/null
# Leaf branch off charter/1049 with the stale (failing) acceptance test.
git -C "$TMP" checkout -qb "$LEAF_BRANCH" 2>/dev/null
write_accept_test "$TMP" fail
printf 'leaf change\n' > "$TMP/leaf.txt"
git -C "$TMP" add -A
git -C "$TMP" commit -qm "leaf: stale acceptance assert" 2>/dev/null
git -C "$TMP" push -q origin "$LEAF_BRANCH" 2>/dev/null
rm -rf "$TMP"

# Sanity: prove the remote leaf really is RED via the REAL integrator (real RED_REASON).
vm_rc=0
vm_out="$(CB_VERIFY_CACHE="$ROOT/sanitycache" CB_VERIFY_CONFIRM_N=1 \
  bash "$INTEGRATOR" verify-merged "$LEAF_BRANCH" "$TARGET_BRANCH" --remote "$REMOTE" 2>/dev/null)" || vm_rc=$?
vm_reason="$(printf '%s\n' "$vm_out" | sed -n 's/^RED_REASON: //p' | head -1)"
[ "$vm_rc" -ne 0 ] \
  && ok "setup: real merged-tree verify is RED (rc=$vm_rc) — genuine stuck leaf" \
  || ko "setup: expected RED merged tree, got rc=$vm_rc (fixture not failing)"
printf '%s' "$vm_reason" | grep -qE "FAIL|$RED_TOKEN" \
  && ok "setup: real RED_REASON carries the failing assertion ($RED_TOKEN)" \
  || ko "setup: RED_REASON missing real assertion (got: $vm_reason)"

# ── gh stub (board state + pr list/view/merge) ──
GHSTUB="$(mktemp)"
cat > "$GHSTUB" << 'GHEOF'
#!/usr/bin/env bash
obj="$1"; verb="$2"; shift 2 2>/dev/null || true
_args=()
while [ $# -gt 0 ]; do
  case "$1" in -R|--repo|-L|--limit) shift ;; *) _args+=("$1") ;; esac; shift
done
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
    while [ $# -gt 0 ]; do
      case "$1" in --add-label) adds+=("$2"); shift ;; --remove-label) rems+=("$2"); shift ;; esac; shift
    done
    adds_json="$(printf '%s\n' "${adds[@]+"${adds[@]}"}" | jq -R . | jq -s .)"
    rems_json="$(printf '%s\n' "${rems[@]+"${rems[@]}"}" | jq -R . | jq -s .)"
    jq --argjson n "$n" --argjson adds "$adds_json" --argjson rems "$rems_json" '
      map(if .number == $n then
        .labels = [(.labels // [])[] | select(.name as $nm | ($rems | index($nm)) == null)]
        | reduce $adds[] as $a (.;
            if ([.labels[].name] | index($a)) == null then .labels += [{name: $a}] else . end)
      else . end)' "$BOARD_STATE" > "$BOARD_STATE.t" && mv "$BOARD_STATE.t" "$BOARD_STATE"
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
    printf 'comment #%s: %s\n' "$n" "$body" >> "$GH_LOG" ;;
  "issue create")
    title=""; label=""
    while [ $# -gt 0 ]; do case "$1" in --title|-t) title="$2"; shift ;; --label|-l) label="$2"; shift ;; --body|-b) shift ;; esac; shift; done
    _max=$(jq 'map(.number) | max // 0' "$BOARD_STATE"); _new=$((_max + 1))
    _lj="$(printf '%s\n' "$label" | jq -R 'select(length>0) | {name:.}' | jq -s .)"
    jq --argjson n "$_new" --arg t "$title" --argjson l "$_lj" \
      '. + [{number:$n, state:"OPEN", title:$t, labels:$l, comments:[]}]' \
      "$BOARD_STATE" > "$BOARD_STATE.t" && mv "$BOARD_STATE.t" "$BOARD_STATE"
    printf '%s\n' "$_new"; printf 'create #%s [%s]: %s\n' "$_new" "$label" "$title" >> "$GH_LOG" ;;
  "issue close") printf 'close #%s\n' "${1:-?}" >> "$GH_LOG" ;;
  "pr list") cat "$PR_JSON" 2>/dev/null || printf '[]' ;;
  "pr view") printf '{"state":"OPEN","mergeCommit":null}\n' ;;
  "pr merge") printf 'merge %s\n' "${1:-?}" >> "$GH_LOG" ;;
  "pr comment"|"pr close") : ;;
  "label create") ;;
  "auth token") printf 'fake-token\n' ;;
  *) printf 'gh-stub UNHANDLED: %s %s %s\n' "$obj" "$verb" "$*" >> "$GH_LOG" ;;
esac
exit 0
GHEOF
mv "$GHSTUB" "$BIN/gh"
chmod +x "$BIN/gh"

# ── board + state helpers ──
has_label(){ [ "$(jq -r --argjson n "$1" 'map(select(.number==$n))[0].labels[]?.name' "$BOARD_STATE" | grep -c "^${2}\$")" -ge 1 ]; }
no_label(){ ! has_label "$1" "$2"; }
sget(){ cat "$CBHOME/run/state/$1/$2" 2>/dev/null || printf ''; }
sset(){ mkdir -p "$CBHOME/run/state/$1"; printf '%s' "$3" > "$CBHOME/run/state/$1/$2"; }
mk_dead_pid(){ ( exit 0 ) & local p=$!; wait "$p" 2>/dev/null; printf '%s' "$p"; }
mk_status(){ mkdir -p "$CBHOME/run/work/$1"; printf '{"phase":"%s"}' "$2" > "$CBHOME/run/work/$1/status.json"; }
# Assert no status:blocked label AND no blocked-label edit was ever logged, AND no human task.
assert_never_blocked(){
  local where="$1"
  if no_label "$LEAF" "status:blocked" \
     && ! grep -q 'status:blocked' "$GH_LOG" 2>/dev/null \
     && [ "$(jq '[.[] | select(.labels[]?.name | test("^type:human-"))] | length' "$BOARD_STATE")" = "0" ]; then
    ok "$where: NO status:blocked / no human gate ever written"
  else
    ko "$where: status:blocked or human gate appeared (GH_LOG: $(grep -i 'blocked\|human' "$GH_LOG" 2>/dev/null | tr '\n' ';'))"
  fi
}

# ── CB_HOME with board adapter + launchable predicate ──
mkdir -p "$CBHOME"
cp "$BOARD_GH_SRC" "$CBHOME/board-gh.sh"; cp "$LAUNCHABLE_SRC" "$CBHOME/launchable.sh"
chmod +x "$CBHOME/board-gh.sh" "$CBHOME/launchable.sh"

# One REAL launcher tick (a full separate process). State persists on disk under CB_HOME.
launcher_tick(){
  PATH="$BIN:$PATH" \
    CB_REPO="test/repo" CB_HOME="$CBHOME" \
    CB_TRIAGE_PARSE="$TRIAGE_PARSE" CB_RECOVERY_PARSE="$RECOVERY_PARSE" \
    CB_INTEGRATOR="$INTEGRATOR" \
    CB_GIT_REMOTE="$REMOTE" \
    CB_VERIFY_CACHE="$VCACHE" CB_VERIFY_CONFIRM_N=1 \
    CB_POLL=0 CB_MAX_TICKS=1 CB_IDLE_CONFIRM=1 CB_MAX_PARALLEL=0 \
    CB_RETRY_CAP=2 CB_RECOVERY_CAP=2 CB_RECOVERY_LEAD_CAP=1 \
    bash "$LAUNCHER" run >/dev/null 2>&1
}

# ── Seed: post-escalation state. Leaf is kind=recovery with an EMPTY plan and a
#    `## Recovery (machine)` comment from the recovery-lead manager (2 steps, merge).
#    A dead recovery-lead pid marks the manager spawn as finished -> tick A ingests. ──
PLAN_COMMENT='## Recovery (machine)
[{"action":"update-stale-assert","target":"acceptance-block","route":"executor-rework"},{"action":"re-update-assert","target":"acceptance-block","route":"executor-rework"}]
terminal: merge'

jq -n --arg b "$PLAN_COMMENT" '
  [ { number:1130, state:"OPEN",
      labels:[{name:"type:agent"},{name:"status:needs-recovery"}],
      body:"Charter: #1049", comments:[{body:$b}] } ]' > "$BOARD_STATE"

# Open PR snapshot used by _recovery_reverify (and the integrator) to locate the leaf PR.
jq -n --arg h "$LEAF_BRANCH" --arg b "$TARGET_BRANCH" \
  '[{number:9100, headRefName:$h, baseRefName:$b}]' > "$PR_JSON"

sset "$LEAF" kind "recovery"
sset "$LEAF" recovery_lead_n "1"
sset "$LEAF" recovery_plan ""
sset "$LEAF" pid "$(mk_dead_pid)"
mk_status "$LEAF" done

# ══════════════════════════════════════════════════════════════════════════════
echo "== TICK A: ingest the recovery plan + persist cursor, dispatch step0 =="
# ══════════════════════════════════════════════════════════════════════════════
launcher_tick

_plan_a="$(sget "$LEAF" recovery_plan)"
_cursor_a="$(sget "$LEAF" recovery_cursor)"
[ -n "$_plan_a" ] \
  && ok "A.1: recovery_plan PERSISTED via sset/sget after tick A (non-empty TSV)" \
  || ko "A.1: recovery_plan not persisted after tick A"
printf '%s\n' "$_plan_a" | awk -F'\t' '$1=="terminal"{f=1} END{exit !f}' \
  && ok "A.2: persisted plan carries a terminal row" \
  || ko "A.2: persisted plan missing terminal row"
[ "$_cursor_a" = "0" ] \
  && ok "A.3: recovery_cursor PERSISTED at 0 after ingest" \
  || ko "A.3: recovery_cursor != 0 after tick A (got '$_cursor_a')"
[ "$(sget "$LEAF" kind)" = "recovery" ] \
  && ok "A.4: kind=recovery preserved across the tick" \
  || ko "A.4: kind not recovery after tick A (got '$(sget "$LEAF" kind)')"
has_label "$LEAF" "status:needs-rework" \
  && ok "A.5: step0 (executor-rework) dispatched -> status:needs-rework" \
  || ko "A.5: step0 route not dispatched after tick A"
assert_never_blocked "A.6"

# Between ticks: the step0 executor ran but the leaf is STILL RED (assert not yet fixed).
# Mark the re-dispatched spawn finished (dead pid + phase=done); kind=recovery preserved.
sset "$LEAF" pid "$(mk_dead_pid)"
mk_status "$LEAF" done

# ══════════════════════════════════════════════════════════════════════════════
echo "== TICK B: re-verify step0 RED (real verify-merged) -> advance cursor 0 -> 1 =="
# ══════════════════════════════════════════════════════════════════════════════
launcher_tick

_cursor_b="$(sget "$LEAF" recovery_cursor)"
[ "$_cursor_b" = "1" ] \
  && ok "B.1: recovery_cursor ADVANCED across the tick boundary (0 -> 1) via sset/sget" \
  || ko "B.1: cursor did not advance to 1 (got '$_cursor_b')"
[ -n "$(sget "$LEAF" recovery_plan)" ] \
  && ok "B.2: recovery_plan still persisted into tick B (cross-process state)" \
  || ko "B.2: recovery_plan lost between ticks"
[ "$(sget "$LEAF" kind)" = "recovery" ] \
  && ok "B.3: kind=recovery still engaged after step0 RED" \
  || ko "B.3: kind lost after tick B (got '$(sget "$LEAF" kind)')"
has_label "$LEAF" "status:needs-rework" \
  && ok "B.4: step1 (executor-rework) re-dispatched -> status:needs-rework" \
  || ko "B.4: step1 route not dispatched after tick B"
assert_never_blocked "B.5"

# Between ticks: the recovery executor FIXES the stale assert — push the passing test.
# (the spawn is stubbed; this real push stands in for the executor's corrective commit.)
push_leaf_mode pass
# Update the PR snapshot is unnecessary (same branch); mark the spawn finished.
sset "$LEAF" pid "$(mk_dead_pid)"
mk_status "$LEAF" done

# ══════════════════════════════════════════════════════════════════════════════
echo "== TICK C: re-verify GREEN (real verify-merged) -> terminal=merge -> review =="
# ══════════════════════════════════════════════════════════════════════════════
launcher_tick

[ -z "$(sget "$LEAF" kind)" ] \
  && ok "C.1: GREEN re-verify honored terminal=merge -> recovery state CLEARED (kind empty)" \
  || ko "C.1: kind not cleared after GREEN merge (got '$(sget "$LEAF" kind)')"
[ "$(sget "$LEAF" term)" = "1" ] \
  && ok "C.2: term=1 — recovery run finalized" \
  || ko "C.2: term != 1 after GREEN merge (got '$(sget "$LEAF" term)')"
has_label "$LEAF" "status:review" \
  && ok "C.3: terminal is MERGE — leaf routed to status:review (integrator-bound)" \
  || ko "C.3: leaf not in status:review after GREEN terminal=merge"
assert_never_blocked "C.4"

# Final invariant: across ALL three real ticks the leaf reached a merge-bound terminal
# and never a human halt.
if has_label "$LEAF" "status:review" && no_label "$LEAF" "status:blocked" \
   && no_label "$LEAF" "status:needs-recovery"; then
  ok "FINAL: cross-TICK recovery reached merge-or-deferred terminal with NO human gate"
else
  ko "FINAL: terminal invariant violated (labels: $(jq -c --argjson n "$LEAF" 'map(select(.number==$n))[0].labels' "$BOARD_STATE"))"
fi

echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
