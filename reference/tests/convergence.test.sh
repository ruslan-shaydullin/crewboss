#!/usr/bin/env bash
# convergence.test.sh — analyst↔reviewer substance-convergence loop (#334 C1 / #335).
# Class d integration-stub: gh stub file-board (incl. issue create for human-decision),
# REAL launcher + board-gh.sh + composition-parse + manifest; spawn stubs log roles.
# CB_MANIFEST = copy of team-example with policy.review_role="reviewer" added.
#
# A hermetic `flock` shim is injected into $BIN (macOS has no flock; the launcher's
# `flock -n 9` would otherwise fail-closed to "another launcher holds the lock — exit").
# Single-launcher test → "always acquired" (exit 0) is the correct lock semantics here.
#
# Proves C1's mandate ("сходимость за K раундов; эскалация при превышении; история пишется"):
#   CONVERGE:    reviewer CRITIQUE ×K then AGREE → review:agreed → proceeds to cost/cto.
#                cround increments each round; round history (REVIEW comments) recorded.
#   ESCALATE:    reviewer always CRITIQUE → cround hits CONVERGE_CAP → type:human-decision;
#                reviewer spawned EXACTLY cap times (cap stops the ping-pong) → idempotent.
#   FORMAT-CAP:  analyst keeps emitting invalid composition → format-reject path ALSO caps
#                → human-decision (the runaway we hit before the reviewer ever runs).
#   AGREED-SKIP: review:agreed already present → reviewer NOT spawned, straight to cost/cto.
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
ANALYSIS_GARBAGE_FLAG="$ROOT/analysis-garbage"
REVIEW_LOG="$ROOT/review.log"
REVIEW_REJECT_FLAG="$ROOT/review-reject"
APPROVAL_LOG="$ROOT/approval.log"
PLAN_LOG="$ROOT/plan.log"
export SANDBOX BOARD_STATE GH_LOG ANALYSIS_LOG ANALYSIS_GARBAGE_FLAG
export REVIEW_LOG REVIEW_REJECT_FLAG APPROVAL_LOG PLAN_LOG

# CB_MANIFEST: copy of team-example, with review_role added to policy
CB_MANIFEST_DIR="$ROOT/manifest"
cp -r "$TEAM_EXAMPLE/." "$CB_MANIFEST_DIR"
jq '.policy.review_role="reviewer"' "$CB_MANIFEST_DIR/org.json" > "$CB_MANIFEST_DIR/org.json.t" \
  && mv "$CB_MANIFEST_DIR/org.json.t" "$CB_MANIFEST_DIR/org.json"
export CB_MANIFEST_DIR MANIFEST_LIB_SRC

BIN="$ROOT/bin"; mkdir -p "$BIN"

# ── flock shim (hermetic, single-launcher) ────────────────────────────────────
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/flock"
chmod +x "$BIN/flock"

# ── board helpers ─────────────────────────────────────────────────────────────
has_label(){ [ "$(jq -r --argjson n "$1" 'map(select(.number==$n))[0].labels[]?.name' \
                   "$BOARD_STATE" 2>/dev/null | grep -c "^$2$")" -ge 1 ]; }
no_label(){  ! has_label "$1" "$2"; }
comment_count(){ jq -r --argjson n "$1" 'map(select(.number==$n))[0].comments[]?.body' \
                   "$BOARD_STATE" 2>/dev/null | grep -c "$2"; }
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
hd_title_for(){ jq -r --argjson c "$1" '
  [.[] | select(.state=="OPEN")
        | select([.labels[]?.name] | index("type:human-decision") != null)
        | select((.body//"") | test("Charter:\\s*#?" + ($c|tostring)))] | last | .title // ""' \
  "$BOARD_STATE" 2>/dev/null || echo ""; }

reset_sandbox(){
  rm -rf "$SANDBOX"; mkdir -p "$SANDBOX"
  : > "$GH_LOG"
  rm -f "$ANALYSIS_GARBAGE_FLAG" "$REVIEW_REJECT_FLAG"
  local cbhome="$1"
  rm -rf "$cbhome"; mkdir -p "$cbhome"
  cp "$BOARD_GH_SRC"   "$cbhome/board-gh.sh"
  cp "$LAUNCHABLE_SRC" "$cbhome/launchable.sh"
  chmod +x "$cbhome/board-gh.sh" "$cbhome/launchable.sh"
}

# ── gh stub (file-board; identical contract to approval-gate.test.sh) ──────────
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
# Always succeeds (posts composition + team-review). ANALYSIS_GARBAGE_FLAG holds a COUNTDOWN:
# while > 0, decrement and post an INVALID composition (## header but no parseable leaf/role
# lines) so the format-reject path fires; at 0, post a valid composition. Lets a test interleave
# a format-glitch round with substance rounds.
ANALYSIS_STUB="$ROOT/analysis-stub.sh"
cat > "$ANALYSIS_STUB" <<'ASEOF'
#!/usr/bin/env bash
CID="$1"; AROLE="$2"
printf '%s %s\n' "$CID" "$AROLE" >> "$ANALYSIS_LOG"
_garb=0
[ -f "$ANALYSIS_GARBAGE_FLAG" ] && _garb=$(cat "$ANALYSIS_GARBAGE_FLAG" 2>/dev/null || echo 0)
if [ "${_garb:-0}" -gt 0 ]; then
  printf '%d' "$((_garb - 1))" > "$ANALYSIS_GARBAGE_FLAG"
  gh issue comment "$CID" -R "test/repo" --body "## Composition (machine)
garbage content no valid fields at all"
else
  gh issue comment "$CID" -R "test/repo" --body "## Composition (machine)
- approach: parallel implementation
- role: go-backend-dev
- leaf: L-1 -> go-backend-dev
- leaf: L-2 -> go-backend-dev
- est_cost_usd: 1.5"
fi
gh issue edit "$CID" -R "test/repo" \
  --remove-label status:needs-analysis \
  --add-label status:team-review
exit 0
ASEOF
chmod +x "$ANALYSIS_STUB"

# ── review spawn stub (substance reviewer) ────────────────────────────────────
# If REVIEW_REJECT_FLAG count > 0: decrement and CRITIQUE (comment + back to needs-analysis).
# Otherwise: AGREE (add review:agreed; charter stays in team-review).
REVIEW_STUB="$ROOT/review-stub.sh"
cat > "$REVIEW_STUB" <<'RVEOF'
#!/usr/bin/env bash
CID="$1"; RROLE="$2"
printf '%s %s\n' "$CID" "$RROLE" >> "$REVIEW_LOG"
if [ -f "$REVIEW_REJECT_FLAG" ]; then
  cnt=$(cat "$REVIEW_REJECT_FLAG" 2>/dev/null || echo 0)
  if [ "$cnt" -gt 0 ]; then
    printf '%d' "$((cnt - 1))" > "$REVIEW_REJECT_FLAG"
    gh issue comment "$CID" -R "test/repo" --body "REVIEW: changes-requested
- что: missing qa-engineer | почему: rubric needs-tests | фикс: add qa-engineer role"
    gh issue edit "$CID" -R "test/repo" \
      --remove-label status:team-review \
      --add-label status:needs-analysis
    printf 'review-stub: CRITIQUE for #%s (remaining=%d)\n' "$CID" "$((cnt-1))" >> "$REVIEW_LOG"
    exit 0
  fi
fi
gh issue comment "$CID" -R "test/repo" --body "REVIEW: agreed — sound on all four anchors"
gh issue edit "$CID" -R "test/repo" --add-label review:agreed
printf 'review-stub: AGREE for #%s\n' "$CID" >> "$REVIEW_LOG"
exit 0
RVEOF
chmod +x "$REVIEW_STUB"

# ── approval (cto) + plan (tech-lead) stubs — success paths ────────────────────
APPROVAL_STUB="$ROOT/approval-stub.sh"
cat > "$APPROVAL_STUB" <<'CTEOF'
#!/usr/bin/env bash
CID="$1"; CROLE="$2"
printf '%s %s\n' "$CID" "$CROLE" >> "$APPROVAL_LOG"
gh issue edit "$CID" -R "test/repo" \
  --add-label composition:approved \
  --add-label status:needs-plan \
  --remove-label status:team-review
exit 0
CTEOF
chmod +x "$APPROVAL_STUB"

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
  : > "$ANALYSIS_LOG"; : > "$REVIEW_LOG"; : > "$APPROVAL_LOG"; : > "$PLAN_LOG"; : > "$GH_LOG"
  PATH="$BIN:$PATH" \
    CB_REPO="test/repo" \
    CB_HOME="$cbhome" \
    CB_SPAWN="$PLAN_STUB" \
    CB_PLAN_SPAWN="$PLAN_STUB" \
    CB_ANALYSIS_SPAWN="$ANALYSIS_STUB" \
    CB_REVIEW_SPAWN="$REVIEW_STUB" \
    CB_APPROVAL_SPAWN="$APPROVAL_STUB" \
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

# Standard budget: avg 0.10 × 2 leaves = 0.20 ≤ 1.00 → cto path (not human escalation)
write_budget_low(){ local d="$1"; mkdir -p "$d/run"
  printf '{"spent_usd":0.30,"runs":[\n  {"task":"t1","role":"r1","cost":0.1,"at":"2026-01-01T00:00:00Z"},\n  {"task":"t2","role":"r2","cost":0.1,"at":"2026-01-01T00:00:01Z"},\n  {"task":"t3","role":"r3","cost":0.1,"at":"2026-01-01T00:00:02Z"}\n]}\n' \
    > "$d/run/budget.json"; }

COMP_2L_JSON='## Composition (machine)\n- approach: parallel implementation\n- role: go-backend-dev\n- leaf: L-1 -> go-backend-dev\n- leaf: L-2 -> go-backend-dev\n- est_cost_usd: 1.5'

# =============================================================================
# CONVERGE: reviewer CRITIQUE ×2 then AGREE → review:agreed → cto. cround = K rounds.
# =============================================================================
echo "=== CONVERGE: 2× CRITIQUE then AGREE → review:agreed → proceeds to cto ==="
CBHOME_C="$ROOT/cbhome_c"; LOG_C="$ROOT/loop_c.log"
reset_sandbox "$CBHOME_C"; write_budget_low "$CBHOME_C"
printf '2' > "$REVIEW_REJECT_FLAG"   # reject twice, then agree on the 3rd review
printf '[{"number":5,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:needs-analysis"}],"body":"charter goal","comments":[]}]\n' \
  > "$BOARD_STATE"

run_loop "$CBHOME_C" "$LOG_C" "CB_CONVERGE_CAP=5"

_rv_c=$(grep -c '^5 reviewer' "$REVIEW_LOG" 2>/dev/null)
[ "$_rv_c" -eq 3 ] \
  && ok "CONVERGE: reviewer spawned exactly 3× (2 CRITIQUE + 1 AGREE)" \
  || ko "CONVERGE: reviewer spawn count=$_rv_c (expected 3 — 2 reject then agree)"

has_label 5 "review:agreed" \
  && ok "CONVERGE: review:agreed set after convergence" \
  || ko "CONVERGE: review:agreed NOT set (never converged)"

# round history: ≥2 CRITIQUE comments recorded on the charter thread
_crit_c=$(comment_count 5 "REVIEW: changes-requested")
[ "${_crit_c:-0}" -ge 2 ] \
  && ok "CONVERGE: round history written (≥2 CRITIQUE comments, got $_crit_c)" \
  || ko "CONVERGE: round history missing (CRITIQUE comments=$_crit_c, expected ≥2)"

grep -q "cto" "$APPROVAL_LOG" \
  && ok "CONVERGE: cto spawned (gate opened after agreement)" \
  || ko "CONVERGE: cto NOT spawned (agreement did not unblock cost gate)"

_st_c=$(issue_state 5)
{ [ "$_st_c" = "needs-plan" ] || [ "$_st_c" = "plan-review" ]; } \
  && ok "CONVERGE: charter proceeded past convergence (state=$_st_c)" \
  || ko "CONVERGE: charter state=$_st_c (expected needs-plan/plan-review)"

# =============================================================================
# ESCALATE: reviewer always CRITIQUE → cround hits cap → human-decision.
#   reviewer spawned EXACTLY cap times (cap stops the ping-pong); cto never reached.
# =============================================================================
echo "=== ESCALATE: always CRITIQUE → CONVERGE_CAP=3 → human-decision (cap stops runaway) ==="
CBHOME_E="$ROOT/cbhome_e"; LOG_E="$ROOT/loop_e.log"
reset_sandbox "$CBHOME_E"; write_budget_low "$CBHOME_E"
printf '99' > "$REVIEW_REJECT_FLAG"   # never agree
printf '[{"number":5,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:needs-analysis"}],"body":"charter goal","comments":[]}]\n' \
  > "$BOARD_STATE"

run_loop "$CBHOME_E" "$LOG_E" "CB_CONVERGE_CAP=3"

_rv_e=$(grep -c '^5 reviewer' "$REVIEW_LOG" 2>/dev/null)
[ "$_rv_e" -eq 3 ] \
  && ok "ESCALATE: reviewer spawned exactly cap=3 times (no runaway ping-pong)" \
  || ko "ESCALATE: reviewer spawn count=$_rv_e (expected 3 == cap)"

_hd_e=$(open_hd_for 5)
[ "${_hd_e:-0}" -ge 1 ] \
  && ok "ESCALATE: human-decision created at cap" \
  || ko "ESCALATE: human-decision NOT created at cap"

case "$(hd_title_for 5)" in
  *"did not converge"*) ok "ESCALATE: human-decision titled 'did not converge'" ;;
  *) ko "ESCALATE: human-decision title wrong: '$(hd_title_for 5)'" ;;
esac

grep -q "cto" "$APPROVAL_LOG" \
  && ko "ESCALATE: cto spawned despite non-convergence (cost gate must stay shut)" \
  || ok "ESCALATE: cto NOT spawned (never reached cost gate)"

# idempotent: a second run must NOT create a duplicate human-decision
run_loop "$CBHOME_E" "${LOG_E}.2" "CB_CONVERGE_CAP=3"
_hd_e2=$(open_hd_for 5)
[ "${_hd_e2:-0}" -eq "${_hd_e:-0}" ] \
  && ok "ESCALATE: idempotent — no duplicate human-decision on second run" \
  || ko "ESCALATE: human-decision duplicated (count2=$_hd_e2 vs first=$_hd_e)"

# =============================================================================
# FORMAT-CAP: analyst keeps emitting invalid composition → format-reject path caps
#   → human-decision; reviewer NEVER spawned (never passes the format gate).
# =============================================================================
echo "=== FORMAT-CAP: invalid composition ×cap → human-decision (runaway fix) ==="
CBHOME_F="$ROOT/cbhome_f"; LOG_F="$ROOT/loop_f.log"
reset_sandbox "$CBHOME_F"; write_budget_low "$CBHOME_F"
printf '99' > "$ANALYSIS_GARBAGE_FLAG"   # analyst always posts an unparseable composition
printf '[{"number":5,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:needs-analysis"}],"body":"charter goal","comments":[]}]\n' \
  > "$BOARD_STATE"

run_loop "$CBHOME_F" "$LOG_F" "CB_CONVERGE_CAP=3"

_hd_f=$(open_hd_for 5)
[ "${_hd_f:-0}" -ge 1 ] \
  && ok "FORMAT-CAP: human-decision created when composition never parses" \
  || ko "FORMAT-CAP: human-decision NOT created (format-reject runaway not capped)"

case "$(hd_title_for 5)" in
  *"not converging"*) ok "FORMAT-CAP: human-decision titled 'composition not converging'" ;;
  *) ko "FORMAT-CAP: human-decision title wrong: '$(hd_title_for 5)'" ;;
esac

_rv_f=$(grep -c '^5 reviewer' "$REVIEW_LOG" 2>/dev/null)
[ "$_rv_f" -eq 0 ] \
  && ok "FORMAT-CAP: reviewer NEVER spawned (invalid composition gated before review)" \
  || ko "FORMAT-CAP: reviewer spawned $_rv_f× on invalid composition (gate order wrong)"

grep -q "cto" "$APPROVAL_LOG" \
  && ko "FORMAT-CAP: cto spawned on unparseable composition" \
  || ok "FORMAT-CAP: cto NOT spawned (correct)"

# =============================================================================
# AGREED-SKIP: review:agreed already present → reviewer NOT spawned → straight to cto.
# =============================================================================
echo "=== AGREED-SKIP: review:agreed present → reviewer bypassed → cto ==="
CBHOME_A="$ROOT/cbhome_a"; LOG_A="$ROOT/loop_a.log"
reset_sandbox "$CBHOME_A"; write_budget_low "$CBHOME_A"
printf '0' > "$REVIEW_REJECT_FLAG"
printf '[{"number":5,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:team-review"},{"name":"review:agreed"}],"body":"charter goal","comments":[{"body":"%s"}]}]\n' \
  "$COMP_2L_JSON" > "$BOARD_STATE"

run_loop "$CBHOME_A" "$LOG_A" "CB_CONVERGE_CAP=5"

_rv_a=$(grep -c '^5 reviewer' "$REVIEW_LOG" 2>/dev/null)
[ "$_rv_a" -eq 0 ] \
  && ok "AGREED-SKIP: reviewer NOT spawned (already agreed)" \
  || ko "AGREED-SKIP: reviewer spawned $_rv_a× despite review:agreed (no short-circuit)"

grep -q "cto" "$APPROVAL_LOG" \
  && ok "AGREED-SKIP: cto spawned (proceeded straight to cost gate)" \
  || ko "AGREED-SKIP: cto NOT spawned (agreed charter did not proceed)"

# =============================================================================
# FORMAT-MID-SUBSTANCE (#352): a transient format-glitch BETWEEN substance rounds must NOT
# consume a substance-review round. Separate counters (fround vs cround) → still converges.
# With CONVERGE_CAP=2 and the OLD shared counter, the glitch+1 reject would hit the cap and
# escalate before the 2nd review — so the no-HD assertion below is a real regression lock.
# =============================================================================
echo "=== FORMAT-MID-SUBSTANCE: format-glitch between substance rounds → still converges (no premature escalation) ==="
CBHOME_M="$ROOT/cbhome_m"; LOG_M="$ROOT/loop_m.log"
reset_sandbox "$CBHOME_M"; write_budget_low "$CBHOME_M"
printf '1' > "$ANALYSIS_GARBAGE_FLAG"   # one format-glitch composition, then valid
printf '1' > "$REVIEW_REJECT_FLAG"      # reviewer rejects once, then agrees
printf '[{"number":5,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:needs-analysis"}],"body":"charter goal","comments":[]}]\n' \
  > "$BOARD_STATE"

run_loop "$CBHOME_M" "$LOG_M" "CB_CONVERGE_CAP=2" "CB_FORMAT_CAP=2"

_hd_m=$(open_hd_for 5)
[ "${_hd_m:-0}" -eq 0 ] \
  && ok "FORMAT-MID-SUBSTANCE: NO premature escalation (format-glitch did not consume a substance round)" \
  || ko "FORMAT-MID-SUBSTANCE: human-decision created — format-glitch ate a substance round (shared-counter regression)"

has_label 5 "review:agreed" \
  && ok "FORMAT-MID-SUBSTANCE: converged (review:agreed) despite the mid-convergence format-glitch" \
  || ko "FORMAT-MID-SUBSTANCE: did NOT converge"

_rv_m=$(grep -c '^5 reviewer' "$REVIEW_LOG" 2>/dev/null)
[ "$_rv_m" -eq 2 ] \
  && ok "FORMAT-MID-SUBSTANCE: both substance rounds ran (reviewer spawned 2×, glitch on separate counter)" \
  || ko "FORMAT-MID-SUBSTANCE: reviewer spawned $_rv_m× (expected 2 — substance rounds not preserved)"

[ "$(comment_count 5 'format round')" -ge 1 ] \
  && ok "FORMAT-MID-SUBSTANCE: the format-glitch round actually occurred (format-reject fired)" \
  || ko "FORMAT-MID-SUBSTANCE: no format-reject evidence — test did not exercise the glitch path"

# =============================================================================
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
