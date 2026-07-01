#!/usr/bin/env bash
# plan-convergence.test.sh — tech-lead↔analyst plan-convergence loop (#382).
# The SECOND convergence loop: after the tech-lead decomposes a charter (→ plan-review),
# the analyst reviews the PLAN before any leaf executes. Rounds until plan:agreed; cap → human.
# Mirror of convergence.test.sh (the #334 composition loop) for the plan-review stage.
#
# Class d integration-stub: gh stub file-board, REAL launcher + board-gh.sh + manifest.
# CB_MANIFEST = copy of team-example with policy.plan_review_role="solution-analyst" added
# (the field that ARMS the plan-convergence gate; absent → existing single-pass plan flow, the
# default — proven by the gate's `[ -n "$_plan_review_role" ]` guard staying false there).
#
# A hermetic `flock` shim is injected into $BIN (macOS has no flock); single-launcher → exit 0.
#
# Charters are seeded at needs-plan + composition:approved (post-cto state) to isolate the PLAN
# stage — analysis/composition-convergence/cto are upstream and already covered by convergence.test.sh.
#
#   PLAN-CONVERGE: plan-reviewer CRITIQUE then AGREE → tech-lead RE-PLANS (the rework round) →
#                  plan:agreed → status:approved (leaves released). pround = rounds; history recorded.
#   PLAN-ESCALATE: plan-reviewer always CRITIQUE → pround hits CB_PLAN_CONVERGE_CAP → human-decision;
#                  plan-reviewer spawned EXACTLY cap times (cap stops the ping-pong) → idempotent.
#   AGREED-SKIP:   plan:agreed already present → plan-reviewer NOT spawned → straight to status:approved.
#   PLAN-ESCALATE-CAP6: CB_PLAN_CONVERGE_CAP and CB_CONVERGE_CAP both unset → launcher last-resort
#                  fallback of 6 applies; human-decision fires at round 6, NOT at old default 4.
#   PLAN-LABEL-OVERRIDE: converge-cap:3 label on the charter overrides CB_PLAN_CONVERGE_CAP=6 env;
#                  human-decision fires at round 3 (label wins over env).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER="${LAUNCHER_OVERRIDE:-$HERE/../runtime/crewboss-launcher-gh.sh}"
BOARD_GH_SRC="$HERE/../../proto/r6/board-gh.sh"
LAUNCHABLE_SRC="$HERE/../../proto/r6/launchable.sh"
TEAM_EXAMPLE="$(cd "$HERE/../../team-example" && pwd)"
MANIFEST_LIB_SRC="$HERE/../../reference/launcher/manifest.sh"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

# ── shared state ──────────────────────────────────────────────────────────────
SANDBOX="$ROOT/sb"
BOARD_STATE="$SANDBOX/board.json"
GH_LOG="$SANDBOX/gh.log"
PLAN_LOG="$ROOT/plan.log"               # tech-lead spawns (re-plan = rework round evidence)
PLAN_REVIEW_LOG="$ROOT/plan-review.log" # plan-reviewer spawns
PLAN_CRITIQUE_FLAG="$ROOT/plan-critique" # countdown: while >0 CRITIQUE, at 0 AGREE
export SANDBOX BOARD_STATE GH_LOG PLAN_LOG PLAN_REVIEW_LOG PLAN_CRITIQUE_FLAG

# CB_MANIFEST: copy of team-example, with plan_review_role added to policy (arms the gate)
CB_MANIFEST_DIR="$ROOT/manifest"
cp -r "$TEAM_EXAMPLE/." "$CB_MANIFEST_DIR"
jq '.policy.plan_review_role="solution-analyst"' "$CB_MANIFEST_DIR/org.json" > "$CB_MANIFEST_DIR/org.json.t" \
  && mv "$CB_MANIFEST_DIR/org.json.t" "$CB_MANIFEST_DIR/org.json"
export CB_MANIFEST_DIR MANIFEST_LIB_SRC

BIN="$ROOT/bin"; mkdir -p "$BIN"

# ── flock shim (hermetic, single-launcher) ────────────────────────────────────
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/flock"
chmod +x "$BIN/flock"

# ── board helpers ─────────────────────────────────────────────────────────────
has_label(){ [ "$(jq -r --argjson n "$1" 'map(select(.number==$n))[0].labels[]?.name' \
                   "$BOARD_STATE" 2>/dev/null | grep -c "^$2$")" -ge 1 ]; }
comment_count(){ jq -r --argjson n "$1" 'map(select(.number==$n))[0].comments[]?.body' \
                   "$BOARD_STATE" 2>/dev/null | grep -c "$2"; }
issue_state(){ jq -r --argjson n "$1" 'map(select(.number==$n))[0]|
                if .state=="CLOSED" then "done"
                elif ([.labels[]?.name]|any(.=="status:approved")) then "approved"
                elif ([.labels[]?.name]|any(.=="status:plan-review")) then "plan-review"
                elif ([.labels[]?.name]|any(.=="status:needs-plan")) then "needs-plan"
                elif ([.labels[]?.name]|any(.=="status:blocked")) then "blocked"
                else "open" end' "$BOARD_STATE" 2>/dev/null; }
open_hd_for(){ jq -r --argjson c "$1" '
  [.[] | select(.state=="OPEN")
        | select([.labels[]?.name] | index("type:human-decision") != null)
        | select((.body//"") | test("Charter:\\s*#?" + ($c|tostring)))] | length' \
  "$BOARD_STATE" 2>/dev/null || echo "0"; }
hd_title_for(){ jq -r --argjson c "$1" '
  [.[] | select(.state=="OPEN")
        | select([.labels[]?.name] | index("type:human-decision") != null)
        | select((.body//"") | test("Charter:\\s*#?" + ($c|tostring)))] | last | .title // ""' \
  "$BOARD_STATE" 2>/dev/null || echo ""; }

reset_sandbox(){
  rm -rf "$SANDBOX"; mkdir -p "$SANDBOX"
  : > "$GH_LOG"
  rm -f "$PLAN_CRITIQUE_FLAG"
  local cbhome="$1"
  rm -rf "$cbhome"; mkdir -p "$cbhome"
  cp "$BOARD_GH_SRC"   "$cbhome/board-gh.sh"
  cp "$LAUNCHABLE_SRC" "$cbhome/launchable.sh"
  chmod +x "$cbhome/board-gh.sh" "$cbhome/launchable.sh"
}

# ── gh stub (file-board; identical contract to convergence.test.sh) ────────────
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
    state_filter="open"
    while [ $# -gt 0 ]; do
      case "$1" in --state) state_filter="$2"; shift ;; --json) shift ;; esac; shift
    done
    case "$state_filter" in
      open)   jq '[.[] | select(.state=="OPEN")]' "$BOARD_STATE" ;;
      all)    cat "$BOARD_STATE" ;;
      closed) jq '[.[] | select(.state=="CLOSED")]' "$BOARD_STATE" ;;
      *)      cat "$BOARD_STATE" ;;
    esac ;;
  "issue view")
    n="$1"; shift; jqf=""
    while [ $# -gt 0 ]; do
      case "$1" in --jq|-q) jqf="$2"; shift ;; --json) shift ;; esac; shift
    done
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
  "issue create")
    title=""; body=""; label=""
    while [ $# -gt 0 ]; do
      case "$1" in --title) title="$2"; shift ;; --body|-b) body="$2"; shift ;;
        --label) label="$2"; shift ;; esac; shift
    done
    maxn=$(jq 'map(.number) | max // 0' "$BOARD_STATE" 2>/dev/null || echo 0)
    newn=$((maxn+1))
    lab_json="[]"
    [ -n "$label" ] && lab_json="$(printf '[{"name":"%s"}]' "$label")"
    jq --argjson n "$newn" --arg t "$title" --arg b "$body" --argjson l "$lab_json" \
      '. + [{"number":$n,"state":"OPEN","title":$t,"body":$b,"labels":$l,"comments":[]}]' \
      "$BOARD_STATE" > "$BOARD_STATE.t" && mv "$BOARD_STATE.t" "$BOARD_STATE"
    echo "issue create #$newn: $title" >> "$GH_LOG"
    printf 'https://github.com/test/repo/issues/%s\n' "$newn" ;;
  "auth token") echo "fake-token" ;;
  "label create") ;;
  *) echo "gh-stub UNHANDLED: $obj $verb $*" >> "$GH_LOG" ;;
esac
exit 0
GHEOF
chmod +x "$BIN/gh"

# ── tech-lead (plan) spawn stub ───────────────────────────────────────────────
# Decomposes the charter: posts a plan + moves needs-plan → plan-review. Runs again on every
# re-plan (after a CRITIQUE routes the charter back to needs-plan) — a 2nd spawn here IS the
# rework round (tech-lead read the critique and re-planned). No flag: always succeeds.
PLAN_STUB="$ROOT/plan-stub.sh"
cat > "$PLAN_STUB" <<'PSEOF'
#!/usr/bin/env bash
CID="$1"; PROLE="$2"
printf '%s %s\n' "$CID" "$PROLE" >> "$PLAN_LOG"
gh issue comment "$CID" -R "test/repo" --body "## Plan (machine)
- leaf: L-1 -> go-backend-dev
- acceptance: tests pass"
gh issue edit "$CID" -R "test/repo" \
  --remove-label status:needs-plan \
  --add-label status:plan-review
exit 0
PSEOF
chmod +x "$PLAN_STUB"

# ── plan-reviewer (analyst-on-plan) spawn stub ────────────────────────────────
# PLAN_CRITIQUE_FLAG holds a COUNTDOWN: while >0 decrement and CRITIQUE (comment + route the
# charter back to needs-plan so the tech-lead re-plans). At 0: AGREE (add plan:agreed; charter
# stays in plan-review → the gate releases it to status:approved). Mirror of the review stub.
PLAN_REVIEW_STUB="$ROOT/plan-review-stub.sh"
cat > "$PLAN_REVIEW_STUB" <<'PREOF'
#!/usr/bin/env bash
CID="$1"; RROLE="$2"
printf '%s %s\n' "$CID" "$RROLE" >> "$PLAN_REVIEW_LOG"
if [ -f "$PLAN_CRITIQUE_FLAG" ]; then
  cnt=$(cat "$PLAN_CRITIQUE_FLAG" 2>/dev/null || echo 0)
  if [ "$cnt" -gt 0 ]; then
    printf '%d' "$((cnt - 1))" > "$PLAN_CRITIQUE_FLAG"
    gh issue comment "$CID" -R "test/repo" --body "PLAN-REVIEW: changes-requested
- что: plan touches a sha-locked file but omits regen step | фикс: add a regen-and-relock leaf"
    gh issue edit "$CID" -R "test/repo" \
      --remove-label status:plan-review \
      --add-label status:needs-plan
    printf 'plan-review-stub: CRITIQUE for #%s (remaining=%d)\n' "$CID" "$((cnt-1))" >> "$PLAN_REVIEW_LOG"
    exit 0
  fi
fi
gh issue comment "$CID" -R "test/repo" --body "PLAN-REVIEW: agreed — plan grounded against code, all anchors sound"
gh issue edit "$CID" -R "test/repo" --add-label plan:agreed
printf 'plan-review-stub: AGREE for #%s\n' "$CID" >> "$PLAN_REVIEW_LOG"
exit 0
PREOF
chmod +x "$PLAN_REVIEW_STUB"

# ── loop runner ───────────────────────────────────────────────────────────────
run_loop(){
  local cbhome="$1" logfile="${2:-/dev/null}"; shift 2
  : > "$PLAN_LOG"; : > "$PLAN_REVIEW_LOG"; : > "$GH_LOG"
  PATH="$BIN:$PATH" \
    CB_REPO="test/repo" \
    CB_HOME="$cbhome" \
    CB_SPAWN="$PLAN_STUB" \
    CB_PLAN_SPAWN="$PLAN_STUB" \
    CB_PLAN_REVIEW_SPAWN="$PLAN_REVIEW_STUB" \
    CB_MANIFEST="$CB_MANIFEST_DIR" \
    CB_MANIFEST_LIB="$MANIFEST_LIB_SRC" \
    CB_POLL=0 \
    CB_MAX_TICKS=80 \
    CB_IDLE_CONFIRM=2 \
    CB_MAX_PARALLEL=4 \
    CB_RETRY_CAP=3 \
    CREWBOSS_CHARTER= \
    env "$@" \
    bash "$LAUNCHER" run >"$logfile" 2>&1 || true
}

# Post-cto charter: needs-plan + composition:approved (isolates the PLAN stage)
seed_needs_plan(){ printf '[{"number":5,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:needs-plan"},{"name":"composition:approved"},{"name":"review:agreed"}],"body":"charter goal","comments":[]}]\n' > "$BOARD_STATE"; }

# =============================================================================
# PLAN-CONVERGE: plan-reviewer CRITIQUE ×1 then AGREE → tech-lead RE-PLANS (the rework round) →
#   plan:agreed → status:approved. The rework round (critique → re-plan → agree) is the point.
# =============================================================================
echo "=== PLAN-CONVERGE: CRITIQUE then AGREE → tech-lead re-plans → plan:agreed → status:approved ==="
CBHOME_C="$ROOT/cbhome_c"; LOG_C="$ROOT/loop_c.log"
reset_sandbox "$CBHOME_C"
printf '1' > "$PLAN_CRITIQUE_FLAG"   # critique once, then agree on the 2nd plan-review
seed_needs_plan

run_loop "$CBHOME_C" "$LOG_C" "CB_PLAN_CONVERGE_CAP=5"

_pr_c=$(grep -c '^5 solution-analyst' "$PLAN_REVIEW_LOG" 2>/dev/null)
[ "$_pr_c" -eq 2 ] \
  && ok "PLAN-CONVERGE: plan-reviewer spawned exactly 2× (1 CRITIQUE + 1 AGREE)" \
  || ko "PLAN-CONVERGE: plan-reviewer spawn count=$_pr_c (expected 2 — critique then agree)"

_tl_c=$(grep -c '^5 tech-lead' "$PLAN_LOG" 2>/dev/null)
[ "$_tl_c" -eq 2 ] \
  && ok "PLAN-CONVERGE: tech-lead RE-PLANNED (spawned 2× — the rework round happened)" \
  || ko "PLAN-CONVERGE: tech-lead spawn count=$_tl_c (expected 2 — no rework round)"

has_label 5 "plan:agreed" \
  && ok "PLAN-CONVERGE: plan:agreed set after convergence" \
  || ko "PLAN-CONVERGE: plan:agreed NOT set (never converged)"

_crit_c=$(comment_count 5 "PLAN-REVIEW: changes-requested")
[ "${_crit_c:-0}" -ge 1 ] \
  && ok "PLAN-CONVERGE: rework round recorded (≥1 PLAN-REVIEW critique comment, got $_crit_c)" \
  || ko "PLAN-CONVERGE: rework round NOT recorded (critique comments=$_crit_c)"

_st_c=$(issue_state 5)
[ "$_st_c" = "approved" ] \
  && ok "PLAN-CONVERGE: charter released to status:approved (leaves unblocked)" \
  || ko "PLAN-CONVERGE: charter state=$_st_c (expected approved)"

grep -q "plan:agreed → status:approved" "$LOG_C" \
  && ok "PLAN-CONVERGE: gate logged the plan:agreed → approved release" \
  || ko "PLAN-CONVERGE: release log line missing"

grep -q "awaiting plan-convergence" "$LOG_C" \
  && ok "PLAN-CONVERGE: tech-lead post-proc deferred to the gate (not terminal at plan-review)" \
  || ko "PLAN-CONVERGE: 'awaiting plan-convergence' log missing (plan went terminal — gate bypassed)"

# =============================================================================
# PLAN-ESCALATE: plan-reviewer always CRITIQUE → pround hits cap → human-decision.
#   plan-reviewer spawned EXACTLY cap times (cap stops the ping-pong); never released.
# =============================================================================
echo "=== PLAN-ESCALATE: always CRITIQUE → CB_PLAN_CONVERGE_CAP=3 → human-decision ==="
CBHOME_E="$ROOT/cbhome_e"; LOG_E="$ROOT/loop_e.log"
reset_sandbox "$CBHOME_E"
printf '99' > "$PLAN_CRITIQUE_FLAG"   # never agree
seed_needs_plan

run_loop "$CBHOME_E" "$LOG_E" "CB_PLAN_CONVERGE_CAP=3"

_pr_e=$(grep -c '^5 solution-analyst' "$PLAN_REVIEW_LOG" 2>/dev/null)
[ "$_pr_e" -eq 3 ] \
  && ok "PLAN-ESCALATE: plan-reviewer spawned exactly cap=3 times (no runaway ping-pong)" \
  || ko "PLAN-ESCALATE: plan-reviewer spawn count=$_pr_e (expected 3 == cap)"

_hd_e=$(open_hd_for 5)
[ "${_hd_e:-0}" -ge 1 ] \
  && ok "PLAN-ESCALATE: human-decision created at cap" \
  || ko "PLAN-ESCALATE: human-decision NOT created at cap"

case "$(hd_title_for 5)" in
  *"did not converge"*) ok "PLAN-ESCALATE: human-decision titled 'plan did not converge'" ;;
  *) ko "PLAN-ESCALATE: human-decision title wrong: '$(hd_title_for 5)'" ;;
esac

[ "$(issue_state 5)" != "approved" ] \
  && ok "PLAN-ESCALATE: charter NOT released to approved (cap held the gate shut)" \
  || ko "PLAN-ESCALATE: charter reached approved despite non-convergence"

# idempotent: a second run must NOT create a duplicate human-decision
run_loop "$CBHOME_E" "${LOG_E}.2" "CB_PLAN_CONVERGE_CAP=3"
_hd_e2=$(open_hd_for 5)
[ "${_hd_e2:-0}" -eq "${_hd_e:-0}" ] \
  && ok "PLAN-ESCALATE: idempotent — no duplicate human-decision on second run" \
  || ko "PLAN-ESCALATE: human-decision duplicated (count2=$_hd_e2 vs first=$_hd_e)"

# =============================================================================
# AGREED-SKIP: plan:agreed already present → plan-reviewer NOT spawned → straight to approved.
# =============================================================================
echo "=== AGREED-SKIP: plan:agreed present → plan-reviewer bypassed → status:approved ==="
CBHOME_A="$ROOT/cbhome_a"; LOG_A="$ROOT/loop_a.log"
reset_sandbox "$CBHOME_A"
printf '0' > "$PLAN_CRITIQUE_FLAG"
printf '[{"number":5,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:plan-review"},{"name":"composition:approved"},{"name":"plan:agreed"}],"body":"charter goal","comments":[]}]\n' \
  > "$BOARD_STATE"

run_loop "$CBHOME_A" "$LOG_A" "CB_PLAN_CONVERGE_CAP=5"

_pr_a=$(grep -c '^5 solution-analyst' "$PLAN_REVIEW_LOG" 2>/dev/null)
[ "$_pr_a" -eq 0 ] \
  && ok "AGREED-SKIP: plan-reviewer NOT spawned (already agreed)" \
  || ko "AGREED-SKIP: plan-reviewer spawned $_pr_a× despite plan:agreed (no short-circuit)"

[ "$(issue_state 5)" = "approved" ] \
  && ok "AGREED-SKIP: charter released straight to status:approved" \
  || ko "AGREED-SKIP: charter state=$(issue_state 5) (expected approved)"

# =============================================================================
# LIMBO-RECOVER: charter with plan:agreed + composition:approved but NO status:plan-review
#   must be caught by the reconcile block and transitioned to status:approved.
#   (Regression test for the fix that adds the idempotent reconcile block — charter #955.)
# =============================================================================
echo "=== LIMBO-RECOVER: plan:agreed + composition:approved, no status:plan-review === status:approved ==="
CBHOME_L="$ROOT/cbhome_l"; LOG_L="$ROOT/loop_l.log"
reset_sandbox "$CBHOME_L"
printf '0' > "$PLAN_CRITIQUE_FLAG"
printf '[{"number":5,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"plan:agreed"},{"name":"composition:approved"}],"body":"charter goal","comments":[]}]\n' \
  > "$BOARD_STATE"

run_loop "$CBHOME_L" "$LOG_L" "CB_PLAN_CONVERGE_CAP=5"

_pr_l=$(grep -c '^5 solution-analyst' "$PLAN_REVIEW_LOG" 2>/dev/null)
[ "$_pr_l" -eq 0 ] \
  && ok "LIMBO-RECOVER: plan-reviewer NOT spawned (plan:agreed already present)" \
  || ko "LIMBO-RECOVER: plan-reviewer spawned ${_pr_l}x despite plan:agreed (short-circuit broken)"

[ "$(issue_state 5)" = "approved" ] \
  && ok "LIMBO-RECOVER: charter reached status:approved (reconcile block fired)" \
  || ko "LIMBO-RECOVER: charter state=$(issue_state 5) (expected approved — reconcile block missing or not firing)"

grep -q "plan:agreed" "$LOG_L" && grep -q "status:approved" "$LOG_L" \
  && ok "LIMBO-RECOVER: log contains 'plan:agreed' and 'status:approved' (reconcile gate logged release)" \
  || ko "LIMBO-RECOVER: log missing plan:agreed/status:approved release entry (reconcile gate did not fire)"

# =============================================================================
# NORMAL-FLOW-INTACT: charter with status:plan-review + composition:approved + plan:agreed
#   must still reach status:approved via the existing gate (reconcile block must not break this).
# =============================================================================
echo "=== NORMAL-FLOW-INTACT: status:plan-review + composition:approved + plan:agreed === status:approved ==="
CBHOME_N="$ROOT/cbhome_n"; LOG_N="$ROOT/loop_n.log"
reset_sandbox "$CBHOME_N"
printf '0' > "$PLAN_CRITIQUE_FLAG"
printf '[{"number":5,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:plan-review"},{"name":"composition:approved"},{"name":"plan:agreed"}],"body":"charter goal","comments":[]}]\n' \
  > "$BOARD_STATE"

run_loop "$CBHOME_N" "$LOG_N" "CB_PLAN_CONVERGE_CAP=5"

_pr_n=$(grep -c '^5 solution-analyst' "$PLAN_REVIEW_LOG" 2>/dev/null)
[ "$_pr_n" -eq 0 ] \
  && ok "NORMAL-FLOW-INTACT: plan-reviewer NOT spawned (plan:agreed short-circuits review)" \
  || ko "NORMAL-FLOW-INTACT: plan-reviewer spawned ${_pr_n}x despite plan:agreed"

[ "$(issue_state 5)" = "approved" ] \
  && ok "NORMAL-FLOW-INTACT: charter released to status:approved (existing gate still fires)" \
  || ko "NORMAL-FLOW-INTACT: charter state=$(issue_state 5) (expected approved — existing gate broken)"

# =============================================================================
# NO-PREMATURE-APPROVE: charters that lack both conditions must NOT receive status:approved.
#   Three sub-cases (separate runs); each asserts issue_state != "approved".
# =============================================================================
echo "=== NO-PREMATURE-APPROVE: partial-condition charters must NOT reach status:approved ==="

# Sub-case a: plan:agreed present but NO composition:approved === NOT approved
CBHOME_Pa="$ROOT/cbhome_pa"; LOG_Pa="$ROOT/loop_pa.log"
reset_sandbox "$CBHOME_Pa"
printf '0' > "$PLAN_CRITIQUE_FLAG"
printf '[{"number":5,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"plan:agreed"}],"body":"charter goal","comments":[]}]\n' \
  > "$BOARD_STATE"

run_loop "$CBHOME_Pa" "$LOG_Pa" "CB_PLAN_CONVERGE_CAP=5"

[ "$(issue_state 5)" != "approved" ] \
  && ok "NO-PREMATURE-APPROVE(a): plan:agreed-only charter NOT approved (composition:approved absent)" \
  || ko "NO-PREMATURE-APPROVE(a): charter reached approved without composition:approved (premature release)"

# Sub-case b: composition:approved present but NO plan:agreed === NOT approved
CBHOME_Pb="$ROOT/cbhome_pb"; LOG_Pb="$ROOT/loop_pb.log"
reset_sandbox "$CBHOME_Pb"
printf '0' > "$PLAN_CRITIQUE_FLAG"
printf '[{"number":5,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"composition:approved"}],"body":"charter goal","comments":[]}]\n' \
  > "$BOARD_STATE"

run_loop "$CBHOME_Pb" "$LOG_Pb" "CB_PLAN_CONVERGE_CAP=5"

[ "$(issue_state 5)" != "approved" ] \
  && ok "NO-PREMATURE-APPROVE(b): composition:approved-only charter NOT approved (plan:agreed absent)" \
  || ko "NO-PREMATURE-APPROVE(b): charter reached approved without plan:agreed (premature release)"

# Sub-case c: plan:agreed + composition:approved present AND hold label === NOT approved
CBHOME_Pc="$ROOT/cbhome_pc"; LOG_Pc="$ROOT/loop_pc.log"
reset_sandbox "$CBHOME_Pc"
printf '0' > "$PLAN_CRITIQUE_FLAG"
printf '[{"number":5,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"plan:agreed"},{"name":"composition:approved"},{"name":"hold"}],"body":"charter goal","comments":[]}]\n' \
  > "$BOARD_STATE"

run_loop "$CBHOME_Pc" "$LOG_Pc" "CB_PLAN_CONVERGE_CAP=5"

[ "$(issue_state 5)" != "approved" ] \
  && ok "NO-PREMATURE-APPROVE(c): held charter (plan:agreed + composition:approved + hold) NOT approved" \
  || ko "NO-PREMATURE-APPROVE(c): held charter reached approved (hold label not respected)"

# =============================================================================
# PLAN-ESCALATE-CAP6: when CB_PLAN_CONVERGE_CAP and CB_CONVERGE_CAP are both unset,
#   the launcher's new last-resort fallback of 6 applies.
#   human-decision fires at round 6; it must NOT fire at the old default of 4.
# =============================================================================
echo "=== PLAN-ESCALATE-CAP6: no env cap → launcher fallback 6 → human-decision at round 6 ==="
CBHOME_CAP6="$ROOT/cbhome_cap6"; LOG_CAP6="$ROOT/loop_cap6.log"
reset_sandbox "$CBHOME_CAP6"
printf '99' > "$PLAN_CRITIQUE_FLAG"   # never agree
seed_needs_plan   # status:needs-plan, no converge-cap label

# Run WITHOUT CB_PLAN_CONVERGE_CAP or CB_CONVERGE_CAP — rely on launcher's new fallback of 6
run_loop "$CBHOME_CAP6" "$LOG_CAP6"
# (no extra env args → neither CB_PLAN_CONVERGE_CAP nor CB_CONVERGE_CAP is set)

_pr_cap6=$(grep -c '^5 solution-analyst' "$PLAN_REVIEW_LOG" 2>/dev/null)
[ "$_pr_cap6" -eq 6 ] \
  && ok "PLAN-ESCALATE-CAP6: plan-reviewer spawned exactly 6× (launcher fallback cap=6)" \
  || ko "PLAN-ESCALATE-CAP6: plan-reviewer spawn count=$_pr_cap6 (expected 6 — launcher fallback cap should be 6)"

[ "${_pr_cap6:-0}" -gt 4 ] \
  && ok "PLAN-ESCALATE-CAP6: escalation did NOT fire at round 4 (new fallback 6 > old default 4)" \
  || ko "PLAN-ESCALATE-CAP6: escalation fired at or before round 4 (old default 4 still in effect)"

_hd_cap6=$(open_hd_for 5)
[ "${_hd_cap6:-0}" -ge 1 ] \
  && ok "PLAN-ESCALATE-CAP6: human-decision created at cap=6" \
  || ko "PLAN-ESCALATE-CAP6: human-decision NOT created at cap=6"

[ "$(issue_state 5)" != "approved" ] \
  && ok "PLAN-ESCALATE-CAP6: charter NOT released to approved (cap=6 held the gate shut)" \
  || ko "PLAN-ESCALATE-CAP6: charter reached approved despite non-convergence at cap=6"

# =============================================================================
# PLAN-LABEL-OVERRIDE: a converge-cap:3 label on the charter overrides the env cap.
#   CB_PLAN_CONVERGE_CAP=6 in env (higher than label), label converge-cap:3 wins.
#   human-decision fires at round 3; it must NOT fire at round 6 (env cap).
# =============================================================================
echo "=== PLAN-LABEL-OVERRIDE: converge-cap:3 label beats CB_PLAN_CONVERGE_CAP=6 → escalate at 3 ==="
CBHOME_LBL="$ROOT/cbhome_lbl"; LOG_LBL="$ROOT/loop_lbl.log"
reset_sandbox "$CBHOME_LBL"
printf '99' > "$PLAN_CRITIQUE_FLAG"   # never agree
# Seed charter with converge-cap:3 label in addition to standard needs-plan labels
printf '[{"number":5,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:needs-plan"},{"name":"composition:approved"},{"name":"review:agreed"},{"name":"converge-cap:3"}],"body":"charter goal","comments":[]}]\n' \
  > "$BOARD_STATE"

# CB_PLAN_CONVERGE_CAP=6 in env (higher than label's 3) — label must win
run_loop "$CBHOME_LBL" "$LOG_LBL" "CB_PLAN_CONVERGE_CAP=6"

_pr_lbl=$(grep -c '^5 solution-analyst' "$PLAN_REVIEW_LOG" 2>/dev/null)
[ "$_pr_lbl" -eq 3 ] \
  && ok "PLAN-LABEL-OVERRIDE: plan-reviewer spawned exactly 3× (label converge-cap:3 overrode env cap=6)" \
  || ko "PLAN-LABEL-OVERRIDE: plan-reviewer spawn count=$_pr_lbl (expected 3 — label converge-cap:3 must win over CB_PLAN_CONVERGE_CAP=6)"

[ "${_pr_lbl:-0}" -lt 6 ] \
  && ok "PLAN-LABEL-OVERRIDE: escalation fired before env cap 6 (label cap wins)" \
  || ko "PLAN-LABEL-OVERRIDE: spawn count=$_pr_lbl ≥ 6 (env cap was not overridden by converge-cap:3 label)"

_hd_lbl=$(open_hd_for 5)
[ "${_hd_lbl:-0}" -ge 1 ] \
  && ok "PLAN-LABEL-OVERRIDE: human-decision created at label cap=3" \
  || ko "PLAN-LABEL-OVERRIDE: human-decision NOT created at label cap=3"

[ "$(issue_state 5)" != "approved" ] \
  && ok "PLAN-LABEL-OVERRIDE: charter NOT released to approved (label cap=3 held the gate shut)" \
  || ko "PLAN-LABEL-OVERRIDE: charter reached approved despite non-convergence at label cap=3"

# =============================================================================
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
