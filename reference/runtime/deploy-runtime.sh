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
  # Resolve ~ on the BOX (single-quoting CB_REMOTE_HOME='~/cbnet' otherwise passes a
  # literal tilde → "No such file or directory"). [deploy-debt 2026-06-17]
  # shellcheck disable=SC2086,SC2029
  ssh $CB_SSH_OPTS "$CB_HOST" \
    "H=\$(eval echo $CB_REMOTE_HOME); CB_HOME=\$H bash \$H/crewboss-doctor.sh"
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
ssh $CB_SSH_OPTS "$CB_HOST" "
  set -e; H=\$(eval echo $CB_REMOTE_HOME)
  chmod +x \"\$H/gh-shim.sh\"
  ln -sf gh-shim.sh \"\$H/gh\"
"
printf '  wired: gh-shim.sh (chmod +x + gh -> gh-shim.sh symlink for PATH-prepend)\n'

# ── Build + deploy the dashboard UI ───────────────────────────────────────────
# The box serves the built vite dist from <home>/www (see crewboss-api.py static route).
# Runs by default so CSS/JS fixes (e.g. #698) reach the live box on every deploy.
# Pass CB_BUILD_UI=0 to skip for backend-only deploys. [deploy-debt 2026-06-17]
if [ "${CB_BUILD_UI:-1}" != "0" ]; then
  printf '=== building dashboard UI on %s ===\n' "$CB_HOST"
  # shellcheck disable=SC2086,SC2029
  ssh $CB_SSH_OPTS "$CB_HOST" "
    set -e; H=\$(eval echo $CB_REMOTE_HOME)
    [ -f \"\$H/run-env.sh\" ] && . \"\$H/run-env.sh\" || true
    UB=\$HOME/cbnet-uibuild
    if [ -d \"\$UB/.git\" ]; then git -C \"\$UB\" fetch -q origin main && git -C \"\$UB\" reset -q --hard origin/main
    else git clone -q \"https://github.com/\${CB_REPO:-ruslan-shaydullin/crewboss}.git\" \"\$UB\"; fi
    cd \"\$UB/ui/app\"; npm install --no-audit --no-fund >/tmp/ui-deploy.log 2>&1; npm run build >>/tmp/ui-deploy.log 2>&1
    rm -rf \"\$H/www\"; cp -r dist \"\$H/www\"; echo '  UI built + deployed to '\"\$H\"'/www'
  " || printf '  WARN: UI build step failed (see /tmp/ui-deploy.log on box)\n'
fi

# ── Optional: sync board labels to the repo (CB_SYNC_LABELS=1) ────────────────
# New board labels (e.g. blast-radius:* from #190) must exist in the GitHub repo or
# gh issue edit fails. labels-setup.sh is idempotent. Opt-in (gh-call heavy). [deploy-debt]
if [ "${CB_SYNC_LABELS:-}" = "1" ]; then
  printf '=== syncing board labels to repo ===\n'
  # shellcheck disable=SC2086,SC2029
  ssh $CB_SSH_OPTS "$CB_HOST" "
    H=\$(eval echo $CB_REMOTE_HOME); [ -f \"\$H/run-env.sh\" ] && . \"\$H/run-env.sh\" || true
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
    "H=\$(eval echo $CB_REMOTE_HOME); mkdir -p \"\$H/team/roles\" \"\$H/gov/.claude/agents\"" \
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
ssh $CB_SSH_OPTS "$CB_HOST" "
  # Preferred: the crewboss-api systemd service (survives ssh close, auto-restarts on crash,
  # starts on boot — closes the API-operability SPOF). reference/runtime/crewboss-api.service
  # documents the unit; install it once with: sudo cp + systemctl enable --now. [#188 gap-1]
  if [ -f /etc/systemd/system/crewboss-api.service ]; then
    sudo systemctl restart crewboss-api && echo 'API restarted (systemd crewboss-api, robust)'
  else
    # Fallback: no unit installed — detached start (fragile, dies on abrupt ssh teardown).
    H=\$(eval echo $CB_REMOTE_HOME); cd \"\$H\"
    if [ -f run-env.sh ]; then . run-env.sh; elif [ -f \$HOME/.crewboss.env ]; then . \$HOME/.crewboss.env; fi
    export CB_REPO=\${CB_REPO:-ruslan-shaydullin/crewboss} CB_HOME=\"\$H\"
    for _p in \$(fuser 8787/tcp 2>/dev/null); do kill -9 \"\$_p\" 2>/dev/null || true; done; sleep 1
    nohup setsid python3 crewboss-api.py --port 8787 > run/api.out 2>&1 < /dev/null & disown 2>/dev/null || true
    echo \"\$!\" > run/api.pid; sleep 2
    echo 'API restarted (FALLBACK detached — install crewboss-api.service for robustness)'
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
