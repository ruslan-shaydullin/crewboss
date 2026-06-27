#!/usr/bin/env bash
# provision-podman.sh — Provision a working container runtime on AL2023 EC2 box.
#
# Background (leaf #769, charter #768):
#   AL2023 2023.12 repo snapshot has no podman package.  Only docker 25.0.16
#   (+ runc/containerd) is available.  The crewboss integrator calls `podman run`
#   (crewboss-integrator.sh line ~487).  This script installs a working `podman`
#   so the visual-regression gate can run without the soft-sentinel bypass.
#
# Strategy:
#   Step 1 — Option B: try real podman from EPEL.
#   Step 2 — Option A (fallback): install a /usr/local/bin/podman shell wrapper
#             that exec-delegates to docker.
#
# Deviation note (Option A):
#   Rootful docker is used because EPEL is unavailable on the AL2023 snapshot.
#   ec2-user added to the docker group = effective root on this dedicated CI box.
#   Accepted risk; deviation from rootless-podman design of #741 is documented.
#
# Usage (must run as ec2-user with sudo privileges):
#   sudo bash /home/ec2-user/cbnet/provision-podman.sh
#
# Idempotent: safe to re-run.

set -euo pipefail

BOX_USER="${SUDO_USER:-ec2-user}"
WRAPPER="/usr/local/bin/podman"

log() { printf '[provision-podman] %s\n' "$*"; }

# ── Step 1: Option B — try EPEL + real podman ────────────────────────────────
log "Step 1: trying Option B (real podman from EPEL) ..."
OPTION_B_OK=0

if command -v podman >/dev/null 2>&1; then
  log "podman already installed: $(podman --version)"
  OPTION_B_OK=1
else
  # Try enabling EPEL if available
  if dnf install -y epel-release 2>/dev/null; then
    log "EPEL installed; trying dnf install podman ..."
    if dnf install --enablerepo=epel -y podman 2>/dev/null; then
      log "Option B succeeded: $(podman --version)"
      OPTION_B_OK=1
    else
      log "podman not in EPEL on this snapshot"
    fi
  else
    log "epel-release not in AL2023 repo snapshot — Option B unavailable"
  fi
fi

# ── Step 2: Option A — docker → podman wrapper (fallback) ────────────────────
if [ "$OPTION_B_OK" -eq 0 ]; then
  log "Step 2: Option B failed; installing Option A (docker wrapper) ..."

  # Verify docker is available
  if ! command -v docker >/dev/null 2>&1; then
    printf 'ERROR: docker not found — cannot install wrapper. Aborting.\n' >&2
    exit 1
  fi

  log "docker found: $(docker --version)"

  # Create the wrapper
  log "Writing wrapper to $WRAPPER ..."
  cat > "$WRAPPER" <<'WRAPPER_EOF'
#!/bin/sh
exec docker "$@"
WRAPPER_EOF
  chmod +x "$WRAPPER"
  log "Wrapper installed at $WRAPPER"

  # Ensure ec2-user is in the docker group
  if ! groups "$BOX_USER" 2>/dev/null | grep -q docker; then
    log "Adding $BOX_USER to docker group ..."
    usermod -aG docker "$BOX_USER"
    log "$BOX_USER added to docker group (new group effective after next login/newgrp)"
  else
    log "$BOX_USER already in docker group"
  fi

  # Start docker daemon if not running
  if ! systemctl is-active --quiet docker 2>/dev/null; then
    log "Starting docker daemon ..."
    systemctl start docker || true
  fi
fi

# ── Verify ────────────────────────────────────────────────────────────────────
log "Verifying podman --version ..."
if ! podman --version; then
  printf 'ERROR: podman --version failed\n' >&2
  exit 1
fi

log "Running podman run --rm hello-world as $BOX_USER ..."
# Run hello-world; if the user just got docker group membership, use sg/newgrp
if sudo -u "$BOX_USER" podman run --rm hello-world 2>&1 | grep -qi hello; then
  log "SUCCESS: hello-world output contains 'hello' — container runtime is operational"
else
  log "WARN: hello-world did not contain expected output; try: newgrp docker && podman run --rm hello-world"
  printf 'ERROR: hello-world test failed\n' >&2
  exit 1
fi

log "Provisioning complete."
if [ "$OPTION_B_OK" -eq 1 ]; then
  printf '\nRUNTIME-CHOICE: Option B (real podman from EPEL).\n'
else
  printf '\nRUNTIME-CHOICE: Option A (docker wrapper). Rootful docker used because AL2023 repo snapshot has no podman. ec2-user in docker group = effective root on this dedicated CI box. Deviation from rootless-podman design of #741. Accepted risk.\n'
fi
