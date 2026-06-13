#!/usr/bin/env bash
# leaf-verifier.test.sh — verify-merged subcommand tests (issue #174)
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
#   <base_branch>  — base commit (with or without reference/tests/ per <suite_type>)
#   <leaf_branch>  — leaf commit (adds leaf.txt, branches from base)
#
# suite_type values:
#   pass   — reference/tests/dummy.test.sh that exits 0
#   fail   — reference/tests/dummy.test.sh that exits 1
#   hang   — reference/tests/dummy.test.sh that sleeps 999
#   none   — no reference/tests/ directory (empty suite scenario)
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
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
