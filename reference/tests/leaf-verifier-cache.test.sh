#!/usr/bin/env bash
# leaf-verifier-cache.test.sh — verify-merged CACHE tests (issue #175)
#
# Class ii: drives REAL crewboss-integrator.sh verify-merged against a
# synthetic bare-remote (anti-reimplementation: the test calls the subcommand,
# it does NOT re-implement cache logic).
#
# Test cases:
#   cache-hit        — same (leaf-sha, base-sha) → engine runs EXACTLY ONCE on
#                      second call (counter file incremented only once, not twice).
#                      RED before cache: counter=2; GREEN after: counter=1.
#   F3-base-move     — same leaf-sha, base branch advances (sibling merged) →
#                      cache INVALIDATED → engine re-runs (counter=2, not masked).
#                      RED without F3-key: base move masked by stale leaf-sha hit.
#   leaf-move        — new commit on leaf → leaf-sha changes → cache miss →
#                      engine re-runs (counter=2).
#   infra-not-cached — infra verdict (timeout or bad remote) NOT stored in cache;
#                      a subsequent valid call re-runs the engine.
#
# Counter mechanism: test suite in bare remote writes one 'x' byte to
# CB_TEST_COUNTER_FILE (inherited env var) each time the engine runs.
# Counting bytes = counting engine invocations (each invocation = one 'x').
#
# Requires: git, bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
INTEGRATOR="${INTEGRATOR_OVERRIDE:-$HERE/../runtime/crewboss-integrator.sh}"

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko()  { fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

# ── helper: setup_bare_remote_counter ────────────────────────────────────────
# Creates a bare repo at <path> with:
#   <base_branch> — base commit with reference/tests/acceptance-block.test.sh
#                   (increments CB_TEST_COUNTER_FILE + exits 0)
#   <leaf_branch> — leaf commit (adds leaf.txt on top of base)
#
# The engine writes one 'x' byte to CB_TEST_COUNTER_FILE per run.
setup_bare_remote_counter() {
  local remote_path="$1" base_branch="${2:-charter/5}" leaf_branch="${3:-leaf/42}"
  rm -rf "$remote_path"
  git init --bare -q "$remote_path"

  local tmp
  tmp="$(mktemp -d)"
  git clone -q "$remote_path" "$tmp" 2>/dev/null
  git -C "$tmp" config user.email t@t
  git -C "$tmp" config user.name  T

  # Base commit with counter-incrementing test suite
  printf 'base\n' > "$tmp/README.md"
  mkdir -p "$tmp/reference/tests"
  # Writes one 'x' byte to counter file (if env var set), then exits 0
  printf '#!/usr/bin/env bash\n[ -n "${CB_TEST_COUNTER_FILE:-}" ] && printf x >> "$CB_TEST_COUNTER_FILE"\nexit 0\n' \
    > "$tmp/reference/tests/acceptance-block.test.sh"
  chmod +x "$tmp/reference/tests/acceptance-block.test.sh"

  git -C "$tmp" add -A
  git -C "$tmp" commit -qm "base" 2>/dev/null
  git -C "$tmp" push -q origin "HEAD:refs/heads/$base_branch" 2>/dev/null

  # Leaf commit (non-conflicting)
  printf 'leaf change\n' > "$tmp/leaf.txt"
  git -C "$tmp" add -A
  git -C "$tmp" commit -qm "leaf work" 2>/dev/null
  git -C "$tmp" push -q origin "HEAD:refs/heads/$leaf_branch" 2>/dev/null

  rm -rf "$tmp"
}

# ── helper: count_engine_runs ─────────────────────────────────────────────────
# Returns the number of 'x' bytes in the counter file (= engine run count).
count_engine_runs() {
  local f="${1:-}"
  [ -f "$f" ] || { printf '0'; return; }
  wc -c < "$f" | tr -d ' '
}

# =============================================================================
# Test 1: cache hit — engine runs EXACTLY ONCE for same (leaf-sha, base-sha)
# =============================================================================
echo "=== Cache Test 1: cache hit (same leaf+base sha → engine runs exactly once) ==="
REMOTE_C1="$ROOT/remote-c1.git"
CACHE_C1="$ROOT/cache-c1"
COUNTER_C1="$ROOT/counter-c1"
setup_bare_remote_counter "$REMOTE_C1" "charter/5" "leaf/42"
mkdir -p "$CACHE_C1"

rc=0
CB_TEST_COUNTER_FILE="$COUNTER_C1" CB_VERIFY_CACHE="$CACHE_C1" \
  bash "$INTEGRATOR" verify-merged leaf/42 charter/5 \
  --remote "$REMOTE_C1" 2>/dev/null || rc=$?
[ "$rc" -eq 0 ] \
  && ok "cache-hit: first call → pass (exit 0)" \
  || ko "cache-hit: first call expected exit 0, got $rc"

rc=0
CB_TEST_COUNTER_FILE="$COUNTER_C1" CB_VERIFY_CACHE="$CACHE_C1" \
  bash "$INTEGRATOR" verify-merged leaf/42 charter/5 \
  --remote "$REMOTE_C1" 2>/dev/null || rc=$?
[ "$rc" -eq 0 ] \
  && ok "cache-hit: second call → pass (exit 0, from cache)" \
  || ko "cache-hit: second call expected exit 0, got $rc"

runs=$(count_engine_runs "$COUNTER_C1")
[ "$runs" -eq 1 ] \
  && ok "cache-hit: engine ran exactly once (counter=$runs) — second call was cache hit" \
  || ko "cache-hit: expected counter=1, got $runs (without cache both calls run engine → 2)"

# =============================================================================
# Test 2: F3 — base-branch advance invalidates cache (sibling merged into base)
# =============================================================================
echo "=== Cache Test 2: F3 base-move invalidates cache ==="
REMOTE_C2="$ROOT/remote-c2.git"
CACHE_C2="$ROOT/cache-c2"
COUNTER_C2="$ROOT/counter-c2"
setup_bare_remote_counter "$REMOTE_C2" "charter/5" "leaf/42"
mkdir -p "$CACHE_C2"

# First call — caches pass verdict for (leaf_sha_1, base_sha_1)
rc=0
CB_TEST_COUNTER_FILE="$COUNTER_C2" CB_VERIFY_CACHE="$CACHE_C2" \
  bash "$INTEGRATOR" verify-merged leaf/42 charter/5 \
  --remote "$REMOTE_C2" 2>/dev/null || rc=$?
[ "$rc" -eq 0 ] && ok "F3: first call pass (exit 0)" || ko "F3: first call expected exit 0, got $rc"

runs=$(count_engine_runs "$COUNTER_C2")
[ "$runs" -eq 1 ] \
  && ok "F3: engine ran once after first call (counter=$runs)" \
  || ko "F3: expected counter=1 after first call, got $runs"

# Advance base branch — simulate sibling leaf merged into charter/5
TMP_ADV="$ROOT/tmp-adv-c2"
git clone -q "$REMOTE_C2" "$TMP_ADV" 2>/dev/null
git -C "$TMP_ADV" config user.email t@t
git -C "$TMP_ADV" config user.name  T
git -C "$TMP_ADV" checkout -q charter/5 2>/dev/null \
  || git -C "$TMP_ADV" checkout -qb charter/5 "origin/charter/5" 2>/dev/null
printf 'sibling-leaf-content\n' > "$TMP_ADV/sibling.txt"
git -C "$TMP_ADV" add -A
git -C "$TMP_ADV" commit -qm "integrate sibling leaf" 2>/dev/null
git -C "$TMP_ADV" push -q origin "HEAD:refs/heads/charter/5" 2>/dev/null
rm -rf "$TMP_ADV"

# Second call — base-sha changed → cache key differs → cache miss → engine re-runs
rc=0
CB_TEST_COUNTER_FILE="$COUNTER_C2" CB_VERIFY_CACHE="$CACHE_C2" \
  bash "$INTEGRATOR" verify-merged leaf/42 charter/5 \
  --remote "$REMOTE_C2" 2>/dev/null || rc=$?
[ "$rc" -eq 0 ] \
  && ok "F3: second call (base moved) pass (exit 0)" \
  || ko "F3: second call expected exit 0, got $rc"

runs=$(count_engine_runs "$COUNTER_C2")
[ "$runs" -eq 2 ] \
  && ok "F3: engine re-ran after base moved (counter=$runs) — base movement invalidated cache" \
  || ko "F3: expected counter=2 (re-ran), got $runs (F3 hole: leaf-only key masked base shift)"

# =============================================================================
# Test 3: leaf-move — new commit on leaf branch invalidates cache
# =============================================================================
echo "=== Cache Test 3: leaf-move invalidates cache ==="
REMOTE_C3="$ROOT/remote-c3.git"
CACHE_C3="$ROOT/cache-c3"
COUNTER_C3="$ROOT/counter-c3"
setup_bare_remote_counter "$REMOTE_C3" "charter/5" "leaf/42"
mkdir -p "$CACHE_C3"

# First call
rc=0
CB_TEST_COUNTER_FILE="$COUNTER_C3" CB_VERIFY_CACHE="$CACHE_C3" \
  bash "$INTEGRATOR" verify-merged leaf/42 charter/5 \
  --remote "$REMOTE_C3" 2>/dev/null || rc=$?
[ "$rc" -eq 0 ] && ok "leaf-move: first call pass (exit 0)" || ko "leaf-move: first call expected exit 0, got $rc"

runs=$(count_engine_runs "$COUNTER_C3")
[ "$runs" -eq 1 ] \
  && ok "leaf-move: engine ran once after first call (counter=$runs)" \
  || ko "leaf-move: expected counter=1 after first call, got $runs"

# Advance leaf branch — new commit (new leaf-sha)
TMP_LEAF="$ROOT/tmp-leaf-c3"
git clone -q "$REMOTE_C3" "$TMP_LEAF" 2>/dev/null
git -C "$TMP_LEAF" config user.email t@t
git -C "$TMP_LEAF" config user.name  T
git -C "$TMP_LEAF" checkout -qb leaf/42 "origin/leaf/42" 2>/dev/null
printf 'additional fix\n' >> "$TMP_LEAF/leaf.txt"
git -C "$TMP_LEAF" add -A
git -C "$TMP_LEAF" commit -qm "leaf fix v2" 2>/dev/null
git -C "$TMP_LEAF" push -q origin "HEAD:refs/heads/leaf/42" 2>/dev/null
rm -rf "$TMP_LEAF"

# Second call — leaf-sha changed → cache miss → engine re-runs
rc=0
CB_TEST_COUNTER_FILE="$COUNTER_C3" CB_VERIFY_CACHE="$CACHE_C3" \
  bash "$INTEGRATOR" verify-merged leaf/42 charter/5 \
  --remote "$REMOTE_C3" 2>/dev/null || rc=$?
[ "$rc" -eq 0 ] \
  && ok "leaf-move: second call (leaf moved) pass (exit 0)" \
  || ko "leaf-move: second call expected exit 0, got $rc"

runs=$(count_engine_runs "$COUNTER_C3")
[ "$runs" -eq 2 ] \
  && ok "leaf-move: engine re-ran after leaf moved (counter=$runs)" \
  || ko "leaf-move: expected counter=2 (re-ran), got $runs"

# =============================================================================
# Test 4: infra not cached — infra verdict is NOT stored; next valid call re-runs
# =============================================================================
echo "=== Cache Test 4: infra not cached ==="
REMOTE_C4="$ROOT/remote-c4.git"
CACHE_C4="$ROOT/cache-c4"
COUNTER_C4="$ROOT/counter-c4"
setup_bare_remote_counter "$REMOTE_C4" "charter/5" "leaf/42"
mkdir -p "$CACHE_C4"

# Resolve the (leaf_sha, base_sha) for this remote so we can inspect the cache file.
LEAF_SHA_C4=$(git ls-remote "$REMOTE_C4" "refs/heads/leaf/42" | awk '{print $1}')
BASE_SHA_C4=$(git ls-remote "$REMOTE_C4" "refs/heads/charter/5" | awk '{print $1}')
CACHE_KEY_C4="${LEAF_SHA_C4}_${BASE_SHA_C4}"
CACHE_FILE_C4="${CACHE_C4}/${CACHE_KEY_C4}"

# Pre-populate cache with 'infra' to simulate a prior infra verdict
# (or verify that the engine itself does not write infra to cache on timeout).
# Strategy A: inject 'infra' manually, then call → should ignore and re-run engine.
printf 'infra' > "$CACHE_FILE_C4"

rc=0
CB_TEST_COUNTER_FILE="$COUNTER_C4" CB_VERIFY_CACHE="$CACHE_C4" \
  bash "$INTEGRATOR" verify-merged leaf/42 charter/5 \
  --remote "$REMOTE_C4" 2>/dev/null || rc=$?
[ "$rc" -eq 0 ] \
  && ok "infra-not-cached: engine ran despite 'infra' in cache (exit 0)" \
  || ko "infra-not-cached: expected exit 0 (engine re-ran), got $rc"

runs=$(count_engine_runs "$COUNTER_C4")
[ "$runs" -eq 1 ] \
  && ok "infra-not-cached: engine ran (counter=$runs) — infra cache entry was ignored" \
  || ko "infra-not-cached: expected counter=1, got $runs (infra blocked engine re-run)"

# Cache file should now contain 'pass' (overwritten from 'infra' by the engine run)
CACHE_CONTENT_C4=$(cat "$CACHE_FILE_C4" 2>/dev/null)
[ "$CACHE_CONTENT_C4" = "pass" ] \
  && ok "infra-not-cached: cache updated to 'pass' after valid engine run" \
  || ko "infra-not-cached: expected cache='pass', got '$CACHE_CONTENT_C4'"

# Strategy B: use CB_VERIFY_TIMEOUT=1 with a hanging remote to trigger REAL infra,
# then verify no cache file is written for that key.
echo "=== Cache Test 4b: timeout infra is NOT written to cache ==="
REMOTE_C4B="$ROOT/remote-c4b.git"
CACHE_C4B="$ROOT/cache-c4b"
mkdir -p "$CACHE_C4B"
# Set up remote with hanging test suite
rm -rf "$ROOT/remote-c4b.git"
git init --bare -q "$REMOTE_C4B"
TMP_C4B="$(mktemp -d)"
git clone -q "$REMOTE_C4B" "$TMP_C4B" 2>/dev/null
git -C "$TMP_C4B" config user.email t@t
git -C "$TMP_C4B" config user.name  T
printf 'base\n' > "$TMP_C4B/README.md"
mkdir -p "$TMP_C4B/reference/tests"
# Hanging test: sleeps longer than CB_VERIFY_TIMEOUT
printf '#!/usr/bin/env bash\nsleep 999\n' > "$TMP_C4B/reference/tests/acceptance-block.test.sh"
chmod +x "$TMP_C4B/reference/tests/acceptance-block.test.sh"
git -C "$TMP_C4B" add -A
git -C "$TMP_C4B" commit -qm "base" 2>/dev/null
git -C "$TMP_C4B" push -q origin "HEAD:refs/heads/charter/5" 2>/dev/null
printf 'leaf\n' > "$TMP_C4B/leaf.txt"
git -C "$TMP_C4B" add -A
git -C "$TMP_C4B" commit -qm "leaf" 2>/dev/null
git -C "$TMP_C4B" push -q origin "HEAD:refs/heads/leaf/42" 2>/dev/null
rm -rf "$TMP_C4B"

# Resolve key for C4B remote
LEAF_SHA_C4B=$(git ls-remote "$REMOTE_C4B" "refs/heads/leaf/42" | awk '{print $1}')
BASE_SHA_C4B=$(git ls-remote "$REMOTE_C4B" "refs/heads/charter/5" | awk '{print $1}')
CACHE_FILE_C4B="${CACHE_C4B}/${LEAF_SHA_C4B}_${BASE_SHA_C4B}"

# Call verify-merged with 1-second timeout → infra (timeout)
rc=0
CB_VERIFY_CACHE="$CACHE_C4B" CB_VERIFY_TIMEOUT=1 \
  bash "$INTEGRATOR" verify-merged leaf/42 charter/5 \
  --remote "$REMOTE_C4B" 2>/dev/null || rc=$?
[ "$rc" -eq 2 ] \
  && ok "infra-not-cached(4b): timeout → infra (exit 2)" \
  || ko "infra-not-cached(4b): expected exit 2 (infra), got $rc"

if [ -f "$CACHE_FILE_C4B" ]; then
  ko "infra-not-cached(4b): cache file was written for infra verdict (must NOT be cached)"
else
  ok "infra-not-cached(4b): no cache file written for infra verdict"
fi

# =============================================================================
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
