#!/usr/bin/env bash
# smoke-runner.test.sh — regression suite for the REAL-run smoke gate harness.
# charter #993, leaf `smoke-regression-tests` (issue #996).
#
# WHAT THIS PINS
#   cmd_verify_merged (reference/runtime/crewboss-integrator.sh) now invokes
#   reference/runtime/smoke-runner.sh <merged_dir> as a REAL-run gate. This suite
#   proves the harness honours its FROZEN exit-code contract — the class of bug it
#   exists to catch ("built but does not run live") slipped past every mock-green
#   gate before (#969 `gh issue list --paginate` = non-existent flag; #973
#   `api.py while True:` = /api/state hangs).
#
# FROZEN exit-code contract (consumed, never re-implemented here):
#   exit 0   = PASS  (all applicable detectors green, OR no applicable detector -> no-op pass)
#   exit 1   = FAIL  (artifact proven broken: hang/timeout-of-artifact, unknown flag/command,
#                     non-200, invalid/empty JSON, crash)
#   exit 2|3 = INFRA (port busy, network/rate-limit, runner self-error) — never a silent pass
#   failing-detector reason on stdout as `SMOKE_REASON: <detector>`
#
# NO mock / NO stub of gh ANYWHERE. The hermetic RED cases are hermetic BY NATURE —
#   flag-parse rejection (gh rejects an unknown flag before any network) and
#   per-detector timeout (a hung artifact is detected by the wall clock) — NEVER by
#   mocking gh. Mocking gh is exactly the false-green this gate exists to kill.
#
# CLASSIFICATION: EXCLUDED in reference/runtime/per-leaf-manifest (process-spawn,
#   per-detector timing, real-gh BOX-only valid-PASS lane) -> GHA full suite only,
#   never the per-leaf ALLOW gate (fail-closed default).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
RUNNER="${SMOKE_RUNNER_OVERRIDE:-$HERE/../runtime/smoke-runner.sh}"
API_SRC="$HERE/../../ui/server/crewboss-api.py"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0; skip=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }
sk(){ skip=$((skip+1)); printf 'SKIP %s\n' "$1"; }

# Safety wrapper: a broken runner must NEVER hang this suite. The runner owns its own
# per-detector timeout (contract); this outer bound is belt-and-suspenders. A fired
# outer timeout (124) means the runner failed to self-bound -> contract violation.
TIMEOUT_BIN="$(command -v timeout || true)"
# Use the outer timeout ONLY if it actually works here. The runner owns its own
# per-detector timeout (frozen contract); this outer bound is belt-and-suspenders.
if [ -n "$TIMEOUT_BIN" ] && ! "$TIMEOUT_BIN" 1 true >/dev/null 2>&1; then
  TIMEOUT_BIN=""   # present but non-functional (e.g. sandboxed) -> direct invocation
fi
RC=0; ROUT=""
run_runner(){ # $1 = merged_dir ; sets RC and ROUT
  local md="$1"
  if [ -n "$TIMEOUT_BIN" ]; then
    ROUT="$("$TIMEOUT_BIN" 90 bash "$RUNNER" "$md" 2>&1)"; RC=$?
  else
    ROUT="$(bash "$RUNNER" "$md" 2>&1)"; RC=$?
  fi
}

# ── Guard: runner is delivered by the executor leaf (smoke-runner.sh). On a branch
#    where it has not yet been merged we cannot exercise the contract — SKIP cleanly
#    (never silently pass a mocked stand-in). On integration the file is present and
#    every case below runs for real. ─────────────────────────────────────────────
if [ ! -f "$RUNNER" ]; then
  echo "=== smoke-runner.sh not present — suite SKIPPED (built by executor leaf; runs on integration merge) ==="
  sk "runner absent: $RUNNER"
  printf '\n=== SUMMARY: %d passed, %d failed, %d skipped ===\n' "$pass" "$fail" "$skip"
  [ "$fail" -eq 0 ]; exit
fi

# =============================================================================
# Case 1: HERMETIC RED — api hang (catches #973)
#   Fixture mirrors the real artifact path (ui/server/crewboss-api.py) but injects a
#   non-terminating build_state (`while True:`). GET /api/state therefore never
#   returns. smoke-runner MUST exit 1 BY TIMEOUT — proving (a) the per-detector
#   timeout fires and (b) the gate itself does NOT hang. Fully offline.
# =============================================================================
echo "=== Case 1: HERMETIC RED — api hang (#973) -> exit 1 by per-detector timeout ==="
MD1="$TMP/md1"; mkdir -p "$MD1/ui/server"
if [ -f "$API_SRC" ]; then
  # Faithful: copy the real server, then replace build_state's body with a hang so the
  # server still binds + routes exactly as production, but /api/state never returns.
  python3 - "$API_SRC" "$MD1/ui/server/crewboss-api.py" <<'PY'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
t = open(src).read().splitlines(keepends=True)
out, i, n = [], 0, len(t)
while i < n:
    line = t[i]
    if re.match(r'\s*def build_state\s*\(', line):
        indent = re.match(r'(\s*)', line).group(1)
        out.append(line)
        out.append(indent + "    # charter #973 fixture: never returns -> /api/state hangs\n")
        out.append(indent + "    while True:\n")
        out.append(indent + "        pass\n")
        i += 1
        # skip the original body (deeper-indented lines) until dedent to def level
        while i < n:
            nxt = t[i]
            if nxt.strip() == "" :
                i += 1; continue
            ind = re.match(r'(\s*)', nxt).group(1)
            if len(ind) <= len(indent):
                break
            i += 1
        continue
    out.append(line); i += 1
open(dst, "w").write("".join(out))
PY
else
  # Self-contained fallback: minimal but real ThreadingHTTPServer with a hanging
  # /api/state. No mocking — a genuine live server that genuinely hangs.
  cat > "$MD1/ui/server/crewboss-api.py" <<'PY'
#!/usr/bin/env python3
import os, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
PORT = int(sys.argv[sys.argv.index("--port")+1]) if "--port" in sys.argv else int(os.environ.get("PORT","8765"))
def build_state():
    # charter #973 fixture: never returns -> /api/state hangs
    while True:
        pass
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path == "/api/state":
            build_state()  # hangs forever
        self.send_response(404); self.end_headers()
if __name__ == "__main__":
    ThreadingHTTPServer((os.environ.get("CB_API_HOST","127.0.0.1"), PORT), H).serve_forever()
PY
fi
run_runner "$MD1"
if [ "$RC" -eq 1 ]; then
  ok "api-hang: exit 1 (artifact proven broken by timeout)"
elif [ "$RC" -eq 124 ]; then
  ko "api-hang: outer timeout fired (RC=124) — runner did NOT self-bound the hang (contract violation)"
else
  ko "api-hang: expected exit 1, got $RC — output: $ROUT"
fi
printf '%s\n' "$ROUT" | grep -q 'SMOKE_REASON:' \
  && ok "api-hang: SMOKE_REASON emitted on a failing detector" \
  || sk "api-hang: no SMOKE_REASON line (contract recommends one; not asserting hard)"

# =============================================================================
# Case 2: HERMETIC RED — bad gh flag (catches #969)
#   Fixture script calls `gh issue list --paginate` — a NON-EXISTENT flag. gh rejects
#   it at PARSE time, so NO network is required: the failure is deterministic and
#   offline. smoke-runner MUST exit 1 and the reason MUST mention the unknown flag.
#   Requires a REAL gh binary (we DO NOT mock — that is the whole point); SKIP if absent.
# =============================================================================
echo "=== Case 2: HERMETIC RED — bad gh flag (#969) -> exit 1, unknown flag ==="
if ! command -v gh >/dev/null 2>&1; then
  sk "bad-gh-flag: real gh binary not on PATH (NO mock allowed) — cannot exercise offline"
else
  MD2="$TMP/md2"; mkdir -p "$MD2/reference/runtime"
  cat > "$MD2/reference/runtime/board-gh.sh" <<'SH'
#!/usr/bin/env bash
# charter #969 fixture: a non-existent gh flag -> gh dies "unknown flag" at parse time.
gh issue list --paginate --json number
SH
  chmod +x "$MD2/reference/runtime/board-gh.sh"
  run_runner "$MD2"
  if [ "$RC" -eq 1 ]; then
    ok "bad-gh-flag: exit 1 (unknown flag rejected at parse time, offline)"
  elif [ "$RC" -eq 124 ]; then
    ko "bad-gh-flag: outer timeout fired (RC=124) — runner self-hang (contract violation)"
  else
    ko "bad-gh-flag: expected exit 1, got $RC — output: $ROUT"
  fi
  printf '%s\n' "$ROUT" | grep -Eqi 'unknown flag|SMOKE_REASON:' \
    && ok "bad-gh-flag: failure reason surfaced (unknown flag / SMOKE_REASON)" \
    || ko "bad-gh-flag: no unknown-flag / SMOKE_REASON in output — $ROUT"
fi

# =============================================================================
# Case 3: GATED valid-PASS lane (BOX-ONLY, real gh + network + board)
#   Valid artifacts -> smoke-runner exit 0. This needs a LIVE gh token + reachable
#   board + network, so it runs ONLY when explicitly opted in (CB_SMOKE_LIVE=1 and a
#   token present). Otherwise it is EXPLICITLY SKIPPED — never stubbed, never a silent
#   mock-pass. It must NEVER be quietly mocked (e.g. on GHA without a box token).
# =============================================================================
echo "=== Case 3: GATED valid-PASS lane (real-gh, BOX-only; SKIP without live token/board) ==="
_have_token=0
[ -n "${GH_TOKEN:-}" ] || [ -n "${GITHUB_TOKEN:-}" ] && _have_token=1
if [ "${CB_SMOKE_LIVE:-0}" != "1" ] || [ "$_have_token" -ne 1 ] || ! command -v gh >/dev/null 2>&1; then
  sk "valid-PASS: no live token/board (CB_SMOKE_LIVE!=1 or no GH_TOKEN/gh) — SKIP, NOT mocked"
else
  # Real tree: the repo's own ui/server + runtime are valid live artifacts.
  MD3="$TMP/md3"; mkdir -p "$MD3/ui/server" "$MD3/reference/runtime"
  if [ -f "$API_SRC" ]; then cp "$API_SRC" "$MD3/ui/server/crewboss-api.py"; fi
  run_runner "$MD3"
  if [ "$RC" -eq 0 ]; then
    ok "valid-PASS: exit 0 on valid live artifacts"
  elif [ "$RC" -eq 2 ] || [ "$RC" -eq 3 ]; then
    sk "valid-PASS: INFRA (RC=$RC: port busy / network / rate-limit) — not a leaf failure"
  else
    ko "valid-PASS: expected exit 0 on valid artifacts, got $RC — $ROUT"
  fi
fi

# =============================================================================
# Case 4: Base-path-intact regression
#   A merged tree with NO smoke-applicable artifact must yield a no-op PASS (exit 0)
#   per the frozen contract. This proves the smoke layer is a transparent pass-through
#   and did NOT break the base verify-merged path (no false-RED on detector-free trees).
#   Fully offline + hermetic.
# =============================================================================
echo "=== Case 4: base-path-intact — no applicable detector -> no-op PASS (exit 0) ==="
MD4="$TMP/md4"; mkdir -p "$MD4/reference/runtime"
cat > "$MD4/reference/runtime/inert.sh" <<'SH'
#!/usr/bin/env bash
# inert: no gh call, no api, no live surface — nothing for smoke to detect.
echo "inert artifact"
SH
chmod +x "$MD4/reference/runtime/inert.sh"
run_runner "$MD4"
if [ "$RC" -eq 0 ]; then
  ok "base-path: no-op PASS (exit 0) on a detector-free tree — base path intact"
elif [ "$RC" -eq 124 ]; then
  ko "base-path: outer timeout (RC=124) on an inert tree — runner self-hang"
else
  ko "base-path: expected exit 0 (no-op pass), got $RC — $ROUT"
fi

printf '\n=== SUMMARY: %d passed, %d failed, %d skipped ===\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ]
