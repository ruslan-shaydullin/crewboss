#!/usr/bin/env bash
# board-charter-visibility.test.sh — regression test for charter eviction fix (#947,
# charter #499).
#
# Proves that build_state() uses two independent gh api calls (charter-specific +
# all-issues) so low-numbered open charters (#5, #10, #15) remain visible even when
# 100+ newer leaf issues fill the single-call cap.
#
# Stub intercepts $1 == "api" (NOT gh issue list):
#   * args contain labels=type:charter  -> ETag header + 3 synthetic open charters
#   * args lack label filter            -> ETag header + 111 high-numbered issues (#200-#310)
#   * args contain If-None-Match        -> HTTP/2 304 (exercises 304 short-circuit path)
#
# Assertions via python3 -c (no background HTTP server):
#   1. First  build_state() call  -> board contains #5, #10, #15
#   2. Second build_state() call  -> 304 fired; cache still contains #5, #10, #15
#
# Class ALLOW: verdict = pure function of merged content (gh stub on PATH +
#   direct python3 -c build_state() call, no background server, no timing/poll/sleep).
#   Meets ALLOW criterion (fail-safe).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
API_PY="$REPO_ROOT/ui/server/crewboss-api.py"

pass=0; fail=0
ok(){ printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

if [ ! -f "$API_PY" ]; then
  no "crewboss-api.py not found: $API_PY"
  printf '\npassed=%d failed=%d\n' "$pass" "$fail"; exit 1
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin";     mkdir -p "$BIN"
CBHOME="$TMP/cbhome"; mkdir -p "$CBHOME/run"

# -- gh stub: intercepts "gh api" only ----------------------------------------
cat > "$BIN/gh" << 'GHSTUB'
#!/usr/bin/env bash
# Only handle "gh api ..." -- all other gh sub-commands are no-ops for this test.
[ "$1" = "api" ] || exit 0

# If-None-Match present -> 304 (exercises cache short-circuit path)
for arg in "$@"; do
  case "$arg" in
    *If-None-Match*) printf 'HTTP/2 304\n\n'; exit 0 ;;
  esac
done

# Detect charter-specific call (labels=type:charter or label=type:charter)
charter_call=0
for arg in "$@"; do
  case "$arg" in
    *label*type:charter*) charter_call=1; break ;;
  esac
done

if [ "$charter_call" = 1 ]; then
  # Charter call: 3 synthetic open charters with low issue numbers
  printf 'HTTP/2 200\nETag: "charter-etag-v1"\n\n'
  printf '[{"number":5,"state":"open","title":"Charter 5","body":"","labels":[{"name":"type:charter"}]},'
  printf '{"number":10,"state":"open","title":"Charter 10","body":"","labels":[{"name":"type:charter"}]},'
  printf '{"number":15,"state":"open","title":"Charter 15","body":"","labels":[{"name":"type:charter"}]}]'
else
  # All-issues call: 111 high-numbered issues (#200-#310); low charters absent (eviction scenario)
  printf 'HTTP/2 200\nETag: "all-issues-etag-v1"\n\n'
  printf '['
  first=1
  for i in $(seq 200 310); do
    [ "$first" = 0 ] && printf ','
    first=0
    printf '{"number":%d,"state":"open","title":"Issue %d","body":"","labels":[]}' "$i" "$i"
  done
  printf ']'
fi
exit 0
GHSTUB
chmod +x "$BIN/gh"

# -- Python test script (no HTTP server; calls build_state() directly) ---------
PY_SCRIPT='
import sys, os, importlib.util

api_path = sys.argv[1]
cb_home  = sys.argv[2]

# Set env before module load so module-level REPO/CB_HOME/RUN pick up test values
os.environ["CB_REPO"] = "test/repo"
os.environ["CB_HOME"] = cb_home

spec = importlib.util.spec_from_file_location("crewboss_api", api_path)
mod  = importlib.util.module_from_spec(spec)
_orig_argv = sys.argv[:]
sys.argv = [api_path]          # prevent --port parse from failing
try:
    spec.loader.exec_module(mod)
except SystemExit:
    pass
sys.argv = _orig_argv

build_state = getattr(mod, "build_state", None)
if build_state is None:
    print("ERROR: build_state not found in crewboss-api.py"); sys.exit(2)

# Ensure module globals match test values (belt-and-suspenders)
mod.REPO    = "test/repo"
mod.CB_HOME = cb_home
mod.RUN     = os.path.join(cb_home, "run")

# Reset any stale global state
mod._etag_store.clear()
mod._cached_issues = None
if hasattr(mod, "_cached_charter_issues"):
    mod._cached_charter_issues = None

# -- Assertion 1: first call fetches fresh data; charters #5,#10,#15 visible --
result1 = build_state()
if not isinstance(result1, dict):
    print("FAIL call-1: build_state returned %r not dict" % type(result1).__name__)
    sys.exit(1)
board1 = result1.get("board", [])
nums1  = {item["n"] for item in board1}
for n in (5, 10, 15):
    if n not in nums1:
        print("FAIL call-1: charter #%d absent from board "
              "(eviction not fixed). Board sample: %s" % (n, sorted(nums1)[:20]))
        sys.exit(1)
print("PASS call-1: charters #5,#10,#15 visible in board (%d total items)" % len(board1))

# -- Assertion 2: second call triggers 304; cache still has all 3 charters ----
result2 = build_state()
if result2 is None:
    print("FAIL call-2: build_state returned None (broken 304 path / cache miss)")
    sys.exit(1)
if not isinstance(result2, dict):
    print("FAIL call-2: build_state returned %r not dict" % type(result2).__name__)
    sys.exit(1)
board2 = result2.get("board", [])
nums2  = {item["n"] for item in board2}
for n in (5, 10, 15):
    if n not in nums2:
        print("FAIL call-2: charter #%d absent from cache. "
              "Board sample: %s" % (n, sorted(nums2)[:20]))
        sys.exit(1)
print("PASS call-2: charters #5,#10,#15 still visible from cache (%d total items)" % len(board2))
sys.exit(0)
'

# -- Run assertions ------------------------------------------------------------
echo "=== board-charter-visibility: charter eviction regression ==="
py_out=""; py_rc=0
py_out=$(PATH="$BIN:$PATH" python3 -c "$PY_SCRIPT" "$API_PY" "$CBHOME") || py_rc=$?

if [ "$py_rc" -eq 0 ]; then
  ok "charter-visibility: charters #5,#10,#15 present on fresh fetch and in 304 cache"
  printf '  %s\n' "$py_out"
else
  no "charter-visibility: FAILED (exit $py_rc)"
  printf '  %s\n' "$py_out"
fi

printf '\npassed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
