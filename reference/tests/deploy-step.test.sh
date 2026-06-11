#!/usr/bin/env bash
#
# deploy-step.test.sh — smoke tests for deploy-runtime.sh (issue #69, class d)
#
# Stubs ssh and scp via PATH-shim scripts that log every invocation.
# Verifies that deploy-runtime.sh:
#
#   (a) passes crewboss-api.py to scp (API must reach the box)
#   (b) passes EVERY canonical manifest file to scp (full manifest coverage)
#   (c) calls ssh (API restart triggered on the box)
#
# RED now:  reference/runtime/deploy-runtime.sh does not exist.
# GREEN after: deploy-runtime.sh implemented.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
DEPLOY="$HERE/../runtime/deploy-runtime.sh"
MANIFEST="$REPO_ROOT/reference/runtime-manifest.tsv"

pass=0; fail=0
ok() { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

# ── pre-flight ──────────────────────────────────────────────────────────────
if [ ! -f "$DEPLOY" ]; then
  printf 'SKIP: deploy-runtime.sh not found at %s\n' "$DEPLOY"
  printf '=== SUMMARY: 0 passed, 1 failed ===\n'
  exit 1
fi

if [ ! -f "$MANIFEST" ]; then
  printf 'SKIP: manifest not found at %s\n' "$MANIFEST"
  printf '=== SUMMARY: 0 passed, 1 failed ===\n'
  exit 1
fi

# ── shim setup ───────────────────────────────────────────────────────────────
SHIM_DIR="$(mktemp -d)"
REMOTE_DIR="$(mktemp -d)"
LOG="$SHIM_DIR/calls.log"
trap 'rm -rf "$SHIM_DIR" "$REMOTE_DIR"' EXIT

# scp shim: log args, copy local source to REMOTE_DIR (simulate deployment)
# Env vars CB_SHIM_LOG and CB_SHIM_REMOTE are set for the child process.
cat > "$SHIM_DIR/scp" <<'SCP_SHIM'
#!/usr/bin/env bash
printf 'scp %s\n' "$*" >> "$CB_SHIM_LOG"
# Find the local source file (first non-option, non-host:path argument)
for arg; do
  case "$arg" in
    -*) continue ;;       # skip option flags
    *:*) continue ;;      # skip host:dest
  esac
  [ -f "$arg" ] && {
    cp "$arg" "$CB_SHIM_REMOTE/$(basename "$arg")"
    break
  }
done
exit 0
SCP_SHIM
chmod +x "$SHIM_DIR/scp"

# ssh shim: log args, exit 0
cat > "$SHIM_DIR/ssh" <<'SSH_SHIM'
#!/usr/bin/env bash
printf 'ssh %s\n' "$*" >> "$CB_SHIM_LOG"
exit 0
SSH_SHIM
chmod +x "$SHIM_DIR/ssh"

# ── run deploy-runtime.sh with stubbed PATH ───────────────────────────────────
echo "=== Running deploy-runtime.sh with stubbed ssh/scp ==="

deploy_rc=0
PATH="$SHIM_DIR:$PATH" \
  CB_HOST="testbox" \
  CB_REMOTE_HOME="$REMOTE_DIR" \
  CB_SHIM_LOG="$LOG" \
  CB_SHIM_REMOTE="$REMOTE_DIR" \
  MANIFEST="$MANIFEST" \
  REPO_ROOT="$REPO_ROOT" \
  bash "$DEPLOY" > "$SHIM_DIR/deploy.out" 2>&1 || deploy_rc=$?

if [ "$deploy_rc" -eq 0 ]; then
  ok "deploy-runtime.sh exited 0"
else
  no "deploy-runtime.sh exited $deploy_rc — output:"
  sed 's/^/    /' "$SHIM_DIR/deploy.out"
fi

# ===========================================================================
echo "=== Test (a): crewboss-api.py is deployed via scp ==="

if grep -q 'crewboss-api\.py' "$LOG" 2>/dev/null; then
  ok "scp was called with crewboss-api.py"
else
  no "crewboss-api.py NOT found in scp call log"
  if [ -s "$LOG" ]; then
    printf '    (call log first 10 lines):\n'
    head -10 "$LOG" | sed 's/^/    /'
  else
    printf '    (call log is empty)\n'
  fi
fi

# ===========================================================================
echo "=== Test (b): all canonical manifest files are deployed via scp ==="

missing=0
while IFS=$'\t' read -r repo_path _sha256 status _purpose; do
  case "${repo_path:-}" in ''|'#'*) continue ;; esac
  [ "${status:-}" = "canonical" ] || continue
  bname="$(basename "$repo_path")"
  if ! grep -q "$bname" "$LOG" 2>/dev/null; then
    printf '    NOT DEPLOYED: %s\n' "$bname"
    missing=$((missing+1))
  fi
done < "$MANIFEST"

if [ "$missing" -eq 0 ]; then
  ok "all canonical manifest files were passed to scp"
else
  no "$missing canonical file(s) were not passed to scp"
fi

# ===========================================================================
echo "=== Test (c): API restart triggered via ssh ==="

if grep -q '^ssh ' "$LOG" 2>/dev/null; then
  ok "ssh was called (API restart triggered)"
else
  no "ssh was NOT called — API restart not triggered"
fi

# ===========================================================================
echo
printf '=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
