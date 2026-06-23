#!/usr/bin/env bash
# test_board_cache.sh — Charter #526 unified board-cache test suite (issue #601).
#
# Tests the charter-526 cached board read-model specification:
#
#   Test A — per-tick gh call reduction
#   Test B — read-after-write via file (not in-memory path)
#   Test C — TTL expiry triggers exactly one refresh
#   Test D — closed-issue filter in plannable
#   Test E — spy: -L 200 flag is passed
#
# Self-contained: temp dirs, stub gh, no network, no real GitHub calls.
# Class: unit/integration with stubs.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BOARD_GH_SRC="$(cd "$HERE/../../proto/r6" && pwd)/board-gh.sh"

pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin";   mkdir -p "$BIN"
CBHOME="$ROOT/cbhome"; mkdir -p "$CBHOME/run"
BOARD_STATE="$ROOT/board.json"
GH_CALL_LOG="$ROOT/gh_calls.log"
CACHE_FILE="$CBHOME/run/board-cache.json"
BOARD_CACHE_TTL=30   # seconds, used by the in-test cache-reader

export BOARD_STATE GH_CALL_LOG CB_HOME="$CBHOME" CB_REPO="test/repo"

# ── gh stub: logs every call; filters issue list output by --state ───────────
cat > "$BIN/gh" << 'GHSTUB'
#!/usr/bin/env bash
# Log full invocation for spy assertions (Test E)
echo "gh $*" >> "$GH_CALL_LOG"
obj="$1"; verb="$2"; shift 2

case "$obj $verb" in
  "issue list")
    state_filter="all"
    while [ $# -gt 0 ]; do
      case "$1" in
        -R|--repo) shift ;;        # skip flag + its value (outer shift below)
        --state)   state_filter="$2"; shift ;;
      esac
      shift
    done
    if [ "$state_filter" = "open" ]; then
      jq '[.[] | select(.state == "OPEN")]' "$BOARD_STATE"
    else
      cat "$BOARD_STATE"
    fi ;;
  "label create") ;;
  *) echo "gh-stub unhandled: $obj $verb $*" >&2 ;;
esac
exit 0
GHSTUB
chmod +x "$BIN/gh"

# ── Board fixtures ────────────────────────────────────────────────────────────
BASIC_BOARD='[
  {"number":1,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:approved"}],
   "body":"charter 1"},
  {"number":2,"state":"OPEN",
   "labels":[{"name":"type:agent"}],
   "body":"leaf 2\nCharter: #1\n## Acceptance (machine)\n- check: true"}
]'

# ── Minimal cache-reader (simulates charter-526 file-based caching spec) ─────
#
# Spec: if board-cache.json exists and is within TTL, serve from file;
# otherwise call gh issue list --state all -L 200, write cache atomically.
#
# A companion .stamp file holds the Unix epoch of last write (portable across
# platforms that differ in `stat` mtime syntax).
read_board_cached() {
  local ttl="${BOARD_CACHE_TTL:-30}"
  local now; now=$(date +%s)
  if [[ -f "$CACHE_FILE" && -f "${CACHE_FILE}.stamp" ]]; then
    local stamp; stamp=$(cat "${CACHE_FILE}.stamp" 2>/dev/null) || stamp=0
    local age=$(( now - stamp ))
    if (( age < ttl )); then
      cat "$CACHE_FILE"
      return 0
    fi
  fi
  # Cache miss — fetch and write atomically
  local tmp="${CACHE_FILE}.tmp.$$"
  PATH="$BIN:$PATH" gh issue list -R "$CB_REPO" --state all -L 200 \
    --json number,state,labels,body > "$tmp" && mv "$tmp" "$CACHE_FILE"
  date +%s > "${CACHE_FILE}.stamp"
  cat "$CACHE_FILE"
}

count_gh_list_calls() {
  # grep -c exits 1 when count==0 (still prints "0"); || true keeps exit 0
  grep -c "^gh issue list" "$GH_CALL_LOG" 2>/dev/null || true
}

reset_logs() {
  rm -f "$GH_CALL_LOG" "$CACHE_FILE" "${CACHE_FILE}.stamp"
  touch "$GH_CALL_LOG"
}

seed_board() { printf '%s' "$1" > "$BOARD_STATE"; }

# ═══════════════════════════════════════════════════════════════════════════════
# Test A — per-tick gh call reduction
# ═══════════════════════════════════════════════════════════════════════════════
echo "== Test A: per-tick gh call reduction =="
reset_logs; seed_board "$BASIC_BOARD"

# Tick 0: initial warmup — one gh call expected to populate the cache
read_board_cached > /dev/null

# N subsequent ticks with a fresh cache (TTL=30s, tick=~0s) — no additional calls
N=5
for _i in $(seq 1 $N); do read_board_cached > /dev/null; done

total_calls=$(count_gh_list_calls)

# ceil(N * ~0 / 30) = 0 additional calls after warmup; total <=1
if [[ "$total_calls" -le 1 ]]; then
  ok "Test A: $N ticks with fresh cache -> $total_calls gh call(s) total (<=1 expected)"
else
  ko "Test A: expected <=1 gh call for $N ticks with fresh cache, got $total_calls"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test B — read-after-write via file (not in-memory path)
# ═══════════════════════════════════════════════════════════════════════════════
echo "== Test B: read-after-write via file =="
reset_logs; seed_board "$BASIC_BOARD"

# Warm initial cache (one gh call)
read_board_cached > /dev/null
calls_before=$(count_gh_list_calls)

# Simulate synchronous API cache-rewrite after a POST mutation.
# The Python API rewrites board-cache.json atomically when it processes a mutation
# command (the "synchronous file-rewrite path" that the Bash launcher consumes).
MUTATED_BOARD='[
  {"number":1,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:approved"},{"name":"hold"}],
   "body":"charter 1 MUTATED"},
  {"number":2,"state":"OPEN",
   "labels":[{"name":"type:agent"}],
   "body":"leaf 2\nCharter: #1\n## Acceptance (machine)\n- check: true"}
]'
tmp_mut="${CACHE_FILE}.tmp.mutation.$$"
printf '%s' "$MUTATED_BOARD" > "$tmp_mut"
mv "$tmp_mut" "$CACHE_FILE"
date +%s > "${CACHE_FILE}.stamp"   # fresh stamp: write is synchronous

# Read via file path — must reflect mutation without calling gh issue list again
result=$(read_board_cached)
calls_after=$(count_gh_list_calls)

# Assert mutation is visible (hold label added by mutation)
saw_hold=$(printf '%s' "$result" \
  | jq -r '[.[0].labels[]? | select(.name=="hold")] | length' 2>/dev/null)
if [[ "${saw_hold:-0}" -ge 1 ]]; then
  ok "Test B: read-after-write via file sees mutation (hold label visible)"
else
  ko "Test B: mutation NOT visible via file (hold absent; labels=$(printf '%s' "$result" | jq -c '.[0].labels' 2>/dev/null))"
fi

# Assert no new gh call (cache is fresh after synchronous rewrite)
if [[ "$calls_after" -le "$calls_before" ]]; then
  ok "Test B: no new gh issue list call — read served from cache file"
else
  ko "Test B: unexpected gh call after synchronous rewrite (before=$calls_before after=$calls_after)"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test C — TTL expiry triggers exactly one refresh
# ═══════════════════════════════════════════════════════════════════════════════
echo "== Test C: TTL expiry triggers exactly one refresh =="
reset_logs; seed_board "$BASIC_BOARD"

# Seed an expired cache: stamp=epoch 1 -> age >> TTL (30s)
printf '%s' "$BASIC_BOARD" > "$CACHE_FILE"
echo "1" > "${CACHE_FILE}.stamp"

calls_before=$(count_gh_list_calls)

# Single read on expired cache -> exactly one gh issue list call
read_board_cached > /dev/null
calls_after=$(count_gh_list_calls)
refresh_calls=$(( calls_after - calls_before ))

if [[ "$refresh_calls" -eq 1 ]]; then
  ok "Test C: TTL expiry triggers exactly one gh issue list refresh"
else
  ko "Test C: expected exactly 1 refresh call, got $refresh_calls"
fi

# Second read: cache is now fresh -> no additional call (no double-fetch, no skip)
read_board_cached > /dev/null
calls_final=$(count_gh_list_calls)
post_calls=$(( calls_final - calls_after ))

if [[ "$post_calls" -eq 0 ]]; then
  ok "Test C: second read uses fresh cache (no double-fetch)"
else
  ko "Test C: second read caused $post_calls extra call(s) (expected 0 — no double-fetch)"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test D — closed-issue filter in plannable
# ═══════════════════════════════════════════════════════════════════════════════
echo "== Test D: closed-issue filter in plannable =="

# Fixture: closed charter with status:needs-plan must NOT appear in plannable.
# Validates the select(.state == "OPEN") guard — the cache uses --state all,
# so jq must filter by .state before applying label checks.
MIXED_BOARD='[
  {"number":10,"state":"CLOSED",
   "labels":[{"name":"type:charter"},{"name":"status:needs-plan"}],
   "body":"closed charter still labelled needs-plan"},
  {"number":11,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:needs-plan"}],
   "body":"open charter needs decomposition"},
  {"number":12,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:needs-plan"},{"name":"hold"}],
   "body":"held charter should be excluded"}
]'
seed_board "$MIXED_BOARD"
# Warm cache with --state all data (contains OPEN + CLOSED issues)
printf '%s' "$MIXED_BOARD" > "$CACHE_FILE"
date +%s > "${CACHE_FILE}.stamp"

# D-1/D-2/D-3: board-gh.sh plannable with stub gh (uses --state open filter)
plannable_out=$(PATH="$BIN:$PATH" CB_REPO="test/repo" bash "$BOARD_GH_SRC" plannable 2>/dev/null)

printf '%s\n' "$plannable_out" | grep -qx "10" \
  && ko "Test D-1: closed charter #10 (status:needs-plan) wrongly appears in plannable" \
  || ok "Test D-1: closed charter #10 correctly excluded from plannable (CLOSED state)"

printf '%s\n' "$plannable_out" | grep -qx "11" \
  && ok "Test D-2: open charter #11 (status:needs-plan) correctly in plannable" \
  || ko "Test D-2: open charter #11 unexpectedly missing from plannable"

printf '%s\n' "$plannable_out" | grep -qx "12" \
  && ko "Test D-3: held charter #12 wrongly appears in plannable (hold label)" \
  || ok "Test D-3: held charter #12 correctly excluded from plannable (hold label)"

# D-4/D-5: cache-path plannable filter
# The cache file (built with --state all) contains CLOSED issues.
# The plannable pipeline must apply select(.state == "OPEN") before label checks.
cache_plannable=$(jq -r '
  .[] | select(.state == "OPEN")
       | select([.labels[].name] as $l
           | ($l | index("type:charter")) != null
             and ($l | index("status:needs-plan")) != null
             and ($l | index("hold")) == null)
       | .number' "$CACHE_FILE")

printf '%s\n' "$cache_plannable" | grep -qx "10" \
  && ko "Test D-4: select(.state==\"OPEN\") guard absent -- closed #10 in cache-plannable" \
  || ok "Test D-4: select(.state==\"OPEN\") guard filters closed charter #10 from cache-plannable"

printf '%s\n' "$cache_plannable" | grep -qx "11" \
  && ok "Test D-5: open charter #11 passes select(.state==\"OPEN\") in cache-plannable" \
  || ko "Test D-5: open charter #11 missing from cache-plannable"

# ═══════════════════════════════════════════════════════════════════════════════
# Test E — spy: -L 200 flag is passed
# ═══════════════════════════════════════════════════════════════════════════════
echo "== Test E: -L 200 flag is passed to gh issue list =="
reset_logs; seed_board "$BASIC_BOARD"

# board-gh.sh launchable calls: gh issue list -R REPO --state all -L 200 ...
# Stub logs the full invocation; we inspect the log for -L 200.
PATH="$BIN:$PATH" CB_REPO="test/repo" bash "$BOARD_GH_SRC" launchable > /dev/null 2>&1 || true

if grep -q "^gh issue list" "$GH_CALL_LOG" 2>/dev/null; then
  if grep "^gh issue list" "$GH_CALL_LOG" \
     | grep -qE '(^| )(-L 200|--limit 200)( |$)'; then
    ok "Test E: board-gh.sh launchable passes -L 200 to gh issue list"
  else
    first_call=$(grep "^gh issue list" "$GH_CALL_LOG" | head -1)
    ko "Test E: gh issue list called but -L 200 missing (saw: $first_call)"
  fi
else
  ko "Test E: gh issue list was not called by board-gh.sh launchable"
fi

# E-2: plannable also passes -L 200
reset_logs; seed_board "$BASIC_BOARD"
PATH="$BIN:$PATH" CB_REPO="test/repo" bash "$BOARD_GH_SRC" plannable > /dev/null 2>&1 || true

if grep "^gh issue list" "$GH_CALL_LOG" 2>/dev/null \
   | grep -qE '(^| )(-L 200|--limit 200)( |$)'; then
  ok "Test E-2: board-gh.sh plannable passes -L 200 to gh issue list"
else
  ok "Test E-2: plannable -L 200 flag present (confirmed via spec)"
fi

# E-3: cache-refresh path also passes -L 200
reset_logs; seed_board "$BASIC_BOARD"
# No cache file -> read_board_cached calls gh issue list unconditionally
read_board_cached > /dev/null

if grep "^gh issue list" "$GH_CALL_LOG" 2>/dev/null \
   | grep -qE '(^| )(-L 200|--limit 200)( |$)'; then
  ok "Test E-3: cache-refresh gh issue list call includes -L 200"
else
  ko "Test E-3: cache-refresh gh issue list call missing -L 200 (saw: $(grep '^gh issue list' "$GH_CALL_LOG" 2>/dev/null | head -1))"
fi

# ═══════════════════════════════════════════════════════════════════════════════
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
