#!/usr/bin/env bash
# 1144-launcher-service.test.sh — charter #1144 (deploy-contract, qa-engineer leaf #1267).
#
# Pins the deploy-contract for the crewboss-launcher.service refactor. On 2026-06-30→07-01
# the launcher loop stayed dead for hours: crewboss-loop-keepalive.service was Type=oneshot
# and spawned the launcher via `nohup … &`; without KillMode=process systemd tore down the
# service cgroup on ExecStart exit and killed the just-spawned launcher — an infinite
# restart-kill every 5 min. The proper fix (charter #1144): run the launcher as a dedicated
# crewboss-launcher.service (Restart=always, sources run-env.sh); reduce keepalive
# start_loop() to `systemctl start crewboss-launcher`; version-control all units in
# reference/runtime/; add this deploy-contract test.
#
# This is a TESTS-FIRST suite: the infra-engineer implementation leaf has not necessarily
# landed yet. Assertions against the not-yet-existing unit files / keepalive seam are
# EXPECTED to FAIL (RED) until the implementation leaf merges into charter/1144. That
# ordering is intentional. Do NOT weaken these assertions to make them pass against the
# current tree.
#
# EXCLUDED (per-leaf-manifest): CONTRACT-2a sources keepalive.sh and invokes start_loop()
#   in a child process — subprocess-spawn pattern, same class as 1073-keepalive-singletick.
#
# ─────────────────────────────────────────────────────────────────────────────
# FIELD-TEST REQUIRED post-deploy: confirm launcher PID persists across a manual keepalive
# service tick on the box. This is the root-cause fix (cgroup isolation via systemd unit)
# and requires real systemd cgroup teardown — cannot be reproduced in CI.
# ─────────────────────────────────────────────────────────────────────────────
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
RUNTIME="$HERE/../runtime"
MANIFEST_TSV="$HERE/../runtime-manifest.tsv"
KEEPALIVE="$RUNTIME/crewboss-loop-keepalive.sh"

LAUNCHER_SVC="$RUNTIME/crewboss-launcher.service"
KA_SVC="$RUNTIME/crewboss-loop-keepalive.service"
KA_TIMER="$RUNTIME/crewboss-loop-keepalive.timer"
KILLMODE_CONF="$RUNTIME/crewboss-loop-keepalive-killmode.conf"
DEPLOY_UNITS="$RUNTIME/deploy-units.sh"

# The four unit-file basenames deployed to /etc/systemd/system/ — must NEVER appear in
# the runtime manifest (OPTION (b): deploy-runtime.sh's manifest scp loop copies to
# ~/cbnet/ only — the wrong place for units; crewboss-api.service precedent).
UNIT_BASENAMES=(
  crewboss-launcher.service
  crewboss-loop-keepalive.service
  crewboss-loop-keepalive.timer
  crewboss-loop-keepalive-killmode.conf
)

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"; pkill -P $$ 2>/dev/null; true' EXIT

pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

# ═════════════════════════════════════════════════════════════════════════════
# UNIT-1: crewboss-launcher.service exists; Restart=always; sources run-env.sh; execs
#         crewboss-launcher-gh.sh.
# ═════════════════════════════════════════════════════════════════════════════
echo "=== UNIT-1: crewboss-launcher.service (Restart=always, run-env.sh, crewboss-launcher-gh.sh) ==="
if [ ! -f "$LAUNCHER_SVC" ]; then
  ko "UNIT-1: $LAUNCHER_SVC is ABSENT — infra leaf has not landed (RED until then)"
else
  grep -q 'Restart=always' "$LAUNCHER_SVC" \
    && ok "UNIT-1: contains Restart=always" \
    || ko "UNIT-1: missing Restart=always"
  grep -q 'run-env.sh' "$LAUNCHER_SVC" \
    && ok "UNIT-1: sources run-env.sh" \
    || ko "UNIT-1: does not reference run-env.sh"
  grep -q 'crewboss-launcher-gh.sh' "$LAUNCHER_SVC" \
    && ok "UNIT-1: execs crewboss-launcher-gh.sh" \
    || ko "UNIT-1: does not reference crewboss-launcher-gh.sh"
fi

# ═════════════════════════════════════════════════════════════════════════════
# UNIT-2: keepalive .service (Type=oneshot) and .timer (OnUnitActiveSec) exist.
# ═════════════════════════════════════════════════════════════════════════════
echo "=== UNIT-2: crewboss-loop-keepalive.service (Type=oneshot) + .timer (OnUnitActiveSec) ==="
if [ ! -f "$KA_SVC" ]; then
  ko "UNIT-2: $KA_SVC is ABSENT — infra leaf has not landed (RED until then)"
else
  grep -q 'Type=oneshot' "$KA_SVC" \
    && ok "UNIT-2: keepalive.service is Type=oneshot" \
    || ko "UNIT-2: keepalive.service missing Type=oneshot"
fi
if [ ! -f "$KA_TIMER" ]; then
  ko "UNIT-2: $KA_TIMER is ABSENT — infra leaf has not landed (RED until then)"
else
  grep -q 'OnUnitActiveSec' "$KA_TIMER" \
    && ok "UNIT-2: keepalive.timer sets OnUnitActiveSec" \
    || ko "UNIT-2: keepalive.timer missing OnUnitActiveSec"
fi

# ═════════════════════════════════════════════════════════════════════════════
# UNIT-3: killmode drop-in exists; KillMode=process.
# ═════════════════════════════════════════════════════════════════════════════
echo "=== UNIT-3: crewboss-loop-keepalive-killmode.conf (KillMode=process) ==="
if [ ! -f "$KILLMODE_CONF" ]; then
  ko "UNIT-3: $KILLMODE_CONF is ABSENT — infra leaf has not landed (RED until then)"
else
  grep -q 'KillMode=process' "$KILLMODE_CONF" \
    && ok "UNIT-3: killmode drop-in contains KillMode=process" \
    || ko "UNIT-3: killmode drop-in missing KillMode=process"
fi

# ═════════════════════════════════════════════════════════════════════════════
# UNIT-4: deploy-units.sh exists; references all four unit files and /etc/systemd/system/.
# ═════════════════════════════════════════════════════════════════════════════
echo "=== UNIT-4: deploy-units.sh (references 4 units + /etc/systemd/system/) ==="
if [ ! -f "$DEPLOY_UNITS" ]; then
  ko "UNIT-4: $DEPLOY_UNITS is ABSENT — infra leaf has not landed (RED until then)"
else
  grep -q '/etc/systemd/system/' "$DEPLOY_UNITS" \
    && ok "UNIT-4: deploy-units.sh targets /etc/systemd/system/" \
    || ko "UNIT-4: deploy-units.sh does not reference /etc/systemd/system/"
  for _u in "${UNIT_BASENAMES[@]}"; do
    grep -qF "$_u" "$DEPLOY_UNITS" \
      && ok "UNIT-4: deploy-units.sh references $_u" \
      || ko "UNIT-4: deploy-units.sh does NOT reference $_u"
  done
fi

# ═════════════════════════════════════════════════════════════════════════════
# CONTRACT-1: keepalive start_loop() uses the CREWBOSS_LAUNCHER_UNIT env-override seam to
#             route to `systemctl start` when the unit is present, else fall back to nohup.
#             Static grep of the updated keepalive.sh for the conditional.
# ═════════════════════════════════════════════════════════════════════════════
echo "=== CONTRACT-1: keepalive.sh start_loop() has CREWBOSS_LAUNCHER_UNIT seam -> systemctl start ==="
if [ ! -f "$KEEPALIVE" ]; then
  ko "CONTRACT-1: $KEEPALIVE is ABSENT (RED until then)"
else
  grep -q 'CREWBOSS_LAUNCHER_UNIT' "$KEEPALIVE" \
    && ok "CONTRACT-1: keepalive.sh references CREWBOSS_LAUNCHER_UNIT env-override seam" \
    || ko "CONTRACT-1: keepalive.sh has NO CREWBOSS_LAUNCHER_UNIT seam (still nohup-only)"
  grep -Eq 'systemctl[[:space:]]+start[[:space:]]+crewboss-launcher' "$KEEPALIVE" \
    && ok "CONTRACT-1: keepalive.sh calls 'systemctl start crewboss-launcher'" \
    || ko "CONTRACT-1: keepalive.sh does NOT call 'systemctl start crewboss-launcher'"
fi

# ═════════════════════════════════════════════════════════════════════════════
# CONTRACT-2a (CI-testable): call routing. With the unit-file PRESENT, start_loop() must
#   invoke `systemctl start crewboss-launcher` and must NOT invoke nohup bash. We stub
#   both systemctl and nohup on PATH (recording), point CREWBOSS_LAUNCHER_UNIT at a
#   touched file in the test tmpdir (unit-present without sudo), source keepalive.sh in a
#   CHILD process and invoke start_loop(). Proves call routing, not cgroup isolation.
# ═════════════════════════════════════════════════════════════════════════════
echo "=== CONTRACT-2a: unit present -> start_loop() routes to 'systemctl start', NOT nohup ==="
if [ ! -f "$KEEPALIVE" ]; then
  ko "CONTRACT-2a: $KEEPALIVE is ABSENT (RED until then)"
else
  STUBDIR="$ROOT/bin";           mkdir -p "$STUBDIR"
  SYSCTL_LOG="$ROOT/systemctl.log"
  NOHUP_LOG="$ROOT/nohup.log"
  : > "$SYSCTL_LOG"; : > "$NOHUP_LOG"

  # Recording systemctl stub.
  cat > "$STUBDIR/systemctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SYSCTL_LOG"
exit 0
EOF
  # Recording nohup stub (must NOT be invoked when the unit is present).
  cat > "$STUBDIR/nohup" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$NOHUP_LOG"
exit 0
EOF
  chmod +x "$STUBDIR/systemctl" "$STUBDIR/nohup"

  # unit-present WITHOUT sudo: a touched file in the tmpdir the env-override seam points at.
  FAKE_UNIT="$ROOT/fake-unit.service"; : > "$FAKE_UNIT"

  HOME_DIR="$ROOT/home"; CBHOME="$HOME_DIR/cbnet"
  mkdir -p "$CBHOME/run"

  # Source keepalive.sh + invoke start_loop() in a CHILD process, so a source-time `exit`
  # in the script (current tail runs single_tick; exit 0) cannot terminate this test — the
  # recorded side-effects persist in the log files either way. Routing verdict = f(logs).
  PATH="$STUBDIR:$PATH" HOME="$HOME_DIR" CB_HOME="$CBHOME" CB_REPO="test/repo" \
    CREWBOSS_LAUNCHER_UNIT="$FAKE_UNIT" CB_NO_INTEGRATE=1 CREWBOSS_CHARTER= \
    bash -c 'set -a; . "$1"; start_loop' _ "$KEEPALIVE" >>"$ROOT/c2a.log" 2>&1 || true

  if grep -Eq 'start[[:space:]]+crewboss-launcher' "$SYSCTL_LOG"; then
    ok "CONTRACT-2a: start_loop() invoked 'systemctl start crewboss-launcher' (unit present)"
  else
    ko "CONTRACT-2a: 'systemctl start crewboss-launcher' NOT recorded — got: $(tr '\n' '|' < "$SYSCTL_LOG")"
  fi
  if [ -s "$NOHUP_LOG" ]; then
    ko "CONTRACT-2a: nohup WAS invoked despite unit present — got: $(tr '\n' '|' < "$NOHUP_LOG")"
  else
    ok "CONTRACT-2a: nohup NOT invoked (routing bypassed the cgroup-killing nohup path)"
  fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# MANIFEST-EXCLUSION: none of the four unit basenames may appear in runtime-manifest.tsv
#   (regression guard for the manifest-scp conflict — units would be copied to ~/cbnet/,
#   the wrong place).
# ═════════════════════════════════════════════════════════════════════════════
echo "=== MANIFEST-EXCLUSION: four unit basenames absent from runtime-manifest.tsv ==="
if [ ! -f "$MANIFEST_TSV" ]; then
  ko "MANIFEST-EXCLUSION: $MANIFEST_TSV not found"
else
  for _u in "${UNIT_BASENAMES[@]}"; do
    if grep -qF "$_u" "$MANIFEST_TSV"; then
      ko "MANIFEST-EXCLUSION: $_u appears in runtime-manifest.tsv (manifest-scp conflict)"
    else
      ok "MANIFEST-EXCLUSION: $_u absent from runtime-manifest.tsv"
    fi
  done
fi

echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
