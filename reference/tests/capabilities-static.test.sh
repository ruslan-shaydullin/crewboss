#!/usr/bin/env bash
#
# capabilities-static.test.sh — static-analysis gate for charter #357
#   (full capability-axis enforcement: creds / net / seccomp).
#
# CLASS: ALLOW (per-leaf verify-merged safe). This test is PURE static analysis
#   of the spawn / proxy / kafel source (grep / awk only). It launches no nsjail,
#   no proxy, no launcher loop, no background process, and has no timing/poll/sleep
#   asserts. Its verdict is a pure function of merged content — the fail-safe ALLOW
#   criterion (#194). It encodes the expectations the charter-#357 implementation
#   leaves (leaf/357-spec, leaf/357-creds-net-enforcement, leaf/357-seccomp-profiles)
#   MUST satisfy; those leaves' per-leaf verify-merged gate runs this file.
#
# Each check prints  PASS: <what>  or  FAIL: <what>.  Exit non-zero if any FAIL.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
RUNTIME="$REPO_ROOT/reference/runtime"

PREP="$RUNTIME/crewboss-prep-spawn-gh.sh"
PROXY="$RUNTIME/proxy.py"
ANALYST_KAFEL="$RUNTIME/analyst.kafel"
EXECUTOR_KAFEL="$RUNTIME/executor.kafel"
MANAGER_KAFEL="$RUNTIME/manager.kafel"
RUNTIME_MANIFEST="$REPO_ROOT/reference/runtime-manifest.tsv"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

# Helper: grep a file, tolerating a missing file (missing => no match => FAIL).
_grep() { # pattern file
  [ -f "$2" ] || return 1
  grep -Eq "$1" "$2"
}

# ---------------------------------------------------------------------------
# 1. prep-spawn extracts CB_NET via manifest_role_field AND exports it.
#    Without `export CB_NET`, proxy.py always sees CB_NET unset -> default-deny
#    for every role.
# ---------------------------------------------------------------------------
if _grep 'CB_NET=.*manifest_role_field' "$PREP" && _grep '^[[:space:]]*export[[:space:]]+CB_NET' "$PREP"; then
  pass "prep-spawn: CB_NET extracted via manifest_role_field AND exported"
else
  fail "prep-spawn: CB_NET must be assigned via manifest_role_field AND 'export CB_NET' (proxy sees unset otherwise)"
fi

# ---------------------------------------------------------------------------
# 2. prep-spawn unsets pre-existing git/GH creds for creds:none. The unset MUST
#    live in the CB_CREDS extraction block (after manifest load at line 32+),
#    NOT at lines 12-19 which precede manifest load. nsjail -e inherits all env,
#    so a conditional export-skip is insufficient — an inherited GH_TOKEN would
#    still flow into the jail. `unset` is required.
# ---------------------------------------------------------------------------
if _grep 'unset[[:space:]]+GH_TOKEN[[:space:]]+GIT_CONFIG_COUNT[[:space:]]+GIT_CONFIG_KEY_0[[:space:]]+GIT_CONFIG_VALUE_0' "$PREP"; then
  pass "prep-spawn: unset GH_TOKEN GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 present (creds:none)"
else
  fail "prep-spawn: must 'unset GH_TOKEN GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0' in CB_CREDS block"
fi

# ---------------------------------------------------------------------------
# 3. proxy.py: api.anthropic.com in a hardcoded always-on set AND a default-deny
#    branch keyed on CB_NET.
# ---------------------------------------------------------------------------
if _grep 'api\.anthropic\.com' "$PROXY" && _grep 'CB_NET' "$PROXY"; then
  pass "proxy.py: api.anthropic.com always-on AND CB_NET default-deny branch present"
else
  fail "proxy.py: must contain api.anthropic.com always-on AND a default-deny branch keyed on CB_NET"
fi

# ---------------------------------------------------------------------------
# 4. proxy.py MUST NOT list platform.claude.com in the always-on Anthropic
#    baseline — CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 is set at spawn.sh:95,
#    so platform.claude.com is excluded.
# ---------------------------------------------------------------------------
if _grep 'platform\.claude\.com' "$PROXY"; then
  fail "proxy.py: platform.claude.com must NOT be in the always-on baseline (DISABLE_NONESSENTIAL_TRAFFIC=1)"
else
  pass "proxy.py: platform.claude.com absent from always-on baseline (correctly excluded)"
fi

# ---------------------------------------------------------------------------
# 5. prep-spawn calls manifest_role_profile (CB_PROFILE extraction in the same
#    454-460 block).
# ---------------------------------------------------------------------------
if _grep 'manifest_role_profile' "$PREP"; then
  pass "prep-spawn: manifest_role_profile called (CB_PROFILE extraction)"
else
  fail "prep-spawn: must call manifest_role_profile to extract CB_PROFILE"
fi

# ---------------------------------------------------------------------------
# 6. analyst.kafel MUST NOT remove exec/clone/clone3 from ALLOW — the Bash tool
#    needs them; analyst read-only is enforced at the FS layer (#356), not here.
# ---------------------------------------------------------------------------
if _grep 'execve' "$ANALYST_KAFEL" && _grep '\bclone\b' "$ANALYST_KAFEL" && _grep '\bclone3\b' "$ANALYST_KAFEL"; then
  pass "analyst.kafel: exec/clone/clone3 retained in ALLOW (Bash tool needs them)"
else
  fail "analyst.kafel: must retain execve/clone/clone3 in ALLOW (analyst read-only is a FS-layer concern, #356)"
fi

# ---------------------------------------------------------------------------
# 7. manager.kafel MUST NOT include truncate/ftruncate/fallocate in ALLOW
#    (confirms they are stripped -> SIGSYS on the work-tree write path).
# ---------------------------------------------------------------------------
if _grep '\b(truncate|ftruncate|fallocate)\b' "$MANAGER_KAFEL"; then
  fail "manager.kafel: truncate/ftruncate/fallocate must be STRIPPED from ALLOW (they must hit DEFAULT KILL -> SIGSYS)"
else
  pass "manager.kafel: truncate/ftruncate/fallocate absent from ALLOW (correctly stripped)"
fi

# ---------------------------------------------------------------------------
# 8. manager.kafel MUST include write and writev in ALLOW — required for
#    stdout/stderr/pipes. kafel has no BPF fd-argument filtering, so blocking
#    write would kill the process before any output.
# ---------------------------------------------------------------------------
if _grep '\bwrite\b' "$MANAGER_KAFEL" && _grep '\bwritev\b' "$MANAGER_KAFEL"; then
  pass "manager.kafel: write and writev retained in ALLOW (stdout/stderr/pipes; no fd-arg filtering)"
else
  fail "manager.kafel: MUST retain write and writev in ALLOW (blocking them kills the process before any output)"
fi

# ---------------------------------------------------------------------------
# 9. runtime-manifest.tsv contains canonical entries for the three kafel files.
#    deploy-runtime.sh only deploys files listed here (flat basename deploy).
# ---------------------------------------------------------------------------
_mfok=1
for k in analyst.kafel executor.kafel manager.kafel; do
  if _grep "$k[[:space:]].*canonical" "$RUNTIME_MANIFEST"; then
    :
  else
    _mfok=0
  fi
done
if [ "$_mfok" -eq 1 ]; then
  pass "runtime-manifest.tsv: canonical rows for analyst.kafel, executor.kafel, manager.kafel present"
else
  fail "runtime-manifest.tsv: must contain canonical rows for analyst.kafel, executor.kafel, manager.kafel (else never deployed)"
fi

echo "----------------------------------------------------------------------"
if [ "$fails" -ne 0 ]; then
  echo "capabilities-static: $fails check(s) FAILED"
  exit 1
fi
echo "capabilities-static: all checks PASSED"
exit 0
