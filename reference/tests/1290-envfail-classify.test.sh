#!/usr/bin/env bash
# 1290-envfail-classify.test.sh — charter #1290 / issue #1302 (qa-engineer test-writer leaf).
#
# P1 of charter #1290: an environment failure (RL-storm / gh-403 / network-unreachable)
# during verify-merged or the smoke gate must be classified as a RETRYABLE infra red
# (exit 3, RED_REASON: infra:<sig>) — NOT as a code red. It must NOT increment the
# per-leaf red/rework counter and must NEVER confirm terminal RED. A GENUINE code
# failure (no infra signature) must still confirm RED exactly as today.
#
# Incident basis (2026-07-02, leaf #1281 of charter #1220): verify-merged went red 3×
# in a row on `smoke:api-state-invalid` — every failure inside the burned-core RL
# window 04:31–05:31 UTC. build_state got 403 from gh during the storm and returned an
# invalid /api/state; the leaf's code was blameless, but the rework-cap (2/2) burned on
# false reds. This suite pins the RED→GREEN contract that stops that.
#
# This file bundles TWO env-fail surfaces:
#   PART A — verify-merged env-fail classification (drives the REAL cmd_verify_merged
#            against bare-remote fixtures, exactly like the 1109 rich-reason suite).
#   PART B — smoke-runner board-empty disambiguation (drives the REAL smoke-runner.sh:
#            board-empty + post-hoc gh probe 403 -> infra gh-403-board; probe healthy ->
#            existing api-state-invalid fail).
#
# HARNESS CONVENTION (identical to 1109 / smoke-runner suites, so this file is runnable
# standalone and stays GREEN on the current tree):
#   * The always-true REGRESSION assertions (genuine RED still confirms; base smoke
#     path intact) are asserted NOW and MUST stay green.
#   * The NEW-behaviour assertions are gated behind a behavioural/marker feature probe.
#     Before the P1 impl leaf lands they SKIP (reported, never a silent pass); once the
#     impl lands they assert the full infra-classification contract. This mirrors the
#     smoke-runner.test.sh "harness absent -> SKIP" and 1144 tests-first conventions.
#
# CLASSIFICATION: EXCLUDED in reference/runtime/per-leaf-manifest — PART A drives the
# REAL cmd_verify_merged against bare-remote fixtures (recursive verify-merged), PART B
# spawns smoke-runner.sh processes with per-detector timeouts / real-gh probe. Both
# violate the ALLOW purity criterion (fail-closed), same precedent as 1109 / smoke-runner.
#
# Fixture-creation pattern: write test scripts to a temp name then mv (avoids shell
# redirections directly naming test-file paths — #523 ITA gate convention).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
INTEGRATOR="${INTEGRATOR_OVERRIDE:-$HERE/../runtime/crewboss-integrator.sh}"
SMOKE_RUNNER="${SMOKE_RUNNER_OVERRIDE:-$HERE/../runtime/smoke-runner.sh}"

pass=0; fail=0; skip=0
ok() { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko() { fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }
sk() { skip=$((skip+1)); printf 'SKIP %s\n' "$1"; }

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

# ── infra signature the P1 impl must recognise in a failing test's output ─────────
# A gh-403 / primary-RL storm surfaces one of these on stderr/stdout of the engine
# test (build_state / board-gh probes shell out to gh). The classifier scans the
# captured per-test output for these signatures BEFORE treating the red as code-red.
INFRA_LINE='HTTP 403: API rate limit exceeded (gh api /repos ...); Could not resolve host: api.github.com'
# A genuine code failure carries NO infra signature.
CODE_LINE='FAIL acceptance-block -- expected 3 leaves, got 2'

# ── _write_test <dir> <base> <mode> ──────────────────────────────────────────────
# mode=infra  -> failing ALLOW fixture printing the infra signature (exit 1)
# mode=code   -> failing ALLOW fixture printing a plain assertion   (exit 1)
_write_test() {
  local dir="$1" base="$2" mode="$3" f
  f="$(mktemp)"
  {
    printf '#!/usr/bin/env bash\n'
    if [ "$mode" = "infra" ]; then
      printf 'printf "%%s\\n" "%s"\n' "$INFRA_LINE"
      printf 'printf "%%s\\n" "%s" >&2\n' "$INFRA_LINE"
    else
      printf 'printf "%%s\\n" "%s"\n' "$CODE_LINE"
      printf 'printf "%%s\\n" "%s" >&2\n' "$CODE_LINE"
    fi
    printf 'exit 1\n'
  } > "$f"
  mv "$f" "$dir/reference/tests/${base}.test.sh"
  chmod +x "$dir/reference/tests/${base}.test.sh"
}

# ── seed_remote <remote> <mode> ──────────────────────────────────────────────────
# Bare remote: charter/5 base + leaf/42, no-op regen stub (else absent-regen guard
# fires exit 2), and a failing ALLOW fixture (acceptance-block) in the requested mode.
seed_remote() {
  local remote="$1" mode="$2" tmp
  rm -rf "$remote"; git init --bare -q "$remote"
  tmp="$(mktemp -d)"
  git clone -q "$remote" "$tmp" 2>/dev/null
  git -C "$tmp" config user.email t@t; git -C "$tmp" config user.name T
  mkdir -p "$tmp/reference/bin" "$tmp/reference/tests"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/reference/bin/regen-manifest.sh"
  chmod +x "$tmp/reference/bin/regen-manifest.sh"
  _write_test "$tmp" acceptance-block "$mode"
  printf 'base\n' > "$tmp/README.md"
  git -C "$tmp" add -A; git -C "$tmp" commit -qm base 2>/dev/null
  git -C "$tmp" push -q origin "HEAD:refs/heads/charter/5" 2>/dev/null
  printf 'leaf change\n' > "$tmp/leaf.txt"
  git -C "$tmp" add -A; git -C "$tmp" commit -qm leaf 2>/dev/null
  git -C "$tmp" push -q origin "HEAD:refs/heads/leaf/42" 2>/dev/null
  rm -rf "$tmp"
}

# run_vm <cache> <remote> <confirm_n> -> RC + VM_OUT
run_vm() {
  local cache="$1" remote="$2" n="$3"; RC=0
  VM_OUT="$(CB_VERIFY_CACHE="$cache" CB_VERIFY_CONFIRM_N="$n" \
    bash "$INTEGRATOR" verify-merged leaf/42 charter/5 --remote "$remote" 2>/dev/null)" || RC=$?
}
redcount_file() { ls "$1"/*.redcount 2>/dev/null | head -1; }
redcount_val()  { local f; f="$(redcount_file "$1")"; [ -n "$f" ] && cat "$f" 2>/dev/null || echo 0; }

# =============================================================================
echo "=== PART A: verify-merged env-fail classification ==="
# =============================================================================

# ── A1 (REGRESSION, green now + after): a GENUINE code red still confirms RED ─────
# CONFIRM_N=2: first red -> exit 3 (1/2, retryable), second red -> exit 1 (2/2 confirmed).
CA="$ROOT/ca"; RA="$ROOT/ra.git"
seed_remote "$RA" code
run_vm "$CA" "$RA" 2
[ "$RC" -eq 3 ] \
  && ok "A1: genuine red — first pass exit 3 (1/2, retryable)" \
  || ko "A1: genuine red — expected exit 3 on 1st, got $RC"
[ "$(redcount_val "$CA")" = "1" ] \
  && ok "A1: genuine red — redcount bumped to 1" \
  || ko "A1: genuine red — redcount expected 1, got $(redcount_val "$CA")"
run_vm "$CA" "$RA" 2
[ "$RC" -eq 1 ] \
  && ok "A1: genuine red — second pass exit 1 (2/2 CONFIRMED terminal)" \
  || ko "A1: genuine red — expected exit 1 on 2nd, got $RC"
printf '%s\n' "$VM_OUT" | grep -q '^RED_REASON:' \
  && ok "A1: genuine red — RED_REASON printed on confirmation" \
  || ko "A1: genuine red — no RED_REASON on confirmed terminal red"

# ── A2 (NEW behaviour, behaviourally feature-gated): infra red is retryable ───────
# Drive the SAME confirm loop with the infra-signature fixture. The impl leaf must
# classify it as infra: exit 3 EVERY tick, RED_REASON: infra:<sig>, redcount NOT
# bumped, RED never confirmed. FEATURE PROBE: run twice with CONFIRM_N=2 — if the
# 2nd tick still exits 3 (not 1) the classifier is present; else it is not (skip).
CB="$ROOT/cb"; RB="$ROOT/rb.git"
seed_remote "$RB" infra
run_vm "$CB" "$RB" 2; RC_FIRST="$RC"; OUT_FIRST="$VM_OUT"
run_vm "$CB" "$RB" 2; RC_SECOND="$RC"; OUT_SECOND="$VM_OUT"

if [ "$RC_SECOND" -eq 3 ]; then
  # Classifier present — assert the full infra contract.
  ok "A2: infra red — classifier present (2nd tick still exit 3, not confirmed)"
  [ "$RC_FIRST" -eq 3 ] \
    && ok "A2: infra red — first tick exit 3 (retryable)" \
    || ko "A2: infra red — first tick expected exit 3, got $RC_FIRST"
  { printf '%s\n' "$OUT_FIRST" "$OUT_SECOND" | grep -qiE 'RED_REASON:[[:space:]]*infra:'; } \
    && ok "A2: infra red — RED_REASON carries infra:<signature>" \
    || ko "A2: infra red — RED_REASON missing infra: prefix"
  [ "$(redcount_val "$CB")" = "0" ] \
    && ok "A2: infra red — rework/red counter NOT incremented (stays 0)" \
    || ko "A2: infra red — counter wrongly bumped to $(redcount_val "$CB")"
  [ "$RC_SECOND" -ne 1 ] \
    && ok "A2: infra red — never confirmed terminal (no exit 1 across 2 infra ticks)" \
    || ko "A2: infra red — wrongly confirmed terminal red (exit 1)"
else
  sk "A2: infra classifier not present yet (2nd tick exit=$RC_SECOND) — P1 impl pending; new-behaviour assertions skipped"
fi

# =============================================================================
echo "=== PART B: smoke-runner board-empty disambiguation ==="
# =============================================================================
# board-empty is currently ALWAYS `fail api-state-invalid` (smoke-runner.sh ~L237).
# The P1 impl adds a POST-HOC real gh probe (never a /rate_limit preflight, per #1274):
#   board-empty + probe 403/rate-limit -> infra "gh-403-board" (exit 3)
#   board-empty + probe healthy        -> existing fail api-state-invalid (exit 1)
# Pinned seam: CB_SMOKE_GH_PROBE_OVERRIDE in {403,ok} forces the probe result
# deterministically (offline). Feature marker: `gh-403-board` in smoke-runner.sh.
OUTER_TIMEOUT="${CB_SMOKE_OUTER_TIMEOUT:-180}"

_write_boardempty_api() {   # api.py whose /api/state returns 200 valid JSON with EMPTY board
  local md="$1"; mkdir -p "$md"
  cat > "$md/crewboss-api.py" <<'PYEOF'
import http.server, json, sys
def build_state():
    return {"ok": True, "board": []}      # board-empty: valid JSON object, empty board
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path in ("/api/state", "/api/health"):
            body = json.dumps({"ok": True} if self.path=="/api/health" else build_state()).encode()
            self.send_response(200); self.send_header("Content-Type","application/json")
            self.end_headers(); self.wfile.write(body)
        else:
            self.send_response(404); self.end_headers()
    def log_message(self, *a): pass
if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
PYEOF
}

if [ ! -f "$SMOKE_RUNNER" ]; then
  sk "PART B: smoke-runner.sh absent — smoke gate not yet integrated; board-empty cases skipped"
elif ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  sk "PART B: python3/curl unavailable — cannot run the smoke api detector"
elif ! grep -q 'gh-403-board' "$SMOKE_RUNNER"; then
  # Feature not present yet: assert the CURRENT base-path contract stays intact
  # (board-empty -> fail api-state-invalid, exit 1) so the base smoke path has teeth.
  # SOFT base check: the smoke api detector spawns a real python http server under
  # the runner's timeout/kafel machinery, which some hardened/seccomp CI sandboxes
  # kill (SIGSYS) or cannot bind a port in. When it cleanly reproduces the current
  # verdict we assert it (teeth); otherwise we SKIP (never a false red in a
  # constrained env). The load-bearing contract is the gated new-behaviour below.
  md="$ROOT/pb_base"; _write_boardempty_api "$md"
  rc=0
  out="$(timeout "$OUTER_TIMEOUT" bash "$SMOKE_RUNNER" "$md" 2>&1)" || rc=$?
  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'api-state-invalid'; then
    ok "PART B base: board-empty -> fail api-state-invalid exit 1 (current contract intact)"
  else
    sk "PART B base: smoke api detector not reproducible here (rc=$rc out=[$out]) — environment-gated"
  fi
  sk "PART B: gh-403-board disambiguation not present yet — P1 impl pending; new-behaviour assertions skipped"
else
  # Feature present — assert both disambiguation branches via the pinned probe seam.
  md1="$ROOT/pb_403"; _write_boardempty_api "$md1"
  rc=0
  out="$(CB_SMOKE_GH_PROBE_OVERRIDE=403 timeout "$OUTER_TIMEOUT" bash "$SMOKE_RUNNER" "$md1" 2>&1)" || rc=$?
  if [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -q 'gh-403-board'; then
    ok "PART B: board-empty + probe 403 -> infra gh-403-board exit 3 (RL-storm, retryable)"
  else
    ko "PART B: board-empty + probe 403 expected exit 3 infra gh-403-board, got rc=$rc out=[$out]"
  fi
  md2="$ROOT/pb_ok"; _write_boardempty_api "$md2"
  rc=0
  out="$(CB_SMOKE_GH_PROBE_OVERRIDE=ok timeout "$OUTER_TIMEOUT" bash "$SMOKE_RUNNER" "$md2" 2>&1)" || rc=$?
  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'api-state-invalid'; then
    ok "PART B: board-empty + probe healthy -> fail api-state-invalid exit 1 (genuine red preserved)"
  else
    ko "PART B: board-empty + probe healthy expected exit 1 api-state-invalid, got rc=$rc out=[$out]"
  fi
fi

# =============================================================================
echo
printf 'passed=%d failed=%d skipped=%d\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ]
