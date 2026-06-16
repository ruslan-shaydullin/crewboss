#!/usr/bin/env bash
# approval-gate.test.sh — approval-gate (HD-2) tests (issue #138).
# Class d integration-stub: gh stub file-board (including issue view --json comments and
# issue create for human-decision), REAL launcher + board-gh.sh, spawn stubs log roles.
# CB_MANIFEST = copy of team-example (threshold 1.00).
# Budget fixture run/budget.json EXACTLY in crewboss-spawn.sh format.
#
# RED-approved:   budget avg 0.10 × 2 leaves = 0.20 ≤ 1.00 → spawn cto → approve → needs-plan
# RED-chain (F-1): needs-plan → analyst → team-review → cto → needs-plan → tech-lead → plan-review
# RED-tries-isolation (F-1c): RETRY_CAP=2, analyst fails once then succeeds, cto fails once
#   then succeeds → charter NOT blocked (tries stage-isolated, cleared on success)
# RED-rejected:   cto rejects → needs-analysis, no composition:approved, analysis re-triggered
# RED-over-threshold: avg 0.60 × 3 leaves = 1.80 > 1.00 → human-decision, no cto spawn
# RED-no-history: budget.json absent → escalation to human-decision
# RED-invalid:    garbage Composition block → auto-reject → needs-analysis with comment
#
# EXCLUDED (invokes real launcher): reference/runtime/per-leaf-manifest
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
ANALYSIS_LOG="$ROOT/analysis.log"
ANALYSIS_FAIL_FLAG="$ROOT/analysis-fail"
APPROVAL_LOG="$ROOT/approval.log"
APPROVAL_FAIL_FLAG="$ROOT/approval-fail"
APPROVAL_REJECT_FLAG="$ROOT/approval-reject"
PLAN_LOG="$ROOT/plan.log"
export SANDBOX BOARD_STATE GH_LOG ANALYSIS_LOG ANALYSIS_FAIL_FLAG
export APPROVAL_LOG APPROVAL_FAIL_FLAG APPROVAL_REJECT_FLAG PLAN_LOG

# CB_MANIFEST: copy of team-example
CB_MANIFEST_DIR="$ROOT/manifest"
cp -r "$TEAM_EXAMPLE/." "$CB_MANIFEST_DIR"
export CB_MANIFEST_DIR MANIFEST_LIB_SRC

BIN="$ROOT/bin"; mkdir -p "$BIN"

# ── board helpers ─────────────────────────────────────────────────────────────
has_label(){ [ "$(jq -r --argjson n "$1" 'map(select(.number==$n))[0].labels[]?.name' \
                   "$BOARD_STATE" 2>/dev/null | grep -c "^$2$")" -ge 1 ]; }
no_label(){  ! has_label "$1" "$2"; }
has_comment(){ jq -r --argjson n "$1" 'map(select(.number==$n))[0].comments[]?.body' \
                 "$BOARD_STATE" 2>/dev/null | grep -qi "$2"; }
issue_state(){ jq -r --argjson n "$1" 'map(select(.number==$n))[0]|
                if .state=="CLOSED" then "done"
                elif ([.labels[]?.name]|any(.=="status:team-review")) then "team-review"
                elif ([.labels[]?.name]|any(.=="status:needs-analysis")) then "needs-analysis"
                elif ([.labels[]?.name]|any(.=="status:needs-plan")) then "needs-plan"
                elif ([.labels[]?.name]|any(.=="status:plan-review")) then "plan-review"
                elif ([.labels[]?.name]|any(.=="status:blocked")) then "blocked"
                else "open" end' "$BOARD_STATE" 2>/dev/null; }
open_hd_for(){ jq -r --argjson c "$1" '
  [.[] | select(.state=="OPEN")
        | select([.labels[]?.name] | index("type:human-decision") != null)
        | select((.body//"") | test("Charter:\\s*#?" + ($c|tostring)))] | length' \
  "$BOARD_STATE" 2>/dev/null || echo "0"; }

reset_sandbox(){
  rm -rf "$SANDBOX"; mkdir -p "$SANDBOX"
  : > "$GH_LOG"
  : > "$ANALYSIS_LOG"
  : > "$APPROVAL_LOG"
  : > "$PLAN_LOG"
  rm -f "$ANALYSIS_FAIL_FLAG" "$APPROVAL_FAIL_FLAG" "$APPROVAL_REJECT_FLAG"
  local cbhome="$1"
  rm -rf "$cbhome"; mkdir -p "$cbhome"
  cp "$BOARD_GH_SRC"   "$cbhome/board-gh.sh"
  cp "$LAUNCHABLE_SRC" "$cbhome/launchable.sh"
  chmod +x "$cbhome/board-gh.sh" "$cbhome/launchable.sh"
}

# ── gh stub ───────────────────────────────────────────────────────────────────
# Handles: issue list/view/edit/comment/close/create, auth token, label create.
# BOARD_STATE stores all issues (state, labels, body, comments).
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

# ── analysis spawn stub ───────────────────────────────────────────────────────
# If ANALYSIS_FAIL_FLAG has count > 0: decrement and fail (exit 1).
# Otherwise: post 2-leaf composition comment + transition to team-review.
ANALYSIS_STUB="$ROOT/analysis-stub.sh"
cat > "$ANALYSIS_STUB" <<'ASEOF'
#!/usr/bin/env bash
CID="$1"; AROLE="$2"
printf '%s %s\n' "$CID" "$AROLE" >> "$ANALYSIS_LOG"
if [ -f "$ANALYSIS_FAIL_FLAG" ]; then
  cnt=$(cat "$ANALYSIS_FAIL_FLAG" 2>/dev/null || echo 0)
  if [ "$cnt" -gt 0 ]; then
    printf '%d' "$((cnt - 1))" > "$ANALYSIS_FAIL_FLAG"
    printf 'analysis-stub: FAIL for #%s (remaining=%d)\n' "$CID" "$((cnt-1))" >> "$ANALYSIS_LOG"
    exit 1
  fi
fi
# Success: post composition comment (2 leaves, go-backend-dev) + move to team-review
gh issue comment "$CID" -R "test/repo" --body "## Composition (machine)
- approach: parallel implementation
- role: go-backend-dev
- leaf: L-1 -> go-backend-dev
- leaf: L-2 -> go-backend-dev
- est_cost_usd: 1.5"
gh issue edit "$CID" -R "test/repo" \
  --remove-label status:needs-analysis \
  --add-label status:team-review
printf 'analysis-stub: SUCCESS for #%s\n' "$CID" >> "$ANALYSIS_LOG"
exit 0
ASEOF
chmod +x "$ANALYSIS_STUB"

# ── approval spawn stub (CTO) ─────────────────────────────────────────────────
# If APPROVAL_REJECT_FLAG exists: reject (→ needs-analysis, no composition:approved).
# If APPROVAL_FAIL_FLAG has count > 0: decrement and exit 0 WITHOUT changing state.
# Otherwise: approve (add composition:approved + status:needs-plan, remove status:team-review).
APPROVAL_STUB="$ROOT/approval-stub.sh"
cat > "$APPROVAL_STUB" <<'CTEOF'
#!/usr/bin/env bash
CID="$1"; CROLE="$2"
printf '%s %s\n' "$CID" "$CROLE" >> "$APPROVAL_LOG"
if [ -f "$APPROVAL_REJECT_FLAG" ]; then
  gh issue comment "$CID" -R "test/repo" --body "Approval rejected: composition needs revision"
  gh issue edit "$CID" -R "test/repo" \
    --remove-label status:team-review \
    --add-label status:needs-analysis
  printf 'approval-stub: REJECT for #%s\n' "$CID" >> "$APPROVAL_LOG"
  exit 0
fi
if [ -f "$APPROVAL_FAIL_FLAG" ]; then
  cnt=$(cat "$APPROVAL_FAIL_FLAG" 2>/dev/null || echo 0)
  if [ "$cnt" -gt 0 ]; then
    printf '%d' "$((cnt - 1))" > "$APPROVAL_FAIL_FLAG"
    printf 'approval-stub: FAIL (no state change) for #%s (remaining=%d)\n' "$CID" "$((cnt-1))" >> "$APPROVAL_LOG"
    exit 0
  fi
fi
# Success: approve
gh issue edit "$CID" -R "test/repo" \
  --add-label composition:approved \
  --add-label status:needs-plan \
  --remove-label status:team-review
printf 'approval-stub: APPROVE for #%s\n' "$CID" >> "$APPROVAL_LOG"
exit 0
CTEOF
chmod +x "$APPROVAL_STUB"

# ── plan spawn stub (tech-lead) ───────────────────────────────────────────────
PLAN_STUB="$ROOT/plan-stub.sh"
cat > "$PLAN_STUB" <<'PSEOF'
#!/usr/bin/env bash
CID="$1"; PROLE="$2"
printf '%s %s\n' "$CID" "$PROLE" >> "$PLAN_LOG"
gh issue edit "$CID" -R "test/repo" \
  --remove-label status:needs-plan \
  --add-label status:plan-review
exit 0
PSEOF
chmod +x "$PLAN_STUB"

# ── loop runner ───────────────────────────────────────────────────────────────
run_loop(){
  local cbhome="$1" logfile="${2:-/dev/null}"; shift 2
  : > "$ANALYSIS_LOG"
  : > "$APPROVAL_LOG"
  : > "$GH_LOG"
  : > "$PLAN_LOG"
  PATH="$BIN:$PATH" \
    CB_REPO="test/repo" \
    CB_HOME="$cbhome" \
    CB_SPAWN="$PLAN_STUB" \
    CB_PLAN_SPAWN="$PLAN_STUB" \
    CB_ANALYSIS_SPAWN="$ANALYSIS_STUB" \
    CB_APPROVAL_SPAWN="$APPROVAL_STUB" \
    CB_MANIFEST="$CB_MANIFEST_DIR" \
    CB_MANIFEST_LIB="$MANIFEST_LIB_SRC" \
    CB_POLL=0 \
    CB_MAX_TICKS=40 \
    CB_IDLE_CONFIRM=2 \
    CB_MAX_PARALLEL=4 \
    CB_RETRY_CAP=3 \
    CREWBOSS_CHARTER= \
    env "$@" \
    bash "$LAUNCHER" run >"$logfile" 2>&1 || true
}

# Standard budget: 3 runs, spent_usd=0.30 → avg 0.10 (2 leaves → est 0.20 ≤ 1.00)
write_budget_low(){ local d="$1"; mkdir -p "$d/run"
  printf '{"spent_usd":0.30,"runs":[\n  {"task":"t1","role":"r1","cost":0.1,"at":"2026-01-01T00:00:00Z"},\n  {"task":"t2","role":"r2","cost":0.1,"at":"2026-01-01T00:00:01Z"},\n  {"task":"t3","role":"r3","cost":0.1,"at":"2026-01-01T00:00:02Z"}\n]}\n' \
    > "$d/run/budget.json"; }

# Over-threshold budget: 1 run, spent_usd=0.60 → avg 0.60 (3 leaves → est 1.80 > 1.00)
write_budget_high(){ local d="$1"; mkdir -p "$d/run"
  printf '{"spent_usd":0.60,"runs":[\n  {"task":"t1","role":"r1","cost":0.6,"at":"2026-01-01T00:00:00Z"}\n]}\n' \
    > "$d/run/budget.json"; }

# Valid 2-leaf composition (JSON-encoded in board state — \n is JSON escape for newline)
COMP_2L_JSON='## Composition (machine)\n- approach: parallel implementation\n- role: go-backend-dev\n- leaf: L-1 -> go-backend-dev\n- leaf: L-2 -> go-backend-dev\n- est_cost_usd: 1.5'

# Valid 3-leaf composition
COMP_3L_JSON='## Composition (machine)\n- approach: parallel implementation\n- role: go-backend-dev\n- leaf: L-1 -> go-backend-dev\n- leaf: L-2 -> go-backend-dev\n- leaf: L-3 -> go-backend-dev\n- est_cost_usd: 5.0'

# =============================================================================
# RED-approved: budget avg 0.10 × 2 leaves = 0.20 ≤ 1.00 → spawn cto → approve → needs-plan
# =============================================================================
echo "=== RED-approved: est 0.20 ≤ 1.00 → cto spawned → charter approved ==="
CBHOME_A="$ROOT/cbhome_a"; LOGFILE_A="$ROOT/loop_a.log"
reset_sandbox "$CBHOME_A"
write_budget_low "$CBHOME_A"

# Board state with composition comment (use JSON-escaped \n in string value)
printf '[{"number":5,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:team-review"}],"body":"charter goal","comments":[{"body":"%s"}]}]\n' \
  "$COMP_2L_JSON" > "$BOARD_STATE"

run_loop "$CBHOME_A" "$LOGFILE_A"

grep -q "cto" "$APPROVAL_LOG" \
  && ok "RED-approved: cto spawned for charter #5" \
  || ko "RED-approved: cto NOT spawned (approval-cycle broken)"

has_label 5 "composition:approved" \
  && ok "RED-approved: charter #5 has composition:approved" \
  || ko "RED-approved: charter #5 missing composition:approved"

# After approval charter goes to needs-plan; tech-lead may also run → plan-review
{ has_label 5 "status:needs-plan" || has_label 5 "status:plan-review"; } \
  && ok "RED-approved: charter #5 transitioned past team-review (needs-plan or plan-review)" \
  || ko "RED-approved: charter #5 NOT in needs-plan or plan-review after CTO approval"

no_label 5 "status:team-review" \
  && ok "RED-approved: charter #5 team-review label removed" \
  || ko "RED-approved: charter #5 still has team-review label"

# =============================================================================
# RED-chain (F-1): needs-plan → analyst → team-review → cto → needs-plan → tech-lead → plan-review
# =============================================================================
echo "=== RED-chain (F-1): full pipeline in one run ==="
CBHOME_CH="$ROOT/cbhome_ch"; LOGFILE_CH="$ROOT/loop_ch.log"
reset_sandbox "$CBHOME_CH"
write_budget_low "$CBHOME_CH"

printf '[{"number":5,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:needs-plan"}],"body":"charter goal","comments":[]}]\n' \
  > "$BOARD_STATE"

run_loop "$CBHOME_CH" "$LOGFILE_CH" "CB_MAX_TICKS=60"

grep -q "^5 solution-analyst" "$ANALYSIS_LOG" \
  && ok "RED-chain: analyst spawned for #5" \
  || ko "RED-chain: analyst NOT spawned"

grep -q "cto" "$APPROVAL_LOG" \
  && ok "RED-chain: cto spawned for #5" \
  || ko "RED-chain: cto NOT spawned"

grep -q "^5 tech-lead" "$PLAN_LOG" \
  && ok "RED-chain: tech-lead spawned for #5" \
  || ko "RED-chain: tech-lead NOT spawned"

_cst_ch=$(issue_state 5)
[ "$_cst_ch" = "plan-review" ] \
  && ok "RED-chain: charter #5 reached plan-review" \
  || ko "RED-chain: charter #5 state=$_cst_ch (expected plan-review)"

# F-1: approval spawn NOT processed by kind=charter branch
grep -q "plan failed" "$LOGFILE_CH" \
  && ko "RED-chain: 'plan failed' in log — kind=approval routed by kind=charter (F-1 broken)" \
  || ok "RED-chain: no 'plan failed' in log (kind=approval post-processed separately)"

grep -q "idle — run complete" "$LOGFILE_CH" \
  && ok "RED-chain: loop exited cleanly (idle — run complete)" \
  || ok "RED-chain: loop finished (acceptable)"

# =============================================================================
# RED-tries-isolation (F-1c): analyst fails once then succeeds, cto fails once then succeeds
# → tries are stage-isolated; charter NOT blocked; reaches tech-lead
# =============================================================================
echo "=== RED-tries-isolation (F-1c): stage-isolated tries — analyst fail+ok, cto fail+ok ==="
CBHOME_TI="$ROOT/cbhome_ti"; LOGFILE_TI="$ROOT/loop_ti.log"
reset_sandbox "$CBHOME_TI"
write_budget_low "$CBHOME_TI"

printf '[{"number":5,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:needs-plan"}],"body":"charter goal","comments":[]}]\n' \
  > "$BOARD_STATE"

printf '1' > "$ANALYSIS_FAIL_FLAG"   # analyst fails exactly once, then succeeds
printf '1' > "$APPROVAL_FAIL_FLAG"   # cto fails exactly once (no state change), then succeeds

run_loop "$CBHOME_TI" "$LOGFILE_TI" "CB_MAX_TICKS=80" "CB_RETRY_CAP=2"

_cnt_a=$(grep -c "^5 solution-analyst" "$ANALYSIS_LOG" 2>/dev/null || echo 0)
[ "$_cnt_a" -ge 2 ] \
  && ok "RED-tries-isolation: analyst spawned ≥2 times (fail+retry, cnt=$_cnt_a)" \
  || ko "RED-tries-isolation: analyst spawn count=$_cnt_a (expected ≥2)"

_cnt_c=$(grep -c "cto" "$APPROVAL_LOG" 2>/dev/null || echo 0)
[ "$_cnt_c" -ge 2 ] \
  && ok "RED-tries-isolation: cto spawned ≥2 times (fail+retry, cnt=$_cnt_c)" \
  || ko "RED-tries-isolation: cto spawn count=$_cnt_c (expected ≥2)"

no_label 5 "status:blocked" \
  && ok "RED-tries-isolation: charter #5 NOT blocked (stage-isolated tries)" \
  || ko "RED-tries-isolation: charter #5 blocked — tries NOT isolated between stages"

grep -q "^5 tech-lead" "$PLAN_LOG" \
  && ok "RED-tries-isolation: tech-lead spawned (chain completed)" \
  || ko "RED-tries-isolation: tech-lead NOT spawned (chain incomplete)"

# =============================================================================
# RED-rejected: cto always rejects → needs-analysis, no composition:approved,
#   no tech-lead, analysis re-triggered (F-1: term/tries cleared on rejection)
# =============================================================================
echo "=== RED-rejected: cto rejects → needs-analysis, analysis re-triggered ==="
CBHOME_RJ="$ROOT/cbhome_rj"; LOGFILE_RJ="$ROOT/loop_rj.log"
reset_sandbox "$CBHOME_RJ"
write_budget_low "$CBHOME_RJ"

# CTO always rejects; analyst always succeeds → oscillating cycle
touch "$APPROVAL_REJECT_FLAG"

printf '[{"number":5,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:team-review"}],"body":"charter goal","comments":[{"body":"%s"}]}]\n' \
  "$COMP_2L_JSON" > "$BOARD_STATE"

run_loop "$CBHOME_RJ" "$LOGFILE_RJ" "CB_MAX_TICKS=20"

grep -q "cto" "$APPROVAL_LOG" \
  && ok "RED-rejected: cto spawned for charter #5" \
  || ko "RED-rejected: cto NOT spawned"

has_comment 5 "Approval rejected" \
  && ok "RED-rejected: rejection comment present on charter #5" \
  || ko "RED-rejected: rejection comment missing"

no_label 5 "composition:approved" \
  && ok "RED-rejected: no composition:approved (correct — rejected)" \
  || ko "RED-rejected: composition:approved present despite rejection"

grep -q "^5 tech-lead" "$PLAN_LOG" \
  && ko "RED-rejected: tech-lead spawned despite rejection (leaves launched prematurely)" \
  || ok "RED-rejected: tech-lead NOT spawned (leaves correctly not started)"

# F-1: analyst re-triggered after rejection (term/tries cleared so analysis-cycle can pick up)
grep -q "^5 solution-analyst" "$ANALYSIS_LOG" \
  && ok "RED-rejected: analysis re-triggered after rejection (term/tries cleared — F-1)" \
  || ko "RED-rejected: analyst NOT re-triggered (term/tries not cleared — F-1 broken)"

# =============================================================================
# RED-over-threshold: avg 0.60 × 3 leaves = 1.80 > 1.00 → human-decision, no cto spawn
# =============================================================================
echo "=== RED-over-threshold: est 1.80 > 1.00 → human-decision, no cto spawn ==="
CBHOME_OT="$ROOT/cbhome_ot"; LOGFILE_OT="$ROOT/loop_ot.log"
reset_sandbox "$CBHOME_OT"
write_budget_high "$CBHOME_OT"

printf '[{"number":5,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:team-review"}],"body":"charter goal","comments":[{"body":"%s"}]}]\n' \
  "$COMP_3L_JSON" > "$BOARD_STATE"

run_loop "$CBHOME_OT" "$LOGFILE_OT" "CB_MAX_TICKS=15"

_hd_count=$(open_hd_for 5)
[ "${_hd_count:-0}" -ge 1 ] \
  && ok "RED-over-threshold: human-decision issue created for charter #5" \
  || ko "RED-over-threshold: human-decision NOT created"

grep -q "cto" "$APPROVAL_LOG" \
  && ko "RED-over-threshold: cto spawned despite over-threshold (escalation broken)" \
  || ok "RED-over-threshold: cto NOT spawned (correct — escalated to human)"

has_label 5 "status:team-review" \
  && ok "RED-over-threshold: charter #5 remains in team-review" \
  || ko "RED-over-threshold: charter #5 moved out of team-review (should stay)"

# Idempotent: second run must NOT create another human-decision issue
run_loop "$CBHOME_OT" "${LOGFILE_OT}.2" "CB_MAX_TICKS=5"
_hd_count2=$(open_hd_for 5)
[ "${_hd_count2:-0}" -eq "${_hd_count:-0}" ] \
  && ok "RED-over-threshold: idempotent — no duplicate human-decision on second run" \
  || ko "RED-over-threshold: human-decision duplicated (count2=$_hd_count2 vs first=$_hd_count)"

# N-1: loop exits idle (human-decision open → team-review does NOT hold loop alive)
grep -q "idle — run complete" "$LOGFILE_OT" \
  && ok "RED-over-threshold: loop exited idle (N-1: human-decision excludes loop alive)" \
  || ok "RED-over-threshold: loop finished (acceptable)"

grep -q "max ticks" "$LOGFILE_OT" \
  && ko "RED-over-threshold: loop hit max-ticks (should exit idle when human-decision open)" \
  || ok "RED-over-threshold: loop did NOT hit max-ticks"

# =============================================================================
# RED-no-history: budget.json absent → escalation to human-decision
# =============================================================================
echo "=== RED-no-history: absent budget.json → escalation to human-decision ==="
CBHOME_NH="$ROOT/cbhome_nh"; LOGFILE_NH="$ROOT/loop_nh.log"
reset_sandbox "$CBHOME_NH"
mkdir -p "$CBHOME_NH/run"
# No budget.json — directory exists but file absent

printf '[{"number":5,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:team-review"}],"body":"charter goal","comments":[{"body":"%s"}]}]\n' \
  "$COMP_2L_JSON" > "$BOARD_STATE"

run_loop "$CBHOME_NH" "$LOGFILE_NH" "CB_MAX_TICKS=15"

_hd_nh=$(open_hd_for 5)
[ "${_hd_nh:-0}" -ge 1 ] \
  && ok "RED-no-history: human-decision created (no budget history → conservative escalation)" \
  || ko "RED-no-history: human-decision NOT created (no-history escalation broken)"

grep -q "cto" "$APPROVAL_LOG" \
  && ko "RED-no-history: cto spawned despite no history (escalation broken)" \
  || ok "RED-no-history: cto NOT spawned (correct — escalated due to no history)"

grep -q "idle — run complete" "$LOGFILE_NH" \
  && ok "RED-no-history: loop exited idle (N-1 predicate)" \
  || ok "RED-no-history: loop finished (acceptable)"

grep -q "max ticks" "$LOGFILE_NH" \
  && ko "RED-no-history: loop hit max-ticks (should idle-exit when human-decision open)" \
  || ok "RED-no-history: loop did NOT hit max-ticks"

# =============================================================================
# RED-invalid: garbage Composition block → auto-reject → needs-analysis with comment
# =============================================================================
echo "=== RED-invalid: garbage composition → auto-reject to needs-analysis ==="
CBHOME_IV="$ROOT/cbhome_iv"; LOGFILE_IV="$ROOT/loop_iv.log"
reset_sandbox "$CBHOME_IV"
write_budget_low "$CBHOME_IV"

# Charter in team-review with garbage/invalid composition comment.
# Analyst always fails so re-analysis after auto-reject doesn't produce valid composition.
printf '99' > "$ANALYSIS_FAIL_FLAG"

# JSON-encoded garbage comment (has ## Composition header but no valid fields).
# Use \\n so printf writes literal \n in the JSON string (JSON escape for newline).
printf '[{"number":5,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:team-review"}],"body":"charter goal","comments":[{"body":"## Composition (machine)\\ngarbage content no valid fields at all"}]}]\n' \
  > "$BOARD_STATE"

run_loop "$CBHOME_IV" "$LOGFILE_IV" "CB_MAX_TICKS=15" "CB_RETRY_CAP=2"

# Auto-reject comment must have been added
has_comment 5 "approval-gate" \
  && ok "RED-invalid: approval-gate auto-reject comment present on charter #5" \
  || ko "RED-invalid: approval-gate comment missing (auto-reject not triggered)"

# CTO must NOT have been spawned
grep -q "cto" "$APPROVAL_LOG" \
  && ko "RED-invalid: cto spawned despite invalid composition (auto-reject broken)" \
  || ok "RED-invalid: cto NOT spawned (invalid composition → auto-rejected)"

# Charter must have been routed to needs-analysis (evidenced by label change in gh log)
grep -q "needs-analysis" "$GH_LOG" \
  && ok "RED-invalid: charter #5 routed to needs-analysis (auto-reject succeeded)" \
  || ko "RED-invalid: needs-analysis not found in gh log (auto-reject routing missing)"

# Acceptance check (from spec): human_approval_above_usd must appear in launcher
grep -q "human_approval_above_usd" "$LAUNCHER" \
  && ok "check: human_approval_above_usd present in launcher" \
  || ko "check: human_approval_above_usd NOT found in launcher"

# =============================================================================
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
