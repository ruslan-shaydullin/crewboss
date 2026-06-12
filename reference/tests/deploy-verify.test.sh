#!/usr/bin/env bash
#
# deploy-verify.test.sh — T5: post-deploy verify gate in deploy-runtime.sh
#
# Tests the `verify` subcommand/step added to deploy-runtime.sh (issue #151).
# Stubs scp/ssh via PATH-shim scripts; models the box as a tmpdir.
# Uses a mini manifest with real file names from reference/runtime-manifest.tsv
# so the tests are realistic without requiring all 65+ canonical files in repo.
#
# Case A: box = snapshot state (run-charter.sh sha-drift, crewboss-integrator.sh absent)
#         → verify exits non-zero and names BOTH files in output
#         (mirrors the real box-drift scenario from issue #151)
#
# Case B: box = fresh deploy by manifest → verify exits 0;
#         deploy-set covers ALL canonical including crewboss-integrator.sh and run-charter.sh
#
# RED-0: step `verify` does not exist — deploy exits 0 for any post-state.
# GREEN: verify detects MISSING/MISMATCH and deploy exits non-zero on drift.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
DEPLOY="$HERE/../runtime/deploy-runtime.sh"
DOCTOR="$HERE/../runtime/crewboss-doctor.sh"

pass=0; fail=0
ok() { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

# ── pre-flight ──────────────────────────────────────────────────────────────
if [ ! -f "$DEPLOY" ]; then
  printf 'SKIP: deploy-runtime.sh not found at %s\n' "$DEPLOY"
  printf '=== SUMMARY: 0 passed, 1 failed ===\n'
  exit 1
fi

if [ ! -f "$DOCTOR" ]; then
  printf 'SKIP: crewboss-doctor.sh not found at %s\n' "$DOCTOR"
  printf '=== SUMMARY: 0 passed, 1 failed ===\n'
  exit 1
fi

if ! grep -q 'verify' "$DEPLOY"; then
  printf 'SKIP: deploy-runtime.sh contains no "verify" step\n'
  printf '=== SUMMARY: 0 passed, 1 failed ===\n'
  exit 1
fi

# ── work area ───────────────────────────────────────────────────────────────
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── canonical (correct) versions of the three test files ────────────────────
CANON="$WORK/canon"
mkdir -p "$CANON"

# Canonical run-charter.sh: post-F9 version with CB_GIT_REMOTE + CB_PLAN_SPAWN
printf '#!/usr/bin/env bash\n# run-charter.sh canonical (post-F9)\nexport CB_GIT_REMOTE="https://example"\nexport CB_PLAN_SPAWN="$HOME/cbnet/crewboss-prep-spawn-gh.sh"\n' \
  > "$CANON/run-charter.sh"
# Canonical crewboss-integrator.sh
printf '#!/usr/bin/env bash\n# crewboss-integrator.sh canonical\n' \
  > "$CANON/crewboss-integrator.sh"
# Canonical crewboss-doctor.sh: use the real reference implementation
cp "$DOCTOR" "$CANON/crewboss-doctor.sh"

SHA_RUN_CHARTER="$(sha256sum "$CANON/run-charter.sh"   | awk '{print $1}')"
SHA_INTEGRATOR="$(sha256sum  "$CANON/crewboss-integrator.sh" | awk '{print $1}')"
SHA_DOCTOR="$(sha256sum      "$CANON/crewboss-doctor.sh"     | awk '{print $1}')"

# ── mini manifest (real file names, test-local shas) ────────────────────────
MINI_MANIFEST="$WORK/runtime-manifest.tsv"
{
  printf '# test mini-manifest for deploy-verify.test.sh\n'
  printf '# repo_path\tsha256\tstatus\tpurpose\n'
  printf 'reference/runtime/run-charter.sh\t%s\tcanonical\trun-charter (test)\n'         "$SHA_RUN_CHARTER"
  printf 'reference/runtime/crewboss-integrator.sh\t%s\tcanonical\tintegrator (test)\n' "$SHA_INTEGRATOR"
  printf 'reference/runtime/crewboss-doctor.sh\t%s\tcanonical\tdoctor (test)\n'         "$SHA_DOCTOR"
} > "$MINI_MANIFEST"

# ── PATH shims ───────────────────────────────────────────────────────────────
SHIM_DIR="$WORK/shims"
LOG="$WORK/calls.log"
mkdir -p "$SHIM_DIR"

# scp shim: log call, copy local source file to CB_SHIM_BOX/basename
cat > "$SHIM_DIR/scp" <<'SCP_SHIM'
#!/usr/bin/env bash
printf 'scp %s\n' "$*" >> "$CB_SHIM_LOG"
for arg; do
  case "$arg" in
    -*) continue ;;          # skip option flags
    *:*) continue ;;         # skip host:dest argument
  esac
  [ -f "$arg" ] && {
    cp "$arg" "$CB_SHIM_BOX/$(basename "$arg")"
    break
  }
done
exit 0
SCP_SHIM
chmod +x "$SHIM_DIR/scp"

# ssh shim: log call, then:
#   - commands containing crewboss-doctor.sh → eval locally (runs drift check)
#   - all other commands (API restart etc.)  → stub OK
cat > "$SHIM_DIR/ssh" <<'SSH_SHIM'
#!/usr/bin/env bash
printf 'ssh %s\n' "$*" >> "$CB_SHIM_LOG"
# Extract remote command: first non-option argument after the host
host_seen=0
remote_cmd=""
for arg; do
  case "$arg" in -*) continue ;; esac
  if [ "$host_seen" -eq 0 ]; then
    host_seen=1   # first non-option = host
  else
    remote_cmd="$arg"
    break
  fi
done
[ -z "$remote_cmd" ] && exit 0
# Run doctor commands locally so the shim exercises the real drift logic.
# All other commands (API restart, etc.) are stubbed.
if printf '%s' "$remote_cmd" | grep -q 'crewboss-doctor'; then
  eval "$remote_cmd"
  exit $?
else
  printf 'ssh-stub: %s\n' "${remote_cmd%$'\n'*}" >&2
  exit 0
fi
SSH_SHIM
chmod +x "$SHIM_DIR/ssh"

# Helper: run deploy-runtime.sh with shims and test env
run_deploy_args() {
  local box="$1"; shift
  # Reset call log
  : > "$LOG"
  PATH="$SHIM_DIR:$PATH" \
    CB_HOST="testbox" \
    CB_REMOTE_HOME="$box" \
    CB_SHIM_LOG="$LOG" \
    CB_SHIM_BOX="$box" \
    MANIFEST="$MINI_MANIFEST" \
    REPO_ROOT="$REPO_ROOT" \
    bash "$DEPLOY" "$@" 2>&1
}

# ===========================================================================
echo "=== Case A: snapshot box → verify non-zero + names drifted files ==="

BOX_A="$WORK/box-snapshot"
mkdir -p "$BOX_A"

# Snapshot state:
#   run-charter.sh  — present but WRONG sha (pre-F9, no CB_GIT_REMOTE)
#   crewboss-integrator.sh — ABSENT (was never deployed pre-F9)
#   crewboss-doctor.sh — correct (needed so verify can call it)
printf '#!/usr/bin/env bash\n# run-charter.sh pre-F9 (NO CB_GIT_REMOTE, NO CB_PLAN_SPAWN)\n' \
  > "$BOX_A/run-charter.sh"
cp "$CANON/crewboss-doctor.sh" "$BOX_A/crewboss-doctor.sh"
cp "$MINI_MANIFEST"             "$BOX_A/runtime-manifest.tsv"
# crewboss-integrator.sh deliberately omitted

out_a=""
rc_a=0
out_a="$(run_deploy_args "$BOX_A" verify)" || rc_a=$?

if [ "$rc_a" -ne 0 ]; then
  ok "Case A: verify exits non-zero for snapshot box"
else
  no "Case A: verify exited 0 (expected non-zero) — output: $out_a"
fi

if printf '%s\n' "$out_a" | grep -q 'run-charter\.sh'; then
  ok "Case A: output names run-charter.sh (sha drift)"
else
  no "Case A: output does not mention run-charter.sh — output: $out_a"
fi

if printf '%s\n' "$out_a" | grep -q 'crewboss-integrator\.sh'; then
  ok "Case A: output names crewboss-integrator.sh (absent on box)"
else
  no "Case A: output does not mention crewboss-integrator.sh — output: $out_a"
fi

# ===========================================================================
echo "=== Case B: fresh deploy by manifest → verify exits 0 ==="

BOX_B="$WORK/box-fresh"
REPO_B="$WORK/repo-b"
mkdir -p "$BOX_B" "$REPO_B/reference/runtime"

# Provide canonical files at repo paths so scp shim can copy them
cp "$CANON/run-charter.sh"          "$REPO_B/reference/runtime/run-charter.sh"
cp "$CANON/crewboss-integrator.sh"  "$REPO_B/reference/runtime/crewboss-integrator.sh"
cp "$CANON/crewboss-doctor.sh"      "$REPO_B/reference/runtime/crewboss-doctor.sh"

# Full deploy (scp + restart + verify) must exit 0
: > "$LOG"
out_b=""
rc_b=0
out_b="$(
  PATH="$SHIM_DIR:$PATH" \
    CB_HOST="testbox" \
    CB_REMOTE_HOME="$BOX_B" \
    CB_SHIM_LOG="$LOG" \
    CB_SHIM_BOX="$BOX_B" \
    MANIFEST="$MINI_MANIFEST" \
    REPO_ROOT="$REPO_B" \
    bash "$DEPLOY" 2>&1
)" || rc_b=$?

if [ "$rc_b" -eq 0 ]; then
  ok "Case B: full deploy exits 0 (scp + verify green)"
else
  no "Case B: full deploy exited $rc_b (expected 0) — output: $out_b"
fi

# Deploy-set must cover all canonical files including crewboss-integrator.sh and run-charter.sh
if [ -f "$BOX_B/crewboss-integrator.sh" ]; then
  ok "Case B: deploy-set covers crewboss-integrator.sh"
else
  no "Case B: crewboss-integrator.sh not found in deployed box"
fi

if [ -f "$BOX_B/run-charter.sh" ]; then
  ok "Case B: deploy-set covers run-charter.sh"
else
  no "Case B: run-charter.sh not found in deployed box"
fi

if [ -f "$BOX_B/crewboss-doctor.sh" ]; then
  ok "Case B: deploy-set covers crewboss-doctor.sh"
else
  no "Case B: crewboss-doctor.sh not found in deployed box"
fi

# verify was called as part of the deploy (check output mentions it)
if printf '%s\n' "$out_b" | grep -q 'verify'; then
  ok "Case B: deploy output mentions verify step"
else
  no "Case B: deploy output does not mention verify step — output: $out_b"
fi

# ===========================================================================
echo
printf '=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
