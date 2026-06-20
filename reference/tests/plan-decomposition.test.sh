#!/usr/bin/env bash
# plan-decomposition.test.sh — leaf-count gate for charter decomposition (#391/#393).
# When a tech-lead completes planning with 0 leaf sub-issues the charter must NOT
# reach status:approved.  It must be re-routed to status:needs-plan (retry) or
# status:blocked (after RETRY_CAP exhausted).
#
# Class d integration-stub: gh stub + file-board, REAL launcher (crewboss-launcher-gh.sh)
# + board-gh.sh + manifest.sh, hermetic flock shim.  Charters seeded at
# status:needs-plan + composition:approved (post-cto state) to isolate the plan stage.
# The file-board is a JSON array in $BOARD_STATE.
#
# CB_MANIFEST = copy of team-example with policy.require_decomp_leaves=true added
# (the field that ARMS the leaf-count gate; absent → existing single-pass plan flow).
#
# A hermetic `flock` shim is injected into $BIN; single-launcher → exit 0.
#
# STUB-WITH-LEAVES: tech-lead creates 1 type:agent leaf with Charter: #5 in its body
#   then moves the charter to plan-review.
#   Assertions: charter reaches status:approved; leaf exists on board.
#
# STUB-NO-LEAVES: tech-lead only moves charter to plan-review — zero leaves created.
#   Assertions: charter does NOT reach status:approved; eventually status:blocked;
#   gate reason "decomposition incomplete" appears in gh-stub log / board comments.
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
export SANDBOX BOARD_STATE GH_LOG

# CB_MANIFEST: copy of team-example, with require_decomp_leaves added to policy
# (the flag that ARMS the leaf-count gate; absent → existing behaviour unchanged)
CB_MANIFEST_DIR="$ROOT/manifest"
cp -r "$TEAM_EXAMPLE/." "$CB_MANIFEST_DIR"
jq '.policy.require_decomp_leaves=true' "$CB_MANIFEST_DIR/org.json" \
  > "$CB_MANIFEST_DIR/org.json.t" \
  && mv "$CB_MANIFEST_DIR/org.json.t" "$CB_MANIFEST_DIR/org.json"
export CB_MANIFEST_DIR MANIFEST_LIB_SRC

BIN="$ROOT/bin"; mkdir -p "$BIN"

# ── hermetic flock shim (single-launcher, no macOS compat issues) ─────────────
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
leaf_count_for(){ # count OPEN non-charter issues with Charter: #<id> in body and type:agent label
  jq -r --argjson c "$1" '
    [ .[] | select(.state=="OPEN")
          | select(([.labels[].name] | any(. == "type:agent")))
          | select((.body//"") | test("Charter:\\s*#?" + ($c|tostring)))
    ] | length' "$BOARD_STATE" 2>/dev/null || echo 0; }

reset_sandbox(){
  rm -rf "$SANDBOX"; mkdir -p "$SANDBOX"
  : > "$GH_LOG"
  local cbhome="$1"
  rm -rf "$cbhome"; mkdir -p "$cbhome"
  cp "$BOARD_GH_SRC"   "$cbhome/board-gh.sh"
  cp "$LAUNCHABLE_SRC" "$cbhome/launchable.sh"
  chmod +x "$cbhome/board-gh.sh" "$cbhome/launchable.sh"
}

# ── gh stub (file-board) ───────────────────────────────────────────────────────
# gh issue list --state all -L 200 --json number,labels,body returns the current
# file-board JSON — this is what the launcher's _dc_leafn jq query reads.
# Without this, the leaf-count would always fall back to 0, making the test non-deterministic.
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

# ── tech-lead stub WITH leaves ─────────────────────────────────────────────────
# Creates 1 leaf issue (type:agent, body Charter: #CID) then moves charter to plan-review.
PLAN_STUB_LEAVES="$ROOT/plan-stub-leaves.sh"
cat > "$PLAN_STUB_LEAVES" <<'LEOF'
#!/usr/bin/env bash
CID="$1"
gh issue create -R "test/repo" \
  --title "implement feature for charter $CID" \
  --body "Charter: #$CID
Implement the required functionality." \
  --label "type:agent"
gh issue edit "$CID" -R "test/repo" \
  --remove-label status:needs-plan \
  --add-label status:plan-review
exit 0
LEOF
chmod +x "$PLAN_STUB_LEAVES"

# ── tech-lead stub WITHOUT leaves ─────────────────────────────────────────────
# Only moves charter to plan-review — creates ZERO leaf issues.
PLAN_STUB_NO_LEAVES="$ROOT/plan-stub-no-leaves.sh"
cat > "$PLAN_STUB_NO_LEAVES" <<'NLEOF'
#!/usr/bin/env bash
CID="$1"
gh issue edit "$CID" -R "test/repo" \
  --remove-label status:needs-plan \
  --add-label status:plan-review
exit 0
NLEOF
chmod +x "$PLAN_STUB_NO_LEAVES"

# ── loop runner ───────────────────────────────────────────────────────────────
run_loop(){
  local cbhome="$1" logfile="${2:-/dev/null}"; shift 2
  : > "$GH_LOG"
  PATH="$BIN:$PATH" \
    CB_REPO="test/repo" \
    CB_HOME="$cbhome" \
    CB_SPAWN="$PLAN_STUB_LEAVES" \
    CB_PLAN_SPAWN="$PLAN_STUB_LEAVES" \
    CB_MANIFEST="$CB_MANIFEST_DIR" \
    CB_MANIFEST_LIB="$MANIFEST_LIB_SRC" \
    CB_GIT_REMOTE="" \
    CB_POLL=0 \
    CB_MAX_TICKS=20 \
    CB_IDLE_CONFIRM=2 \
    CB_MAX_PARALLEL=4 \
    CB_RETRY_CAP=2 \
    CB_AUTO_PLAN_APPROVE=1 \
    CREWBOSS_CHARTER="" \
    env "$@" \
    bash "$LAUNCHER" run >"$logfile" 2>&1 || true
}

# Post-cto charter: needs-plan + composition:approved (isolates the PLAN stage)
seed_needs_plan(){
  printf '[{"number":5,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:needs-plan"},{"name":"composition:approved"},{"name":"review:agreed"}],"body":"charter goal","comments":[]}]\n' \
    > "$BOARD_STATE"
}

# =============================================================================
# STUB-WITH-LEAVES: tech-lead creates 1 leaf + moves to plan-review →
#   leaf-count gate passes (≥1 leaf) → CB_AUTO_PLAN_APPROVE → status:approved.
# =============================================================================
echo "=== STUB-WITH-LEAVES: leaf created → gate passes → status:approved ==="
CBHOME_L="$ROOT/cbhome_l"; LOG_L="$ROOT/loop_l.log"
reset_sandbox "$CBHOME_L"
seed_needs_plan

run_loop "$CBHOME_L" "$LOG_L"

_st_l=$(issue_state 5)
[ "$_st_l" = "approved" ] \
  && ok "STUB-WITH-LEAVES: charter #5 reached status:approved" \
  || ko "STUB-WITH-LEAVES: charter #5 state=$_st_l (expected approved)"

_lc_l=$(leaf_count_for 5)
[ "${_lc_l:-0}" -ge 1 ] \
  && ok "STUB-WITH-LEAVES: leaf issue exists with type:agent + Charter: #5 (count=${_lc_l})" \
  || ko "STUB-WITH-LEAVES: leaf issue NOT found with type:agent label and Charter: #5 in body"

# =============================================================================
# STUB-NO-LEAVES: tech-lead moves to plan-review with 0 leaves →
#   leaf-count gate fires → retry → RETRY_CAP → status:blocked.
# =============================================================================
echo "=== STUB-NO-LEAVES: 0 leaves → gate fires → retry → RETRY_CAP=2 → status:blocked ==="
CBHOME_N="$ROOT/cbhome_n"; LOG_N="$ROOT/loop_n.log"
reset_sandbox "$CBHOME_N"
seed_needs_plan

run_loop "$CBHOME_N" "$LOG_N" "CB_PLAN_SPAWN=$PLAN_STUB_NO_LEAVES"

_st_n=$(issue_state 5)
[ "$_st_n" != "approved" ] \
  && ok "STUB-NO-LEAVES: charter #5 did NOT reach status:approved (state=$_st_n)" \
  || ko "STUB-NO-LEAVES: charter #5 reached status:approved despite 0 leaves (gate bypassed)"

[ "$_st_n" = "blocked" ] \
  && ok "STUB-NO-LEAVES: charter #5 is status:blocked (gate + RETRY_CAP enforced)" \
  || ko "STUB-NO-LEAVES: charter #5 is not blocked (state=$_st_n; expected blocked after RETRY_CAP)"

# Gate reason appears in stub log (comment posted by the gate)
grep -q "decomposition incomplete" "$GH_LOG" \
  && ok "STUB-NO-LEAVES: gate reason 'decomposition incomplete' found in gh stub log" \
  || ko "STUB-NO-LEAVES: gate reason 'decomposition incomplete' NOT found in gh stub log"

# =============================================================================
echo
printf 'failed=%d\n' "$fail"
[ "$fail" -eq 0 ]
