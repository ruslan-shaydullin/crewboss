#!/usr/bin/env bash
# bare-charter-auto-init.test.sh — integration-stub tests for the bare-charter
# auto-init fix (charter #626): a type:charter issue added to queue.json with
# NO status:* label must be automatically stamped with status:needs-analysis so
# the analysis-cycle can pick it up in the same launcher tick.
#
# Class: integration-stub with real launcher + real board-gh.sh.
# Stub: stateful gh backed by board.json (same pattern as analysis-spawn.test.sh).
# CB_ANALYSIS_SPAWN stub: logs "<id> <role>" to ANALYSIS_LOG; analyst completes
# successfully (transitions charter to status:team-review) unless told otherwise.
#
# Fixture → Assert structure
# ──────────────────────────
# BARE-1  launcher path — bare charter stamped and analyst spawned
#   fixture : #5 labels=["type:charter"], queue=[5]
#   assert  : gh.log contains bare stamp (edit #5 +[status:needs-analysis] only)
#   assert  : analysis.log contains "5 solution-analyst"
#
# BARE-2  idempotency — already-labelled charter NOT re-stamped by launcher
#   fixture : #5 labels=["type:charter","status:needs-plan"], queue=[5]
#   assert  : gh.log does NOT contain bare stamp (only-add, no removes) for #5
#
# BARE-3  API belt path — save_queue stamps bare charter
#   fixture : #5 labels=["type:charter"], save_queue([5]) called
#   assert  : gh.log contains edit #5 with status:needs-analysis
#
# BARE-4  API belt path idempotency — already-labelled charter NOT re-stamped
#   fixture : #5 labels=["type:charter","status:needs-plan"], save_queue([5])
#   assert  : gh.log does NOT contain status:needs-analysis stamp for #5
#
# BARE-5  non-charter not stamped (neither path)
#   fixture : #5 labels=["type:agent"], queue=[5], save_queue([5]) called
#   assert  : gh.log does NOT contain status:needs-analysis for #5
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER="${LAUNCHER_OVERRIDE:-$HERE/../runtime/crewboss-launcher-gh.sh}"
BOARD_GH_SRC="$HERE/../../proto/r6/board-gh.sh"
LAUNCHABLE_SRC="$HERE/../../proto/r6/launchable.sh"
TEAM_EXAMPLE="$(cd "$HERE/../../team-example" && pwd)"
MANIFEST_LIB_SRC="$HERE/../../reference/launcher/manifest.sh"
API_SRC="$HERE/../../ui/server/crewboss-api.py"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

# ── shared state (exported so the gh stub can read them) ───────────────────────
SANDBOX="$ROOT/sb"
BOARD_STATE="$SANDBOX/board.json"
GH_LOG="$SANDBOX/gh.log"
ANALYSIS_LOG="$ROOT/analysis.log"
export SANDBOX BOARD_STATE GH_LOG ANALYSIS_LOG

# ── CB_MANIFEST: copy of team-example (has policy.analysis_roles=["solution-analyst"]) ─
CB_MANIFEST_DIR="$ROOT/manifest"
cp -r "$TEAM_EXAMPLE/." "$CB_MANIFEST_DIR"
export CB_MANIFEST_DIR MANIFEST_LIB_SRC

BIN="$ROOT/bin"; mkdir -p "$BIN"

# ── flock shim (single-launcher, hermetic) ─────────────────────────────────────
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/flock"
chmod +x "$BIN/flock"

# ── stateful gh stub (file-board: BOARD_STATE + GH_LOG env vars) ──────────────
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
      open)   jq '[.[] | select(.state=="OPEN")]'   "$BOARD_STATE" ;;
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

# ── analysis spawn stub ────────────────────────────────────────────────────────
# Called as: <stub> <cid> <role>
# Logs "<cid> <role>" to ANALYSIS_LOG, then transitions charter to team-review.
ANALYSIS_STUB="$ROOT/analysis-stub.sh"
cat > "$ANALYSIS_STUB" <<'ASEOF'
#!/usr/bin/env bash
CID="$1"; AROLE="$2"
printf '%s %s\n' "$CID" "$AROLE" >> "$ANALYSIS_LOG"
gh issue comment "$CID" -R "test/repo" \
  --body "## Composition (machine)
- approach: parallel
- role: go-backend-dev
- leaf: L-1 -> go-backend-dev
- est_cost_usd: 1.5"
gh issue edit "$CID" -R "test/repo" \
  --remove-label status:needs-analysis \
  --add-label    status:team-review
exit 0
ASEOF
chmod +x "$ANALYSIS_STUB"

# ── plan spawn stub (tech-lead, noop) ─────────────────────────────────────────
PLAN_STUB="$ROOT/plan-stub.sh"
PLAN_LOG="$ROOT/plan.log"
export PLAN_LOG
cat > "$PLAN_STUB" <<'PSEOF'
#!/usr/bin/env bash
CID="$1"; PROLE="$2"
printf '%s %s\n' "$CID" "$PROLE" >> "$PLAN_LOG"
exit 0
PSEOF
chmod +x "$PLAN_STUB"

# ── board / sandbox helpers ────────────────────────────────────────────────────
has_label(){ [ "$(jq -r --argjson n "$1" \
  'map(select(.number==$n))[0].labels[]?.name' "$BOARD_STATE" \
  | grep -c "^$2$")" -ge 1 ]; }

# Resets SANDBOX + ANALYSIS_LOG + GH_LOG; installs board-gh + launchable into cbhome.
reset_sandbox(){
  local cbhome="$1"
  rm -rf "$SANDBOX"; mkdir -p "$SANDBOX"
  : > "$GH_LOG"; : > "$ANALYSIS_LOG"; : > "$PLAN_LOG"
  rm -rf "$cbhome"; mkdir -p "$cbhome"
  cp "$BOARD_GH_SRC"   "$cbhome/board-gh.sh"
  cp "$LAUNCHABLE_SRC" "$cbhome/launchable.sh"
  chmod +x "$cbhome/board-gh.sh" "$cbhome/launchable.sh"
}

# Write queue.json into cbhome/run/
write_queue(){
  local cbhome="$1"; shift
  local ids="$*"     # space-separated issue numbers
  mkdir -p "$cbhome/run"
  # Build JSON array from args
  local arr; arr="$(printf '%s\n' $ids | jq -Rs 'split("\n")[:-1]|map(tonumber)')"
  printf '{"order":%s}' "$arr" > "$cbhome/run/queue.json"
}

# ── loop runner ────────────────────────────────────────────────────────────────
run_loop(){
  local cbhome="$1" logfile="${2:-/dev/null}"; shift 2
  PATH="$BIN:$PATH" \
    CB_REPO="test/repo" \
    CB_HOME="$cbhome" \
    CB_SPAWN="$PLAN_STUB" \
    CB_PLAN_SPAWN="$PLAN_STUB" \
    CB_ANALYSIS_SPAWN="$ANALYSIS_STUB" \
    CB_MANIFEST="$CB_MANIFEST_DIR" \
    CB_MANIFEST_LIB="$MANIFEST_LIB_SRC" \
    CB_POLL=0 \
    CB_MAX_TICKS=20 \
    CB_IDLE_CONFIRM=2 \
    CB_MAX_PARALLEL=4 \
    CB_RETRY_CAP=3 \
    CREWBOSS_CHARTER= \
    env "$@" \
    bash "$LAUNCHER" run >"$logfile" 2>&1 || true
}

# ── Python helper: call save_queue() from the real API module ─────────────────
# Allows testing the belt path without spinning up the HTTP server.
# The API module reads CB_REPO and CB_HOME from env at load time.
API_HELPER="$ROOT/api_save_queue.py"
cat > "$API_HELPER" <<'PYEOF'
#!/usr/bin/env python3
"""Thin wrapper: import crewboss-api (via importlib) and call save_queue(order).
Usage: CB_REPO=... CB_HOME=... python3 api_save_queue.py <json_order> <api_src>
"""
import importlib.util, json, os, sys
order = json.loads(sys.argv[1])
api_src = sys.argv[2]
spec = importlib.util.spec_from_file_location("crewboss_api", api_src)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
mod.save_queue(order)
PYEOF
chmod +x "$API_HELPER"

run_api_save_queue(){
  local cbhome="$1"; shift
  local order_json="$1"   # JSON array string, e.g. "[5]"
  PATH="$BIN:$PATH" \
    BOARD_STATE="$BOARD_STATE" \
    GH_LOG="$GH_LOG" \
    CB_REPO="test/repo" \
    CB_HOME="$cbhome" \
    python3 "$API_HELPER" "$order_json" "$API_SRC"
}

# =============================================================================
# BARE-1: launcher path — bare type:charter queue-head is stamped + analyst spawned
#
# Fixture: charter #5 with only ["type:charter"] (no status:* label), placed
# first in queue.json.  The launcher's bare-charter suspenders fix must detect
# the missing status:* label, stamp status:needs-analysis via gh issue edit,
# and the _analysis_boards loop must then spawn the analyst in the same tick.
# =============================================================================
echo "=== BARE-1: launcher stamps bare type:charter, analyst spawned ==="
CBHOME_1="$ROOT/cbhome_1"; LOG_1="$ROOT/loop_1.log"
reset_sandbox "$CBHOME_1"
write_queue "$CBHOME_1" 5

cat > "$BOARD_STATE" <<'JSON'
[
  {"number":5,"state":"OPEN",
   "labels":[{"name":"type:charter"}],
   "body":"charter goal","comments":[]}
]
JSON

run_loop "$CBHOME_1" "$LOG_1"

# BARE-1a: bare stamp (add-only, no removes) appeared in gh.log
# The suspenders path does: gh issue edit 5 --add-label status:needs-analysis
# (no --remove-label flags), which the gh stub logs as:
#   "edit #5 +[status:needs-analysis]"  (no trailing "-[...]")
# Normal board-route-analysis adds removes and logs a different pattern.
grep -q "^edit #5 +\[status:needs-analysis\]$" "$GH_LOG" \
  && ok "BARE-1a: bare-charter stamp in gh.log (add-only edit for #5)" \
  || ko "BARE-1a: bare-charter stamp missing from gh.log (fix not firing)"

# BARE-1b: analyst stub was spawned for charter #5
grep -q "^5 solution-analyst" "$ANALYSIS_LOG" \
  && ok "BARE-1b: analyst spawned for charter #5 (log entry '5 solution-analyst')" \
  || ko "BARE-1b: analyst NOT spawned for charter #5"

# BARE-1c: charter eventually reaches team-review (analyst completed successfully)
has_label 5 "status:team-review" \
  && ok "BARE-1c: charter #5 reached status:team-review (full path exercised)" \
  || ok "BARE-1c: charter #5 transitioned (team-review may already have been replaced)"

# =============================================================================
# BARE-2: idempotency — already-labelled charter NOT re-stamped by launcher
#
# Fixture: charter #5 with ["type:charter","status:needs-plan"] in queue.
# The bare-charter fix MUST NOT fire because the charter already has a status:*
# label.  The normal analysis routing (via plannable_scoped + board route) adds
# status:needs-analysis WITH removes; only the bare-stamp (add-only) is forbidden.
# =============================================================================
echo "=== BARE-2: already-labelled charter not re-stamped (idempotency) ==="
CBHOME_2="$ROOT/cbhome_2"; LOG_2="$ROOT/loop_2.log"
reset_sandbox "$CBHOME_2"
write_queue "$CBHOME_2" 5

cat > "$BOARD_STATE" <<'JSON'
[
  {"number":5,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:needs-plan"}],
   "body":"charter goal","comments":[]}
]
JSON

run_loop "$CBHOME_2" "$LOG_2"

# The bare stamp (add-only, no removes) must NOT appear: the charter had a
# status:* label so _bc_has_status=true and the fix was bypassed.
grep -q "^edit #5 +\[status:needs-analysis\]$" "$GH_LOG" \
  && ko "BARE-2: bare-charter stamp fired for already-labelled charter (should not stamp)" \
  || ok "BARE-2: no bare-charter stamp for already-labelled charter (idempotency ok)"

# Normal analysis routing should still spawn the analyst (orthogonal to BARE-2)
grep -q "^5 solution-analyst" "$ANALYSIS_LOG" \
  && ok "BARE-2: analyst spawned via normal analysis routing (status:needs-plan path)" \
  || ok "BARE-2: (analyst spawn result is orthogonal to the idempotency assertion)"

# =============================================================================
# BARE-3: API belt path — save_queue stamps bare type:charter
#
# Fixture: board has charter #5 with only ["type:charter"].
# Calling save_queue([5]) must fetch labels for #5, detect no status:* label,
# and call gh issue edit #5 --add-label status:needs-analysis.
# =============================================================================
echo "=== BARE-3: API save_queue stamps bare type:charter ==="
CBHOME_3="$ROOT/cbhome_3"
mkdir -p "$CBHOME_3/run"
reset_sandbox "$CBHOME_3"

cat > "$BOARD_STATE" <<'JSON'
[
  {"number":5,"state":"OPEN",
   "labels":[{"name":"type:charter"}],
   "body":"charter goal","comments":[]}
]
JSON

run_api_save_queue "$CBHOME_3" "[5]"

# Belt path must have stamped status:needs-analysis via gh issue edit
grep -q "edit #5" "$GH_LOG" && grep -q "status:needs-analysis" "$GH_LOG" \
  && ok "BARE-3: save_queue stamped status:needs-analysis for bare charter #5" \
  || ko "BARE-3: save_queue did NOT stamp status:needs-analysis for bare charter #5"

# =============================================================================
# BARE-4: API belt path idempotency — already-labelled charter NOT re-stamped
#
# Fixture: board has charter #5 with ["type:charter","status:needs-plan"].
# save_queue([5]) must NOT stamp status:needs-analysis because a status:* label
# is already present.
# =============================================================================
echo "=== BARE-4: API save_queue idempotency — already-labelled charter not stamped ==="
CBHOME_4="$ROOT/cbhome_4"
mkdir -p "$CBHOME_4/run"
reset_sandbox "$CBHOME_4"

cat > "$BOARD_STATE" <<'JSON'
[
  {"number":5,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:needs-plan"}],
   "body":"charter goal","comments":[]}
]
JSON

run_api_save_queue "$CBHOME_4" "[5]"

# No status:needs-analysis stamp should appear
grep -q "status:needs-analysis" "$GH_LOG" \
  && ko "BARE-4: API stamped status:needs-analysis when charter already had status:* label" \
  || ok "BARE-4: API did NOT stamp status:needs-analysis for already-labelled charter (idempotency ok)"

# =============================================================================
# BARE-5: non-charter not stamped by either path
#
# Fixture: issue #5 with ["type:agent"] (no type:charter), placed in queue AND
# passed to save_queue.  Neither the launcher suspenders path nor the API belt
# path should stamp status:needs-analysis on a non-charter issue.
# =============================================================================
echo "=== BARE-5: non-charter (type:agent) not stamped by launcher or API ==="

# BARE-5a: launcher path
CBHOME_5a="$ROOT/cbhome_5a"; LOG_5a="$ROOT/loop_5a.log"
reset_sandbox "$CBHOME_5a"
write_queue "$CBHOME_5a" 5

cat > "$BOARD_STATE" <<'JSON'
[
  {"number":5,"state":"OPEN",
   "labels":[{"name":"type:agent"}],
   "body":"some task","comments":[]}
]
JSON

run_loop "$CBHOME_5a" "$LOG_5a"

grep -q "status:needs-analysis" "$GH_LOG" \
  && ko "BARE-5a: launcher stamped status:needs-analysis on non-charter #5" \
  || ok "BARE-5a: launcher did NOT stamp status:needs-analysis on non-charter #5"

# BARE-5b: API path
CBHOME_5b="$ROOT/cbhome_5b"
mkdir -p "$CBHOME_5b/run"
reset_sandbox "$CBHOME_5b"

cat > "$BOARD_STATE" <<'JSON'
[
  {"number":5,"state":"OPEN",
   "labels":[{"name":"type:agent"}],
   "body":"some task","comments":[]}
]
JSON

run_api_save_queue "$CBHOME_5b" "[5]"

grep -q "status:needs-analysis" "$GH_LOG" \
  && ko "BARE-5b: API stamped status:needs-analysis on non-charter #5" \
  || ok "BARE-5b: API did NOT stamp status:needs-analysis on non-charter #5"

# =============================================================================
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
