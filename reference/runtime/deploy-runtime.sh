#!/usr/bin/env bash
# deploy-runtime.sh — deploy the full runtime manifest to a crewboss box.
#
# Reads reference/runtime-manifest.tsv from REPO_ROOT and SCPs every canonical
# file to the remote box, then restarts the API daemon via ssh, then verifies
# the post-deploy state by running crewboss-doctor.sh (drift-only mode) on the
# box.  Exits non-zero if verify detects any MISSING / MISMATCH files.
#
# Subcommands:
#   (none)   — full deploy: scp + restart + verify
#   verify   — verify only (no scp, no restart); requires box already deployed
#
# Required env:
#   CB_HOST         — remote target (user@hostname or hostname)
#
# Optional env:
#   REPO_ROOT       — repo checkout root (default: auto-detected)
#   MANIFEST        — path to manifest tsv (default: $REPO_ROOT/reference/runtime-manifest.tsv)
#   CB_REMOTE_HOME  — path to cbnet dir on box (default: ~/cbnet)
#   CB_SSH_OPTS     — extra options forwarded to both scp and ssh (default: empty)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
MANIFEST="${MANIFEST:-$REPO_ROOT/reference/runtime-manifest.tsv}"
CB_HOST="${CB_HOST:-}"
CB_REMOTE_HOME="${CB_REMOTE_HOME:-~/cbnet}"
CB_SSH_OPTS="${CB_SSH_OPTS:-}"

if [ -z "$CB_HOST" ]; then
  printf 'ERROR: CB_HOST is not set (e.g. CB_HOST=ec2-user@1.2.3.4)\n' >&2
  exit 1
fi

if [ ! -f "$MANIFEST" ]; then
  printf 'ERROR: manifest not found: %s\n' "$MANIFEST" >&2
  exit 1
fi

# ── verify: post-deploy drift check via crewboss-doctor.sh on box ─────────────
# Reuses doctor drift logic (reads runtime-manifest.tsv already on box).
# Called after deploy, and also directly via `deploy-runtime.sh verify`.
# List of files checked is driven by the manifest — no hardcode.
cmd_verify() {
  printf '=== verifying post-deploy state on %s ===\n' "$CB_HOST"
  verify_rc=0
  # shellcheck disable=SC2086,SC2029
  verify_out="$(ssh $CB_SSH_OPTS "$CB_HOST" \
    "CB_HOME='$CB_REMOTE_HOME' bash '$CB_REMOTE_HOME/crewboss-doctor.sh'" 2>&1)" \
    || verify_rc=$?

  drift_lines="$(printf '%s\n' "$verify_out" | grep -E '^(MISSING|MISMATCH):' || true)"

  if [ -n "$drift_lines" ]; then
    printf 'ERROR: post-deploy verify detected drift on %s:\n' "$CB_HOST" >&2
    printf '%s\n' "$drift_lines" >&2
    exit 1
  fi
  if [ "$verify_rc" -ne 0 ]; then
    printf 'ERROR: crewboss-doctor.sh exited %d on box — check output:\n' \
      "$verify_rc" >&2
    printf '%s\n' "$verify_out" >&2
    exit 1
  fi
  printf '=== verify OK: no drift on %s ===\n' "$CB_HOST"
}

# ── subcommand dispatch ────────────────────────────────────────────────────────
case "${1:-}" in
  verify)
    cmd_verify
    exit 0
    ;;
  "")
    # proceed with full deploy below
    ;;
  *)
    printf 'ERROR: unknown subcommand: %s\n' "$1" >&2
    printf 'Usage: %s [verify]\n' "$(basename "$0")" >&2
    exit 1
    ;;
esac

printf '=== deploy-runtime: deploying manifest to %s:%s ===\n' \
  "$CB_HOST" "$CB_REMOTE_HOME"

deploy_count=0
missing_count=0

# ── Deploy every canonical file ───────────────────────────────────────────────
while IFS=$'\t' read -r repo_path sha256 status _purpose; do
  case "${repo_path:-}" in ''|'#'*) continue ;; esac
  [ "${status:-}" = "canonical" ] || continue

  local_path="$REPO_ROOT/$repo_path"
  bname="$(basename "$repo_path")"

  if [ ! -f "$local_path" ]; then
    printf 'MISSING local: %s\n' "$repo_path" >&2
    missing_count=$((missing_count+1))
    continue
  fi

  # shellcheck disable=SC2086
  scp $CB_SSH_OPTS "$local_path" "$CB_HOST:$CB_REMOTE_HOME/$bname"
  printf '  deployed: %s\n' "$bname"
  deploy_count=$((deploy_count+1))
done < "$MANIFEST"

if [ "$missing_count" -gt 0 ]; then
  printf 'ERROR: %d local file(s) missing from checkout — aborting\n' \
    "$missing_count" >&2
  exit 1
fi

# ── Deploy manifest copy (doctor uses it for drift verification) ──────────────
# shellcheck disable=SC2086
scp $CB_SSH_OPTS "$MANIFEST" "$CB_HOST:$CB_REMOTE_HOME/runtime-manifest.tsv"
printf '  deployed: runtime-manifest.tsv (manifest copy)\n'

# ── Restart API daemon ────────────────────────────────────────────────────────
printf '=== restarting API on %s ===\n' "$CB_HOST"
# shellcheck disable=SC2086,SC2029
ssh $CB_SSH_OPTS "$CB_HOST" "
  CB_HOME='$CB_REMOTE_HOME'
  API_PID=\"\$CB_HOME/run/api.pid\"
  mkdir -p \"\$CB_HOME/run\"
  if [ -f \"\$API_PID\" ]; then
    kill \"\$(cat \"\$API_PID\")\" 2>/dev/null || true
    rm -f \"\$API_PID\"
    sleep 0.3
  fi
  nohup python3 \"\$CB_HOME/crewboss-api.py\" --port 8787 \
    > \"\$CB_HOME/run/api.out\" 2>&1 &
  echo \$! > \"\$API_PID\"
  echo 'API restarted'
"

printf '=== deploy complete: %d files deployed ===\n' "$deploy_count"

# ── Verify post-deploy state ──────────────────────────────────────────────────
# Deploy without green verify is non-zero: guards against silent box drift.
cmd_verify
