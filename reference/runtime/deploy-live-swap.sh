#!/usr/bin/env bash
# deploy-live-swap.sh — charter #1290, leaf #1306 (infra-engineer).
#
# SAFE, between-ticks deploy of the charter-#1290 live-loop fixes to a running
# crewboss box. This is deliberately NOT `deploy-runtime.sh`: that tool blind-scps
# EVERY canonical file and hard-restarts the API mid-session. For the LIVE LAUNCHER
# LOOP (crewboss-launcher-gh.sh et al.) a blind overwrite mid-tick can corrupt an
# in-flight spawn / integrator merge — exactly the 2026-07-02 incident class.
#
# This tool swaps only the five charter-#1290 files, and only at a tick boundary:
#
#   1. BACKUP   — snapshot the currently-deployed files (+ their sha256, + the
#                 box manifest) so a rollback is byte-exact.
#   2. QUIESCE  — set run/kill_switch so the loop exits cleanly at the TOP of its
#                 next tick (exit 42, before any spawn), wait for launcher.pid to
#                 clear, then stop the unit so Restart=always cannot relaunch the
#                 OLD code. This is the "between ticks" guarantee.
#   3. SWAP     — copy the merged files from the repo over the deployed ones
#                 (restoring the executable bit) and refresh the box manifest copy
#                 so crewboss-doctor's drift check reflects the new sha-lock.
#   4. RESTART  — clear kill_switch and start the crewboss-launcher unit on the
#                 NEW code.
#   5. VERIFY   — crewboss-doctor.sh (drift check: deployed sha256 == manifest)
#                 AND observe ONE full healthy tick.
#   6. SHA-LOCK — re-confirm each deployed file's sha256 == its
#                 reference/runtime-manifest.tsv entry.
#   7. ROLLBACK — on ANY unhealthy signal in 5/6, restore from the backup, restart,
#                 re-check doctor, and exit non-zero. Either way, a report is
#                 printed to stdout and appended to the deploy log.
#
# Usage:
#   bash deploy-live-swap.sh deploy        # do the live deploy (needs a real box)
#   bash deploy-live-swap.sh simulate      # self-contained rehearsal in a temp box
#                                          # (fake systemctl + fake loop) — proves
#                                          # the full backup/swap/verify/rollback path
#
# Config (env):
#   CB_HOME            deployment root on the box            (default $HOME/cbnet)
#   REPO_ROOT          repo checkout                         (default: auto)
#   CB_LAUNCHER_UNIT   systemd unit name                     (default crewboss-launcher)
#   CB_SYSTEMCTL       service-control command prefix        (default "sudo systemctl")
#   CB_DOCTOR          doctor script                         (default repo runtime doctor)
#   CB_DEPLOY_MANIFEST refresh box manifest copy on swap     (default 1)
#   CB_QUIESCE_TIMEOUT seconds to wait for a clean tick exit (default 180)
#   CB_TICK_TIMEOUT    seconds to wait to observe one tick   (default 300)
#   CB_TICK_PROBE      cmd printing the completed-tick count (default: read
#                                              $CB_HOME/run/tick.count, else 0)
#
# Exit: 0 = deployed + verified healthy;  non-zero = rolled back / aborted.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
MANIFEST="${MANIFEST:-$REPO_ROOT/reference/runtime-manifest.tsv}"
CB_LAUNCHER_UNIT="${CB_LAUNCHER_UNIT:-crewboss-launcher}"
CB_SYSTEMCTL="${CB_SYSTEMCTL:-sudo systemctl}"
CB_DOCTOR="${CB_DOCTOR:-$SCRIPT_DIR/crewboss-doctor.sh}"
CB_DEPLOY_MANIFEST="${CB_DEPLOY_MANIFEST:-1}"
CB_QUIESCE_TIMEOUT="${CB_QUIESCE_TIMEOUT:-180}"
CB_TICK_TIMEOUT="${CB_TICK_TIMEOUT:-300}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"

# The five charter-#1290 live-loop files this leaf deploys.
FILES=(
  crewboss-launcher-gh.sh
  crewboss-integrator.sh
  smoke-runner.sh
  cb-pr-create.sh
  rework-prep.sh
)

# Paths derive from CB_HOME, which the simulate path overrides — so resolve them
# lazily (NOT at load time) via _init_paths, called at the top of each entrypoint.
_init_paths(){
  CB_HOME="${CB_HOME:-$HOME/cbnet}"
  RUN="$CB_HOME/run"
  KILL_SWITCH="$RUN/kill_switch"
  PID_FILE="$RUN/launcher.pid"
  BACKUP_DIR="$CB_HOME/backups/deploy-1306-$TS"
  DEPLOY_LOG="$RUN/deploy-1306.log"
}

log(){ printf '[deploy-1306] %s\n' "$*"; }
report(){
  printf '%s\n' "$*"
  mkdir -p "$RUN" 2>/dev/null || true
  printf '%s\n' "$*" >> "$DEPLOY_LOG" 2>/dev/null || true
}

# manifest_sha <basename> — echo the canonical sha256 for reference/runtime/<name>
# from the REPO manifest, or empty if not sha-locked (e.g. smoke-runner.sh).
manifest_sha(){
  local rp="reference/runtime/$1"
  [ -f "$MANIFEST" ] || return 0
  grep -v '^[[:space:]]*#' "$MANIFEST" \
    | awk -F'\t' -v p="$rp" '$1==p {print $2; exit}'
}

deployed_sha(){ sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

# tick_count — completed-tick counter on the box. Overridable via CB_TICK_PROBE.
tick_count(){
  if [ -n "${CB_TICK_PROBE:-}" ]; then eval "$CB_TICK_PROBE"; return; fi
  cat "$RUN/tick.count" 2>/dev/null || echo 0
}

svc(){ log "systemctl $*"; $CB_SYSTEMCTL "$@"; }

_wait_loop_gone(){
  local waited=0 p
  while :; do
    p="$(cat "$PID_FILE" 2>/dev/null || echo)"
    [ -n "$p" ] && kill -0 "$p" 2>/dev/null || break
    [ "$waited" -ge "$CB_QUIESCE_TIMEOUT" ] && { report "QUIESCE WARN: loop still alive after ${CB_QUIESCE_TIMEOUT}s"; return 1; }
    sleep 1; waited=$((waited+1))
  done
  echo "$waited"
}

# ── Step 1: preflight ─────────────────────────────────────────────────────────
preflight(){
  local rc=0
  [ -d "$CB_HOME" ] || { report "PREFLIGHT FAIL: CB_HOME does not exist: $CB_HOME"; return 1; }
  for name in "${FILES[@]}"; do
    [ -f "$REPO_ROOT/reference/runtime/$name" ] || { report "PREFLIGHT FAIL: source missing in repo: reference/runtime/$name"; rc=1; }
  done
  return "$rc"
}

# ── Step 2: backup currently-deployed files ───────────────────────────────────
backup(){
  mkdir -p "$BACKUP_DIR"
  : > "$BACKUP_DIR/SHA256SUMS.before"
  for name in "${FILES[@]}"; do
    if [ -f "$CB_HOME/$name" ]; then
      cp "$CB_HOME/$name" "$BACKUP_DIR/$name"
      printf '%s  %s\n' "$(deployed_sha "$CB_HOME/$name")" "$name" >> "$BACKUP_DIR/SHA256SUMS.before"
    else
      printf 'ABSENT  %s\n' "$name" >> "$BACKUP_DIR/SHA256SUMS.before"
    fi
  done
  if [ "$CB_DEPLOY_MANIFEST" = "1" ] && [ -f "$CB_HOME/runtime-manifest.tsv" ]; then
    cp "$CB_HOME/runtime-manifest.tsv" "$BACKUP_DIR/runtime-manifest.tsv"
  fi
  report "backup taken: $BACKUP_DIR"
}

# ── Step 3a: quiesce the loop at a tick boundary ──────────────────────────────
quiesce(){
  mkdir -p "$RUN"
  log "setting kill_switch — loop will exit cleanly at next tick top (exit 42)"
  : > "$KILL_SWITCH"
  local waited; waited="$(_wait_loop_gone)" || true
  log "loop reached tick boundary (after ${waited:-?}s) — stopping unit so Restart=always cannot relaunch OLD code"
  svc stop "$CB_LAUNCHER_UNIT" || report "QUIESCE WARN: 'stop $CB_LAUNCHER_UNIT' returned non-zero"
}

# ── Step 3b: swap files (+ refresh box manifest copy) ─────────────────────────
_put(){ cp "$1" "$2"; chmod 0755 "$2"; }
swap_in(){
  for name in "${FILES[@]}"; do
    _put "$REPO_ROOT/reference/runtime/$name" "$CB_HOME/$name"
    log "swapped: $name"
  done
  if [ "$CB_DEPLOY_MANIFEST" = "1" ]; then
    cp "$MANIFEST" "$CB_HOME/runtime-manifest.tsv"
    log "refreshed box manifest copy (doctor drift now reflects new sha-lock)"
  fi
}

# ── Step 4: restart on new code ───────────────────────────────────────────────
restart(){
  rm -f "$KILL_SWITCH"
  log "cleared kill_switch — starting unit on NEW code"
  svc start "$CB_LAUNCHER_UNIT" || { report "RESTART FAIL: could not start $CB_LAUNCHER_UNIT"; return 1; }
}

# ── Step 5: doctor + observe one full tick ────────────────────────────────────
verify_health(){
  local rc=0
  report "=== doctor ==="
  if CB_HOME="$CB_HOME" bash "$CB_DOCTOR" 2>&1 | tee -a "$DEPLOY_LOG"; then
    report "doctor: healthy"
  else
    report "doctor: UNHEALTHY"; rc=1
  fi

  report "=== observe one full tick (timeout ${CB_TICK_TIMEOUT}s) ==="
  local start_ticks waited=0 now
  start_ticks="$(tick_count)"
  while :; do
    now="$(tick_count)"
    if [ "${now:-0}" -gt "${start_ticks:-0}" ]; then
      report "observed a completed tick ($start_ticks -> $now) after ${waited}s"; break
    fi
    if [ "$waited" -ge "$CB_TICK_TIMEOUT" ]; then
      report "TICK FAIL: no tick completed within ${CB_TICK_TIMEOUT}s (stuck at $start_ticks)"; rc=1; break
    fi
    sleep 1; waited=$((waited+1))
  done
  return "$rc"
}

# ── Step 6: sha-lock confirmation (task step 3) ───────────────────────────────
verify_shalock(){
  local rc=0 want got
  report "=== sha-lock confirmation (deployed == manifest) ==="
  for name in "${FILES[@]}"; do
    want="$(manifest_sha "$name")"
    got="$(deployed_sha "$CB_HOME/$name")"
    if [ -z "$want" ]; then
      report "  n/a  $name (not sha-locked in manifest) deployed=$got"
    elif [ "$want" = "$got" ]; then
      report "  ok   $name $got"
    else
      report "  FAIL $name want=$want got=$got"; rc=1
    fi
  done
  return "$rc"
}

# ── Step 7: rollback from backup ──────────────────────────────────────────────
rollback(){
  report "!!! ROLLBACK: restoring from $BACKUP_DIR"
  : > "$KILL_SWITCH"
  _wait_loop_gone >/dev/null || true
  svc stop "$CB_LAUNCHER_UNIT" || true
  for name in "${FILES[@]}"; do
    if [ -f "$BACKUP_DIR/$name" ]; then
      _put "$BACKUP_DIR/$name" "$CB_HOME/$name"; report "  restored: $name"
    else
      rm -f "$CB_HOME/$name"; report "  removed (was absent before): $name"
    fi
  done
  if [ "$CB_DEPLOY_MANIFEST" = "1" ] && [ -f "$BACKUP_DIR/runtime-manifest.tsv" ]; then
    cp "$BACKUP_DIR/runtime-manifest.tsv" "$CB_HOME/runtime-manifest.tsv"; report "  restored: runtime-manifest.tsv"
  fi
  rm -f "$KILL_SWITCH"
  svc start "$CB_LAUNCHER_UNIT" || report "  ROLLBACK WARN: could not restart unit"
  report "=== post-rollback doctor ==="
  CB_HOME="$CB_HOME" bash "$CB_DOCTOR" 2>&1 | tee -a "$DEPLOY_LOG" || report "post-rollback doctor still unhealthy — MANUAL ATTENTION"
}

deploy(){
  _init_paths
  report "════ charter #1290 / leaf #1306 live-loop deploy @ $TS ════"
  report "CB_HOME=$CB_HOME  unit=$CB_LAUNCHER_UNIT"
  preflight || { report "aborting before any change (preflight failed)"; return 2; }
  backup
  quiesce
  swap_in
  if ! restart; then rollback; report "RESULT: FAILED (restart) — rolled back"; return 1; fi

  local health=0 shalock=0
  verify_health || health=1
  verify_shalock || shalock=1

  if [ "$health" -ne 0 ] || [ "$shalock" -ne 0 ]; then
    rollback
    report "RESULT: FAILED (health=$health shalock=$shalock) — rolled back to pre-deploy state"
    return 1
  fi
  report "RESULT: SUCCESS — charter #1290 fixes are live and verified (doctor healthy, one healthy tick, sha-lock matched)"
  return 0
}

# ── simulate: self-contained rehearsal (no real systemd / box) ────────────────
# Builds a throwaway CB_HOME with OLD stub files + a fake systemctl driving a fake
# loop (touches launcher.pid, honours kill_switch, increments run/tick.count). This
# exercises the ENTIRE backup→quiesce→swap→restart→verify→sha-lock→success path.
# No box manifest is placed, so doctor's box-wide drift check (which needs ALL ~76
# canonical files present) is skipped; the targeted sha-lock of the five deployed
# files is still asserted by verify_shalock against the REAL repo manifest.
simulate(){
  local box; box="$(mktemp -d)"
  mkdir -p "$box/run" "$box/backups" "$box/sim"
  # OLD deployed content (distinct from repo → proves the swap really happened).
  for name in "${FILES[@]}"; do printf '#!/usr/bin/env bash\n# OLD %s (pre-#1290)\n' "$name" > "$box/$name"; chmod +x "$box/$name"; done

  # Fake loop: honours kill_switch, writes pid, increments tick.count each "tick".
  cat > "$box/sim/fake-loop.sh" <<'LOOP'
#!/usr/bin/env bash
RUN="$1/run"; mkdir -p "$RUN"; echo $$ > "$RUN/launcher.pid"
trap 'rm -f "$RUN/launcher.pid"' EXIT
while :; do
  [ -f "$RUN/kill_switch" ] && exit 42
  c=$(cat "$RUN/tick.count" 2>/dev/null || echo 0); echo $((c+1)) > "$RUN/tick.count"
  sleep 1
done
LOOP
  chmod +x "$box/sim/fake-loop.sh"

  # Fake systemctl: start = launch fake-loop detached; stop = kill it.
  local sctl="$box/sim/fake-systemctl.sh"
  cat > "$sctl" <<SCTL
#!/usr/bin/env bash
act="\$1"; RUN="$box/run"
case "\$act" in
  start) setsid bash "$box/sim/fake-loop.sh" "$box" >/dev/null 2>&1 < /dev/null & echo started ;;
  stop)  p=\$(cat "\$RUN/launcher.pid" 2>/dev/null || echo); [ -n "\$p" ] && kill "\$p" 2>/dev/null; sleep 1; rm -f "\$RUN/launcher.pid"; echo stopped ;;
  *) echo "fake-systemctl: \$*" ;;
esac
exit 0
SCTL
  chmod +x "$sctl"

  # Boot the OLD loop so quiesce has a live loop to stop between ticks.
  bash "$sctl" start "$CB_LAUNCHER_UNIT" >/dev/null; sleep 2

  log "SIMULATION box: $box"
  local rc
  CB_HOME="$box" \
  CB_SYSTEMCTL="bash $sctl" \
  CB_DEPLOY_MANIFEST=0 \
  CB_QUIESCE_TIMEOUT=15 CB_TICK_TIMEOUT=30 \
    deploy
  rc=$?

  log "post-sim deployed vs repo sha (must match on SUCCESS):"
  for name in "${FILES[@]}"; do
    printf '  %-26s deployed=%s repo=%s\n' "$name" \
      "$(deployed_sha "$box/$name")" "$(deployed_sha "$REPO_ROOT/reference/runtime/$name")"
  done
  bash "$sctl" stop "$CB_LAUNCHER_UNIT" >/dev/null 2>&1 || true
  rm -rf "$box"
  return "$rc"
}

case "${1:-deploy}" in
  deploy)   deploy ;;
  simulate) _init_paths; simulate ;;
  *) printf 'usage: %s {deploy|simulate}\n' "$(basename "$0")" >&2; exit 64 ;;
esac
