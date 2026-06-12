#!/usr/bin/env bash
# run-env-contract.test.sh — T1+T6: env contract delivered to the run loop.
#
# Stubs model reality (lesson P1): isolated HOME, stub `gh` (auth token → FAKETOKEN),
# fake ~/.crewboss.env, stub launcher at $HOME/cbnet/crewboss-launcher-gh.sh that dumps
# the ACTUAL received env to a file. Dump file is waited for with a poll loop + deadline
# (no fixed sleep).
#
# Cases:
#   A  run-charter.sh    — CB_GIT_REMOTE set, CB_MAX_TICKS>=1800, CB_MAX_PARALLEL=4,
#                          CB_SPAWN ends with charter-leaf-prep.sh, CB_PLAN_SPAWN set,
#                          CB_HOME=$HOME/cbnet
#   B  start-stack.sh with-loop — same assertions (catches the finding where start-stack.sh
#                          did not export CB_GIT_REMOTE/CB_SPAWN/CB_PLAN_SPAWN, #142 #1/#2)
#   C  CB_NO_INTEGRATE=1 — CB_GIT_REMOTE empty in dump (D2 opt-out)
#
# RED-0: run-env.sh absent  → test file not sourceable → all fail.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
RUNTIME="$HERE/../runtime"

pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$*"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$*"; }

# ── isolated environment ──────────────────────────────────────────────────────
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
FAKE_HOME="$ROOT/home"
mkdir -p "$FAKE_HOME/cbnet" "$FAKE_HOME/bin"

# stub gh: `auth token` → FAKETOKEN (only subcommand tested here)
cat > "$FAKE_HOME/bin/gh" <<'GHSTUB'
#!/usr/bin/env bash
if [ "${1:-}" = "auth" ] && [ "${2:-}" = "token" ]; then
  echo "FAKETOKEN"
  exit 0
fi
exit 0
GHSTUB
chmod +x "$FAKE_HOME/bin/gh"

# fake ~/.crewboss.env (empty — token comes from stub gh above)
touch "$FAKE_HOME/.crewboss.env"

# stub launcher: dumps actual received env to a file, then exits
cat > "$FAKE_HOME/cbnet/crewboss-launcher-gh.sh" <<'LAUNCHSTUB'
#!/usr/bin/env bash
# stub launcher: record actual env, exit immediately
{
  echo "CB_REPO=$CB_REPO"
  echo "CB_HOME=$CB_HOME"
  echo "CB_MAX_TICKS=$CB_MAX_TICKS"
  echo "CB_MAX_PARALLEL=$CB_MAX_PARALLEL"
  echo "CB_TASK_TIMEOUT=$CB_TASK_TIMEOUT"
  echo "CB_SPAWN=$CB_SPAWN"
  echo "GH_TOKEN=$GH_TOKEN"
  echo "CB_GIT_REMOTE=$CB_GIT_REMOTE"
  echo "CB_PLAN_SPAWN=$CB_PLAN_SPAWN"
  echo "CB_HARNESS=$CB_HARNESS"
  echo "CB_GATE_REPO_DIR=$CB_GATE_REPO_DIR"
} > "$HOME/cbnet/env-dump.txt"
LAUNCHSTUB
chmod +x "$FAKE_HOME/cbnet/crewboss-launcher-gh.sh"

# ── helpers ───────────────────────────────────────────────────────────────────
# wait_file: poll until file exists or deadline (default 5s, 100ms intervals)
wait_file(){
  local f="$1" deadline="${2:-5}" i=0 max
  max=$(( deadline * 10 ))
  while [ ! -f "$f" ] && [ "$i" -lt "$max" ]; do
    sleep 0.1; i=$((i+1))
  done
  [ -f "$f" ]
}

getvar(){
  local dump="$1" key="$2"
  grep "^${key}=" "$dump" | cut -d= -f2-
}

# run_case <label> <script> [extra_args...]
# Clears dump + pid, runs script with isolated env, waits for dump, runs assertions.
run_case(){
  local label="$1" script="$2"; shift 2
  local args=("$@")
  local dump="$FAKE_HOME/cbnet/env-dump.txt"
  local pidfile="$FAKE_HOME/cbnet/run/launcher.pid"

  rm -f "$dump" "$pidfile"
  HOME="$FAKE_HOME" PATH="$FAKE_HOME/bin:$PATH" \
    bash "$script" "${args[@]:-}" >/dev/null 2>&1

  if ! wait_file "$dump"; then
    ko "$label: stub launcher not invoked (env-dump.txt not created)"
    return 1
  fi

  local val

  # CB_GIT_REMOTE contains github.com/stratch1989/crewboss
  val="$(getvar "$dump" CB_GIT_REMOTE)"
  if printf '%s' "$val" | grep -q "github.com/stratch1989/crewboss"; then
    ok "$label: CB_GIT_REMOTE contains github.com/stratch1989/crewboss"
  else
    ko "$label: CB_GIT_REMOTE='$val' missing github.com/stratch1989/crewboss"
  fi

  # CB_MAX_TICKS >= 1800 (T6)
  val="$(getvar "$dump" CB_MAX_TICKS)"
  if [ -n "$val" ] && [ "$val" -ge 1800 ] 2>/dev/null; then
    ok "$label: CB_MAX_TICKS=$val >= 1800 (T6)"
  else
    ko "$label: CB_MAX_TICKS='$val' not >= 1800"
  fi

  # CB_MAX_PARALLEL = 4 (#142 finding #2: launcher default is 2; contract is 4)
  val="$(getvar "$dump" CB_MAX_PARALLEL)"
  if [ "$val" = "4" ]; then
    ok "$label: CB_MAX_PARALLEL=4"
  else
    ko "$label: CB_MAX_PARALLEL='$val' != 4"
  fi

  # CB_SPAWN ends with charter-leaf-prep.sh
  val="$(getvar "$dump" CB_SPAWN)"
  case "$val" in
    *charter-leaf-prep.sh) ok "$label: CB_SPAWN ends with charter-leaf-prep.sh" ;;
    *) ko "$label: CB_SPAWN='$val' does not end with charter-leaf-prep.sh" ;;
  esac

  # CB_PLAN_SPAWN is set
  val="$(getvar "$dump" CB_PLAN_SPAWN)"
  if [ -n "$val" ]; then
    ok "$label: CB_PLAN_SPAWN is set"
  else
    ko "$label: CB_PLAN_SPAWN unset"
  fi

  # CB_HOME = $FAKE_HOME/cbnet
  val="$(getvar "$dump" CB_HOME)"
  if [ "$val" = "$FAKE_HOME/cbnet" ]; then
    ok "$label: CB_HOME=\$HOME/cbnet"
  else
    ko "$label: CB_HOME='$val' != '$FAKE_HOME/cbnet'"
  fi
}

# ── Case A: run-charter.sh ────────────────────────────────────────────────────
echo "== Case A: run-charter.sh =="
run_case "A" "$RUNTIME/run-charter.sh"

# ── Case B: start-stack.sh with-loop ─────────────────────────────────────────
echo "== Case B: start-stack.sh with-loop =="
run_case "B" "$RUNTIME/start-stack.sh" "with-loop"

# ── Case C: CB_NO_INTEGRATE=1 → CB_GIT_REMOTE empty (D2 opt-out) ─────────────
echo "== Case C: CB_NO_INTEGRATE=1 =="
dump="$FAKE_HOME/cbnet/env-dump.txt"
pidfile="$FAKE_HOME/cbnet/run/launcher.pid"
rm -f "$dump" "$pidfile"
HOME="$FAKE_HOME" PATH="$FAKE_HOME/bin:$PATH" CB_NO_INTEGRATE=1 \
  bash "$RUNTIME/run-charter.sh" >/dev/null 2>&1
if wait_file "$dump"; then
  val="$(getvar "$dump" CB_GIT_REMOTE)"
  if [ -z "$val" ]; then
    ok "C: CB_GIT_REMOTE empty with CB_NO_INTEGRATE=1"
  else
    ko "C: CB_GIT_REMOTE='$val' should be empty when CB_NO_INTEGRATE=1"
  fi
else
  ko "C: stub launcher not invoked"
fi

# ── summary ───────────────────────────────────────────────────────────────────
echo
echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
