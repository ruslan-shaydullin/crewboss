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

# A local, fail-closed gate for every entrypoint that may launch or mutate work.
# It does not contact GitHub or invoke an agent. The nsjail probe executes only
# a private /tmp write/read with the real seccomp policy and namespace/mount settings.
if [ "${1:-}" = --preflight ]; then
  # shellcheck source=run-env.sh
  . "$(dirname "${BASH_SOURCE[0]}")/run-env.sh" || exit 2
  errors=0
  preflight_fail() { printf '[doctor] FAIL: %s\n' "$*" >&2; errors=$((errors+1)); }
  [ "$(uname -s)" = Linux ] || preflight_fail 'the agent runtime requires Linux (the dashboard can run locally)'
  [ "$(uname -m)" = x86_64 ] || preflight_fail 'the shipped seccomp policy supports x86_64 only; ARM64 agent execution is not supported'
  [ "${BASH_VERSINFO[0]}" -ge 5 ] || preflight_fail 'the agent runtime requires Bash 5 or newer'
  for binary in git gh jq python3 perl flock; do
    command -v "$binary" >/dev/null 2>&1 || preflight_fail "missing executable: $binary"
  done
  for key in CB_HOME CB_AGENT_HOME CB_CLAUDE_INSTALL_DIR CB_CLAUDE_CONFIG_DIR; do
    value="${!key}"
    case "$value" in /*) ;; *) preflight_fail "$key must be an absolute path"; continue ;; esac
    case "$value" in *:*|*$'\n'*) preflight_fail "$key cannot contain mount delimiters or newlines"; continue ;; esac
    [ "$value" != / ] || { preflight_fail "$key must not be the filesystem root"; continue; }
    [ -d "$value" ] && [ -r "$value" ] || preflight_fail "$key must name a readable directory"
  done
  [ -w "$CB_HOME" ] || preflight_fail 'CB_HOME must be writable by the runtime account'
  [ -w "$CB_CLAUDE_CONFIG_DIR" ] || preflight_fail 'CB_CLAUDE_CONFIG_DIR must be writable by the runtime account'
  for key in CB_CLAUDE_BIN CB_NSJAIL_BIN CB_GH_BIN; do
    value="${!key}"
    case "$value" in /*) ;; *) preflight_fail "$key must be an absolute executable path"; continue ;; esac
    [ -f "$value" ] && [ -x "$value" ] || preflight_fail "$key is not an executable file"
  done
  [ -f "$CB_CLAUDE_CONFIG_FILE" ] && [ -r "$CB_CLAUDE_CONFIG_FILE" ] && [ -w "$CB_CLAUDE_CONFIG_FILE" ] \
    || preflight_fail 'CB_CLAUDE_CONFIG_FILE must name a readable, writable file (create an empty JSON object for a new OAuth setup)'
  case "$CB_CLAUDE_CONFIG_FILE" in /*) ;; *) preflight_fail 'CB_CLAUDE_CONFIG_FILE must be absolute' ;; esac
  for required in claude.kafel nsjail-limits.cfg proxy.py bridge.py redact.pl crewboss-spawn.sh crewboss-launcher-gh.sh; do
    [ -r "$CB_HOME/$required" ] || preflight_fail "runtime file missing: $required"
  done
  if [ "${CB_GOVERNED:-1}" = 1 ]; then
    [ -x "$CB_HOME/gov/.claude/hooks/crewboss-gate.sh" ] \
      || preflight_fail 'governance hook is missing or not executable (gov/.claude/hooks/crewboss-gate.sh)'
    if command -v jq >/dev/null 2>&1; then
      jq -e 'any(.hooks.PreToolUse[]?.hooks[]?; .type == "command" and (.command | contains("crewboss-gate.sh")))' \
        "$CB_HOME/gov/.claude/settings.json" >/dev/null 2>&1 \
        || preflight_fail 'governance settings must wire the crewboss PreToolUse hook'
    fi
  fi
  [ -n "${GH_TOKEN:-}" ] || preflight_fail 'GH_TOKEN is required in the operator configuration'
  [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}${ANTHROPIC_API_KEY:-}" ] \
    || preflight_fail 'configure CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY for the agent provider'
  if [ "$errors" -gt 0 ]; then exit 2; fi
  if ! python3 -c 'import os,sys; sys.exit(len(os.fsencode(sys.argv[1]+"/run/work/18446744073709551615/proxy.sock")) >= 108)' "$CB_HOME"; then
    preflight_fail 'CB_HOME is too long for the per-task Unix proxy socket; choose a shorter runtime path'
    exit 2
  fi
  # Resolve provider symlinks before validating the read-only installation mount.
  resolved_provider="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$CB_CLAUDE_BIN")"
  resolved_install="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$CB_CLAUDE_INSTALL_DIR")"
  resolved_gh="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$CB_GH_BIN")"
  case "$resolved_provider" in "$resolved_install"/*|/usr/*|/bin/*) ;; *)
    preflight_fail 'CB_CLAUDE_INSTALL_DIR must contain the resolved Claude executable'; exit 2 ;;
  esac
  probe_mounts=()
  for mount in /usr /bin /lib /lib64 /sbin /etc; do
    [ ! -e "$mount" ] || probe_mounts+=(-R "$mount")
  done
  if ! "$CB_NSJAIL_BIN" -C "$CB_HOME/nsjail-limits.cfg" -Mo -t 5 --rlimit_cpu max \
      --seccomp_policy "$CB_HOME/claude.kafel" "${probe_mounts[@]}" \
      -R "$CB_CLAUDE_INSTALL_DIR" -R "$resolved_gh:/crewboss-gh-real" \
      -R "$CB_CLAUDE_CONFIG_DIR:$CB_AGENT_HOME/.claude" \
      -R "$CB_CLAUDE_CONFIG_FILE:$CB_AGENT_HOME/.claude.json" -R "$CB_HOME:/cbnet" -B /dev \
      -m none:/tmp:tmpfs:size=16M --really_quiet -- /bin/sh -ec \
      'test -r /proc/self/stat; test -L /proc/self/ns/net; probe=$(mktemp /tmp/crewboss-preflight.XXXXXX); trap '\''rm -f "$probe"'\'' EXIT; printf %s crewboss-preflight > "$probe"; test "$(cat "$probe")" = crewboss-preflight'; then
    preflight_fail 'nsjail probe failed: check inherited resource limits, Linux user namespaces, mount permissions and the seccomp policy'
    exit 2
  fi
  printf '[doctor] ok: runtime configuration, dependencies and sandbox probe\n'
  exit 0
fi

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
    # The installer creates this relative executable alias. Its target is
    # already hash-checked above; a different link or regular file is drift.
    if [ "$bname" = gh ] && [ -L "$f" ] && [ "$(readlink "$f")" = gh-shim.sh ] \
        && [ -n "${expected_sha[gh-shim.sh]+x}" ]; then
      continue
    fi
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
