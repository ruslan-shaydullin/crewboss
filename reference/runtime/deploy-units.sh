#!/usr/bin/env bash
# deploy-units.sh — charter #1144: deploy the crewboss systemd units to the box.
#
# The four unit files live in reference/runtime/ but are intentionally NOT in
# runtime-manifest.tsv (OPTION (b), crewboss-api.service precedent): the manifest scp loop
# copies canonical entries to ~/cbnet/ only — the WRONG location for systemd units. So this
# script hard-codes each unit's local path and its /etc/systemd/system/ target, SCPs it to
# the box via $CB_HOST, then daemon-reloads and enables the launcher + keepalive timer.
#
# FIELD-TEST REQUIRED post-deploy: confirm launcher PID persists across a manual keepalive
# service tick on the box. This is the root-cause fix (cgroup isolation via systemd unit)
# and requires real systemd cgroup teardown — cannot be reproduced in CI.
#
# Usage:
#   CB_HOST=ec2-user@1.2.3.4 bash reference/runtime/deploy-units.sh
#
# Env:
#   CB_HOST      — remote target (user@hostname or hostname). REQUIRED.
#   CB_SSH_OPTS  — extra options forwarded to both scp and ssh (default: empty).
set -euo pipefail

CB_HOST="${CB_HOST:-}"
CB_SSH_OPTS="${CB_SSH_OPTS:-}"

if [ -z "$CB_HOST" ]; then
  printf 'ERROR: CB_HOST is not set (e.g. CB_HOST=ec2-user@1.2.3.4)\n' >&2
  exit 2
fi

HERE="$(cd "$(dirname "$0")" && pwd)"

# Hard-coded unit files and their /etc/systemd/system/ targets. The killmode drop-in goes
# into the crewboss-loop-keepalive.service.d/ drop-in directory as 10-killmode.conf.
LAUNCHER_SVC="$HERE/crewboss-launcher.service"
KA_SVC="$HERE/crewboss-loop-keepalive.service"
KA_TIMER="$HERE/crewboss-loop-keepalive.timer"
KILLMODE_CONF="$HERE/crewboss-loop-keepalive-killmode.conf"

LAUNCHER_SVC_DST="/etc/systemd/system/crewboss-launcher.service"
KA_SVC_DST="/etc/systemd/system/crewboss-loop-keepalive.service"
KA_TIMER_DST="/etc/systemd/system/crewboss-loop-keepalive.timer"
KILLMODE_CONF_DST="/etc/systemd/system/crewboss-loop-keepalive.service.d/10-killmode.conf"

# SCP each unit to a staging path in the remote home, then sudo-move into place (units live
# under /etc/systemd/system/ which is not writable by scp's ssh user without sudo).
deploy_one() {
  local src="$1" dst="$2" stage
  stage="/tmp/$(basename "$dst")"
  printf '=== deploy-units: %s -> %s:%s ===\n' "$(basename "$src")" "$CB_HOST" "$dst"
  # shellcheck disable=SC2086
  scp $CB_SSH_OPTS "$src" "$CB_HOST:$stage"
  # shellcheck disable=SC2086
  ssh $CB_SSH_OPTS "$CB_HOST" "sudo mkdir -p '$(dirname "$dst")' && sudo cp '$stage' '$dst' && rm -f '$stage'"
}

deploy_one "$LAUNCHER_SVC"  "$LAUNCHER_SVC_DST"
deploy_one "$KA_SVC"        "$KA_SVC_DST"
deploy_one "$KA_TIMER"      "$KA_TIMER_DST"
deploy_one "$KILLMODE_CONF" "$KILLMODE_CONF_DST"

printf '=== deploy-units: daemon-reload + enable on %s ===\n' "$CB_HOST"
# shellcheck disable=SC2086
ssh $CB_SSH_OPTS "$CB_HOST" \
  "sudo systemctl daemon-reload && sudo systemctl enable crewboss-launcher crewboss-loop-keepalive.timer"

printf 'done. FIELD-TEST REQUIRED: confirm launcher PID persists across a manual keepalive tick.\n'
