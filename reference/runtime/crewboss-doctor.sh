#!/usr/bin/env bash
# crewboss-doctor.sh — unified runtime health checks: drift detection + process/tunnel health.
#
# ── Drift check (runs when CB_HOME/runtime-manifest.tsv is present) ──────────
#   Compares every deployed file against the release manifest embedded in the
#   provision bundle (runtime-manifest.tsv placed there by build-provision.sh).
#   Reports MISSING / MISMATCH / EXTRA files; contributes to non-zero exit.
#
# ── Process/tunnel check (runs when CB_API_PORT is explicitly set) ───────────
#   1. Exactly one API process on CB_API_PORT (via lsof, NOT pgrep -f).
#      --fix: kill extra processes by PORT (lsof -ti tcp:PORT).
#   2. SSH tunnel health via CB_TUNNEL_CHECK command (skipped if unset).
#
# Design invariant: this script NEVER calls pgrep -f (self-match risk #65).
# Port-based kill is the only restart strategy.
#
# Usage:
#   CB_HOME=~/cbnet [CB_API_PORT=8787] [CB_TUNNEL_CHECK='cmd'] crewboss-doctor.sh [--fix]
#
# Exit: 0 = all checks pass, non-zero = problems detected.

set -uo pipefail

CB_HOME="${CB_HOME:-${HOME}/cbnet}"
# CB_API_PORT has NO default — process check only runs when explicitly set.
CB_API_PORT="${CB_API_PORT:-}"
CB_TUNNEL_CHECK="${CB_TUNNEL_CHECK:-}"
MANIFEST="$CB_HOME/runtime-manifest.tsv"
RUN="$CB_HOME/run"
API_PID_FILE="$RUN/api.pid"
FIX=0
LINT_LABELS=0
for _a; do
  case "$_a" in
    --fix)         FIX=1 ;;
    --lint-labels) LINT_LABELS=1 ;;
  esac
done

log(){ echo "[doctor] $*"; }
problems=0
_ok(){ log "ok: $*"; }
_fail(){ log "FAIL: $*"; problems=$((problems+1)); }

# ══════════════════════════════════════════════════════════════════════════════
# LABEL-TAXONOMY LINT — report-only (WARNING; NEVER mutates the board)
# ══════════════════════════════════════════════════════════════════════════════
# Charter #1291 P4 (leaf #1332). The cold-start incident (#1281 zombie/veto storm)
# exposed that no canonical `status:*` label taxonomy existed anywhere in the
# runtime. This doctor pins that taxonomy as an explicit artifact (source of
# truth) and reports — never mutates — any status:*-shaped label outside it.
#
# CANONICAL DECISION (FIXED, no alternative):
#   * The BARE `hold` label is the canonical operator veto — it matches the six
#     live launcher index("hold") filters and the board description «veto: never
#     launch». It is a live CONTROL SIGNAL, not a taxonomy member, and is
#     therefore NEVER flagged.
#   * The orphan `status:hold` (empty description, zero runtime consumers) is NOT
#     a member of the pinned set → it IS flagged.
#   * Any other `status:*`-shaped label outside the pinned set is flagged.
CB_STATUS_TAXONOMY=(
  status:needs-triage
  status:needs-plan
  status:plan-review
  status:needs-analysis
  status:approved
  status:in-progress
  status:review
  status:team-review
  status:acceptance-review
  status:needs-rework
  status:test-broken
  status:impl-broken
  status:blocked
  status:deferred
  status:needs-conflict-resolution
  status:needs-recovery
)

lint_labels(){
  echo "=== [doctor] label-taxonomy lint (report-only WARNING; never mutates the board) ==="
  if ! command -v gh >/dev/null 2>&1; then
    log "taxonomy lint skipped (gh not on PATH)"
    return 0
  fi
  local repo="${CB_REPO:-}"
  local board
  # Read-only board fetch — labels only. NEVER an issue edit / label mutation.
  board="$(gh issue list ${repo:+--repo "$repo"} --state all --limit 1000 \
             --json number,labels 2>/dev/null || true)"
  if [ -z "$board" ]; then
    log "taxonomy lint skipped (no board labels reachable)"
    return 0
  fi

  declare -A _canon=()
  local _l
  for _l in "${CB_STATUS_TAXONOMY[@]}"; do _canon["$_l"]=1; done

  local labels
  labels="$(printf '%s' "$board" | jq -r '.[].labels[]?.name' 2>/dev/null | sort -u)"

  local flagged=0 name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    # Bare `hold` = canonical live veto (control signal) — NEVER a taxonomy typo.
    [ "$name" = "hold" ] && continue
    case "$name" in
      status:*)
        if [ -z "${_canon[$name]+x}" ]; then
          printf 'LINT-FLAG: %s  (status:*-shaped label outside pinned taxonomy)\n' "$name"
          flagged=$((flagged+1))
        fi
        ;;
    esac
  done <<< "$labels"

  if [ "$flagged" -eq 0 ]; then
    log "taxonomy lint: no off-taxonomy status:* labels found"
  else
    log "WARNING: taxonomy lint flagged $flagged off-taxonomy status:* label(s) — report-only, board NOT mutated"
  fi
  return 0
}

if [ "$LINT_LABELS" -eq 1 ]; then
  lint_labels
fi

# ══════════════════════════════════════════════════════════════════════════════
# DRIFT CHECK — only when manifest is present
# ══════════════════════════════════════════════════════════════════════════════
if [ -f "$MANIFEST" ]; then
  echo "=== [doctor] drift check ==="

  drift_fails=0
  drift_names=""

  declare -A expected_sha
  while IFS=$'\t' read -r repo_path sha256 status _purpose; do
    case "${repo_path:-}" in ''|'#'*) continue ;; esac
    [ "${status:-}" = "canonical" ] || continue
    bname="$(basename "$repo_path")"
    expected_sha["$bname"]="$sha256"
  done < "$MANIFEST"

  # ── Pass 1: verify every manifest entry ──────────────────────────────────
  for bname in "${!expected_sha[@]}"; do
    deployed="$CB_HOME/$bname"
    want="${expected_sha[$bname]}"
    if [ ! -f "$deployed" ]; then
      printf 'MISSING: %s\n' "$bname"
      drift_names="$drift_names $bname"
      drift_fails=$((drift_fails+1))
    else
      actual="$(sha256sum "$deployed" | awk '{print $1}')"
      if [ "$actual" != "$want" ]; then
        printf 'MISMATCH: %s\n' "$bname"
        drift_names="$drift_names $bname"
        drift_fails=$((drift_fails+1))
      fi
    fi
  done

  # ── Pass 2: detect extra (untracked) files at top level of CB_HOME ────────
  for f in "$CB_HOME"/*; do
    [ -f "$f" ] || continue
    bname="$(basename "$f")"
    [ "$bname" = "runtime-manifest.tsv" ] && continue
    if [ -z "${expected_sha[$bname]+x}" ]; then
      printf 'EXTRA: %s\n' "$bname"
      drift_names="$drift_names $bname"
      drift_fails=$((drift_fails+1))
    fi
  done

  # ── Drift summary ─────────────────────────────────────────────────────────
  if [ "$drift_fails" -eq 0 ]; then
    printf 'doctor: no drift (%d files verified)\n' "${#expected_sha[@]}"
  else
    # shellcheck disable=SC2086
    printf 'doctor: drift detected (%d):%s\n' "$drift_fails" "$drift_names"
    problems=$((problems+drift_fails))
  fi
else
  log "drift check skipped (no manifest at $MANIFEST)"
fi

# ══════════════════════════════════════════════════════════════════════════════
# PROCESS + TUNNEL CHECK — only when CB_API_PORT is explicitly set
# ══════════════════════════════════════════════════════════════════════════════
if [ -n "$CB_API_PORT" ]; then

  # ── port_pids_for PORT ──────────────────────────────────────────────────
  # Returns one PID per line listening on tcp:PORT.  NEVER uses pgrep -f.
  port_pids_for(){
    local port="$1"
    if command -v lsof >/dev/null 2>&1; then
      lsof -ti tcp:"$port" 2>/dev/null || true
    else
      # fallback: ss — parse pid= from output
      ss -tlnp "sport = :$port" 2>/dev/null \
        | grep -oP 'pid=\K[0-9]+' | sort -u || true
    fi
  }

  # ── Check 1: exactly one API process on port ────────────────────────────
  echo "=== [doctor] check 1: API process count on port $CB_API_PORT ==="
  _pids=$(port_pids_for "$CB_API_PORT")
  _count=0
  for _p in $_pids; do _count=$((_count+1)); done

  if [ "$_count" -eq 0 ]; then
    _fail "no API process on port $CB_API_PORT"
  elif [ "$_count" -eq 1 ]; then
    _ok "exactly one API process on port $CB_API_PORT (pid $_pids)"
  else
    _fail "multiple ($_count) processes on port $CB_API_PORT — duplicates detected"
    if [ "$FIX" -eq 1 ]; then
      # Identify keeper: prefer PID from pid file; else keep first
      _keeper=""
      [ -f "$API_PID_FILE" ] && _keeper=$(cat "$API_PID_FILE" 2>/dev/null | tr -d '[:space:]') || true
      [ -z "$_keeper" ] && { for _p in $_pids; do _keeper=$_p; break; done; }
      # Kill extras by PID obtained from port (NOT pgrep -f — self-match risk)
      for _p in $_pids; do
        [ "$_p" = "$_keeper" ] && continue
        if kill "$_p" 2>/dev/null; then
          log "killed duplicate process $_p (kept keeper $_keeper)"
        else
          log "warn: could not kill duplicate $_p"
        fi
      done
      log "fix applied: killed $((_count-1)) duplicate(s), kept $_keeper"
    fi
  fi

  # ── Check 2: SSH tunnel health ──────────────────────────────────────────
  echo "=== [doctor] check 2: SSH tunnel health ==="
  if [ -z "$CB_TUNNEL_CHECK" ]; then
    _ok "tunnel check skipped (CB_TUNNEL_CHECK not configured)"
  else
    if eval "$CB_TUNNEL_CHECK" >/dev/null 2>&1; then
      _ok "SSH tunnel alive"
    else
      _fail "SSH tunnel dead (CB_TUNNEL_CHECK='$CB_TUNNEL_CHECK' failed)"
    fi
  fi

else
  log "process/tunnel checks skipped (CB_API_PORT not set)"
fi

# ══════════════════════════════════════════════════════════════════════════════
echo
printf '[doctor] %d problem(s) detected\n' "$problems"
[ "$problems" -eq 0 ]
