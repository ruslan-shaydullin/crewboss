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
#   CB_REMOTE_HOME  — path to cbnet dir on box (default: /var/lib/crewboss/cbnet)
#   CB_SSH_OPTS     — extra options forwarded to both scp and ssh (default: empty)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
MANIFEST="${MANIFEST:-$REPO_ROOT/reference/runtime-manifest.tsv}"
CB_HOST="${CB_HOST:-}"
CB_SERVICE_HOME="${CB_SERVICE_HOME:-/var/lib/crewboss}"
CB_REMOTE_HOME="${CB_REMOTE_HOME:-$CB_SERVICE_HOME/cbnet}"
CB_REMOTE_ENV_FILE="${CB_REMOTE_ENV_FILE:-$CB_SERVICE_HOME/.crewboss.env}"
for _path in "$CB_SERVICE_HOME" "$CB_REMOTE_HOME" "$CB_REMOTE_ENV_FILE"; do
  [[ "$_path" =~ ^/[A-Za-z0-9_./-]+$ ]] && [[ "$_path" != *'/../'* ]] || {
    echo 'deploy-runtime: remote paths must be absolute and contain no spaces or shell metacharacters' >&2; exit 2;
  }
done
REMOTE_ENV="export HOME=$CB_SERVICE_HOME CB_HOME=$CB_REMOTE_HOME CB_ENV_FILE=$CB_REMOTE_ENV_FILE;"
CB_SSH_OPTS="${CB_SSH_OPTS:-}"
SUBCMD="${1:-}"

if [ -z "$CB_HOST" ]; then
  printf 'ERROR: CB_HOST is not set (user@hostname)\n' >&2
  exit 1
fi
[[ "$CB_HOST" =~ ^[A-Za-z0-9_][A-Za-z0-9_.@:-]*$ ]] \
  || { echo 'deploy-runtime: CB_HOST must be a hostname or user@hostname' >&2; exit 2; }

# ── verify step: ssh-check every canonical file on the box via crewboss-doctor ─
# Reuses drift logic from crewboss-doctor.sh (already deployed on the box).
# Does not duplicate sha-check code here.
do_verify() {
  printf '=== deploy-runtime: verify — checking %s against manifest ===\n' "$CB_HOST"
  # Resolve ~ on the BOX (single-quoting CB_REMOTE_HOME='~/cbnet' otherwise passes a
  # literal tilde → "No such file or directory"). [deploy-debt 2026-06-17]
  # shellcheck disable=SC2086,SC2029
  ssh $CB_SSH_OPTS "$CB_HOST" \
    "$REMOTE_ENV H=$CB_REMOTE_HOME; CB_HOME=\$H bash \$H/crewboss-doctor.sh"
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

# ── gh-shim wiring: RL-aware `gh` wrapper (charter #1274, leaf #1301) ──────────
# scp does not preserve the +x bit, so make the shim executable on the box, and expose it
# under the bare name `gh` so the jail's PATH-prepend (crewboss-prep-spawn-gh.sh sets
# PATH=/cbnet:$PATH) resolves in-jail `gh` to the shim FIRST. The shim then walks past
# itself in PATH to run the real gh binary. Idempotent (chmod / ln -sf).
# shellcheck disable=SC2086,SC2029
ssh $CB_SSH_OPTS "$CB_HOST" "$REMOTE_ENV
  set -e; H=$CB_REMOTE_HOME
  chmod +x \"\$H/gh-shim.sh\"
  ln -sf gh-shim.sh \"\$H/gh\"
"
printf '  wired: gh-shim.sh (chmod +x + gh -> gh-shim.sh symlink for PATH-prepend)\n'

# Optional local build: deploy this checkout's UI, never clone the operated repo.
if [ "${CB_BUILD_UI:-0}" = 1 ]; then
  (cd "$REPO_ROOT/ui/app" && npm ci --no-audit --no-fund && npm run build)
  # shellcheck disable=SC2086
  scp $CB_SSH_OPTS -r "$REPO_ROOT/ui/app/dist/." "$CB_HOST:$CB_REMOTE_HOME/ui/"
fi

# ── Optional: sync board labels to the repo (CB_SYNC_LABELS=1) ────────────────
# New board labels (e.g. blast-radius:* from #190) must exist in the GitHub repo or
# gh issue edit fails. labels-setup.sh is idempotent. Opt-in (gh-call heavy). [deploy-debt]
if [ "${CB_SYNC_LABELS:-}" = "1" ]; then
  printf '=== syncing board labels to repo ===\n'
  # shellcheck disable=SC2086,SC2029
  ssh $CB_SSH_OPTS "$CB_HOST" "$REMOTE_ENV
    H=$CB_REMOTE_HOME; . \"\$H/run-env.sh\" || exit 2
    bash \"\$H/crewboss-doctor.sh\" --preflight || exit 2
    bash \"\$H/labels-setup.sh\" >/dev/null 2>&1 && echo '  labels synced' || echo '  WARN: labels-setup non-zero'
  "
fi

# ── Team-catalog sync: role files deploy WITH the code (charter #1291 P4, #1332) ─
# Incident 2026-07-02 #1281: issue routed into role `triage` whose file was ABSENT
# from the box because the live team catalog was never part of deploy — role files
# (triage/reviewer/recovery-lead) reached the box only by operator hand, so the
# spawned session silently crash-died. This step deploys the role catalog into the
# exact roots _cb_role_guard (#1331) checks — $CB_HOME/team/roles and
# $CB_HOME/gov/.claude/agents — so a routed role can never be silently missing.
# Best-effort + non-fatal (never aborts a deploy). Opt-out: CB_SYNC_TEAM=0.
if [ "${CB_SYNC_TEAM:-1}" != "0" ]; then
  printf '=== syncing team catalog (role files) to %s ===\n' "$CB_HOST"
  # shellcheck disable=SC2086,SC2029
  ssh $CB_SSH_OPTS "$CB_HOST" \
    "$REMOTE_ENV H=$CB_REMOTE_HOME; mkdir -p \"\$H/team/roles\" \"\$H/gov/.claude/agents\"" \
    || printf '  WARN: could not create team-catalog dirs on box\n' >&2
  role_count=0
  for _src in "$REPO_ROOT"/reference/.claude/agents/*.md "$REPO_ROOT"/team-example/roles/*.md; do
    [ -f "$_src" ] || continue
    _rb="$(basename "$_src")"
    # shellcheck disable=SC2086
    scp $CB_SSH_OPTS "$_src" "$CB_HOST:$CB_REMOTE_HOME/team/roles/$_rb"        || true
    # shellcheck disable=SC2086
    scp $CB_SSH_OPTS "$_src" "$CB_HOST:$CB_REMOTE_HOME/gov/.claude/agents/$_rb" || true
    role_count=$((role_count+1))
  done
  printf '  team catalog synced: %d role file(s) → team/roles + gov/.claude/agents (matches _cb_role_guard roots)\n' \
    "$role_count"
fi

# ── Restart API daemon ────────────────────────────────────────────────────────
printf '=== restarting API on %s ===\n' "$CB_HOST"
# shellcheck disable=SC2086,SC2029
ssh $CB_SSH_OPTS "$CB_HOST" "$REMOTE_ENV
  # Preferred: the crewboss-api systemd service (survives ssh close, auto-restarts on crash,
  # starts on boot — closes the API-operability SPOF). reference/runtime/crewboss-api.service
  # documents the unit; install it once with: sudo cp + systemctl enable --now. [#188 gap-1]
  if [ -f /etc/systemd/system/crewboss-api.service ]; then
    sudo systemctl restart crewboss-api && echo 'API restarted (systemd crewboss-api, robust)'
  else
    # The guarded starter validates required auth/config. It refuses to kill an
    # arbitrary PID from an old file; install the service for managed restarts.
    H=$CB_REMOTE_HOME
    bash \"\$H/start-api.sh\"

  fi
"

# ── Verify: post-deploy drift check (non-fatal warn) ─────────────────────────
# Doctor reports pre-existing EXTRA-file drift (box has files not in the manifest —
# payload-*.sh, run-173boot.sh cruff) as non-zero, which used to fail an otherwise-good
# deploy. Surface it as a WARNING; canonical MISSING/MISMATCH are the real signal and
# are visible in the doctor output above. [deploy-debt 2026-06-17]
verify_rc=0
do_verify || verify_rc=$?
if [ "$verify_rc" -ne 0 ]; then
  printf 'WARN: post-deploy verify reported drift (rc=%d) — check doctor output above (often pre-existing EXTRA files, not a failed deploy)\n' \
    "$verify_rc" >&2
fi

printf '=== deploy complete: %d files deployed (verify rc=%d) ===\n' "$deploy_count" "$verify_rc"
