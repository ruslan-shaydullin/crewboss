#!/usr/bin/env bash
# smoke-runner.sh — REAL-run smoke gate for crewboss pre-merge verification.
# Charter #993 / leaf `smoke-runner` (issue #997).
#
# WHY THIS EXISTS
#   A whole bug class — "built but does not run live" — slips through the existing
#   gates because the loop's offline fakes answer OK to anything. Real 2026-06-29
#   breakages (charter #969 auto-merged green yet fully broken):
#     - `gh issue list --paginate`  -> --paginate is a NON-EXISTENT flag; every call
#       dies at parse time with `unknown flag`.
#     - `crewboss-api.py` with `while True:` and no exit -> `/api/state` hangs forever
#       (charter #973).
#   This harness re-runs the real artifacts (real `gh`, real process starts) under
#   per-detector timeouts and PROVES whether they actually run, before merge.
#
# REAL-RUN ONLY. Nothing here fakes `gh` or fakes a server — that defeats the gate.
# A reviewer + security reviewer enforce that acceptance manually.
#
# FROZEN CONTRACT (checkpoint 2):
#   Invocation:  smoke-runner.sh <merged_dir>
#   Changed files derived INTERNALLY from `git diff --name-only <base>..HEAD` on the
#   merged tree, or read from env CB_SMOKE_CHANGED. Exit codes (aligned with the
#   engine-suite path in crewboss-integrator.sh):
#     0 = PASS    all applicable detectors green, OR no applicable detector (no-op).
#     1 = FAIL    a detector PROVED the artifact broken: hang/timeout-of-artifact,
#                 unknown flag/command, non-200, invalid/empty JSON, crash.
#     2|3 = INFRA port busy, network/rate-limit, runner self-error -- never a silent pass.
#   On FAIL, the failing detector is printed to stdout as `SMOKE_REASON: <detector>`
#   (the integrator reuses it for the cache .reason). This script ONLY emits exit
#   codes + SMOKE_REASON; it never edits or invokes crewboss-integrator.sh.
#
# Requires: bash, timeout, curl; python3 for the api detector; gh for the .sh detector.
set -u

# ── Tunables (per-detector timeouts — lesson #973: a hanging artifact must fail BY
#    timeout with exit 1 and must NEVER wedge the runner itself) ──────────────────
SMOKE_TIMEOUT="${CB_SMOKE_TIMEOUT:-20}"      # per-detector wall-clock budget (seconds)
STARTUP_TIMEOUT="${CB_SMOKE_STARTUP:-10}"    # seconds to wait for a started server to listen

# Optional seccomp confinement for spawned detectors. reference/runtime/claude.kafel
# is a DEFAULT-KILL + allow-list policy already present in the repo. We wrap detector
# subprocesses with it ONLY when a kafel runner is actually available, so the gate
# degrades safely on hosts without it (coordinated with the security reviewer, cp3).
KAFEL_POLICY="${CB_SMOKE_KAFEL:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/claude.kafel}"
# CONFINE is an executable PREFIX (not a shell function, so it composes after the
# per-detector `timeout`). It expands to the kafel runner when available, else empty.
CONFINE=()
if command -v kafel >/dev/null 2>&1 && [ -f "$KAFEL_POLICY" ]; then
  CONFINE=(kafel -f "$KAFEL_POLICY" --)
fi

API_PID=""
_TMP=()
cleanup() {
  if [ -n "$API_PID" ]; then
    kill "$API_PID" 2>/dev/null
    wait "$API_PID" 2>/dev/null
    API_PID=""
  fi
  local t
  for t in ${_TMP[@]+"${_TMP[@]}"}; do rm -f "$t" 2>/dev/null; done
}
trap cleanup EXIT INT TERM

fail()  { printf 'SMOKE_REASON: %s\n' "$1"; exit 1; }
infra() { printf 'SMOKE_REASON: infra:%s\n' "$1"; exit "${2:-2}"; }
mktmp() { local f; f="$(mktemp)"; _TMP+=("$f"); printf '%s' "$f"; }

# ── Argument / merged-tree resolution ────────────────────────────────────────────
MERGED_DIR="${1:-}"
[ -n "$MERGED_DIR" ] || infra "usage:smoke-runner.sh <merged_dir>" 3
[ -d "$MERGED_DIR" ] || infra "merged-dir-missing" 3
MERGED_DIR="$(cd "$MERGED_DIR" && pwd)"

# ── Derive the changed-file set (command-injection safe: paths are only ever used
#    quoted, never eval'd) ──────────────────────────────────────────────────────────
FILES=()
# #1015: the real-run smoke gate validates LIVE RUNTIME artifacts (proto/,
# reference/runtime/, ui/server/) — NOT test-suite files and NOT the frozen box
# snapshot. Test files intentionally embed broken commands as NEGATIVE fixtures
# (`gh issue list --paginate`, `while True:`) and `_box-snapshot/` is a captured
# mirror, not a deployable artifact; EXECUTING either here is a false RED rather
# than a real-artifact failure. Both are skipped from every selection path.
_is_excluded() {
  case "$1" in
    *.test.sh|*.test.py)             return 0 ;;
    */tests/*|tests/*)               return 0 ;;
    */_box-snapshot/*|_box-snapshot/*) return 0 ;;
  esac
  return 1
}
add_file() {
  local p="$1"
  _is_excluded "$p" && return 0
  case "$p" in
    /*) : ;;
    *)  p="$MERGED_DIR/$p" ;;
  esac
  [ -f "$p" ] && FILES+=("$p")
}
_find_artifacts() {
  while IFS= read -r line; do
    [ -n "$line" ] && { _is_excluded "$line" || FILES+=("$line"); }
  done < <(find "$MERGED_DIR" -type f \( -name '*.sh' -o -name '*api.py' \) 2>/dev/null)
}

if [ -n "${CB_SMOKE_CHANGED:-}" ]; then
  # env-provided list (newline or whitespace separated)
  while IFS= read -r line; do
    [ -n "$line" ] && add_file "$line"
  done < <(printf '%s\n' "$CB_SMOKE_CHANGED" | tr ' \t' '\n\n')
elif git -C "$MERGED_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  # #1015: a merged tree (charter integration) is built by the integrator with
  # `git merge --no-commit --no-ff origin/<leaf>` onto origin/<base>, so HEAD is the
  # BASE and the leaf's change set is exactly the uncommitted diff (`git diff HEAD`).
  # Scope the smoke to THAT change set (plus an explicit CB_SMOKE_BASE..HEAD diff if a
  # committed merge is used) so every artifact the leaf TOUCHES is smoked WITHOUT
  # re-running unchanged snapshots / test fixtures each merge — the #969-class false
  # RED. If neither yields a change set (e.g. a clean checkout) fall back to the
  # detector-relevant whole-tree scan — never a silent no-op false-green.
  _changed="$( { git -C "$MERGED_DIR" diff --name-only HEAD 2>/dev/null; \
                 [ -n "${CB_SMOKE_BASE:-}" ] && \
                   git -C "$MERGED_DIR" diff --name-only "${CB_SMOKE_BASE}..HEAD" 2>/dev/null; \
               } | sort -u )"
  if [ -n "$_changed" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] && add_file "$line"
    done < <(printf '%s\n' "$_changed")
  else
    _find_artifacts
  fi
else
  # No git metadata (e.g. a hermetic fixture tree) -> enumerate the detector-relevant
  # artifacts present in the merged dir. We scope find to the file types we smoke,
  # so this never fans out across an entire repo.
  _find_artifacts
fi

if [ "${#FILES[@]}" -eq 0 ]; then
  # No applicable artifact -> contractual no-op PASS.
  exit 0
fi

# =============================================================================
# Detector: crewboss-api.py — start on an ephemeral port and prove it RUNS LIVE.
#   /api/health (no auth) -> HTTP 200 + body {ok:true}
#   /api/state  (real bearer) -> HTTP 200, valid JSON OBJECT (not a list, not empty),
#                                `board` key present and non-empty, returns BEFORE
#                                the per-detector timeout.
#   Catches #973 (state hang) and #969 surfacing inside the api. Process is killed
#   cleanly afterwards.
# =============================================================================
free_port() {
  python3 - <<'PY' 2>/dev/null
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

detect_api() {
  local api="$1"
  command -v python3 >/dev/null 2>&1 || infra "python3-missing" 2
  command -v curl    >/dev/null 2>&1 || infra "curl-missing" 2

  local port; port="$(free_port)"
  [ -n "$port" ] || infra "no-free-port" 2

  local tok="cb-smoke-$$-${RANDOM}"
  local log; log="$(mktmp)"

  # Dual port-passing so this works for BOTH a positional-arg server and a
  # --port/CB_API_PORT server, without ever inspecting which: env + positional.
  CB_API_TOKEN="$tok" CB_API_PORT="$port" \
  CB_REPO="${CB_REPO:-crewboss/crewboss}" CB_HOME="$(dirname "$api")" \
    ${CONFINE[@]+"${CONFINE[@]}"} python3 "$api" "$port" >"$log" 2>&1 &
  API_PID=$!

  # Wait for the server to actually listen (or die on startup).
  local i up=0 deadline=$(( STARTUP_TIMEOUT * 5 ))
  for (( i=0; i<deadline; i++ )); do
    if ! kill -0 "$API_PID" 2>/dev/null; then up=2; break; fi   # process exited
    if curl -s -m 2 -o /dev/null "http://127.0.0.1:$port/api/health" 2>/dev/null; then
      up=1; break
    fi
    sleep 0.2
  done

  if [ "$up" -ne 1 ]; then
    # Did the artifact crash on boot, or is this an environment problem?
    if grep -Eqi 'address already in use' "$log"; then
      _api_kill; infra "api-port-busy" 2
    fi
    if grep -Eqi 'Traceback|SyntaxError|ImportError|ModuleNotFoundError' "$log"; then
      _api_kill; fail "api-start-crash:$(basename "$api")"
    fi
    _api_kill; infra "api-no-start:$(basename "$api")" 2
  fi

  # Health (no auth).
  local hbody hcode hrc
  hbody="$(mktmp)"
  hcode="$(timeout "$SMOKE_TIMEOUT" curl -s -m "$SMOKE_TIMEOUT" \
            -o "$hbody" -w '%{http_code}' \
            "http://127.0.0.1:$port/api/health" 2>/dev/null)"; hrc=$?

  # State (real bearer) — wrapped so a hang fails BY timeout, never wedges us.
  local sbody scode src
  sbody="$(mktmp)"
  scode="$(timeout "$SMOKE_TIMEOUT" curl -s -m "$SMOKE_TIMEOUT" \
            -o "$sbody" -w '%{http_code}' \
            -H "Authorization: Bearer $tok" \
            "http://127.0.0.1:$port/api/state" 2>/dev/null)"; src=$?

  _api_kill

  # Verdict. State-hang takes priority — it is the #973 detector.
  if [ "$src" -eq 124 ] || [ "$src" -eq 28 ] || [ "$scode" = "000" ] || [ -z "$scode" ]; then
    fail "api-state-timeout:$(basename "$api")"
  fi
  if [ "$hrc" -ne 0 ] || [ "$hcode" != "200" ]; then
    fail "api-health-non-200:$(basename "$api")"
  fi
  if ! grep -Eq '"ok"[[:space:]]*:[[:space:]]*true' "$hbody"; then
    fail "api-health-body:$(basename "$api")"
  fi
  if [ "$scode" != "200" ]; then
    fail "api-state-non-200:$(basename "$api")"
  fi
  if ! python3 - "$sbody" <<'PY' >/dev/null 2>&1
import sys, json
d = json.load(open(sys.argv[1]))
assert isinstance(d, dict), "not-object"
b = d.get("board")
assert b is not None and len(b) > 0, "board-empty"
PY
  then
    fail "api-state-invalid:$(basename "$api")"
  fi
  # All api assertions green.
}

_api_kill() {
  if [ -n "$API_PID" ]; then
    kill "$API_PID" 2>/dev/null
    wait "$API_PID" 2>/dev/null
    API_PID=""
  fi
}

# =============================================================================
# Detector: *.sh that shells out to `gh` — actually EXECUTE the script's key real-gh
#   command against REAL gh under timeout. Assert exit 0, NO `unknown flag`/`unknown
#   command` in output, output sensible. Catches #969 (launcher / board-gh).
#
#   Selection is economical (one cheap key command per script — shared 5000/h budget)
#   and injection-safe: we run either a literal READ-ONLY gh command lifted verbatim
#   from the script (whitespace-tokenised into an argv, NEVER eval'd, rejected if it
#   carries shell metacharacters or variables), or a known read-only entrypoint for a
#   recognised adapter. We never blindly run an arbitrary script body.
# =============================================================================
sh_key_invocation() {
  # Echoes a whitespace-tokenisable argv to run, or returns 1 if nothing is safely
  # runnable. Output is validated free of shell metacharacters/variables.
  local s="$1" raw cmd
  while IFS= read -r raw; do
    cmd="${raw#"${raw%%[![:space:]]*}"}"          # ltrim
    case "$cmd" in gh\ *) : ;; *) continue ;; esac
    # Reject anything carrying variables, substitution, pipes, redirects, etc.
    case "$cmd" in
      *'$'*|*'`'*|*';'*|*'|'*|*'&'*|*'<'*|*'>'*|*'('*|*')'*|*'{'*|*'}'*|*'"'*|*"'"*) continue ;;
    esac
    # Only run-safe, read-only verbs.
    case "$cmd" in
      "gh issue list"*|"gh issue view"*|"gh pr list"*|"gh pr view"*|\
      "gh repo view"*|"gh search "*|"gh label list"*|"gh run list"*|\
      "gh workflow list"*|"gh auth status"*)
        printf '%s\n' "$cmd"; return 0 ;;
    esac
  done < "$s"
  # Known read-only adapter entrypoints (cheap key command).
  case "$(basename "$s")" in
    *board-gh.sh) printf 'bash %s launchable\n' "$s"; return 0 ;;
  esac
  return 1
}

detect_sh() {
  local s="$1" inv out rc
  command -v gh >/dev/null 2>&1 || infra "gh-missing" 2

  inv="$(sh_key_invocation "$s")" || return 0   # nothing safely runnable -> no-op pass
  local _argv=()
  read -ra _argv <<< "$inv"
  [ "${#_argv[@]}" -gt 0 ] || return 0

  # The per-detector `timeout` wrapper stays OUTSIDE confinement (it must keep its
  # own timer); only the detector command itself is confined.
  out="$( cd "$MERGED_DIR" && CB_REPO="${CB_REPO:-crewboss/crewboss}" \
          timeout "$SMOKE_TIMEOUT" ${CONFINE[@]+"${CONFINE[@]}"} "${_argv[@]}" 2>&1 )"; rc=$?

  # Surface the artifact's OWN output so the real failure (e.g. gh's verbatim
  # `unknown flag: --paginate`) is visible to a reviewer and to the reason cache.
  if [ "$rc" -eq 124 ]; then
    printf '%s\n' "$out" >&2
    fail "sh-timeout:$(basename "$s")"
  fi
  if printf '%s' "$out" | grep -Eqi 'unknown (flag|command|shorthand)'; then
    printf '%s\n' "$out" >&2
    fail "sh-unknown-flag:$(basename "$s")"
  fi
  if printf '%s' "$out" | grep -Eqi 'command not found|syntax error|Traceback'; then
    printf '%s\n' "$out" >&2
    fail "sh-crash:$(basename "$s")"
  fi
  if [ "$rc" -eq 0 ]; then
    return 0   # ran clean
  fi
  # Non-zero without a proven-broken signal: most likely auth/network/rate-limit.
  # That is INFRA — we could not complete the smoke, but we did not prove the
  # artifact broken. Never a silent pass.
  if printf '%s' "$out" | grep -Eqi 'auth|token|rate limit|API rate|could not|network|timed out|HTTP 4|HTTP 5|Bad credentials|gh auth login|connection'; then
    infra "sh-gh-unreachable:$(basename "$s")" 2
  fi
  infra "sh-indeterminate:$(basename "$s")" 2
}

# =============================================================================
# Dispatch — apply each applicable detector. A failing detector exits immediately
# (fail/infra are terminal); if every applicable detector is green we fall through
# to the contractual PASS.
# =============================================================================
for f in "${FILES[@]}"; do
  # Smoke ONLY real, deployed runtime artifacts. Skip:
  #   * test files (*.test.sh / *.test.py) and anything under a tests/ directory —
  #     they intentionally embed BROKEN/LEGACY gh fixtures (e.g. a `gh issue list
  #     --paginate` #969 reproduction) that are NOT a deploy defect; running them
  #     live would self-RED the gate on its own regression corpus.
  #   * the frozen _box-snapshot/ capture — a historical box image, not a live
  #     artifact tree; it is exercised through deploy, never smoked in place.
  # This selection is what makes the gate a deploy-defect detector rather than a
  # whole-repo grep for the substring "--paginate".
  case "$f" in
    *.test.sh|*.test.py|*/tests/*|*/_box-snapshot/*) continue ;;
  esac
  case "$(basename "$f")" in
    *api.py) detect_api "$f" ;;
  esac
  case "$f" in
    *.sh)
      if grep -q 'gh ' "$f" 2>/dev/null; then
        detect_sh "$f"
      fi
      ;;
  esac
done

exit 0
