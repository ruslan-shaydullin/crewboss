#!/usr/bin/env bash
#
# spawn-unit.test.sh — spawn primitive unit tests (issue #65, class a)
#
# Port of the r5 harness; two kinds of checks (honestly separated):
#
# PART A — GENUINE RED (per-task proxy socket / R9 epoch property):
#   Test checks whether the spawn script uses R9 role-based dispatch (--agent $ROLE).
#   Without role-based dispatch, the per-task proxy socket is not correctly scoped to
#   an agent role (R9 epoch property). proto/r5 uses --dangerously-skip-permissions
#   (no role) → per-task socket scoping is absent → RED.
#
#   SPAWN_OVERRIDE env var selects the spawn target:
#     SPAWN_OVERRIDE=proto/r5/crewboss-spawn.sh  → RED  (no --agent $ROLE)
#     (default)                                   → GREEN (reference/runtime has --agent $ROLE)
#
#   Red-log method: static analysis (grep the target script for the R9 marker pattern).
#   This avoids live jail/spend; nsjail is not available in CI.
#
# PART B — REGRESSION LOCKS (class a, no red-claim against proto/r5):
#   These properties are already present in proto/r5/crewboss-spawn.sh (lines 27/46/35
#   respectively). They are locked here so a future regression is caught in CI.
#   Their RED condition is the ABSENCE of these tests in CI (class e, absence-red).
#   Do NOT report pseudo-red logs for them in PRs.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

pass=0; fail=0
ok() { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

# Resolve spawn target (default: canonical backport)
if [ -n "${SPAWN_OVERRIDE:-}" ]; then
  # Allow relative or absolute path
  if [[ "${SPAWN_OVERRIDE}" = /* ]]; then
    SPAWN_TARGET="$SPAWN_OVERRIDE"
  else
    SPAWN_TARGET="$REPO_ROOT/$SPAWN_OVERRIDE"
  fi
else
  SPAWN_TARGET="$REPO_ROOT/reference/runtime/crewboss-spawn.sh"
fi

printf 'spawn target: %s\n' "$SPAWN_TARGET"

# ============================================================
# PART A: GENUINE RED — R9 per-task proxy socket / role dispatch
# ============================================================
echo "=== Part A: R9 per-task proxy socket / role dispatch ==="

if [ ! -f "$SPAWN_TARGET" ]; then
  no "spawn target not found: $SPAWN_TARGET"
else
  # The R9 epoch spawn passes the role to claude via --agent $ROLE.
  # This is the mechanism that correctly scopes the per-task proxy socket to an agent role.
  # proto/r5 uses `claude -p "..." --dangerously-skip-permissions` (no role, no --agent) →
  # the per-task socket exists in code but is not role-scoped → RED for R9 per-task socket.
  if awk '/--agent[[:space:]].*\$ROLE|\$ROLE.*--agent/{found=1} END{exit !found}' "$SPAWN_TARGET"; then
    ok "spawn uses --agent \$ROLE (R9 role-based executor; per-task proxy socket properly scoped)"
  else
    no "spawn lacks --agent \$ROLE — not R9 epoch (per-task proxy socket missing role scoping)"
    printf '    target: %s\n' "$SPAWN_TARGET"
    printf '    expected pattern: --agent \$ROLE\n'
    printf '    this is RED for proto/r5 (uses --dangerously-skip-permissions instead)\n'
  fi

  # Confirm per-task socket path construction (SOCK = task-specific path under TDIR)
  if awk '/SOCK=.*TDIR.*proxy\.sock|proxy\.sock.*TDIR/{found=1} END{exit !found}' "$SPAWN_TARGET"; then
    ok "spawn constructs per-task proxy socket path (SOCK=\$TDIR/proxy.sock)"
  else
    no "spawn does not construct per-task proxy socket path (expected SOCK=\$TDIR/proxy.sock)"
  fi

  # CB_TASK_TIMEOUT: R9 epoch passes timeout to nsjail (missing in proto/r5)
  if awk '/CB_TASK_TIMEOUT/{found=1} END{exit !found}' "$SPAWN_TARGET"; then
    ok "spawn uses CB_TASK_TIMEOUT (R9 epoch; nsjail timeout parameter)"
  else
    no "spawn lacks CB_TASK_TIMEOUT — not R9 epoch"
  fi
fi

# ============================================================
# PART B: REGRESSION LOCKS (no red-claim against proto/r5)
# These properties exist in proto/r5 already; they are CI regression guards only.
# ============================================================
echo "=== Part B: regression locks (green against proto/r5 and reference/runtime) ==="
R5="$REPO_ROOT/proto/r5/crewboss-spawn.sh"

for label_target in "r5:$R5" "canonical:$SPAWN_TARGET"; do
  label="${label_target%%:*}"
  target="${label_target#*:}"
  [ -f "$target" ] || { printf '  skip (%s not found)\n' "$target"; continue; }
  printf '  [%s] checking %s\n' "$label" "$(basename "$target")"

  # Regression lock 1: redact_secrets filter (perl $REDACT) applied to spawn output
  # The spawn pipes nsjail output through  perl "$REDACT"  (REDACT=.../redact.pl)
  if awk '/perl[[:space:]].*\$REDACT/{found=1} END{exit !found}' "$target"; then
    ok "($label) redact_secrets filter present (perl \$REDACT pipe)"
  else
    no "($label) redact_secrets filter MISSING — token leak risk"
  fi

  # Regression lock 2: budget hard-stop exits with code 3
  if awk '/exit[[:space:]]+3/{found=1} END{exit !found}' "$target"; then
    ok "($label) budget hard-stop → exit 3"
  else
    no "($label) budget hard-stop exit 3 MISSING"
  fi

  # Regression lock 3: status.json written with mode 0600
  if awk '/chmod[[:space:]]+600.*\$ST|\$ST.*chmod/{found=1} END{exit !found}' "$target"; then
    ok "($label) status.json written with mode 0600"
  else
    no "($label) status.json 0600 permission MISSING"
  fi
done

# ============================================================
echo
printf '=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
