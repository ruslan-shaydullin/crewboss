#!/usr/bin/env bash
# crewboss-doctor.sh — runtime health checks for the crewboss stack.
#
# Checks:
#   1. Exactly one API process on port CB_API_PORT
#      --fix: kill extra processes by PORT (lsof -ti tcp:PORT), NOT pgrep -f (self-match risk)
#   2. SSH tunnel health via CB_TUNNEL_CHECK command
#
# Design invariant: this script NEVER calls pgrep -f (self-match risk documented in #65).
# Port-based kill is the only restart strategy. CI test (doctor-process.test.sh) stubs
# a failing pgrep to prove no reliance on it — the fix must still work.
#
# Usage:
#   CB_HOME=~/cbnet CB_API_PORT=8787 [CB_TUNNEL_CHECK='cmd'] crewboss-doctor.sh [--fix]
#
# Exit: 0 = all checks pass, non-zero = problems detected.
set -uo pipefail
CB_HOME="${CB_HOME:-${HOME}/cbnet}"
CB_API_PORT="${CB_API_PORT:-8787}"
CB_TUNNEL_CHECK="${CB_TUNNEL_CHECK:-}"
RUN="$CB_HOME/run"
API_PID_FILE="$RUN/api.pid"
FIX=0
for _a; do [ "$_a" = "--fix" ] && FIX=1; done

log(){ echo "[doctor] $*"; }
problems=0
_ok(){ log "ok: $*"; }
_fail(){ log "FAIL: $*"; problems=$((problems+1)); }

# ── port_pids_for PORT: PIDs listening on tcp:PORT; output one PID per line ──
# Uses lsof (preferred) or ss (fallback). NEVER pgrep -f (self-match risk).
port_pids_for(){
  local port="$1"
  if command -v lsof >/dev/null 2>&1; then
    lsof -ti tcp:"$port" 2>/dev/null || true
  else
    # fallback: ss - parse pid= from output
    ss -tlnp "sport = :$port" 2>/dev/null \
      | grep -oP 'pid=\K[0-9]+' | sort -u || true
  fi
}

# ── Check 1: exactly one API process on port ──────────────────────────────────
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

# ── Check 2: SSH tunnel health ────────────────────────────────────────────────
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

echo
printf '[doctor] %d problem(s) detected\n' "$problems"
[ "$problems" -eq 0 ]
