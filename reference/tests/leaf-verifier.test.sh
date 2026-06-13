#!/usr/bin/env bash
# leaf-verifier.test.sh — verify-merged subcommand tests (issue #174, #194)
#
# Class ii: drives REAL crewboss-integrator.sh verify-merged subcommand against
# a synthetic bare-remote (anti-reimplementation: we call the subcommand, we do
# NOT re-implement clone/merge/run logic in the test).  Pattern follows
# setup_remote from integrator-loop.test.sh and stale-setup from
# infra-false-green.test.sh:53-71.
#
# Test cases:
#   GREEN       — merged-tree has passing ALLOW-listed *.test.sh → exit 0 / "pass"
#   GREEN-empty — merged-tree has NO reference/tests/ (F1 nullglob) → exit 0 / "pass"
#                 RED before fix: bash receives literal glob string → crash → false fail
#   RED-class2  — merged-tree has failing ALLOW-listed *.test.sh → exit 1 / "fail"
#                 (catches blind merge without real CI — F4 risk-1; I5 preserved)
#   infra       — --remote points to non-existent path → exit 2 / "infra"
#   F2-timeout  — merged-tree has hanging ALLOW-listed *.test.sh + CB_VERIFY_TIMEOUT=1
#                 → exit 2 / "infra" (not a hang)
#   SENTINEL    — merged-tree has excluded sentinel (always exit 1) + ALLOW-listed pass
#                 → exit 0 / "pass" (sentinel not run; deterministic I2/F-A red→green)
#   GUARD       — composition: union(ALLOW, EXCLUDED) == reference/tests/*.test.sh,
#                 disjoint, |ALLOW|=10, |EXCLUDED|=35, |union|=45 (fail-closed drift guard)
#   SMOKE       — two parallel verify-merged on sentinel remote → both stable pass
#
# Requires: git, bash, timeout
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
INTEGRATOR="${INTEGRATOR_OVERRIDE:-$HERE/../runtime/crewboss-integrator.sh}"

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

pass=0; fail=0
ok() { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko() { fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

# ── helper: setup_bare_remote ─────────────────────────────────────────────────
# Creates a bare remote at <path> with:
#   <base_branch>   — base commit (with or without reference/tests/ per <suite_type>)
#   <leaf_branch>   — leaf commit (adds leaf.txt, branches from base)
#   <manifest_allow> — space-separated list of test basenames to ALLOW in the
#                      per-leaf manifest (written to reference/tests/per-leaf-manifest
#                      in the synthetic tree); empty = no manifest written.
#
# suite_type values:
#   pass     — reference/tests/dummy.test.sh that exits 0
#   fail     — reference/tests/dummy.test.sh that exits 1
#   hang     — reference/tests/dummy.test.sh that sleeps 999
#   none     — no reference/tests/ directory (empty suite scenario)
#   sentinel — dummy-safe.test.sh (exit 0) + sentinel-always-fail.test.sh (exit 1)
#              + per-leaf-manifest that ALLOWS only dummy-safe (sentinel excluded)
#              Used for I2/F-A deterministic red→green test (issue #194).
setup_bare_remote() {
  local remote_path="$1" base_branch="${2:-charter/5}" leaf_branch="${3:-leaf/42}" \
        suite_type="${4:-pass}" manifest_allow="${5:-}"
  rm -rf "$remote_path"
  git init --bare -q "$remote_path"

  local tmp; tmp="$(mktemp -d)"
  git clone -q "$remote_path" "$tmp" 2>/dev/null
  git -C "$tmp" config user.email t@t
  git -C "$tmp" config user.name  T

  # Base commit — optionally with reference/tests/
  printf 'base\n' > "$tmp/README.md"
  case "$suite_type" in
    pass)
      mkdir -p "$tmp/reference/tests"
      printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/reference/tests/dummy.test.sh"
      chmod +x "$tmp/reference/tests/dummy.test.sh" ;;
    fail)
      mkdir -p "$tmp/reference/tests"
      printf '#!/usr/bin/env bash\nexit 1\n' > "$tmp/reference/tests/dummy.test.sh"
      chmod +x "$tmp/reference/tests/dummy.test.sh" ;;
    hang)
      mkdir -p "$tmp/reference/tests"
      printf '#!/usr/bin/env bash\nsleep 999\n' > "$tmp/reference/tests/dummy.test.sh"
      chmod +x "$tmp/reference/tests/dummy.test.sh" ;;
    sentinel)
      # Sentinel suite (issue #194 I2/F-A red→green):
      #   dummy-safe.test.sh  — exits 0, listed in ALLOW
      #   sentinel-always-fail.test.sh — exits 1, NOT in ALLOW → excluded by manifest
      # Before I2 fix: all tests run → sentinel exits 1 → verdict=fail (RED).
      # After  I2 fix: ALLOW filter → only dummy-safe runs (exit 0) → verdict=pass (GREEN).
      mkdir -p "$tmp/reference/tests"
      printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/reference/tests/dummy-safe.test.sh"
      chmod +x "$tmp/reference/tests/dummy-safe.test.sh"
      printf '#!/usr/bin/env bash\n# sentinel: always fails — deterministic, no timing\nexit 1\n' \
        > "$tmp/reference/tests/sentinel-always-fail.test.sh"
      chmod +x "$tmp/reference/tests/sentinel-always-fail.test.sh"
      # Manifest: ONLY dummy-safe is ALLOW-listed; sentinel excluded by default
      printf '# per-leaf-manifest (sentinel fixture — issue #194)\nALLOW dummy-safe\n' \
        > "$tmp/reference/tests/per-leaf-manifest"
      ;;
    none)
      # no reference/tests/ directory — empty suite
      ;;
  esac

  # Write per-leaf-manifest from manifest_allow parameter (for pass/fail/hang suite types)
  # sentinel type writes its own manifest above; none type has no tests dir.
  if [ -n "$manifest_allow" ] && [ "$suite_type" != "sentinel" ] && [ "$suite_type" != "none" ]; then
    mkdir -p "$tmp/reference/tests"
    {
      printf '# per-leaf-manifest (synthetic fixture)\n'
      for _n in $manifest_allow; do
        printf 'ALLOW %s\n' "$_n"
      done
    } > "$tmp/reference/tests/per-leaf-manifest"
  fi

  git -C "$tmp" add -A
  git -C "$tmp" commit -qm "base" 2>/dev/null
  git -C "$tmp" push -q origin "HEAD:refs/heads/$base_branch" 2>/dev/null

  # Leaf branch — adds leaf.txt (non-conflicting)
  printf 'leaf change\n' > "$tmp/leaf.txt"
  git -C "$tmp" add -A
  git -C "$tmp" commit -qm "leaf work" 2>/dev/null
  git -C "$tmp" push -q origin "HEAD:refs/heads/$leaf_branch" 2>/dev/null

  rm -rf "$tmp"
}

# =============================================================================
# Test 1: GREEN — passing engine suite on merged tree (ALLOW-listed test exits 0)
# =============================================================================
echo "=== Test 1: GREEN (engine passes on merged tree) ==="
REMOTE1="$ROOT/remote1.git"
VERDICT1="$ROOT/verdict1.txt"
setup_bare_remote "$REMOTE1" "charter/5" "leaf/42" "pass" "dummy"

rc=0
bash "$INTEGRATOR" verify-merged leaf/42 charter/5 \
  --remote "$REMOTE1" --verdict-file "$VERDICT1" 2>/dev/null || rc=$?
[ "$rc" -eq 0 ] \
  && ok "GREEN(pass): exit 0" \
  || ko "GREEN(pass): expected exit 0, got $rc"
[ "$(cat "$VERDICT1" 2>/dev/null)" = "pass" ] \
  && ok "GREEN(pass): verdict=pass" \
  || ko "GREEN(pass): verdict mismatch (got '$(cat "$VERDICT1" 2>/dev/null)')"

# =============================================================================
# Test 2: GREEN empty suite — F1 nullglob (no reference/tests/ in merged tree)
# =============================================================================
echo "=== Test 2: GREEN empty suite (F1 nullglob — no reference/tests/) ==="
REMOTE2="$ROOT/remote2.git"
VERDICT2="$ROOT/verdict2.txt"
setup_bare_remote "$REMOTE2" "charter/5" "leaf/42" "none"

rc=0
bash "$INTEGRATOR" verify-merged leaf/42 charter/5 \
  --remote "$REMOTE2" --verdict-file "$VERDICT2" 2>/dev/null || rc=$?
[ "$rc" -eq 0 ] \
  && ok "GREEN(empty-suite F1): exit 0 — nullglob prevents literal-string bash crash" \
  || ko "GREEN(empty-suite F1): expected exit 0, got $rc"
[ "$(cat "$VERDICT2" 2>/dev/null)" = "pass" ] \
  && ok "GREEN(empty-suite F1): verdict=pass" \
  || ko "GREEN(empty-suite F1): verdict mismatch (got '$(cat "$VERDICT2" 2>/dev/null)')"

# =============================================================================
# Test 3: RED class 2 — engine fails on merged tree (ALLOW-listed test exits 1; I5)
# =============================================================================
echo "=== Test 3: RED class 2 (engine RED on merged tree) ==="
REMOTE3="$ROOT/remote3.git"
VERDICT3="$ROOT/verdict3.txt"
setup_bare_remote "$REMOTE3" "charter/5" "leaf/42" "fail" "dummy"

rc=0
bash "$INTEGRATOR" verify-merged leaf/42 charter/5 \
  --remote "$REMOTE3" --verdict-file "$VERDICT3" 2>/dev/null || rc=$?
[ "$rc" -eq 1 ] \
  && ok "RED-class2: exit 1 (engine RED — catches blind merge without real CI)" \
  || ko "RED-class2: expected exit 1, got $rc"
[ "$(cat "$VERDICT3" 2>/dev/null)" = "fail" ] \
  && ok "RED-class2: verdict=fail" \
  || ko "RED-class2: verdict mismatch (got '$(cat "$VERDICT3" 2>/dev/null)')"

# =============================================================================
# Test 4: infra — non-existent --remote
# =============================================================================
echo "=== Test 4: infra (non-existent --remote) ==="
VERDICT4="$ROOT/verdict4.txt"

rc=0
bash "$INTEGRATOR" verify-merged leaf/42 charter/5 \
  --remote "/nonexistent/path/crewboss-test-$$" \
  --verdict-file "$VERDICT4" 2>/dev/null || rc=$?
[ "$rc" -eq 2 ] \
  && ok "infra(bad-remote): exit 2" \
  || ko "infra(bad-remote): expected exit 2, got $rc"
[ "$(cat "$VERDICT4" 2>/dev/null)" = "infra" ] \
  && ok "infra(bad-remote): verdict=infra" \
  || ko "infra(bad-remote): verdict mismatch (got '$(cat "$VERDICT4" 2>/dev/null)')"

# =============================================================================
# Test 5: F2 timeout — ALLOW-listed hanging test + CB_VERIFY_TIMEOUT=1 → infra
# =============================================================================
echo "=== Test 5: F2 timeout (CB_VERIFY_TIMEOUT=1, hanging test) ==="
REMOTE5="$ROOT/remote5.git"
VERDICT5="$ROOT/verdict5.txt"
setup_bare_remote "$REMOTE5" "charter/5" "leaf/42" "hang" "dummy"

rc=0
CB_VERIFY_TIMEOUT=1 bash "$INTEGRATOR" verify-merged leaf/42 charter/5 \
  --remote "$REMOTE5" --verdict-file "$VERDICT5" 2>/dev/null || rc=$?
[ "$rc" -eq 2 ] \
  && ok "F2-timeout: exit 2 (infra — timed out, did not hang)" \
  || ko "F2-timeout: expected exit 2, got $rc"
[ "$(cat "$VERDICT5" 2>/dev/null)" = "infra" ] \
  && ok "F2-timeout: verdict=infra" \
  || ko "F2-timeout: verdict mismatch (got '$(cat "$VERDICT5" 2>/dev/null)')"

# =============================================================================
# Test 6: SENTINEL — deterministic I2/F-A red→green (issue #194)
#
# Synthetic merged tree has:
#   - per-leaf-manifest that ALLOWS only "dummy-safe"
#   - dummy-safe.test.sh (exits 0 — ALLOWED)
#   - sentinel-always-fail.test.sh (exits 1 — NOT in ALLOW → excluded by default)
#
# Before fix: per-leaf runs ALL *.test.sh → sentinel exits 1 → verdict=fail (RED).
# After  fix: ALLOW filter → only dummy-safe runs (exit 0) → verdict=pass (GREEN).
# This is the principal red→green oracle for I2 (deterministic, not timing-dependent).
# =============================================================================
echo "=== Test 6: SENTINEL (I2/F-A red→green — excluded sentinel, ALLOW filter) ==="
REMOTE6="$ROOT/remote6.git"
VERDICT6="$ROOT/verdict6.txt"
setup_bare_remote "$REMOTE6" "charter/5" "leaf/42" "sentinel"

rc6=0
bash "$INTEGRATOR" verify-merged leaf/42 charter/5 \
  --remote "$REMOTE6" --verdict-file "$VERDICT6" 2>/dev/null || rc6=$?
[ "$rc6" -eq 0 ] \
  && ok "SENTINEL: exit 0 (excluded sentinel-always-fail not run; dummy-safe passes)" \
  || ko "SENTINEL: expected exit 0 (ALLOW filter must exclude sentinel-always-fail), got $rc6"
[ "$(cat "$VERDICT6" 2>/dev/null)" = "pass" ] \
  && ok "SENTINEL: verdict=pass" \
  || ko "SENTINEL: verdict mismatch (got '$(cat "$VERDICT6" 2>/dev/null)'); sentinel must be excluded"

# =============================================================================
# Test 7: GUARD — composition/fail-closed (issue #194)
#
# Asserts that reference/tests/per-leaf-manifest in the REAL REPO:
#   (a) exists
#   (b) union(ALLOW, EXCLUDED) == actual reference/tests/*.test.sh listing (no gaps)
#   (c) intersection(ALLOW, EXCLUDED) == ∅ (no overlaps)
#   (d) |ALLOW| == 10, |EXCLUDED| == 35, |union| == 45
#
# Fail-closed: if a new unclassified test is added, union ≠ actual listing → guard RED.
# =============================================================================
echo "=== Test 7: GUARD (composition / fail-closed drift check) ==="
MANIFEST_PATH="$HERE/per-leaf-manifest"

if [ ! -f "$MANIFEST_PATH" ]; then
  ko "GUARD: per-leaf-manifest not found at $MANIFEST_PATH"
else
  ok "GUARD: per-leaf-manifest exists"

  # Read ALLOW and EXCLUDED lists (sorted)
  _guard_allow=$(grep '^ALLOW ' "$MANIFEST_PATH" | awk '{print $2}' | sort)
  _guard_excl=$(grep '^EXCLUDED ' "$MANIFEST_PATH" | awk '{print $2}' | sort)

  # Actual test file basenames (sorted, without .test.sh)
  _guard_actual=$(ls "$HERE"/*.test.sh 2>/dev/null | xargs -I{} basename {} .test.sh | sort)

  # Count checks
  _allow_count=$(printf '%s\n' "$_guard_allow" | grep -c .)
  _excl_count=$(printf '%s\n' "$_guard_excl" | grep -c .)
  _actual_count=$(printf '%s\n' "$_guard_actual" | grep -c .)

  [ "$_allow_count" -eq 10 ] \
    && ok "GUARD: |ALLOW| == 10" \
    || ko "GUARD: |ALLOW| expected 10, got $_allow_count"

  [ "$_excl_count" -eq 35 ] \
    && ok "GUARD: |EXCLUDED| == 35" \
    || ko "GUARD: |EXCLUDED| expected 35, got $_excl_count"

  [ "$_actual_count" -eq 45 ] \
    && ok "GUARD: |actual *.test.sh| == 45" \
    || ko "GUARD: |actual *.test.sh| expected 45, got $_actual_count"

  # Union == actual listing
  _guard_union=$(printf '%s\n%s\n' "$_guard_allow" "$_guard_excl" | sort)
  if [ "$_guard_union" = "$_guard_actual" ]; then
    ok "GUARD: union(ALLOW, EXCLUDED) == actual *.test.sh listing (no gaps, no extras)"
  else
    ko "GUARD: union mismatch — unclassified or stale entries in manifest"
    printf '  actual but not in manifest:\n'
    comm -23 <(printf '%s\n' "$_guard_actual") <(printf '%s\n' "$_guard_union") | sed 's/^/    /'
    printf '  in manifest but not actual:\n'
    comm -13 <(printf '%s\n' "$_guard_actual") <(printf '%s\n' "$_guard_union") | sed 's/^/    /'
  fi

  # Intersection == ∅
  _guard_inter=$(comm -12 <(printf '%s\n' "$_guard_allow") <(printf '%s\n' "$_guard_excl") 2>/dev/null)
  if [ -z "$_guard_inter" ]; then
    ok "GUARD: ALLOW ∩ EXCLUDED == ∅ (no overlaps)"
  else
    ko "GUARD: overlap between ALLOW and EXCLUDED: $_guard_inter"
  fi

  # Sentinel-excluded guard: each EXCLUDED test is NOT in ALLOW
  _sentinel_in_allow=0
  for _exc in $_guard_excl; do
    if printf '%s\n' "$_guard_allow" | grep -qx "$_exc"; then
      _sentinel_in_allow=$((_sentinel_in_allow + 1))
    fi
  done
  [ "$_sentinel_in_allow" -eq 0 ] \
    && ok "GUARD: no EXCLUDED test is also in ALLOW" \
    || ko "GUARD: $_sentinel_in_allow test(s) appear in both ALLOW and EXCLUDED"
fi

# =============================================================================
# Test 8: SMOKE — concurrent stability (supplementary; not the primary gate)
#
# Runs two parallel verify-merged on the sentinel remote (same remote as Test 6).
# Both should return pass (excluded sentinel is stable across concurrent runs).
# This is a probabilistic supplement to the deterministic sentinel (Test 6).
# =============================================================================
echo "=== Test 8: SMOKE (two parallel verify-merged on sentinel remote) ==="
REMOTE8="$ROOT/remote8.git"
VERDICT8A="$ROOT/verdict8a.txt"
VERDICT8B="$ROOT/verdict8b.txt"
setup_bare_remote "$REMOTE8" "charter/5" "leaf/42" "sentinel"

# Use separate cache dirs to avoid cross-instance cache races
CACHE8A="$(mktemp -d)"
CACHE8B="$(mktemp -d)"
trap 'rm -rf "$ROOT" "$CACHE8A" "$CACHE8B"' EXIT

rc8a=0; rc8b=0
CB_VERIFY_CACHE="$CACHE8A" bash "$INTEGRATOR" verify-merged leaf/42 charter/5 \
  --remote "$REMOTE8" --verdict-file "$VERDICT8A" 2>/dev/null &
PID8A=$!
CB_VERIFY_CACHE="$CACHE8B" bash "$INTEGRATOR" verify-merged leaf/42 charter/5 \
  --remote "$REMOTE8" --verdict-file "$VERDICT8B" 2>/dev/null &
PID8B=$!

wait "$PID8A" 2>/dev/null || rc8a=$?
wait "$PID8B" 2>/dev/null || rc8b=$?

[ "$rc8a" -eq 0 ] \
  && ok "SMOKE: parallel instance-A exit 0" \
  || ko "SMOKE: instance-A expected exit 0, got $rc8a"
[ "$(cat "$VERDICT8A" 2>/dev/null)" = "pass" ] \
  && ok "SMOKE: parallel instance-A verdict=pass" \
  || ko "SMOKE: instance-A verdict mismatch (got '$(cat "$VERDICT8A" 2>/dev/null)')"

[ "$rc8b" -eq 0 ] \
  && ok "SMOKE: parallel instance-B exit 0" \
  || ko "SMOKE: instance-B expected exit 0, got $rc8b"
[ "$(cat "$VERDICT8B" 2>/dev/null)" = "pass" ] \
  && ok "SMOKE: parallel instance-B verdict=pass" \
  || ko "SMOKE: instance-B verdict mismatch (got '$(cat "$VERDICT8B" 2>/dev/null)')"

# =============================================================================
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
