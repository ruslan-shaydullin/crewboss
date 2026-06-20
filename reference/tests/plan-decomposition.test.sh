#!/usr/bin/env bash
# plan-decomposition.test.sh — leaf-count gate for charter planning (#392).
#
# When a tech-lead completes (charter reaches status:plan-review or status:approved),
# the launcher counts type:agent leaves with "Charter: #N" in body.
# 0 leaves + tries < RETRY_CAP → retry to status:needs-plan (re-plan request).
# 0 leaves + tries >= RETRY_CAP → route to status:blocked.
# ≥1 leaves → falls through to existing term=1 success path ("planned ->").
#
# Class d integration-stub: gh stub file-board, REAL launcher + board-gh.sh.
# CB_MANIFEST is NOT set → analysis/approval cycles disabled; isolates the leaf-count gate.
# Charters are seeded at status:needs-plan + composition:approved (post-cto board state).
#
# ZERO-LEAVES-BLOCKED:      CB_RETRY_CAP=1 → blocked on the first gate failure (no retry).
# ZERO-LEAVES-RETRY:        CB_RETRY_CAP=2 → retried to needs-plan (tries=1 < 2), then blocked (tries=2 ≥ 2).
# HAS-LEAVES:               1 type:agent leaf with "Charter: #5" in body → gate passes → term=1 success.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER="${LAUNCHER_OVERRIDE:-$HERE/../runtime/crewboss-launcher-gh.sh}"
BOARD_GH_SRC="$HERE/../../proto/r6/board-gh.sh"
LAUNCHABLE_SRC="$HERE/../../proto/r6/launchable.sh"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

# ── shared state ──────────────────────────────────────────────────────────────
SANDBOX="$ROOT/sb"
BOARD_STATE="$SANDBOX/board.json"
GH_LOG="$SANDBOX/gh.log"
PLAN_LOG="$ROOT/plan.log"
export SANDBOX BOARD_STATE GH_LOG PLAN_LOG

BIN="$ROOT/bin"; mkdir -p "$BIN"

# ── flock shim (single-launcher; macOS compat) ────────────────────────────────
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/flock"
chmod +x "$BIN/flock"

# ── board helpers ─────────────────────────────────────────────────────────────
has_label(){ [ "$(jq -r --argjson n "$1" 'map(select(.number==$n))[0].labels[]?.name' \
                   "$BOARD_STATE" 2>/dev/null | grep -c "^$2$")" -ge 1 ]; }
no_label(){  ! has_label "$1" "$2"; }
issue_state(){ jq -r --argjson n "$1" 'map(select(.number==$n))[0]|
                if .state=="CLOSED" then "done"
                elif ([.labels[]?.name]|any(.=="status:blocked")) then "blocked"
                elif ([.labels[]?.name]|any(.=="status:plan-review")) then "plan-review"
                elif ([.labels[]?.name]|any(.=="status:needs-plan")) then "needs-plan"
                elif ([.labels[]?.name]|any(.=="status:approved")) then "approved"
                else "open" end' "$BOARD_STATE" 2>/dev/null; }

reset_sandbox(){
  rm -rf "$SANDBOX"; mkdir -p "$SANDBOX"
  : > "$GH_LOG"
  : > "$PLAN_LOG"
  local cbhome="$1"
  rm -rf "$cbhome"; mkdir -p "$cbhome"
  cp "$BOARD_GH_SRC"   "$cbhome/board-gh.sh"
  cp "$LAUNCHABLE_SRC" "$cbhome/launchable.sh"
  chmod +x "$cbhome/board-gh.sh" "$cbhome/launchable.sh"
}

# ── gh stub (file-board) ──────────────────────────────────────────────────────
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

# ── plan stub (tech-lead) ─────────────────────────────────────────────────────
# Moves the charter from status:needs-plan → status:plan-review.
# Does NOT create any leaves — leaf creation is tested separately via pre-seeded board state.
PLAN_STUB="$ROOT/plan-stub.sh"
cat > "$PLAN_STUB" <<'PSEOF'
#!/usr/bin/env bash
CID="$1"
printf '%s\n' "$CID" >> "$PLAN_LOG"
gh issue edit "$CID" -R "test/repo" \
  --remove-label status:needs-plan \
  --add-label status:plan-review
exit 0
PSEOF
chmod +x "$PLAN_STUB"

# ── loop runner ───────────────────────────────────────────────────────────────
run_loop(){
  local cbhome="$1" logfile="${2:-/dev/null}"; shift 2
  : > "$PLAN_LOG"; : > "$GH_LOG"
  PATH="$BIN:$PATH" \
    CB_REPO="test/repo" \
    CB_HOME="$cbhome" \
    CB_SPAWN="$PLAN_STUB" \
    CB_PLAN_SPAWN="$PLAN_STUB" \
    CB_MANIFEST="" \
    CB_MANIFEST_LIB="" \
    CB_POLL=0 \
    CB_MAX_TICKS=60 \
    CB_IDLE_CONFIRM=2 \
    CB_MAX_PARALLEL=4 \
    CB_RETRY_CAP=2 \
    CB_AUTO_PLAN_APPROVE=0 \
    CREWBOSS_CHARTER= \
    env "$@" \
    bash "$LAUNCHER" run >"$logfile" 2>&1 || true
}

# Charter at needs-plan + composition:approved (post-cto state); NO leaves in board.
seed_no_leaves(){
  printf '[{"number":5,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:needs-plan"},{"name":"composition:approved"},{"name":"review:agreed"}],"body":"charter body","comments":[]}]\n' \
    > "$BOARD_STATE"
}

# Charter + 1 pre-seeded type:agent leaf with "Charter: #5" in body.
seed_has_leaf(){
  printf '[{"number":5,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:needs-plan"},{"name":"composition:approved"},{"name":"review:agreed"}],"body":"charter body","comments":[]},{"number":10,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"Charter: #5","comments":[]}]\n' \
    > "$BOARD_STATE"
}

# =============================================================================
# ZERO-LEAVES-BLOCKED: CB_RETRY_CAP=1 → blocked on first gate failure (no retry)
# =============================================================================
echo "=== ZERO-LEAVES-BLOCKED: 0 leaves + RETRY_CAP=1 → status:blocked immediately ==="
CBHOME_B="$ROOT/cbhome_b"; LOG_B="$ROOT/loop_b.log"
reset_sandbox "$CBHOME_B"
seed_no_leaves

run_loop "$CBHOME_B" "$LOG_B" "CB_RETRY_CAP=1"

has_label 5 "status:blocked" \
  && ok "ZERO-LEAVES-BLOCKED: charter #5 blocked after 0 leaves at RETRY_CAP=1" \
  || ko "ZERO-LEAVES-BLOCKED: charter #5 NOT blocked (leaf-count gate did not fire or RETRY_CAP not respected)"

grep -q "0 leaves" "$LOG_B" \
  && ok "ZERO-LEAVES-BLOCKED: '0 leaves' appears in launcher log (gate fired)" \
  || ko "ZERO-LEAVES-BLOCKED: '0 leaves' NOT in launcher log (gate may not have fired)"

grep -q "blocked" "$LOG_B" \
  && ok "ZERO-LEAVES-BLOCKED: 'blocked' appears in launcher log" \
  || ko "ZERO-LEAVES-BLOCKED: 'blocked' NOT in launcher log"

grep -q "needs-plan retry" "$LOG_B" \
  && ko "ZERO-LEAVES-BLOCKED: 'needs-plan retry' in log despite RETRY_CAP=1 (should block immediately)" \
  || ok "ZERO-LEAVES-BLOCKED: no 'needs-plan retry' in log (correct — blocked immediately at cap=1)"

# =============================================================================
# ZERO-LEAVES-RETRY: CB_RETRY_CAP=2 → one retry to needs-plan (tries=1 < 2),
#   then blocked on second gate failure (tries=2 ≥ 2).
# =============================================================================
echo "=== ZERO-LEAVES-RETRY: 0 leaves + RETRY_CAP=2 → needs-plan retry, then blocked ==="
CBHOME_R="$ROOT/cbhome_r"; LOG_R="$ROOT/loop_r.log"
reset_sandbox "$CBHOME_R"
seed_no_leaves

run_loop "$CBHOME_R" "$LOG_R" "CB_RETRY_CAP=2"

grep -q "needs-plan retry" "$LOG_R" \
  && ok "ZERO-LEAVES-RETRY: 'needs-plan retry' in log (gate retried on first failure)" \
  || ko "ZERO-LEAVES-RETRY: 'needs-plan retry' NOT in log (retry path not taken)"

grep -q "status:needs-plan" "$GH_LOG" \
  && ok "ZERO-LEAVES-RETRY: status:needs-plan label applied via gh on retry" \
  || ko "ZERO-LEAVES-RETRY: status:needs-plan NOT added via gh (re-route missing)"

has_label 5 "status:blocked" \
  && ok "ZERO-LEAVES-RETRY: charter #5 eventually blocked (tries=2 ≥ RETRY_CAP=2)" \
  || ko "ZERO-LEAVES-RETRY: charter #5 NOT blocked (tries did not accumulate to cap)"

_tl_r=$(grep -c '^5$' "$PLAN_LOG" 2>/dev/null || echo 0)
[ "${_tl_r:-0}" -ge 2 ] \
  && ok "ZERO-LEAVES-RETRY: tech-lead spawned ≥2 times (initial + retry, got $_tl_r)" \
  || ko "ZERO-LEAVES-RETRY: tech-lead spawn count=$_tl_r (expected ≥2 for retry evidence)"

# =============================================================================
# HAS-LEAVES: 1 type:agent leaf with "Charter: #5" in body → gate passes → success
# =============================================================================
echo "=== HAS-LEAVES: 1 type:agent leaf → leaf-count gate passes → term=1 success ==="
CBHOME_H="$ROOT/cbhome_h"; LOG_H="$ROOT/loop_h.log"
reset_sandbox "$CBHOME_H"
seed_has_leaf

run_loop "$CBHOME_H" "$LOG_H" "CB_RETRY_CAP=2"

no_label 5 "status:blocked" \
  && ok "HAS-LEAVES: charter #5 NOT blocked (leaf found, gate passed)" \
  || ko "HAS-LEAVES: charter #5 blocked despite having a leaf (gate false-negative — Fix 1: .body//\"\" required)"

grep -q "needs-plan retry" "$LOG_H" \
  && ko "HAS-LEAVES: 'needs-plan retry' in log despite leaf present (gate misfired)" \
  || ok "HAS-LEAVES: no 'needs-plan retry' in log (leaf correctly counted, no retry)"

grep -q "planned ->" "$LOG_H" \
  && ok "HAS-LEAVES: 'planned ->' in log (gate fell through to existing success path)" \
  || ko "HAS-LEAVES: 'planned ->' NOT in log (success path not reached with leaf present)"

# =============================================================================
# Acceptance check: _leaf_count appears in launcher (gate is present)
# =============================================================================
echo "=== acceptance: _leaf_count present in launcher ==="
cnt=$(grep -c '_leaf_count' "$LAUNCHER" 2>/dev/null || echo 0)
[ "${cnt:-0}" -ge 2 ] \
  && ok "acceptance: grep -c '_leaf_count' launcher = $cnt (>= 2, gate is present)" \
  || ko "acceptance: grep -c '_leaf_count' launcher = $cnt (< 2, gate NOT present)"

# =============================================================================
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
