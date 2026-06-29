#!/usr/bin/env bash
# smoke-runner.test.sh — regression suite for reference/runtime/smoke-runner.sh
# Owner: qa-engineer leaf `smoke-regression-tests` (charter #993, issue #996).
#
# Proves the FROZEN exit-code contract of smoke-runner.sh <merged_dir>:
#   exit 0 = PASS  (all applicable detectors green, or no applicable detector)
#   exit 1 = FAIL  (artifact proven broken: hang/timeout, unknown flag, non-200,
#                   invalid/empty JSON, crash) — reason on stdout `SMOKE_REASON: <detector>`
#   exit 2|3 = INFRA (port busy, network/rate-limit, runner self-error) — never a silent pass
#
# WHY: bugs of class "built but does not run live" pass mock-gh gates (charter #969:
# `gh issue list --paginate` is a non-existent flag; #973: `api.py while True:` hangs).
# **mock is FORBIDDEN in smoke** — the RED lanes here are hermetic by NATURE
# (flag-parse rejection / per-detector timeout), NOT by mocking gh.
#
# Lanes:
#   1. HERMETIC RED — api hang  (catches #973): exit 1 BY TIMEOUT. Offline.
#   2. HERMETIC RED — bad gh flag (catches #969): exit 1, `unknown flag`. Offline.
#   3. GATED valid-PASS — real gh + network + board: exit 0. Explicitly SKIPPED
#      (never mocked, never silent-pass) unless the live signal CB_SMOKE_LIVE=1 is set.
#   4. Base-path-intact — verify-merged still PASSes on a valid tree (smoke layer
#      did not break the base path).
#
# Cross-leaf dependency: smoke-runner.sh is built by the executor (smoke-runner)
# leaf. Until it is merged into this charter integration branch the runner-dependent
# lanes (1-3) explicitly SKIP — they run for real in the GHA full suite once the
# sibling leaf lands. They are NEVER silently mocked or silent-passed.
#
# Requires: bash, timeout, git, python3 (for lanes that run); real gh for lane 2/3.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
RUNNER="${SMOKE_RUNNER_OVERRIDE:-$HERE/../runtime/smoke-runner.sh}"
INTEGRATOR="${INTEGRATOR_OVERRIDE:-$HERE/../runtime/crewboss-integrator.sh}"
FIX="$HERE/fixtures/smoke-runner"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0; skip=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }
sk(){ skip=$((skip+1)); printf 'SKIP %s\n' "$1"; }

RUNNER_PRESENT=0
[ -f "$RUNNER" ] && RUNNER_PRESENT=1

# run_smoke <merged_dir> -> sets RC and OUT.
# Outer timeout is a SAFETY NET only (the gate must never hang the test harness);
# the contract's own per-detector timeout must fire well inside it. If the outer
# net fires (RC=124) the runner itself hung -> that is a contract FAIL, reported.
run_smoke() {
  OUT="$(timeout "${SMOKE_OUTER_TIMEOUT:-60}" bash "$RUNNER" "$1" 2>&1)"; RC=$?
}

# =============================================================================
# Lane 1: HERMETIC RED — api hang (catches #973) -> exit 1 BY TIMEOUT, offline
# =============================================================================
echo "=== Lane 1: HERMETIC RED — api hang (catches #973) ==="
if [ "$RUNNER_PRESENT" -ne 1 ]; then
  sk "lane1(api-hang): smoke-runner.sh not yet merged (sibling executor leaf) — runs in full suite"
else
  M1="$TMP/m1"; mkdir -p "$M1"; cp "$FIX/api-hang/api.py" "$M1/api.py"
  run_smoke "$M1"
  if [ "$RC" -eq 124 ]; then
    ko "lane1(api-hang): smoke-runner itself HUNG (exceeded outer net) — per-detector timeout broken"
  elif [ "$RC" -eq 1 ]; then
    ok "lane1(api-hang): exit 1 — hanging build_state caught by per-detector timeout (gate did not hang)"
  else
    ko "lane1(api-hang): expected exit 1 (FAIL by timeout), got $RC"
  fi
fi

# =============================================================================
# Lane 2: HERMETIC RED — bad gh flag (catches #969) -> exit 1, `unknown flag`, offline
# =============================================================================
echo "=== Lane 2: HERMETIC RED — bad gh flag (catches #969) ==="
if [ "$RUNNER_PRESENT" -ne 1 ]; then
  sk "lane2(bad-gh-flag): smoke-runner.sh not yet merged (sibling executor leaf) — runs in full suite"
elif ! command -v gh >/dev/null 2>&1; then
  ko "lane2(bad-gh-flag): real gh not on PATH — cannot prove flag-parse rejection (mock is FORBIDDEN)"
else
  M2="$TMP/m2"; mkdir -p "$M2"; cp "$FIX/bad-gh-flag/run.sh" "$M2/run.sh"; chmod +x "$M2/run.sh"
  run_smoke "$M2"
  if [ "$RC" -eq 1 ]; then
    ok "lane2(bad-gh-flag): exit 1 — unknown flag rejected at parse time (no mock, no network)"
  else
    ko "lane2(bad-gh-flag): expected exit 1 (FAIL), got $RC"
  fi
  printf '%s' "$OUT" | grep -q 'SMOKE_REASON:' \
    && ok "lane2(bad-gh-flag): SMOKE_REASON emitted on stdout" \
    || ko "lane2(bad-gh-flag): missing SMOKE_REASON line (contract requires failing-detector reason)"
fi

# =============================================================================
# Lane 3: GATED valid-PASS — real gh + network + board -> exit 0
#   BOX-ONLY. Explicitly SKIP (never stub, never silent-pass) without live signal.
# =============================================================================
echo "=== Lane 3: GATED valid-PASS (real gh + board) ==="
if [ "${CB_SMOKE_LIVE:-0}" != "1" ]; then
  sk "lane3(valid-pass): live lane gated off (set CB_SMOKE_LIVE=1 on a box with real token+board) — NOT mocked, NOT silent-passed"
elif [ "$RUNNER_PRESENT" -ne 1 ]; then
  sk "lane3(valid-pass): smoke-runner.sh not yet merged (sibling executor leaf)"
elif ! command -v gh >/dev/null 2>&1; then
  ko "lane3(valid-pass): CB_SMOKE_LIVE=1 but real gh not on PATH"
else
  M3="$TMP/m3"; mkdir -p "$M3"
  cp "$FIX/valid/api.py" "$M3/api.py"
  cp "$FIX/valid/run.sh" "$M3/run.sh"; chmod +x "$M3/run.sh"
  run_smoke "$M3"
  [ "$RC" -eq 0 ] \
    && ok "lane3(valid-pass): exit 0 — valid artifacts pass live smoke" \
    || ko "lane3(valid-pass): expected exit 0, got $RC (OUT: $OUT)"
fi

# =============================================================================
# Lane 4: Base-path-intact — verify-merged still PASSes on a valid tree
#   Proves the smoke layer (charter #993) did not break the base verify-merged path.
# =============================================================================
echo "=== Lane 4: Base-path-intact (verify-merged PASS on valid tree) ==="
if ! command -v git >/dev/null 2>&1; then
  ko "lane4(base-path): git not available"
elif [ ! -f "$INTEGRATOR" ]; then
  ko "lane4(base-path): integrator not found at $INTEGRATOR"
else
  REMOTE4="$TMP/remote4.git"; VERDICT4="$TMP/verdict4.txt"
  git init --bare -q "$REMOTE4"
  WT="$(mktemp -d)"
  git clone -q "$REMOTE4" "$WT" 2>/dev/null
  git -C "$WT" config user.email t@t
  git -C "$WT" config user.name  T
  mkdir -p "$WT/reference/tests"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$WT/reference/tests/acceptance-block.test.sh"
  chmod +x "$WT/reference/tests/acceptance-block.test.sh"
  printf 'ALLOW dummy\n' > "$WT/reference/tests/per-leaf-manifest"
  mkdir -p "$WT/reference/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$WT/reference/bin/regen-manifest.sh"
  chmod +x "$WT/reference/bin/regen-manifest.sh"
  printf 'base\n' > "$WT/README.md"
  git -C "$WT" add -A
  git -C "$WT" commit -qm base 2>/dev/null
  git -C "$WT" push -q origin "HEAD:refs/heads/charter/5" 2>/dev/null
  printf 'leaf change\n' > "$WT/leaf.txt"
  git -C "$WT" add -A
  git -C "$WT" commit -qm "leaf work" 2>/dev/null
  git -C "$WT" push -q origin "HEAD:refs/heads/leaf/42" 2>/dev/null
  rm -rf "$WT"

  rc=0
  bash "$INTEGRATOR" verify-merged leaf/42 charter/5 \
    --remote "$REMOTE4" --verdict-file "$VERDICT4" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] \
    && ok "lane4(base-path): verify-merged exit 0 (base path intact)" \
    || ko "lane4(base-path): expected exit 0, got $rc (smoke layer broke base path)"
  [ "$(cat "$VERDICT4" 2>/dev/null)" = "pass" ] \
    && ok "lane4(base-path): verdict=pass" \
    || ko "lane4(base-path): verdict mismatch (got '$(cat "$VERDICT4" 2>/dev/null)')"
fi

# =============================================================================
echo
printf 'passed=%d failed=%d skipped=%d\n' "$pass" "$fail" "$skip"
[ "$fail" = 0 ]
