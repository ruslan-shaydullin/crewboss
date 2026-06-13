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
#   GREEN       — merged-tree has passing reference/tests/*.test.sh → exit 0 / "pass"
#   GREEN-empty — merged-tree has NO reference/tests/ (F1 nullglob) → exit 0 / "pass"
#                 RED before fix: bash receives literal glob string → crash → false fail
#   RED-class2  — merged-tree has failing *.test.sh → exit 1 / "fail"
#                 (catches blind merge without real CI — F4 risk-1)
#   infra       — --remote points to non-existent path → exit 2 / "infra"
#   F2-timeout  — merged-tree has hanging *.test.sh + CB_VERIFY_TIMEOUT=1
#                 → exit 2 / "infra" (not a hang)
#   SENTINEL    — merged-tree has a non-ALLOW test that always exits 1; after fix
#                 it is filtered out → exit 0 / "pass"  (issue #194 / F-A / I2)
#                 RED before fix: unfiltered loop runs sentinel → rc=1 → "fail"
#   GUARD       — composition guard: union(ALLOW,EXCLUDE)==all *.test.sh (45 total),
#                 disjoint, ALLOW=10, EXCLUDE=35; new unclassified test → RED
#   SMOKE       — two parallel verify-merged calls on sentinel fixture both pass
#
# Requires: git, bash, comm, sort
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
#   <base_branch>  — base commit (with or without reference/tests/ per <suite_type>)
#   <leaf_branch>  — leaf commit (adds leaf.txt, branches from base)
#
# suite_type values:
#   pass       — reference/tests/acceptance-block.test.sh exits 0  (ALLOW-listed)
#   fail       — reference/tests/acceptance-block.test.sh exits 1  (ALLOW-listed → suite RED)
#   hang       — reference/tests/acceptance-block.test.sh sleeps 999 (ALLOW-listed → triggers F2 timeout)
#   none       — no reference/tests/ directory (empty suite scenario; F1 nullglob)
#   sentinel   — reference/tests/always-fail-sentinel.test.sh exits 1; name NOT in ALLOW.
#                Before fix: unfiltered run → red.  After fix: filtered out → pass. (#194)
#
# Note (issue #194): the per-leaf ALLOW-list filter now skips any test whose
# basename is not in reference/runtime/per-leaf-manifest.  Tests 3 and 5 therefore
# use 'acceptance-block' (an ALLOW-listed name) so the suite actually runs and
# its exit code is meaningful.
setup_bare_remote() {
  local remote_path="$1" base_branch="${2:-charter/5}" leaf_branch="${3:-leaf/42}" \
        suite_type="${4:-pass}"
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
      # ALLOW-listed name: acceptance-block — exits 0 → suite passes.
      mkdir -p "$tmp/reference/tests"
      printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/reference/tests/acceptance-block.test.sh"
      chmod +x "$tmp/reference/tests/acceptance-block.test.sh" ;;
    fail)
      # ALLOW-listed name: acceptance-block — exits 1 → suite fails (F4 risk-1 catch).
      mkdir -p "$tmp/reference/tests"
      printf '#!/usr/bin/env bash\nexit 1\n' > "$tmp/reference/tests/acceptance-block.test.sh"
      chmod +x "$tmp/reference/tests/acceptance-block.test.sh" ;;
    hang)
      # ALLOW-listed name: acceptance-block — sleeps 999 → triggers F2 timeout (infra).
      mkdir -p "$tmp/reference/tests"
      printf '#!/usr/bin/env bash\nsleep 999\n' > "$tmp/reference/tests/acceptance-block.test.sh"
      chmod +x "$tmp/reference/tests/acceptance-block.test.sh" ;;
    sentinel)
      # Always-failing sentinel, NOT in the per-leaf ALLOW list.
      # Lives only in the synthetic merged tree's reference/tests/ (NOT in the real
      # repo's tests/ → GHA engine job is unaffected).  The per-leaf filter (#194)
      # must exclude it → suite passes.  Without the filter it would fail.
      mkdir -p "$tmp/reference/tests"
      printf '#!/usr/bin/env bash\n# sentinel: always exits 1 — not in per-leaf ALLOW list\nexit 1\n' \
        > "$tmp/reference/tests/always-fail-sentinel.test.sh"
      chmod +x "$tmp/reference/tests/always-fail-sentinel.test.sh" ;;
    none)
      # no reference/tests/ directory — empty suite
      ;;
  esac

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
# Test 1: GREEN — passing engine suite on merged tree
# =============================================================================
echo "=== Test 1: GREEN (engine passes on merged tree) ==="
REMOTE1="$ROOT/remote1.git"
VERDICT1="$ROOT/verdict1.txt"
setup_bare_remote "$REMOTE1" "charter/5" "leaf/42" "pass"

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
# Test 3: RED class 2 — engine fails on merged tree (semantic breakage after merge)
# =============================================================================
echo "=== Test 3: RED class 2 (engine RED on merged tree) ==="
REMOTE3="$ROOT/remote3.git"
VERDICT3="$ROOT/verdict3.txt"
setup_bare_remote "$REMOTE3" "charter/5" "leaf/42" "fail"

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
# Test 5: F2 timeout — hanging test + CB_VERIFY_TIMEOUT=1 → infra, not hang
# =============================================================================
echo "=== Test 5: F2 timeout (CB_VERIFY_TIMEOUT=1, hanging test) ==="
REMOTE5="$ROOT/remote5.git"
VERDICT5="$ROOT/verdict5.txt"
setup_bare_remote "$REMOTE5" "charter/5" "leaf/42" "hang"

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
# Test 6: SENTINEL — deterministic red→green (F-A / I2 fix, issue #194)
# =============================================================================
# Synthetic merged tree contains 'always-fail-sentinel.test.sh' (always exits 1).
# This name is NOT in the per-leaf ALLOW list in reference/runtime/per-leaf-manifest.
# After fix: filter skips it → zero ALLOW tests run → suite passes (exit 0 / "pass").
# Before fix: unfiltered loop would run it → exits 1 → rc=1 → verdict="fail".
# Deterministic on any CI: no timing/contention dependency (sentinel always exits 1).
echo "=== Test 6: SENTINEL — deterministic red→green (F-A/I2, issue #194) ==="
REMOTE6="$ROOT/remote6.git"
VERDICT6="$ROOT/verdict6.txt"
setup_bare_remote "$REMOTE6" "charter/5" "leaf/42" "sentinel"

rc=0
bash "$INTEGRATOR" verify-merged leaf/42 charter/5 \
  --remote "$REMOTE6" --verdict-file "$VERDICT6" 2>/dev/null || rc=$?
[ "$rc" -eq 0 ] \
  && ok "SENTINEL: exit 0 (always-fail-sentinel filtered by ALLOW-list, not run)" \
  || ko "SENTINEL: expected exit 0, got $rc (non-ALLOW sentinel was executed — filter not applied)"
[ "$(cat "$VERDICT6" 2>/dev/null)" = "pass" ] \
  && ok "SENTINEL: verdict=pass (excluded test did not count as failure)" \
  || ko "SENTINEL: verdict expected 'pass', got '$(cat "$VERDICT6" 2>/dev/null)'"

# =============================================================================
# Test 7: COMPOSITION GUARD — fail-closed (issue #194, guard §WHAT blockers #1/#2)
# =============================================================================
# Reads per-leaf-manifest from the integrator's own directory.
# Asserts: ALLOW=10, EXCLUDE=35, |union|=45==|actual tests|, disjoint, every
# *.test.sh classified in exactly one list.
# NEW unclassified *.test.sh → not in union → guard RED (fail-closed, drift prevention).
echo "=== Test 7: COMPOSITION GUARD (manifest completeness + fail-closed) ==="
_manifest_file="$(dirname "$INTEGRATOR")/per-leaf-manifest"
_tests_dir="$HERE"

guard_fail=0
if [ ! -f "$_manifest_file" ]; then
  ko "GUARD: per-leaf-manifest not found at $_manifest_file"
  guard_fail=1
else
  # Parse ALLOW and EXCLUDE basenames from manifest (sorted, unique)
  _allow_names="$(grep '^ALLOW ' "$_manifest_file" | awk '{print $2}' | sort -u)"
  _excl_names="$(grep '^EXCLUDE ' "$_manifest_file" | awk '{print $2}' | sort -u)"

  _allow_count=0
  [ -n "$_allow_names" ] && _allow_count="$(printf '%s\n' "$_allow_names" | grep -c '.')"
  _excl_count=0
  [ -n "$_excl_names" ]  && _excl_count="$(printf '%s\n' "$_excl_names"  | grep -c '.')"
  _total=$((_allow_count + _excl_count))

  # Actual *.test.sh listing from the real reference/tests/ directory (sorted, unique)
  _actual_names="$(for _t in "$_tests_dir"/*.test.sh; do basename "$_t" .test.sh; done | sort -u)"
  _actual_count=0
  [ -n "$_actual_names" ] && _actual_count="$(printf '%s\n' "$_actual_names" | grep -c '.')"

  # Assert ALLOW count = 10
  [ "$_allow_count" -eq 10 ] \
    && ok "GUARD: ALLOW count = 10" \
    || { ko "GUARD: ALLOW count expected 10, got $_allow_count"; guard_fail=1; }

  # Assert EXCLUDE count = 35
  [ "$_excl_count" -eq 35 ] \
    && ok "GUARD: EXCLUDE count = 35" \
    || { ko "GUARD: EXCLUDE count expected 35, got $_excl_count"; guard_fail=1; }

  # Assert total = 45
  [ "$_total" -eq 45 ] \
    && ok "GUARD: total classified = 45 (10 ALLOW + 35 EXCLUDE)" \
    || { ko "GUARD: total expected 45, got $_total"; guard_fail=1; }

  # Assert actual test count = 45
  [ "$_actual_count" -eq 45 ] \
    && ok "GUARD: actual *.test.sh count = 45" \
    || { ko "GUARD: expected 45 actual *.test.sh files, found $_actual_count"; guard_fail=1; }

  # Assert disjoint: ALLOW ∩ EXCLUDE = ∅
  _intersection="$(comm -12 \
    <(printf '%s\n' "$_allow_names" | sort -u) \
    <(printf '%s\n' "$_excl_names"  | sort -u) | grep -c '.' || true)"
  [ "${_intersection:-0}" -eq 0 ] \
    && ok "GUARD: ALLOW ∩ EXCLUDE = ∅ (disjoint)" \
    || { ko "GUARD: ALLOW and EXCLUDE share $_intersection name(s) — not disjoint"; guard_fail=1; }

  # Assert union == actual listing (every *.test.sh is classified; new test → RED)
  _union_sorted="$(printf '%s\n%s\n' "$_allow_names" "$_excl_names" | grep '.' | sort -u)"

  # Unclassified tests: in actual listing but NOT in union
  _unclassified="$(comm -23 \
    <(printf '%s\n' "$_actual_names" | sort -u) \
    <(printf '%s\n' "$_union_sorted" | sort -u))"
  if [ -z "$_unclassified" ]; then
    ok "GUARD: every *.test.sh is classified (union covers all actual files — no drift)"
  else
    _uc_list="$(printf '%s ' $_unclassified)"
    ko "GUARD: unclassified test(s) found — add to per-leaf-manifest: ${_uc_list% }"
    guard_fail=1
  fi

  # Orphaned manifest entries: in union but NOT in actual listing (typos / deleted tests)
  _orphaned="$(comm -23 \
    <(printf '%s\n' "$_union_sorted" | sort -u) \
    <(printf '%s\n' "$_actual_names" | sort -u))"
  if [ -z "$_orphaned" ]; then
    ok "GUARD: no orphaned manifest entries (all classified names have a matching *.test.sh)"
  else
    _orph_list="$(printf '%s ' $_orphaned)"
    ko "GUARD: manifest has entries with no matching *.test.sh: ${_orph_list% }"
    guard_fail=1
  fi
fi

# =============================================================================
# Test 8: SMOKE — parallel verify-merged (I1 / contention, issue #194)
# =============================================================================
# Two concurrent verify-merged calls on the sentinel fixture.
# Both must return pass: the ALLOW-list filter is stateless and idempotent.
# Non-primary gate (prababilistic on isolated CI) — layered on top of Test 6.
echo "=== Test 8: SMOKE — parallel verify-merged stability (issue #194) ==="
REMOTE8="$ROOT/remote8.git"
setup_bare_remote "$REMOTE8" "charter/5" "leaf/42" "sentinel"

V8A="$ROOT/verdict8a.txt"; V8B="$ROOT/verdict8b.txt"
rc8a=0; rc8b=0

bash "$INTEGRATOR" verify-merged leaf/42 charter/5 \
  --remote "$REMOTE8" --verdict-file "$V8A" 2>/dev/null &
_p8a=$!
bash "$INTEGRATOR" verify-merged leaf/42 charter/5 \
  --remote "$REMOTE8" --verdict-file "$V8B" 2>/dev/null &
_p8b=$!

wait "$_p8a" || rc8a=$?
wait "$_p8b" || rc8b=$?

[ "$rc8a" -eq 0 ] \
  && ok "SMOKE: parallel A exit 0 (sentinel filtered under contention)" \
  || ko "SMOKE: parallel A expected exit 0, got $rc8a"
[ "$(cat "$V8A" 2>/dev/null)" = "pass" ] \
  && ok "SMOKE: parallel A verdict=pass" \
  || ko "SMOKE: parallel A verdict expected 'pass', got '$(cat "$V8A" 2>/dev/null)'"
[ "$rc8b" -eq 0 ] \
  && ok "SMOKE: parallel B exit 0 (sentinel filtered under contention)" \
  || ko "SMOKE: parallel B expected exit 0, got $rc8b"
[ "$(cat "$V8B" 2>/dev/null)" = "pass" ] \
  && ok "SMOKE: parallel B verdict=pass" \
  || ko "SMOKE: parallel B verdict expected 'pass', got '$(cat "$V8B" 2>/dev/null)'"

# =============================================================================
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
