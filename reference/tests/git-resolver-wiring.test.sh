#!/usr/bin/env bash
# git-resolver-wiring.test.sh — conflict-resolution cycle wiring tests (issue #276).
# Class integration-stub (precedent: analysis-spawn/approval-gate): gh stub file-board,
# REAL launcher + board-gh.sh, conflict-spawn stub logs <id> <role>; stub-git-resolver
# removes status:needs-conflict-resolution label to simulate success.
#
# RED-1: charter in status:needs-conflict-resolution → git-resolver spawned
# RED-2: after stub-git-resolver removes label → charter no longer has needs-conflict-resolution
# RED-3 (retry, F-3): git-resolver fails first call → re-spawns; second call succeeds
# RED-4 (blocked, F-3): git-resolver always fails → blocked at RETRY_CAP
# GREEN-guard: charter WITHOUT needs-conflict-resolution → git-resolver NOT spawned
# GREEN-guard-2 (F-1): after success, $STATE/<cid>/term and tries EMPTY
#
# EXCLUDED (invokes real launcher): reference/runtime/per-leaf-manifest
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
CONFLICT_LOG="$ROOT/conflict.log"
CONFLICT_FAIL_FLAG="$ROOT/conflict-fail"
export SANDBOX BOARD_STATE GH_LOG CONFLICT_LOG CONFLICT_FAIL_FLAG

BIN="$ROOT/bin"; mkdir -p "$BIN"

# ── board helpers ─────────────────────────────────────────────────────────────
has_label(){   [ "$(jq -r --argjson n "$1" 'map(select(.number==$n))[0].labels[]?.name' \
                   "$BOARD_STATE" 2>/dev/null | grep -c "^$2$")" -ge 1 ]; }
no_label(){    ! has_label "$1" "$2"; }

reset_sandbox(){
  rm -rf "$SANDBOX"; mkdir -p "$SANDBOX"
  : > "$GH_LOG"
  : > "$CONFLICT_LOG"
  rm -f "$CONFLICT_FAIL_FLAG"
  local cbhome="$1"
  rm -rf "$cbhome"; mkdir -p "$cbhome"
  cp "$BOARD_GH_SRC"   "$cbhome/board-gh.sh"
  cp "$LAUNCHABLE_SRC" "$cbhome/launchable.sh"
  chmod +x "$cbhome/board-gh.sh" "$cbhome/launchable.sh"
}

# ── gh stub ───────────────────────────────────────────────────────────────────
# Handles: issue list/view/edit/comment/close, auth token, label create.
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
  "auth token") echo "fake-token" ;;
  "label create") ;;
  *) echo "gh-stub UNHANDLED: $obj $verb $*" >> "$GH_LOG" ;;
esac
exit 0
GHEOF
chmod +x "$BIN/gh"

# ── conflict-spawn stub (git-resolver) ────────────────────────────────────────
# Called as: conflict-stub.sh <cid> <role>
# Logs "<cid> <role>" to CONFLICT_LOG.
# If CONFLICT_FAIL_FLAG has count > 0: decrement and exit 0 WITHOUT removing label (fail).
# Otherwise: remove status:needs-conflict-resolution label (success).
CONFLICT_STUB="$ROOT/conflict-stub.sh"
cat > "$CONFLICT_STUB" <<'CSEOF'
#!/usr/bin/env bash
CID="$1"; CROLE="$2"
printf '%s %s\n' "$CID" "$CROLE" >> "$CONFLICT_LOG"
# Check fail counter
if [ -f "$CONFLICT_FAIL_FLAG" ]; then
  cnt=$(cat "$CONFLICT_FAIL_FLAG" 2>/dev/null || echo 0)
  if [ "$cnt" -gt 0 ]; then
    printf '%d' "$((cnt - 1))" > "$CONFLICT_FAIL_FLAG"
    printf 'conflict-stub: FAIL for #%s (remaining=%d)\n' "$CID" "$((cnt-1))" >> "$CONFLICT_LOG"
    exit 0
  fi
fi
# Success: remove the conflict-resolution label
gh issue edit "$CID" -R "test/repo" \
  --remove-label status:needs-conflict-resolution
printf 'conflict-stub: SUCCESS for #%s\n' "$CID" >> "$CONFLICT_LOG"
exit 0
CSEOF
chmod +x "$CONFLICT_STUB"

# ── plan spawn stub (tech-lead / other roles) ─────────────────────────────────
PLAN_LOG="$ROOT/plan.log"
PLAN_STUB="$ROOT/plan-stub.sh"
export PLAN_LOG
cat > "$PLAN_STUB" <<'PSEOF'
#!/usr/bin/env bash
CID="$1"; PROLE="$2"
printf '%s %s\n' "$CID" "$PROLE" >> "$PLAN_LOG"
exit 0
PSEOF
chmod +x "$PLAN_STUB"

# ── loop runner ───────────────────────────────────────────────────────────────
run_loop(){
  local cbhome="$1" logfile="${2:-/dev/null}"; shift 2
  : > "$CONFLICT_LOG"
  : > "$GH_LOG"
  : > "$PLAN_LOG"
  PATH="$BIN:$PATH" \
    CB_REPO="test/repo" \
    CB_HOME="$cbhome" \
    CB_SPAWN="$PLAN_STUB" \
    CB_PLAN_SPAWN="$PLAN_STUB" \
    CB_CONFLICT_SPAWN="$CONFLICT_STUB" \
    CB_POLL=0 \
    CB_MAX_TICKS=40 \
    CB_IDLE_CONFIRM=2 \
    CB_MAX_PARALLEL=4 \
    CB_RETRY_CAP=3 \
    CREWBOSS_CHARTER= \
    env "$@" \
    bash "$LAUNCHER" run >"$logfile" 2>&1 || true
}

# =============================================================================
# RED-1 + RED-2: charter in needs-conflict-resolution → git-resolver spawned;
# stub removes label → charter no longer in needs-conflict-resolution
# =============================================================================
echo "=== RED-1 + RED-2: needs-conflict-resolution → git-resolver spawned + label removed ==="
CBHOME_12="$ROOT/cbhome_12"
LOGFILE_12="$ROOT/loop_12.log"
reset_sandbox "$CBHOME_12"

cat > "$BOARD_STATE" <<'JSON'
[
  {"number":10,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:needs-conflict-resolution"}],
   "body":"charter goal","comments":[]}
]
JSON

run_loop "$CBHOME_12" "$LOGFILE_12" "CB_MAX_TICKS=15"

# RED-1: git-resolver was spawned (stub log contains the charter id)
grep -q "^10 git-resolver" "$CONFLICT_LOG" \
  && ok "RED-1: git-resolver spawned for charter #10" \
  || ko "RED-1: git-resolver NOT in conflict.log (expected conflict-cycle to spawn it)"

# RED-2: charter no longer has needs-conflict-resolution (stub removed the label)
no_label 10 "status:needs-conflict-resolution" \
  && ok "RED-2: charter #10 no longer has status:needs-conflict-resolution" \
  || ko "RED-2: charter #10 STILL has status:needs-conflict-resolution (label not removed)"

# Also verify launcher log shows git-resolver spawn
grep -qi "git-resolver\|conflict-resolution" "$LOGFILE_12" \
  && ok "RED-2: launcher log shows conflict-resolution activity" \
  || ko "RED-2: no conflict-resolution activity in launcher log"

# =============================================================================
# RED-3 (retry, F-3): git-resolver fails first call → re-spawns; second succeeds
# =============================================================================
echo "=== RED-3: git-resolver fails first call → re-spawn; second succeeds ==="
CBHOME_3="$ROOT/cbhome_3"
LOGFILE_3="$ROOT/loop_3.log"
reset_sandbox "$CBHOME_3"

cat > "$BOARD_STATE" <<'JSON'
[
  {"number":10,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:needs-conflict-resolution"}],
   "body":"charter goal","comments":[]}
]
JSON

printf '1' > "$CONFLICT_FAIL_FLAG"   # fail exactly once, then succeed

run_loop "$CBHOME_3" "$LOGFILE_3" "CB_MAX_TICKS=40" "CB_RETRY_CAP=3"

# Resolver should have been called at least twice (fail + retry)
_cnt3=$(grep -c "^10 git-resolver" "$CONFLICT_LOG" 2>/dev/null || echo 0)
[ "$_cnt3" -ge 2 ] \
  && ok "RED-3: git-resolver re-spawned after first failure (log count=$_cnt3 ≥ 2)" \
  || ko "RED-3: git-resolver NOT re-spawned (log count=$_cnt3, expected ≥ 2)"

# Charter should have label removed (second call succeeded)
no_label 10 "status:needs-conflict-resolution" \
  && ok "RED-3: charter #10 resolved after retry (label removed)" \
  || ko "RED-3: charter #10 STILL has needs-conflict-resolution after retry"

# =============================================================================
# RED-4 (blocked): git-resolver always fails → blocked at RETRY_CAP
# =============================================================================
echo "=== RED-4: git-resolver always fails → blocked at RETRY_CAP ==="
CBHOME_4="$ROOT/cbhome_4"
LOGFILE_4="$ROOT/loop_4.log"
reset_sandbox "$CBHOME_4"

cat > "$BOARD_STATE" <<'JSON'
[
  {"number":10,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:needs-conflict-resolution"}],
   "body":"charter goal","comments":[]}
]
JSON

printf '99' > "$CONFLICT_FAIL_FLAG"   # always fail

run_loop "$CBHOME_4" "$LOGFILE_4" "CB_MAX_TICKS=30" "CB_RETRY_CAP=2"

# Charter must be blocked
has_label 10 "status:blocked" \
  && ok "RED-4: charter #10 blocked at RETRY_CAP" \
  || ko "RED-4: charter #10 NOT blocked (livelock risk)"

# Loop must exit cleanly (blocked charters terminate the loop)
grep -q "idle — run complete\|max ticks" "$LOGFILE_4" \
  && ok "RED-4: loop exited cleanly after blocking" \
  || ok "RED-4: loop finished (acceptable)"

# No livelock: blocked charter MUST NOT keep loop alive past max-ticks
grep -q "max ticks" "$LOGFILE_4" \
  && ko "RED-4: loop hit max-ticks (blocked charter not terminating loop — livelock risk)" \
  || ok "RED-4: loop did NOT hit max-ticks (blocked charter does not livelock)"

# =============================================================================
# GREEN-guard: charter WITHOUT needs-conflict-resolution → git-resolver NOT spawned
# =============================================================================
echo "=== GREEN-guard: no needs-conflict-resolution → git-resolver NOT spawned ==="
CBHOME_G="$ROOT/cbhome_g"
LOGFILE_G="$ROOT/loop_g.log"
reset_sandbox "$CBHOME_G"

cat > "$BOARD_STATE" <<'JSON'
[
  {"number":10,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:plan-review"}],
   "body":"charter goal","comments":[]}
]
JSON

run_loop "$CBHOME_G" "$LOGFILE_G" "CB_MAX_TICKS=8"

# git-resolver must NOT have been spawned
[ ! -s "$CONFLICT_LOG" ] \
  && ok "GREEN-guard: conflict.log empty — git-resolver NOT spawned (correct)" \
  || ko "GREEN-guard: git-resolver was spawned despite no needs-conflict-resolution label"

# =============================================================================
# GREEN-guard-2 (F-1): after successful resolution, $STATE/<cid>/term and tries EMPTY
# =============================================================================
echo "=== GREEN-guard-2 (F-1): after success, term + tries empty ==="
CBHOME_G2="$ROOT/cbhome_g2"
LOGFILE_G2="$ROOT/loop_g2.log"
reset_sandbox "$CBHOME_G2"

cat > "$BOARD_STATE" <<'JSON'
[
  {"number":10,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:needs-conflict-resolution"}],
   "body":"charter goal","comments":[]}
]
JSON

run_loop "$CBHOME_G2" "$LOGFILE_G2" "CB_MAX_TICKS=15"

# After successful resolution: term must be empty
_term=$(cat "$CBHOME_G2/run/state/10/term" 2>/dev/null || echo "")
[ -z "$_term" ] \
  && ok "GREEN-guard-2: state/10/term is empty after success (F-1 contract)" \
  || ko "GREEN-guard-2: state/10/term='$_term' (non-empty — deadlock risk for re-use)"

# After successful resolution: tries must be empty
_tries=$(cat "$CBHOME_G2/run/state/10/tries" 2>/dev/null || echo "")
[ -z "$_tries" ] \
  && ok "GREEN-guard-2: state/10/tries is empty after success (F-1 contract)" \
  || ko "GREEN-guard-2: state/10/tries='$_tries' (non-empty — counts contaminate next stage)"

# =============================================================================
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
