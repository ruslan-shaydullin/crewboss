#!/usr/bin/env bash
#
# deploy-verify.test.sh — T5: post-deploy verify gate for deploy-runtime.sh (#151)
#
# Stubs scp/ssh via PATH shims that model a "box" as a local tmpdir (no network,
# real file names from the manifest).  HOME is isolated.
#
# Case A: box = copy of _box-snapshot/cbnet (stale, pre-F9 state)
#         → verify must exit non-zero AND name run-charter.sh (sha drift)
#           AND name crewboss-integrator.sh (absent from snapshot)
#
# Case B: box = fresh deploy from manifest
#         → full deploy+verify must exit 0; deploy set covers ALL canonical files
#           including crewboss-integrator.sh and run-charter.sh
#
# RED-0: before this fix, deploy-runtime.sh had no verify step — it always
#        succeeded regardless of post-deploy box state.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
DEPLOY="$HERE/../runtime/deploy-runtime.sh"
MANIFEST="$REPO_ROOT/reference/runtime-manifest.tsv"
SNAPSHOT="$REPO_ROOT/_box-snapshot/cbnet"
DOCTOR="$HERE/../runtime/crewboss-doctor.sh"

pass=0; fail=0
ok() { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

# ── pre-flight ────────────────────────────────────────────────────────────────
if [ ! -f "$DEPLOY" ]; then
  printf 'SKIP: deploy-runtime.sh not found at %s\n' "$DEPLOY"
  printf '=== SUMMARY: 0 passed, 1 failed ===\n'; exit 1
fi
if [ ! -f "$MANIFEST" ]; then
  printf 'SKIP: runtime-manifest.tsv not found at %s\n' "$MANIFEST"
  printf '=== SUMMARY: 0 passed, 1 failed ===\n'; exit 1
fi
if [ ! -d "$SNAPSHOT" ]; then
  printf 'SKIP: _box-snapshot/cbnet not found at %s\n' "$SNAPSHOT"
  printf '=== SUMMARY: 0 passed, 1 failed ===\n'; exit 1
fi
if [ ! -f "$DOCTOR" ]; then
  printf 'SKIP: crewboss-doctor.sh not found at %s\n' "$DOCTOR"
  printf '=== SUMMARY: 0 passed, 1 failed ===\n'; exit 1
fi

# ── shared shim dir + isolated HOME ───────────────────────────────────────────
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SHIM_DIR="$WORK/shims"
mkdir -p "$SHIM_DIR"
FAKE_HOME="$WORK/home"
mkdir -p "$FAKE_HOME"

# scp shim: log invocation, copy local source file to CB_SHIM_REMOTE
cat > "$SHIM_DIR/scp" <<'SCP_EOF'
#!/usr/bin/env bash
printf 'scp %s\n' "$*" >> "$CB_SHIM_LOG"
for arg; do
  case "$arg" in -*) continue ;; *:*) continue ;; esac
  [ -f "$arg" ] && { cp "$arg" "$CB_SHIM_REMOTE/$(basename "$arg")"; break; }
done
exit 0
SCP_EOF
chmod +x "$SHIM_DIR/scp"

# ssh shim: log invocation.
# If any argument contains 'crewboss-doctor.sh', run doctor locally on fake box.
# Otherwise (API restart, etc.) succeed silently.
cat > "$SHIM_DIR/ssh" <<'SSH_EOF'
#!/usr/bin/env bash
printf 'ssh %s\n' "$*" >> "$CB_SHIM_LOG"
for arg; do
  if printf '%s\n' "$arg" | grep -q 'crewboss-doctor\.sh'; then
    CB_HOME="$CB_SHIM_REMOTE" bash "$CB_SHIM_REMOTE/crewboss-doctor.sh"
    exit $?
  fi
done
exit 0
SSH_EOF
chmod +x "$SHIM_DIR/ssh"

# ============================================================================
printf '\n=== Case A: box = _box-snapshot/cbnet (stale) → verify must fail ===\n'

BOX_A="$WORK/box_a"
mkdir -p "$BOX_A"
LOG_A="$WORK/log_a.txt"

# Populate fake box A with the snapshot files (old/stale state)
cp "$SNAPSHOT"/* "$BOX_A/" 2>/dev/null || true

# Place the current (authoritative) manifest on the box — as deploy would do
cp "$MANIFEST" "$BOX_A/runtime-manifest.tsv"

# Place the reference crewboss-doctor.sh so the ssh stub can run it
cp "$DOCTOR" "$BOX_A/crewboss-doctor.sh"
chmod +x "$BOX_A/crewboss-doctor.sh"

out_a=""
rc_a=0
out_a="$(
  PATH="$SHIM_DIR:$PATH" \
  HOME="$FAKE_HOME" \
  CB_HOST="testbox" \
  CB_REMOTE_HOME="$BOX_A" \
  CB_SHIM_LOG="$LOG_A" \
  CB_SHIM_REMOTE="$BOX_A" \
  MANIFEST="$MANIFEST" \
  REPO_ROOT="$REPO_ROOT" \
  bash "$DEPLOY" verify 2>&1
)" || rc_a=$?

if [ "$rc_a" -ne 0 ]; then
  ok "A: verify exits non-zero for stale box"
else
  no "A: verify exited 0 (expected non-zero)"
fi

if printf '%s\n' "$out_a" | grep -q 'run-charter\.sh'; then
  ok "A: output names run-charter.sh (sha drift)"
else
  no "A: output does NOT mention run-charter.sh"
  printf '    output was:\n'; printf '%s\n' "$out_a" | sed 's/^/    /'
fi

if printf '%s\n' "$out_a" | grep -q 'crewboss-integrator\.sh'; then
  ok "A: output names crewboss-integrator.sh (absent from snapshot)"
else
  no "A: output does NOT mention crewboss-integrator.sh"
  printf '    output was:\n'; printf '%s\n' "$out_a" | sed 's/^/    /'
fi

# ============================================================================
printf '\n=== Case B: fresh deploy from manifest → verify must pass ===\n'

BOX_B="$WORK/box_b"
mkdir -p "$BOX_B"
LOG_B="$WORK/log_b.txt"

out_b=""
rc_b=0
out_b="$(
  PATH="$SHIM_DIR:$PATH" \
  HOME="$FAKE_HOME" \
  CB_HOST="testbox" \
  CB_REMOTE_HOME="$BOX_B" \
  CB_SHIM_LOG="$LOG_B" \
  CB_SHIM_REMOTE="$BOX_B" \
  MANIFEST="$MANIFEST" \
  REPO_ROOT="$REPO_ROOT" \
  bash "$DEPLOY" 2>&1
)" || rc_b=$?

if [ "$rc_b" -eq 0 ]; then
  ok "B: full deploy+verify exits 0"
else
  no "B: full deploy+verify exited $rc_b (expected 0)"
  printf '    output was:\n'; printf '%s\n' "$out_b" | sed 's/^/    /'
fi

# Confirm deploy covered the two files called out in the issue
for fname in crewboss-integrator.sh run-charter.sh; do
  if grep -q "$fname" "$LOG_B" 2>/dev/null; then
    ok "B: $fname was deployed (scp log)"
  else
    no "B: $fname NOT found in scp log"
  fi
done

# ============================================================================
printf '\n'
printf '=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
