#!/usr/bin/env bash
# plan-decomposition.test.sh — deterministic plan-decomposition gate test (#391).
# Tests the require_decomp_leaves guard in the kind=charter handler of the launcher.
# When armed (require_decomp_leaves=1 in manifest policy), a charter reaching plan-review
# with zero leaf issues MUST NOT advance to status:approved — it must be re-routed to
# status:needs-plan up to RETRY_CAP, then blocked with reason "decomposition incomplete".
#
# Class d integration-stub: gh stub file-board, REAL launcher + board-gh.sh + manifest.sh,
# hermetic flock shim. Mirrors plan-convergence.test.sh structure.
#
# CB_MANIFEST = copy of team-example with policy.require_decomp_leaves="1" added
# (the field that ARMS the leaf-count gate; absent → gate is off by default).
#
# A hermetic `flock` shim is injected into $BIN (macOS has no flock); single-launcher → exit 0.
#
# Charters are seeded at needs-plan + composition:approved (post-cto state) to isolate the
# decomposition stage — analysis/composition-convergence/cto are upstream and already covered.
#
#   STUB-WITH-LEAVES: tech-lead creates one type:agent leaf + moves charter to plan-review →
#                     charter #5 reaches status:approved (gate passes, CB_AUTO_PLAN_APPROVE fires).
#   STUB-NO-LEAVES:   tech-lead moves charter to plan-review with ZERO leaf issues →
#                     require_decomp_leaves gate routes back to status:needs-plan for up to
#                     RETRY_CAP retries, then blocks with reason "decomposition incomplete".
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
PLAN_LOG="$ROOT/plan.log"   # tech-lead spawn log
export SANDBOX BOARD_STATE GH_LOG PLAN_LOG

# CB_MANIFEST: copy of team-example, with require_decomp_leaves added to policy (arms the gate)
CB_MANIFEST_DIR="$ROOT/manifest"
cp -r "$TEAM_EXAMPLE/." "$CB_MANIFEST_DIR"
jq '.policy.require_decomp_leaves="1"' "$CB_MANIFEST_DIR/org.json" > "$CB_MANIFEST_DIR/org.json.t" \
  && mv "$CB_MANIFEST_DIR/org.json.t" "$CB_MANIFEST_DIR/org.json"
export CB_MANIFEST_DIR MANIFEST_LIB_SRC

BIN="$ROOT/bin"; mkdir -p "$BIN"

# ── flock shim (hermetic, single-launcher) ────────────────────────────────────
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/flock"
chmod +x "$BIN/flock"

# ── board helpers ─────────────────────────────────────────────────────────────
has_label(){ [ "$(jq -r --argjson n "$1" 'map(select(.number==$n))[0].labels[]?.name' \
                   "$BOARD_STATE" 2>/dev/null | grep -c "^$2$")" -ge 1 ]; }
issue_state(){ jq -r --argjson n "$1" 'map(select(.number==$n))[0]|
                if .state=="CLOSED" then "done"
                elif ([.labels[]?.name]|any(.=="status:approved")) then "approved"
                elif ([.labels[]?.name]|any(.=="status:plan-review")) then "plan-review"
                elif ([.labels[]?.name]|any(.=="status:needs-plan")) then "needs-plan"
                elif ([.labels[]?.name]|any(.=="status:blocked")) then "blocked"
                else "open" end' "$BOARD_STATE" 2>/dev/null; }
# Count open type:agent leaves belonging to a given charter (by Charter: #N body line)
agent_leaves_for(){ jq -r --argjson c "$1" '
  [ .[] | select(.state=="OPEN")
         | select([.labels[]?.name] | index("type:agent") != null)
         | select((.body//"") | test("Charter:\\s*#?" + ($c|tostring)))
  ] | length' "$BOARD_STATE" 2>/dev/null || echo "0"; }
# Return true (exit 0) if any comment on issue $1 contains string $2
has_comment_matching(){ jq -r --argjson n "$1" \
  '[.[]|select(.number==$n)][0].comments[]?.body' \
  "$BOARD_STATE" 2>/dev/null | grep -qF "$2"; }

reset_sandbox(){
  rm -rf "$SANDBOX"; mkdir -p "$SANDBOX"
  : > "$GH_LOG"
  local cbhome="$1"
  rm -rf "$cbhome"; mkdir -p "$cbhome"
  cp "$BOARD_GH_SRC"   "$cbhome/board-gh.sh"
  cp "$LAUNCHABLE_SRC" "$cbhome/launchable.sh"
  chmod +x "$cbhome/board-gh.sh" "$cbhome/launchable.sh"
}

# ── gh stub (file-board; identical contract to plan-convergence.test.sh) ──────
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

# ── tech-lead stub: WITH-LEAVES ───────────────────────────────────────────────
# Creates one type:agent leaf (Charter: #<cid>) then moves charter to plan-review.
# The require_decomp_leaves gate sees ≥1 leaf → passes → charter advances to approved.
WITH_LEAVES_STUB="$ROOT/tl-with-leaves.sh"
cat > "$WITH_LEAVES_STUB" <<'WLEOF'
#!/usr/bin/env bash
CID="$1"
printf '%s\n' "$CID" >> "$PLAN_LOG"
gh issue create -R "test/repo" \
  --title "L-1: implement core feature" \
  --body "Charter: #$CID

Implement the core feature as described in charter #$CID." \
  --label "type:agent"
gh issue edit "$CID" -R "test/repo" \
  --remove-label status:needs-plan \
  --add-label status:plan-review
exit 0
WLEOF
chmod +x "$WITH_LEAVES_STUB"

# ── tech-lead stub: NO-LEAVES ─────────────────────────────────────────────────
# Sets charter to plan-review ONLY — creates zero leaf issues.
# The require_decomp_leaves gate (L-1 code) detects zero leaves and re-routes the
# charter back to status:needs-plan for retry up to RETRY_CAP, then blocks with
# reason "decomposition incomplete".
NO_LEAVES_STUB="$ROOT/tl-no-leaves.sh"
cat > "$NO_LEAVES_STUB" <<'NLEOF'
#!/usr/bin/env bash
CID="$1"
printf '%s\n' "$CID" >> "$PLAN_LOG"
gh issue edit "$CID" -R "test/repo" \
  --remove-label status:needs-plan \
  --add-label status:plan-review
exit 0
NLEOF
chmod +x "$NO_LEAVES_STUB"

# ── loop runner ───────────────────────────────────────────────────────────────
run_loop(){
  local cbhome="$1" logfile="${2:-/dev/null}" plan_stub="$3"; shift 3
  : > "$PLAN_LOG"; : > "$GH_LOG"
  PATH="$BIN:$PATH" \
    CB_REPO="test/repo" \
    CB_HOME="$cbhome" \
    CB_SPAWN="$plan_stub" \
    CB_PLAN_SPAWN="$plan_stub" \
    CB_MANIFEST="$CB_MANIFEST_DIR" \
    CB_MANIFEST_LIB="$MANIFEST_LIB_SRC" \
    CB_POLL=0 \
    CB_MAX_TICKS=80 \
    CB_IDLE_CONFIRM=2 \
    CB_MAX_PARALLEL=4 \
    CB_RETRY_CAP=3 \
    CB_AUTO_PLAN_APPROVE=1 \
    CREWBOSS_CHARTER= \
    env "$@" \
    bash "$LAUNCHER" run >"$logfile" 2>&1 || true
}

# Post-cto charter: needs-plan + composition:approved (isolates the decomposition stage)
seed_needs_plan(){ printf '[{"number":5,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:needs-plan"},{"name":"composition:approved"},{"name":"review:agreed"}],"body":"charter goal","comments":[]}]\n' > "$BOARD_STATE"; }

# =============================================================================
# STUB-WITH-LEAVES: tech-lead creates one type:agent leaf + moves to plan-review →
#   require_decomp_leaves gate sees leaf count ≥1 → passes →
#   CB_AUTO_PLAN_APPROVE promotes charter to status:approved.
# =============================================================================
echo "=== STUB-WITH-LEAVES: tech-lead creates leaf → charter must reach status:approved ==="
CBHOME_W="$ROOT/cbhome_w"; LOG_W="$ROOT/loop_w.log"
reset_sandbox "$CBHOME_W"
seed_needs_plan

run_loop "$CBHOME_W" "$LOG_W" "$WITH_LEAVES_STUB"

_st_w=$(issue_state 5)
[ "$_st_w" = "approved" ] \
  && ok "STUB-WITH-LEAVES: charter #5 reached status:approved (decomp gate passed)" \
  || ko "STUB-WITH-LEAVES: charter #5 state=$_st_w (expected approved)"

_leaves_w=$(agent_leaves_for 5)
[ "${_leaves_w:-0}" -ge 1 ] \
  && ok "STUB-WITH-LEAVES: at least one type:agent leaf exists for charter #5 (found $_leaves_w)" \
  || ko "STUB-WITH-LEAVES: no type:agent leaves found for charter #5 (count=${_leaves_w:-0})"

# =============================================================================
# STUB-NO-LEAVES: tech-lead sets plan-review with ZERO leaves →
#   require_decomp_leaves gate routes charter to needs-plan → retries →
#   after RETRY_CAP exhausted: charter blocked with "decomposition incomplete".
#   charter MUST NOT reach status:approved.
# =============================================================================
echo "=== STUB-NO-LEAVES: tech-lead creates NO leaves → charter must NOT reach status:approved ==="
CBHOME_N="$ROOT/cbhome_n"; LOG_N="$ROOT/loop_n.log"
reset_sandbox "$CBHOME_N"
seed_needs_plan

run_loop "$CBHOME_N" "$LOG_N" "$NO_LEAVES_STUB"

_st_n=$(issue_state 5)
[ "$_st_n" != "approved" ] \
  && ok "STUB-NO-LEAVES: charter #5 did NOT reach status:approved (state=$_st_n)" \
  || ko "STUB-NO-LEAVES: charter #5 incorrectly reached status:approved (decomp gate missing or bypassed)"

[ "$_st_n" = "blocked" ] \
  && ok "STUB-NO-LEAVES: charter #5 reached status:blocked (leaf-count gate exhausted RETRY_CAP)" \
  || ko "STUB-NO-LEAVES: charter #5 state=$_st_n (expected blocked after RETRY_CAP — requires L-1 gate code)"

if [ "$_st_n" = "blocked" ]; then
  has_comment_matching 5 "decomposition incomplete" \
    && ok "STUB-NO-LEAVES: blocked comment contains 'decomposition incomplete'" \
    || ko "STUB-NO-LEAVES: blocked comment missing 'decomposition incomplete'"
fi

# =============================================================================
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
