#!/usr/bin/env bash
#
# runtime-lint.test.sh — content-lock tests for reference/runtime/ (issue #65, class a)
#
# Test 1: no pkill -f / pgrep -f string patterns in reference/runtime/*.sh
#   RED condition: any reference/runtime/*.sh contains  pkill -f <arg>  or  pgrep -f <arg>
#                  (raw backport of box scripts before the self-match fix)
#   GREEN after: all four patched scripts (start-stack.sh, run-charter.sh, run-gov-gatefire.sh,
#                start-api.sh) use PID-file / port-kill instead.
#
# Test 2: proxy.py contains npm allowlist
#   RED condition: proto/net/proxy.py (drift snapshot) lacks npm entries (grep npm → 0)
#   GREEN after: reference/runtime/proxy.py contains registry.npmjs.org allowlist
#
# Test 3: claude.kafel contains xattr / io_uring / pkey syscalls
#   RED condition: proto/seccomp/claude.kafel (old snapshot) lacks these syscalls
#   GREEN after: reference/runtime/claude.kafel contains the full R9 policy

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
RUNTIME="$REPO_ROOT/reference/runtime"

pass=0; fail=0
ok() { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

# ---------------------------------------------------------------------------
# Test 1: no pkill -f / pgrep -f string patterns in reference/runtime/*.sh
# ---------------------------------------------------------------------------
echo "=== Test 1: no pkill -f / pgrep -f string patterns in reference/runtime/*.sh ==="
if [ ! -d "$RUNTIME" ]; then
  no "reference/runtime/ directory not found"
else
  t1_fail=0
  # Match pkill/pgrep with -f flag followed by a space (indicating a string argument follows)
  # Correct fix: kill by PID-file (kill "$(cat pid-file)") or port
  while IFS= read -r -d '' sh_file; do
    name=$(basename "$sh_file")
    # grep for pkill -f <arg> or pgrep -f <arg> as actual shell commands (not in comments)
    matches=$(awk '
      /^[[:space:]]*#/ { next }
      /(p(kill|grep))[[:space:]]+-f[[:space:]]/ { print NR": "$0 }
    ' "$sh_file")
    if [ -n "$matches" ]; then
      printf '    LINT FAIL %s:\n' "$name"
      echo "$matches" | while IFS= read -r m; do printf '      %s\n' "$m"; done
      t1_fail=$((t1_fail+1))
    fi
  done < <(find "$RUNTIME" -maxdepth 1 -name '*.sh' -print0 | sort -z)
  if [ "$t1_fail" -eq 0 ]; then
    ok "no pkill -f / pgrep -f string patterns found in reference/runtime/*.sh (self-match risk eliminated)"
  else
    no "$t1_fail script(s) still contain pkill -f / pgrep -f string patterns"
  fi
fi

# ---------------------------------------------------------------------------
# Test 2: reference/runtime/proxy.py contains npm allowlist
# ---------------------------------------------------------------------------
echo "=== Test 2: proxy.py contains npm allowlist ==="
PROXY_CANON="$RUNTIME/proxy.py"
PROXY_DRIFT="$REPO_ROOT/proto/net/proxy.py"

# Drift check (demonstrates RED baseline): proto/net/proxy.py lacks npm
if [ -f "$PROXY_DRIFT" ]; then
  drift_npm=$(awk '/npm/{found=1} END{print found+0}' "$PROXY_DRIFT")
  if [ "$drift_npm" -eq 0 ]; then
    printf '  (drift-baseline) proto/net/proxy.py: npm NOT present — confirmed drift\n'
  else
    printf '  (drift-baseline) proto/net/proxy.py: npm present (drift may have been patched)\n'
  fi
fi

if [ ! -f "$PROXY_CANON" ]; then
  no "reference/runtime/proxy.py not found"
else
  if awk '/npm/{found=1} END{exit !found}' "$PROXY_CANON"; then
    ok "reference/runtime/proxy.py contains npm allowlist (registry.npmjs.org)"
  else
    no "reference/runtime/proxy.py is missing npm allowlist — drift not backported"
  fi
fi

# ---------------------------------------------------------------------------
# Test 3: claude.kafel contains xattr / io_uring / pkey syscalls
# ---------------------------------------------------------------------------
echo "=== Test 3: claude.kafel contains xattr / io_uring / pkey ==="
KAFEL_CANON="$RUNTIME/claude.kafel"
KAFEL_DRIFT="$REPO_ROOT/proto/seccomp/claude.kafel"

# Drift check (demonstrates RED baseline): proto/seccomp/claude.kafel lacks these
for syscall in xattr io_uring pkey; do
  if [ -f "$KAFEL_DRIFT" ]; then
    if awk -v s="$syscall" '$0 ~ s {found=1} END{exit !found}' "$KAFEL_DRIFT"; then
      printf '  (drift-baseline) proto/seccomp/claude.kafel: %s IS present (drift may be patched)\n' "$syscall"
    else
      printf '  (drift-baseline) proto/seccomp/claude.kafel: %s NOT present — confirmed drift\n' "$syscall"
    fi
  fi
done

if [ ! -f "$KAFEL_CANON" ]; then
  no "reference/runtime/claude.kafel not found"
else
  t3_fail=0
  for syscall in xattr io_uring pkey; do
    if awk -v s="$syscall" '$0 ~ s {found=1} END{exit !found}' "$KAFEL_CANON"; then
      ok "reference/runtime/claude.kafel contains '$syscall' syscall(s)"
    else
      no "reference/runtime/claude.kafel is missing '$syscall' syscall(s)"
      t3_fail=$((t3_fail+1))
    fi
  done
fi

# ---------------------------------------------------------------------------
echo
printf '=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
