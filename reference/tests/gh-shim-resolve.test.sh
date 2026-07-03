#!/usr/bin/env bash
# gh-shim-resolve.test.sh — regression test for the gh-shim real-binary resolver.
#
# Guards the 2026-07-03 fork-bomb regression: the shim is wired into a jail's PATH
# as a SYMLINK named `gh` pointing at gh-shim.sh. _gh_shim_real() must recognise
# that symlink candidate as ITSELF (resolve it through the link) and skip past it
# to the real gh further down PATH. The old code dir-resolved the candidate but
# not the file symlink, so `/cbnet/gh` != `/cbnet/gh-shim.sh`, the shim selected
# itself, and `"$real" "$@"` recursed without bound (12k+ procs, TasksMax hit).
#
# This test reproduces that exact wiring with a stub "real" gh and asserts the
# shim (a) does NOT recurse (bounded time) and (b) forwards to the real binary.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
SHIM="$REPO_ROOT/reference/runtime/gh-shim.sh"

pass=0; fail=0
ok(){ printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

[ -f "$SHIM" ] || { no "gh-shim.sh not found at $SHIM"; printf 'passed=%d failed=%d\n' "$pass" "$fail"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Stub "real" gh: prints a marker + argv and exits 0. Lives in realbin/.
mkdir -p "$TMP/realbin" "$TMP/shimbin"
cat > "$TMP/realbin/gh" <<'STUB'
#!/usr/bin/env bash
printf 'REAL-GH-OK %s\n' "$*"
exit 0
STUB
chmod +x "$TMP/realbin/gh"

# Wire the shim exactly as production does: a symlink named `gh` -> gh-shim.sh,
# with the shim dir FIRST in PATH so `gh` resolves to the symlink.
ln -s "$SHIM" "$TMP/shimbin/gh"

# Minimal PATH: shim first, stub real gh second, then a bare system path for
# coreutils. CB_RL_STATE_FILE points at a nonexistent file → precall bootstrap
# (no sleep); CB_RL_TEST_MODE bypasses the network in postcall.
run_shim(){
  PATH="$TMP/shimbin:$TMP/realbin:/usr/bin:/bin" \
  CB_RL_STATE_FILE="$TMP/nonexistent-rl-state" \
  CB_RL_TEST_MODE=1 CB_RL_REMAINING_OVERRIDE=5000 CB_RL_GQL_REMAINING_OVERRIDE=5000 \
  "$@"
}

# Bounded execution: if the resolver recurses, this never returns → timeout kills
# it and we record a FAIL. 15s is >100x a healthy run and well short of a fork bomb.
TIMEOUT_BIN="$(command -v timeout || true)"
out=""; rc=0
if [ -n "$TIMEOUT_BIN" ]; then
  out="$(run_shim "$TIMEOUT_BIN" 15 gh version --marker 2>/dev/null)"; rc=$?
else
  # No timeout available: run directly (still deterministic once the fix is in).
  out="$(run_shim gh version --marker 2>/dev/null)"; rc=$?
fi

# ── Assertions ────────────────────────────────────────────────────────────────
if [ "$rc" = "124" ]; then
  no "shim TIMED OUT — real-binary resolver recursed (fork-bomb regression)"
else
  ok "shim returned in bounded time (rc=$rc, no unbounded recursion)"
fi

case "$out" in
  *REAL-GH-OK*version*marker*) ok "shim forwarded to the real gh (argv passed through: '$out')" ;;
  *REAL-GH-OK*)                ok "shim forwarded to the real gh: '$out'" ;;
  *)                           no "shim did NOT reach the real gh (output: '${out:-<empty>}')" ;;
esac

# Direct unit check of the resolver: source the shim (guarded — main only runs
# when executed, not sourced) and assert _gh_shim_resolve collapses the symlink.
# shellcheck disable=SC1090
if ( set +u; CB_GH_SHIM_NO_MAIN=1 . "$SHIM" 2>/dev/null; declare -F _gh_shim_resolve >/dev/null ); then
  resolved="$( set +u; CB_GH_SHIM_NO_MAIN=1 . "$SHIM" 2>/dev/null; _gh_shim_resolve "$TMP/shimbin/gh" )"
  case "$resolved" in
    "$SHIM") ok "_gh_shim_resolve('gh' symlink) → the shim itself ($resolved)" ;;
    *)       no "_gh_shim_resolve returned '$resolved', expected '$SHIM'" ;;
  esac
else
  printf '  skip _gh_shim_resolve unit check (shim not sourceable without side effects)\n'
fi

echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
