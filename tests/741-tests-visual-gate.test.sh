#!/usr/bin/env bash
# 741-tests-visual-gate.test.sh — ALLOW-class unit tests for charter #741 visual gate
#
# Scenario (1): Container-visual happy-path — stub podman exits 0 → pass verdict.
# Scenario (5): Soft-gate fallback — stub podman exits non-zero (infra error);
#               with run/visual_gate_soft sentinel: no-op; without: still non-blocking.
#
# ALLOW-class: pure-function stubs only; no live podman, no GHA, no launcher loops.
# Criterion: verdict = f(stubbed podman exit code + sentinel presence); no background
#            processes, no timing/poll/sleep, no recursive verify-merged.
#
# Implementation note: the visual-gate logic is tested via an inline reference
# implementation (_visual_gate below) that mirrors the charter #741 §2 spec.
# When the real implementation lands in crewboss-integrator.sh the integration
# tests (EXCLUDED-class) will cover it end-to-end; these ALLOW tests guard the algo.
set -uo pipefail

pass=0; fail=0
ok()  { printf 'ok   %s\n' "$*"; pass=$((pass+1)); }
ko()  { printf 'FAIL %s\n' "$*"; fail=$((fail+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin";  mkdir -p "$BIN"
RUN="$TMP/run";  mkdir -p "$RUN"
VFILE="$TMP/verdict"

# ── Reference implementation: charter #741 §2 visual-gate algorithm ──────────
#
# charter #741 §2 intent:
#   a) Run visual-regression.mjs inside a pinned Playwright container via podman.
#   b) podman exits 0   → visual tests pass; suite_rc unchanged.
#   c) podman exits 1   → visual regression detected; force suite_rc=1.
#   d) podman exit ≥125 → container engine / image infra error; treat as soft-gate
#                         (non-blocking so a broken podman install cannot livelock).
#   e) run/visual_gate_soft sentinel present → bypass visual gate entirely (no-op).
#
# Returns (possibly overridden) suite_rc on stdout.
_visual_gate() {
  local suite_rc="${1:-0}" run_dir="${2:-$RUN}"
  local sentinel="$run_dir/visual_gate_soft"

  # (e) Sentinel bypass — gate completely skipped
  if [ -f "$sentinel" ]; then
    printf '%s' "$suite_rc"
    return 0
  fi

  # Run visual regression container (podman must be in PATH; stubbed in tests).
  local vrc=0
  podman run --rm --quiet playwright-visual /visual-regression.mjs 2>/dev/null \
    || vrc=$?

  if [ "$vrc" -eq 0 ]; then
    # (b) Pass — suite_rc unchanged
    printf '%s' "$suite_rc"
  elif [ "$vrc" -ge 125 ]; then
    # (d) Infra error — soft-gate, non-blocking
    printf '%s' "$suite_rc"
  else
    # (c) Visual regression failure — force fail
    printf '1'
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Scenario 1: Container-visual happy-path (podman exits 0) ==="

# Stub: podman passes
cat > "$BIN/podman" <<'SHIM'
#!/bin/sh
exit 0
SHIM
chmod +x "$BIN/podman"

# 1a: suite passing + visual pass → stays passing
out=$(PATH="$BIN:$PATH" _visual_gate "0" "$RUN")
[ "$out" = "0" ] \
  && ok "S1a: suite_rc=0 + podman exit 0 → suite_rc stays 0 (pass)" \
  || ko "S1a: expected 0, got '$out'"

# 1b: suite red + visual pass → suite_rc NOT rescued by visual pass
out=$(PATH="$BIN:$PATH" _visual_gate "1" "$RUN")
[ "$out" = "1" ] \
  && ok "S1b: suite_rc=1 + podman exit 0 → suite_rc stays 1 (visual pass does not rescue)" \
  || ko "S1b: expected 1, got '$out'"

# 1c: happy-path wires verdict=pass when caller writes it after gate
rm -f "$VFILE"
_suite_rc=$(PATH="$BIN:$PATH" _visual_gate "0" "$RUN")
[ "$_suite_rc" = "0" ] && printf 'pass' > "$VFILE"
[ "$(cat "$VFILE" 2>/dev/null)" = "pass" ] \
  && ok "S1c: verdict file = 'pass' written after visual gate returns 0" \
  || ko "S1c: verdict file wrong: '$(cat "$VFILE" 2>/dev/null)'"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Scenario 5a: Soft-gate — sentinel present (podman fails, gate is no-op) ==="

# Stub: podman infra error
cat > "$BIN/podman" <<'SHIM'
#!/bin/sh
exit 125
SHIM
chmod +x "$BIN/podman"

# Write soft-gate sentinel
touch "$RUN/visual_gate_soft"

out=$(PATH="$BIN:$PATH" _visual_gate "0" "$RUN")
[ "$out" = "0" ] \
  && ok "S5a: sentinel present + podman infra fail → gate no-op (suite_rc=0 unchanged)" \
  || ko "S5a: expected 0, got '$out'"

# Verify podman is NOT called when sentinel present (gate must short-circuit)
CALL_MARKER="$TMP/podman_called"
rm -f "$CALL_MARKER"
cat > "$BIN/podman" << SHIM
#!/bin/sh
touch "$CALL_MARKER"
exit 125
SHIM
chmod +x "$BIN/podman"

PATH="$BIN:$PATH" _visual_gate "0" "$RUN" >/dev/null
[ ! -f "$CALL_MARKER" ] \
  && ok "S5a: sentinel short-circuits gate — podman NOT invoked" \
  || ko "S5a: podman was invoked despite sentinel being present (must short-circuit)"

rm -f "$RUN/visual_gate_soft"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Scenario 5b: Soft-gate — no sentinel, infra error is non-blocking ==="

# Stub: podman infra error (exit ≥125 = container engine failure)
cat > "$BIN/podman" <<'SHIM'
#!/bin/sh
exit 125
SHIM
chmod +x "$BIN/podman"

# Without sentinel: infra error must be non-blocking (soft-gate)
out=$(PATH="$BIN:$PATH" _visual_gate "0" "$RUN")
[ "$out" = "0" ] \
  && ok "S5b: no sentinel + podman infra error (125) → non-blocking (suite_rc=0 unchanged)" \
  || ko "S5b: expected 0 (non-blocking), got '$out'"

# Infra error does not clobber a pre-existing red suite_rc
out=$(PATH="$BIN:$PATH" _visual_gate "1" "$RUN")
[ "$out" = "1" ] \
  && ok "S5b: no sentinel + podman infra error + suite red → suite_rc stays 1" \
  || ko "S5b: expected 1, got '$out'"

# Sanity: actual visual failure (podman exit 1) IS blocking even without sentinel
cat > "$BIN/podman" <<'SHIM'
#!/bin/sh
exit 1
SHIM
chmod +x "$BIN/podman"

out=$(PATH="$BIN:$PATH" _visual_gate "0" "$RUN")
[ "$out" = "1" ] \
  && ok "S5b: actual visual failure (podman exit 1) forces suite_rc=1 (IS blocking)" \
  || ko "S5b: expected 1 for visual failure, got '$out'"

# ─────────────────────────────────────────────────────────────────────────────
echo
printf '=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
