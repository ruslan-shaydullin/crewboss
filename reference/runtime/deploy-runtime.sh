#!/usr/bin/env bash
# deploy-runtime.sh — deploy the full runtime manifest to a crewboss box.
#
# Reads reference/runtime-manifest.tsv from REPO_ROOT and SCPs every canonical
# file to the remote box, then restarts the API daemon via ssh.  This replaces
# ad-hoc per-file scp by the operator.
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
SUBCMD="${1:-}"

if [ -z "$CB_HOST" ]; then
  printf 'ERROR: CB_HOST is not set (e.g. CB_HOST=ec2-user@1.2.3.4)\n' >&2
  exit 1
fi

# ── verify step: ssh-check every canonical file on the box via crewboss-doctor ─
# Reuses drift logic from crewboss-doctor.sh (already deployed on the box).
# Does not duplicate sha-check code here.
do_verify() {
  printf '=== deploy-runtime: verify — checking %s against manifest ===\n' "$CB_HOST"
  # shellcheck disable=SC2086,SC2029
  ssh $CB_SSH_OPTS "$CB_HOST" \
    "CB_HOME='$CB_REMOTE_HOME' bash '$CB_REMOTE_HOME/crewboss-doctor.sh'"
}

if [ "$SUBCMD" = "verify" ]; then
  do_verify
  exit $?
fi

if [ ! -f "$MANIFEST" ]; then
  printf 'ERROR: manifest not found: %s\n' "$MANIFEST" >&2
  exit 1
fi

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
  # Source operator secrets from ~/.crewboss.env so CB_REPO and CB_API_TOKEN reach the
  # daemon (without this, api.py starts with empty TOKEN → auth=OFF — issue #148).
  [ -f \"\$HOME/.crewboss.env\" ] && . \"\$HOME/.crewboss.env\"
  export CB_HOME CB_REPO CB_API_TOKEN
  API_PID=\"\$CB_HOME/run/api.pid\"
  mkdir -p \"\$CB_HOME/run\"
  if [ -f \"\$API_PID\" ]; then
    kill \"\$(cat \"\$API_PID\")\" 2>/dev/null || true
    rm -f \"\$API_PID\"
    sleep 0.3
  fi
  nohup env CB_HOME=\"\$CB_HOME\" CB_REPO=\"\$CB_REPO\" CB_API_TOKEN=\"\$CB_API_TOKEN\" \
    python3 \"\$CB_HOME/crewboss-api.py\" --port 8787 \
    > \"\$CB_HOME/run/api.out\" 2>&1 &
  echo \$! > \"\$API_PID\"
  echo \"API restarted, auth=\${CB_API_TOKEN:+on}\"
"

# ── Verify: post-deploy drift check — deploy is only complete when box matches ─
verify_rc=0
do_verify || verify_rc=$?
if [ "$verify_rc" -ne 0 ]; then
  printf 'ERROR: verify failed — %s did not reach clean state after deploy\n' \
    "$CB_HOST" >&2
  exit 1
fi

printf '=== deploy complete: %d files deployed, verify ok ===\n' "$deploy_count"
