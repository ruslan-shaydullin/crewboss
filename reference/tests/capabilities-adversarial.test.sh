#!/usr/bin/env bash
#
# capabilities-adversarial.test.sh — live capability-axis enforcement for charter #357.
#
# CLASS: EXCLUDED (NOT eligible for per-leaf verify-merged). This suite requires a
#   LIVE nsjail + proxy stack and a real spawn pipeline. Its verdict is NOT a pure
#   function of merged content — it depends on kernel seccomp behaviour, live network
#   egress through the proxy, and a real process tree. Per the fail-closed #194
#   criterion (any launcher/process/network/timing dependency => EXCLUDED), this file
#   is covered ONLY by the GHA full suite (ci.yml). It is documented EXCLUDED in
#   reference/runtime/per-leaf-manifest.
#
# It exercises the three enforcement axes adversarially:
#   creds axis    — a pre-existing GH_TOKEN in the launcher env must NOT reach a
#                   creds:none role (proves `unset`, not merely conditional export-skip).
#   net axis      — tiered proxy allowlist: board tier reaches api.anthropic.com,
#                   denies registry.npmjs.org, denies platform.claude.com.
#   seccomp axis  — manager.kafel strips fallocate/ftruncate/truncate => SIGSYS
#                   (NOT EROFS — see SECCOMP AXIS NOTE below).

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
RUNTIME="$REPO_ROOT/reference/runtime"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }
skip() { printf 'SKIP: %s\n' "$1"; }

# This suite needs a live jail + proxy. Outside that environment it SKIPs (never
# false-GREEN, never false-RED); under GHA full suite CB_LIVE_CAPS=1 selects it.
if [ "${CB_LIVE_CAPS:-0}" != "1" ]; then
  skip "capabilities-adversarial requires a live nsjail + proxy stack (set CB_LIVE_CAPS=1 under GHA full suite)"
  exit 0
fi

# Spawn helpers are provided by the live harness; these are the contract seams the
# GHA full suite wires up. Kept as functions so the file is self-describing and
# `bash -n` clean even where the live harness is absent.
spawn_role()  { "$RUNTIME/crewboss-spawn.sh" "$@"; }              # role spawn seam
in_jail()     { spawn_role --exec "$@"; }                        # run a command inside the jail

# ===========================================================================
# creds axis — a pre-existing GH_TOKEN in the CALLING environment (simulating a
#   CI/launcher that exported it) must NOT be presented by a creds:none role.
#   This proves the `unset GH_TOKEN GIT_CONFIG_*` block defeats an INHERITED var
#   (nsjail -e inherits all env), not merely a conditional export-skip.
# ===========================================================================
creds_axis() {
  export GH_TOKEN="ghp_ADVERSARIAL_PREEXISTING_TOKEN"
  export GIT_CONFIG_COUNT=1
  export GIT_CONFIG_KEY_0="http.https://github.com/.extraheader"
  export GIT_CONFIG_VALUE_0="AUTHORIZATION: basic SECRET"

  # Spawn a creds:none role and attempt a git push to the remote.
  local rc=0 out=""
  out="$(in_jail --role analyst --creds none -- \
           git push origin HEAD:refs/heads/adversarial-cred-probe 2>&1)" || rc=$?

  [ "$rc" -ne 0 ] \
    && pass "creds:none — git push rejected (exit $rc), pre-existing GH_TOKEN not presented" \
    || fail "creds:none — git push SUCCEEDED; inherited GH_TOKEN leaked into the jail (unset block missing)"

  # No credentials must appear in the jailed process env / output.
  if printf '%s' "$out" | grep -q 'ghp_ADVERSARIAL_PREEXISTING_TOKEN'; then
    fail "creds:none — credential material observed in jailed output (token leaked)"
  else
    pass "creds:none — no credential material observed (GH_TOKEN unset inside jail)"
  fi

  unset GH_TOKEN GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
}

# ===========================================================================
# net axis — net:board tier. api.anthropic.com is always-on; registry.npmjs.org
#   is NOT in the board tier (proxy DENY); platform.claude.com is excluded from
#   the Anthropic baseline (DISABLE_NONESSENTIAL_TRAFFIC=1 at spawn.sh:95).
# ===========================================================================
net_axis() {
  local rc=0

  rc=0
  in_jail --role analyst --net board -- \
    curl -sS -o /dev/null -m 15 https://api.anthropic.com/ >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] \
    && pass "net:board — https://api.anthropic.com reachable (always-on baseline)" \
    || fail "net:board — api.anthropic.com unreachable (always-on baseline broken)"

  rc=0
  in_jail --role analyst --net board -- \
    curl -sS -o /dev/null -m 15 https://registry.npmjs.org/ >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] \
    && pass "net:board — registry.npmjs.org denied (not in board tier)" \
    || fail "net:board — registry.npmjs.org reachable; board tier over-broad"
  grep -q 'DENY.*registry\.npmjs\.org' "${CB_PROXY_LOG:-/tmp/cbnet/proxy.log}" 2>/dev/null \
    && pass "net:board — proxy logged DENY for registry.npmjs.org" \
    || fail "net:board — expected proxy DENY log for registry.npmjs.org"

  rc=0
  in_jail --role analyst --net board -- \
    curl -sS -o /dev/null -m 15 https://platform.claude.com/ >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] \
    && pass "net:board — platform.claude.com denied (excluded per DISABLE_NONESSENTIAL_TRAFFIC=1)" \
    || fail "net:board — platform.claude.com reachable; must be excluded from Anthropic baseline"
}

# ===========================================================================
# seccomp axis — MUST assert SIGSYS, NOT EROFS.
#
# SECCOMP AXIS NOTE: We assert SIGSYS (not EROFS) because:
# - manager roles have empty fs_work fields; FS-ro from #356 does NOT apply.
# - open(O_CREAT|O_WRONLY) on the work-tree returns errno=0 (success) for managers.
# - manager.kafel strips fallocate/ftruncate/truncate from ALLOW.
# - Those stripped syscalls hit DEFAULT KILL_PROCESS -> SIGSYS.
# - write/writev are retained; kafel has no BPF fd-argument filtering.
# - FS-ro is NOT the file-write guard for manager roles.
# ===========================================================================
seccomp_axis() {
  local SIGSYS=31   # kill -l SYS == 31 on Linux
  local status wsig

  # Inside a manager-profile jail: open a work-tree file for writing (SUCCEEDS,
  # write is in ALLOW), then invoke fallocate/ftruncate on the descriptor. Those
  # syscalls are stripped from manager.kafel ALLOW -> DEFAULT KILL_PROCESS -> SIGSYS.
  in_jail --role backend-head --profile manager -- python3 - <<'PY'
import os, fcntl, sys
# open(O_CREAT|O_WRONLY) succeeds for managers (empty fs_work -> no FS-ro layer).
fd = os.open("cap-seccomp-probe.tmp", os.O_CREAT | os.O_WRONLY, 0o644)
os.write(fd, b"write is in ALLOW\n")   # write/writev retained -> OK
# fallocate() is stripped from manager.kafel ALLOW -> SIGSYS (process killed here).
os.posix_fallocate(fd, 0, 1024)
# ftruncate() is likewise stripped; reached only if fallocate somehow allowed.
os.ftruncate(fd, 0)
os.close(fd)
sys.exit(0)
PY
  status=$?

  # A child killed by a signal is reported by the shell as 128+signum.
  if [ "$status" -gt 128 ]; then
    wsig=$(( status - 128 ))
  else
    wsig=0
  fi

  # WTERMSIG(status) == SIGSYS is the required assertion (NOT EROFS/errno).
  if [ "$wsig" -eq "$SIGSYS" ]; then
    pass "seccomp:manager — fallocate/ftruncate on work-tree fd -> WTERMSIG(status) == SIGSYS ($SIGSYS)"
  else
    fail "seccomp:manager — expected WTERMSIG(status) == SIGSYS ($SIGSYS); got status=$status wsig=$wsig (EROFS/errno is WRONG here)"
  fi
}

creds_axis
net_axis
seccomp_axis

echo "----------------------------------------------------------------------"
if [ "$fails" -ne 0 ]; then
  echo "capabilities-adversarial: $fails check(s) FAILED"
  exit 1
fi
echo "capabilities-adversarial: all checks PASSED"
exit 0
