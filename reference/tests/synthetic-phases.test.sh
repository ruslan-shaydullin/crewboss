#!/usr/bin/env bash
# synthetic-phases.test.sh — QA acceptance tests for phantom-merging fix (#737, charter #718)
#
# Verifies the contract for synthetic integrator chips in build_agents():
#
#  Test 1 — Selftest gate: python3 crewboss-api.py --selftest-synthetic-gate must exit 0.
#    The selftest is the single source of truth for the build_agents() phase contract.
#    BEFORE python-fix #738: selftest asserts loop_running=True → phase=="merging".
#    AFTER  python-fix #738: selftest asserts loop_running=True → phase=="awaiting-integration".
#    In both states the selftest exits 0 (green) — this test guards the gate is never broken.
#
#  Test 2 — Phase NOT "merging" when loop_running=True (new contract — RED until #738):
#    After python-fix #738, integrator chips must use phase="awaiting-integration" for all
#    loop_running states. "merging" was always a lie (no per-leaf merge-activity signal).
#
#  Test 3 — Running-counter contract: 31 synthetic chips (pid=None) + loop_running=True
#    must yield new_running=0 when counted by pid!=null (new App.tsx Hero logic, tsx-fix #739).
#
# ALLOW class (per-leaf-manifest): verdict = pure function of crewboss-api.py content;
#   synchronous python3 call, no background processes, no timing/poll/sleep.
#
# Tests 2 are RED before python-fix #738 is merged into charter/718.
# Test 1 and Test 3 are always green (verified below).

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
API_PY="$REPO_ROOT/ui/server/crewboss-api.py"

pass=0; fail=0
ok(){ printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

if [ ! -f "$API_PY" ]; then
  no "crewboss-api.py not found: $API_PY"
  printf '\n=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"; exit 1
fi

# =============================================================================
# Test 1: --selftest-synthetic-gate exits 0 (contract green)
# =============================================================================
echo "=== Test 1: --selftest-synthetic-gate exits 0 ==="
gate_out=""; gate_rc=0
gate_out=$(python3 "$API_PY" --selftest-synthetic-gate 2>&1) || gate_rc=$?
if [ "$gate_rc" -eq 0 ]; then
  ok "selftest-synthetic-gate: exit 0 (contract self-consistent)"
else
  no "selftest-synthetic-gate: exit $gate_rc (contract broken — selftest assertion mismatch)"
  printf '  output: %s\n' "$gate_out"
fi
if printf '%s' "$gate_out" | grep -q "^PASS"; then
  ok "selftest-synthetic-gate: output starts with PASS"
else
  no "selftest-synthetic-gate: output missing PASS prefix (got: $(printf '%s' "$gate_out" | head -1))"
fi

# =============================================================================
# Test 2: phase contract — loop_running=True must NOT produce phase="merging"
#   Contract: integrator synthetic chip phase = "awaiting-integration" (post-#738)
#   RED before python-fix #738; GREEN after.
# =============================================================================
echo "=== Test 2: phase contract — loop_running=True must not produce 'merging' ==="
phase_py=$(cat << 'PYEOF2'
import sys, importlib.util
import unittest.mock as mock

api_path = sys.argv[1]
spec = importlib.util.spec_from_file_location("crewboss_api", api_path)
mod  = importlib.util.module_from_spec(spec)
_orig = sys.argv[:]
sys.argv = [api_path]
with mock.patch("builtins.open", mock.mock_open(read_data="")):
    try:
        spec.loader.exec_module(mod)
    except SystemExit:
        pass
sys.argv = _orig

build_agents = getattr(mod, "build_agents", None)
if build_agents is None:
    print("ERROR: build_agents not found"); sys.exit(2)

by_n = {i: {"state": "review", "kind": "leaf", "title": "L%d" % i} for i in range(1, 32)}
agents = build_agents(by_n, loop_running=True)
integrators = [a for a in agents if a.get("role") == "integrator" and a.get("pid") is None]

if not integrators:
    print("WARN: no synthetic integrator chips for 31 review leaves"); sys.exit(0)

phases = {a["phase"] for a in integrators}
if "merging" in phases:
    print("FAIL: %d chips have phase='merging' (phantom — apply python-fix #738)" % len(integrators))
    sys.exit(1)
print("PASS: %d integrator chips, none='merging'; phases=%s" % (len(integrators), phases))
sys.exit(0)
PYEOF2
)
phase_out=""; phase_rc=0
phase_out=$(python3 - "$API_PY" <<< "$phase_py") || phase_rc=$?
if [ "$phase_rc" -eq 0 ]; then
  ok "phase-contract: no integrators with phase='merging' when loop_running=True"
  printf '  detail: %s\n' "$phase_out"
elif [ "$phase_rc" -eq 2 ]; then
  no "phase-contract: module load failed"
  printf '  detail: %s\n' "$phase_out"
else
  no "phase-contract: PHANTOM MERGING — integrators use phase='merging' (apply #738)"
  printf '  detail: %s\n' "$phase_out"
fi

# =============================================================================
# Test 3: running-counter — pid-based filter must yield running=0 for synthetic chips
#   31 review-leaves → 31 synthetic integrators (all pid=None).
#   New filter: a.pid != null → running=0 (correct; synthetic chips not real processes).
#   Old filter: a.phase != 'awaiting' → running inflated by N phantom chips.
# =============================================================================
echo "=== Test 3: running-counter — 31 pid=null chips → pid-based count=0 ==="
counter_py=$(cat << 'PYEOF3'
import sys, importlib.util
import unittest.mock as mock

api_path = sys.argv[1]
spec = importlib.util.spec_from_file_location("crewboss_api", api_path)
mod  = importlib.util.module_from_spec(spec)
_orig = sys.argv[:]
sys.argv = [api_path]
with mock.patch("builtins.open", mock.mock_open(read_data="")):
    try:
        spec.loader.exec_module(mod)
    except SystemExit:
        pass
sys.argv = _orig

build_agents = getattr(mod, "build_agents", None)
if build_agents is None:
    print("ERROR: build_agents not found"); sys.exit(2)

by_n = {i: {"state": "review", "kind": "leaf", "title": "L%d" % i} for i in range(1, 32)}
agents = build_agents(by_n, loop_running=True)

# New (correct) counter: pid != null
new_running = len([a for a in agents if a.get("pid") is not None])
# Old (broken) counter: phase != 'awaiting'
old_running = len([a for a in agents if a.get("phase") != "awaiting"])

print("agents=%d new_running(pid!=null)=%d old_running(phase!='awaiting')=%d" % (
    len(agents), new_running, old_running))

if new_running != 0:
    print("FAIL: pid-based counter=%d; expected 0 for all-synthetic fixture" % new_running)
    sys.exit(1)
print("PASS: pid-based counter=0 (all synthetic, no real pid)")
sys.exit(0)
PYEOF3
)
counter_out=""; counter_rc=0
counter_out=$(python3 - "$API_PY" <<< "$counter_py") || counter_rc=$?
if [ "$counter_rc" -eq 0 ]; then
  ok "running-counter: pid-based filter=0 for 31 synthetic chips (correct)"
  printf '  detail: %s\n' "$counter_out"
elif [ "$counter_rc" -eq 2 ]; then
  no "running-counter: module load error"
  printf '  detail: %s\n' "$counter_out"
else
  no "running-counter: unexpected result"
  printf '  detail: %s\n' "$counter_out"
fi

printf '\n=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
