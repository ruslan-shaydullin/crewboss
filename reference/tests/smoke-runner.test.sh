#!/usr/bin/env bash
# smoke-runner.test.sh — regression suite for the REAL-run smoke gate harness.
# Charter #993 / leaf `smoke-regression-tests` (issue #996).
#
# PURPOSE
#   Prove reference/runtime/smoke-runner.sh (built by the executor leaf) honours
#   its FROZEN exit-code contract:
#     exit 0 = PASS  (all applicable detectors green, or no-op pass)
#     exit 1 = FAIL  (artifact proven broken: hang/timeout, unknown flag/command,
#                     non-200, invalid/empty JSON, crash)
#     exit 2|3 = INFRA (port busy, network/rate-limit, runner self-error)
#   plus the failing-detector reason on stdout as `SMOKE_REASON: <detector>`.
#
#   WHY this gate exists: bugs of class "built but does not run live" pass current
#   gates because mock-`gh` answers OK to anything. Real 2026-06-29 examples
#   (charter #969, auto-merged green but fully broken):
#     - `gh issue list --paginate` is a NON-EXISTENT flag -> every call dies
#       `unknown flag` (catches #969).
#     - `api.py` with `while True:` and no exit -> `/api/state` hangs (catches #973).
#
# NO MOCK/STUB OF gh ANYWHERE — that is the whole point of the smoke gate. The
# hermetic RED cases are hermetic BY NATURE (gh flag-parse rejection happens before
# any network; the per-detector timeout fires on the artifact's own hang), NOT by
# mocking gh.
#
# CLASSIFICATION: EXCLUDED in reference/runtime/per-leaf-manifest — this suite
# spawns processes (smoke-runner.sh), relies on per-detector timeouts, and has a
# real-gh/network PASS lane. It is therefore NOT part of the ALLOW-filtered per-leaf
# verify-merged suite (fail-closed default).
#
# Requires: bash, timeout, python3 (case 1), gh (case 2/3), network+token+board (case 3).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SMOKE_RUNNER="${SMOKE_RUNNER_OVERRIDE:-$HERE/../runtime/smoke-runner.sh}"

pass=0; fail=0; skip=0
ok() { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko() { fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }
sk() { skip=$((skip+1)); printf 'SKIP %s\n' "$1"; }

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

# Outer bound so a BROKEN runner that itself hangs cannot wedge this test. It must
# comfortably exceed the runner's own per-detector timeout; if the outer bound is
# hit we treat it as FAIL (the gate must never itself hang — that is case 1's point).
OUTER_TIMEOUT="${CB_SMOKE_OUTER_TIMEOUT:-180}"

# ── Pre-flight: the harness must exist to be tested ──────────────────────────────
# In a pre-integration tree (the runner is a sibling leaf landing in the same
# charter) smoke-runner.sh may be absent. SKIP cleanly — never a silent pass of a
# broken artifact, just "nothing to test here yet".
if [ ! -f "$SMOKE_RUNNER" ]; then
  sk "harness absent at $SMOKE_RUNNER — smoke-runner.sh not yet integrated; live cases skipped"
  printf 'passed=%d failed=%d skipped=%d\n' "$pass" "$fail" "$skip"
  exit 0
fi

# =============================================================================
# Case 1 — HERMETIC RED: api hang (catches #973)
#   Fixture api.py whose build_state() never returns (`while True:`), so /api/state
#   hangs. The runner's PER-DETECTOR timeout MUST fire and produce exit 1 — proving
#   both that the timeout works AND that the gate itself does not hang. Offline.
# =============================================================================
echo "=== Case 1: HERMETIC RED — api.py hang (#973) -> exit 1 by per-detector timeout ==="
if ! command -v python3 >/dev/null 2>&1; then
  sk "case1 api-hang: python3 unavailable — cannot build the hanging api.py fixture"
else
  md="$ROOT/case1"; mkdir -p "$md"
  cat > "$md/api.py" <<'PYEOF'
import http.server, json, sys

def build_state():
    # #973 reproduction: never returns -> any caller of /api/state hangs forever.
    while True:
        pass

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/api/state":
            state = build_state()          # <-- hangs here, response never sent
            body = json.dumps(state).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()
    def log_message(self, *a):
        pass

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
PYEOF

  rc=0
  out="$(timeout "$OUTER_TIMEOUT" bash "$SMOKE_RUNNER" "$md" 2>&1)" || rc=$?
  if [ "$rc" -eq 124 ]; then
    ko "case1 api-hang: OUTER timeout hit (rc=124) — the smoke gate ITSELF hung (per-detector timeout broken)"
  elif [ "$rc" -eq 1 ]; then
    ok "case1 api-hang: exit 1 — per-detector timeout fired, gate did not hang (#973)"
    printf '%s\n' "$out" | grep -q '^SMOKE_REASON:' \
      && ok "case1 api-hang: SMOKE_REASON emitted on stdout" \
      || ko "case1 api-hang: contract violation — no 'SMOKE_REASON:' on stdout"
  else
    ko "case1 api-hang: expected exit 1 (FAIL), got $rc"
  fi
fi

# =============================================================================
# Case 2 — HERMETIC RED: bad gh flag (catches #969)
#   Fixture *.sh invoking `gh issue list --paginate` (a NON-EXISTENT flag). gh
#   rejects it at PARSE time -> `unknown flag`, so NO network is needed. The runner
#   MUST surface this as exit 1 with `unknown flag` detected. Offline.
# =============================================================================
echo "=== Case 2: HERMETIC RED — bad gh flag (#969) -> exit 1, unknown flag ==="
if ! command -v gh >/dev/null 2>&1; then
  sk "case2 bad-gh-flag: gh binary unavailable — cannot exercise flag-parse rejection"
else
  md="$ROOT/case2"; mkdir -p "$md"
  cat > "$md/run.sh" <<'SHEOF'
#!/usr/bin/env bash
# #969 reproduction: --paginate is not a real `gh issue list` flag; gh dies
# `unknown flag: --paginate` at argument-parse time (before any API call).
set -e
gh issue list --paginate
SHEOF
  chmod +x "$md/run.sh"

  rc=0
  out="$(timeout "$OUTER_TIMEOUT" bash "$SMOKE_RUNNER" "$md" 2>&1)" || rc=$?
  if [ "$rc" -eq 124 ]; then
    ko "case2 bad-gh-flag: OUTER timeout hit (rc=124) — gate hung on a parse-time rejection"
  elif [ "$rc" -eq 1 ]; then
    ok "case2 bad-gh-flag: exit 1 — runner surfaced the broken artifact (#969)"
    printf '%s\n' "$out" | grep -qi 'unknown flag' \
      && ok "case2 bad-gh-flag: 'unknown flag' detected in output" \
      || ko "case2 bad-gh-flag: exit 1 but 'unknown flag' not surfaced in output"
  else
    ko "case2 bad-gh-flag: expected exit 1 (FAIL), got $rc"
  fi
fi

# =============================================================================
# Case 3 — GATED valid-PASS lane (real gh + network + board, BOX-ONLY)
#   Valid artifacts -> exit 0. This needs a LIVE gh token + reachable board, so it
#   is EXPLICITLY SKIPPED (not stubbed, not silent-passed) when no live credentials
#   are present (e.g. GHA). It must NEVER be quietly mocked.
# =============================================================================
echo "=== Case 3: GATED valid-PASS lane (real gh+network+board) -> exit 0 ==="
_live=0
if [ "${CB_SMOKE_LIVE:-}" = "1" ] && command -v gh >/dev/null 2>&1; then
  if [ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ] || gh auth status >/dev/null 2>&1; then
    _live=1
  fi
fi
if [ "$_live" -ne 1 ]; then
  sk "case3 valid-PASS: no live gh token/board (set CB_SMOKE_LIVE=1 + auth) — SKIP, never mocked"
else
  # A valid artifact: api.py whose /api/state returns prompt, valid JSON quickly.
  md="$ROOT/case3"; mkdir -p "$md"
  cat > "$md/api.py" <<'PYEOF'
import http.server, json, sys

def build_state():
    return {"ok": True}

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/api/state":
            body = json.dumps(build_state()).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()
    def log_message(self, *a):
        pass

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
PYEOF

  rc=0
  out="$(timeout "$OUTER_TIMEOUT" bash "$SMOKE_RUNNER" "$md" 2>&1)" || rc=$?
  case "$rc" in
    0) ok "case3 valid-PASS: exit 0 on live valid artifacts" ;;
    2|3) sk "case3 valid-PASS: INFRA (exit $rc — port/network/rate-limit), not a verdict on the artifact" ;;
    *) ko "case3 valid-PASS: expected exit 0 on a valid artifact, got $rc -- $out" ;;
  esac
fi

# =============================================================================
# Case 4 — Base-path-intact regression
#   Prove the smoke layer did not break the existing engine path: a representative
#   slice of the ALLOW engine-suite must still be green. (Full verify-merged final
#   PASS on a valid tree is exercised by leaf-verifier.test.sh; here we keep a fast,
#   non-flaky sentinel so this suite stays self-contained and hermetic.)
# =============================================================================
echo "=== Case 4: base-path-intact — representative engine tests still green ==="
_base_ok=1
for _t in acceptance-block runtime-lint manifest-stat; do
  _tf="$HERE/$_t.test.sh"
  if [ ! -f "$_tf" ]; then
    ko "case4 base-path: engine test missing: $_t.test.sh"
    _base_ok=0
    continue
  fi
  if bash "$_tf" >/dev/null 2>&1; then
    ok "case4 base-path: engine test green — $_t"
  else
    ko "case4 base-path: engine test RED — $_t (smoke layer regressed the base path)"
    _base_ok=0
  fi
done
[ "$_base_ok" -eq 1 ] \
  && ok "case4 base-path: representative engine slice intact" \
  || ko "case4 base-path: base engine path regressed"

# =============================================================================
echo
printf 'passed=%d failed=%d skipped=%d\n' "$pass" "$fail" "$skip"
[ "$fail" = 0 ]
