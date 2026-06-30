#!/usr/bin/env bash
# crewboss-loop-keepalive.sh — charter #1073, leaf #1098 (infra-engineer).
#
# Restart the launcher loop iff it has GENUINELY died. LOOP-ONLY (the API is managed
# by systemd crewboss-api.service). Runs from a systemd timer every 5 min — each
# invocation performs exactly ONE tick (single-tick) and exits.
#
# This is the box-only keepalive brought under version control + made unit-testable.
# The qa leaf's tests (#1095) exec/source THIS file:
#   reference/tests/1073-keepalive-singletick.test.sh   (live/stale/absent + root-A)
#   reference/tests/1073-recovery.test.sh               (genuine-dead -> exactly one)
#
# ─ Defects this script closes (charter #1073) ────────────────────────────────
# Root A — lock-path divergence (the 4-loops symptom).
#   crewboss-launcher-gh.sh defaults CB_HOME=/tmp/cbnet -> LOCK=/tmp/cbnet/run/launcher.lock.
#   Operator `run` sources run-env.sh which sets CB_HOME=$HOME/cbnet. If keepalive starts
#   the loop WITHOUT that env contract, the keepalive loop and operator loop hold DIFFERENT
#   lock files -> `flock -n` cannot serialize them -> multiple concurrent loops.
#   FIX: keepalive starts the loop THROUGH the same env contract (source run-env.sh /
#   CB_HOME=$HOME/cbnet) so launcher.lock is the SAME file in both start paths.
#
# Root C — non-atomic liveness.
#   `pgrep -f` has a race window between "empty" and "start"; two ticks (or tick + operator
#   run) both start. The authoritative liveness signal is $RUN/launcher.pid (+ kill -0),
#   written UNDER the launcher flock by the launcher leaf (#1096).
#   FIX: decide liveness from launcher.pid + kill -0, NOT pgrep; and serialize the whole
#   check-and-start under a DEDICATED keepalive lock (NOT the launcher lock) so only ONE
#   start can fire per race window.
#
# Recovery contract: a genuinely dead loop (stale/absent pid) MUST still trigger exactly
# one restart; the system is never left loop-less.
#
# Modes:
#   (default)            — one tick, then exit (systemd-timer invocation).
#   --once / --single-tick / CB_KEEPALIVE_ONCE=1 — explicit single-tick (unit-callable).
#   --dry-run / CB_KEEPALIVE_DRY_RUN=1            — decide + log, but do NOT start a loop.
set -u

# ── 0) Args ──────────────────────────────────────────────────────────────────
ONCE="${CB_KEEPALIVE_ONCE:-0}"
DRY_RUN="${CB_KEEPALIVE_DRY_RUN:-0}"
for arg in "$@"; do
  case "$arg" in
    --once|--single-tick) ONCE=1 ;;
    --dry-run|--dry_run)  DRY_RUN=1 ;;
    *) ;;
  esac
done

# ── 1) Env contract — root A: resolve CB_HOME exactly like operator `run` ─────
# HOME must be concrete so run-env.sh resolves CB_HOME=$HOME/cbnet (systemd/cron env
# may not export HOME). Tests inject HOME explicitly; honour it.
export HOME="${HOME:-/home/ec2-user}"
# Provisional CB_HOME so we can locate run-env.sh (run-env.sh re-exports the canonical
# CB_HOME=$HOME/cbnet, closing the /tmp/cbnet divergence).
: "${CB_HOME:=$HOME/cbnet}"

RUN_ENV="$CB_HOME/run-env.sh"
if [ -f "$RUN_ENV" ]; then
  # set -a so every var run-env.sh exports (CB_HOME, CB_REPO, GH_TOKEN, …) reaches the
  # launcher we spawn — same full contract the operator `run` and the API daemon build.
  # shellcheck source=/dev/null
  set -a; . "$RUN_ENV"; set +a
fi
# After sourcing, CB_HOME == $HOME/cbnet (root-A guarantee). Fall back defensively.
: "${CB_HOME:=$HOME/cbnet}"

RUN="$CB_HOME/run"
PIDF="$RUN/launcher.pid"
LAUNCHER="$CB_HOME/crewboss-launcher-gh.sh"
KEEPALIVE_LOCK="$RUN/keepalive.lock"   # DEDICATED keepalive lock (NOT launcher.lock)
LOG="${CB_KEEPALIVE_LOG:-$RUN/keepalive.out}"

mkdir -p "$RUN" 2>/dev/null || true

ts()  { date -u +%FT%TZ 2>/dev/null || echo "?"; }
log() { printf '[%s] %s\n' "$(ts)" "$1" >> "$LOG" 2>/dev/null || true; }

# ── 2) Atomic liveness — root C: launcher.pid + kill -0, NOT pgrep ───────────
# The launcher writes $RUN/launcher.pid UNDER its flock (leaf #1096); a live, signalable
# pid is the authoritative "loop is alive" signal. Absent file or dead/empty pid = dead.
loop_alive() {
  local pid
  [ -f "$PIDF" ] || return 1
  pid="$(cat "$PIDF" 2>/dev/null)"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null
}

# ── 3) Start exactly one loop THROUGH the shared env contract (root A) ────────
# Direct, self-sufficient launch: run-env.sh was sourced above, so the spawned loop
# rebuilds the FULL env (incl. ~/.crewboss.env tokens) and targets the SAME
# $CB_HOME/run/launcher.lock the operator `run` targets. nohup + background so the tick
# returns; the launcher writes launcher.pid under its own flock.
start_loop() {
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY-RUN: would start loop -> $LAUNCHER run (CB_HOME=$CB_HOME)"
    printf 'DRY-RUN would-start CB_HOME=%s\n' "$CB_HOME"
    return 0
  fi
  nohup bash "$LAUNCHER" run >> "$RUN/launcher.out" 2>&1 &
  log "loop DOWN -> direct launch pid $! (CB_HOME=$CB_HOME)"
}

# ── 4) Serialize the restart decision under the dedicated keepalive lock ──────
# The check-and-start runs INSIDE flock on keepalive.lock so two racing ticks (or a tick
# racing an operator run) cannot both pass the liveness check and both start a loop. The
# lock is held only for the (fast) decision, then released as the subshell exits.
single_tick() {
  (
    exec {kfd}>"$KEEPALIVE_LOCK" || exit 0
    if ! flock -n "$kfd"; then
      log "another keepalive tick holds the lock — skip"
      exit 0
    fi
    # Re-evaluate liveness UNDER the lock (atomic check-and-start).
    if loop_alive; then
      log "loop alive (launcher.pid=$(cat "$PIDF" 2>/dev/null)) — nothing to do"
      exit 0
    fi
    # Genuinely dead (stale/absent pid): restart EXACTLY one — never leave it loop-less.
    start_loop
  )
}

# ── 5) Drive one tick ────────────────────────────────────────────────────────
# Every invocation (timer, --once, --single-tick) performs exactly one tick.
single_tick
exit 0
