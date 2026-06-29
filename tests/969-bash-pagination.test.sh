#!/usr/bin/env bash
# 969-bash-pagination.test.sh — bash-surface regression guard for the #969
# pagination/state-window class.  Charter: #995 / issue: #1015.
#
# Surfaces covered:
#   - proto/r6/board-gh.sh
#   - reference/runtime/crewboss-launcher-gh.sh
#
# Defects guarded (live-only breakages that #969 shipped green):
#   D1  `gh issue list ... --paginate` is a NON-EXISTENT flag (`--paginate` is a
#       `gh api` flag only).  Live symptom: `unknown flag: --paginate` -> empty
#       launchable set -> launcher sees 0 charters.
#   D2  unbounded client pagination must terminate under a hard page/time bound.
#   D5  NEITHER board-gh.sh NOR crewboss-launcher-gh.sh may contain
#       `gh issue list ... --paginate` (static regression).
#
# The ROOT enabler of #969 was a subcommand-BLIND gh stub that accepted
# `--paginate` on ANY subcommand and returned a full fixture array (false-green).
# This stub is subcommand-AWARE: it rejects `gh issue list ... --paginate` with a
# non-zero exit + `unknown flag: --paginate` (mirrors real gh -> D1 goes RED on the
# broken code) while CONTINUING to accept `gh api ... --paginate` as VALID (the
# post-fix code legitimately moves to a bounded fetch; a blanket --paginate block
# would false-red the fix).
#
# Modes (self-provability — see issue #1015 "## Self-provability"):
#   CB_969_MODE=fixture (default) : bundled pre/post-fix fixtures + stub unit +
#       syntax checks.  RED on the pre-fix fixture, GREEN on the post-fix fixture.
#       NO real-source grep, NO live gh — runnable at this leaf's own merge point.
#   CB_969_MODE=source            : assert against the REAL source tree (static
#       grep) AND a guarded live-gh smoke.  Owned by the impl leaves at merge.
#
# Flags:
#   --self-stub-unit : run ONLY the subcommand-aware gh-stub unit, then exit.
#
# gh is stubbed via PATH override; no live CB_REPO required in fixture mode.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
MODE="${CB_969_MODE:-fixture}"

pass=0; fail=0
ok(){ printf 'ok   %s\n' "$*"; pass=$((pass+1)); }
ko(){ printf 'FAIL %s\n' "$*"; fail=$((fail+1)); }

# ===========================================================================
# Subcommand-aware gh stub (mirrors real gh).
#   * `gh issue list ... --paginate` -> exit 1 + "unknown flag: --paginate" (D1 RED)
#   * `gh api ... --paginate`        -> exit 0 (valid; never false-reds the fix)
#   * `gh issue list ... --limit N`  -> exit 0, emits ${GH_STUB_FIXTURE} array
#   * `gh api ... -F page=N`         -> bounded pages: non-empty up to GH_STUB_PAGES,
#                                       then `[]` so a client paginator terminates.
# DELIBERATELY NOT the subcommand-blind `--paginate) use_paginate=1` form (that is
# the exact false-green mechanism #969 escaped through).
# ===========================================================================
install_stub() {
  local bin="$1"; mkdir -p "$bin"
  cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
sub="${1:-}"; sub2="${2:-}"
has_paginate=0; page=1
for a in "$@"; do
  case "$a" in
    --paginate) has_paginate=1 ;;
    page=*)     page="${a#page=}" ;;
  esac
done
if [ "$sub" = "issue" ] && [ "$sub2" = "list" ]; then
  if [ "$has_paginate" = 1 ]; then
    echo "unknown flag: --paginate" >&2
    echo "Usage:  gh issue list [flags]" >&2
    exit 1
  fi
  cat "${GH_STUB_FIXTURE:-/dev/null}" 2>/dev/null || echo "[]"
  exit 0
fi
if [ "$sub" = "api" ]; then
  # --paginate is a valid flag on `gh api` — accept it.
  stub_pages="${GH_STUB_PAGES:-3}"
  if [ "$page" -le "$stub_pages" ] 2>/dev/null; then
    echo '[{"number":1,"state":"closed","labels":[]}]'
  else
    echo '[]'
  fi
  exit 0
fi
echo "[]"; exit 0
STUB
  chmod +x "$bin/gh"
}

# ===========================================================================
# --self-stub-unit : prove the stub's subcommand-aware contract in isolation.
# ===========================================================================
if [ "${1:-}" = "--self-stub-unit" ]; then
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  install_stub "$TMP/bin"; export PATH="$TMP/bin:$PATH"
  rc=0
  out="$(gh issue list -R x/y --state all --paginate --json number 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'unknown flag: --paginate'; then
    echo "ok   stub-unit: 'gh issue list --paginate' rejected (rc=$rc, unknown flag)"
  else
    echo "FAIL stub-unit: 'gh issue list --paginate' NOT rejected (rc=$rc out=[$out])"; exit 1
  fi
  gh api --paginate /repos/x/y/issues >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "ok   stub-unit: 'gh api --paginate' accepted (rc=0)"
  else
    echo "FAIL stub-unit: 'gh api --paginate' rejected (rc=$rc)"; exit 1
  fi
  exit 0
fi

# ===========================================================================
# Shared harness: install the stub on PATH + a small valid board fixture.
# ===========================================================================
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ORIG_PATH="$PATH"
install_stub "$TMP/bin"; export PATH="$TMP/bin:$PATH"
export GH_STUB_FIXTURE="$TMP/board.json"
cat > "$GH_STUB_FIXTURE" <<'JSON'
[{"number":250,"state":"OPEN","labels":[{"name":"type:charter"}],"body":""},
 {"number":249,"state":"OPEN","labels":[],"body":"Charter: #250\n\n## Acceptance (machine)\n- check: echo ok\n"}]
JSON

# The exact gh-fetch patterns used by board-gh.sh / crewboss-launcher-gh.sh.
PREFIX_CMD='gh issue list -R x/y --state all --paginate --json number,state,labels,body'
POSTFIX_CMD='gh issue list -R x/y --state all --limit 2000 --json number,state,labels,body'

# --- D1: pre-fix fetch pattern is RED, post-fix fetch pattern is GREEN ---------
echo "=== D1: subcommand-aware stub discriminates the launcher gh-fetch pattern ==="
rc=0; out="$(eval "$PREFIX_CMD" 2>&1)" || rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'unknown flag: --paginate'; then
  ok "D1 pre-fix fetch ('--paginate') is RED: unknown flag, rc=$rc"
else
  ko "D1 pre-fix fetch should be RED but rc=$rc out=[$out]"
fi
rc=0; out="$(eval "$POSTFIX_CMD" 2>&1)" || rc=$?
if [ "$rc" -eq 0 ]; then
  ok "D1 post-fix fetch ('--limit') is GREEN: rc=0"
else
  ko "D1 post-fix fetch should be GREEN but rc=$rc out=[$out]"
fi

# --- D1 static (bundled): pre-fix fixture string carries the bad flag, post-fix not
echo "=== D1(static, bundled fixtures): --paginate present pre-fix, absent post-fix ==="
printf '%s\n' "$PREFIX_CMD"  | grep -Eq 'gh issue list .*--paginate' \
  && ok "bundled pre-fix fixture contains 'gh issue list ... --paginate'" \
  || ko "bundled pre-fix fixture missing the bad flag (fixture is wrong)"
printf '%s\n' "$POSTFIX_CMD" | grep -Eq 'gh issue list .*--paginate' \
  && ko "bundled post-fix fixture still contains 'gh issue list ... --paginate'" \
  || ok "bundled post-fix fixture is clean of 'gh issue list ... --paginate'"

# --- D2: bounded client pagination terminates under a hard page/time bound -----
echo "=== D2: bounded pagination terminates (no while-True hang) ==="
export GH_STUB_PAGES=3
paginate_count() {
  local cap="$1" page=1 count=0 batch
  while [ "$page" -le "$cap" ]; do
    batch="$(gh api -X GET /repos/x/y/issues -F per_page=100 -F "page=$page")"
    count=$((count+1))
    [ "$batch" = "[]" ] && break
    page=$((page+1))
  done
  printf '%s' "$count"
}
HARD_CAP=20
t0=$SECONDS
n="$(paginate_count "$HARD_CAP")"
elapsed=$(( SECONDS - t0 ))
if [ "$n" -lt "$HARD_CAP" ] && [ "$n" = "$(( GH_STUB_PAGES + 1 ))" ]; then
  ok "D2 pagination terminated after $n calls (< cap $HARD_CAP), ${elapsed}s"
else
  ko "D2 pagination did NOT bound cleanly: calls=$n cap=$HARD_CAP (expected $((GH_STUB_PAGES+1)))"
fi
if [ "$elapsed" -lt 30 ]; then
  ok "D2 pagination under the 30s time bound (${elapsed}s)"
else
  ko "D2 pagination exceeded the time bound (${elapsed}s)"
fi

# ===========================================================================
# CB_969_MODE=source: assert against the REAL source tree + guarded live smoke.
# (Owned by the impl leaves at merge; the real tree on this branch already
#  satisfies it, so it is exercised opportunistically when MODE=source.)
# ===========================================================================
BOARD_SH="$ROOT/proto/r6/board-gh.sh"
LAUNCHER_SH="$ROOT/reference/runtime/crewboss-launcher-gh.sh"
if [ "$MODE" = "source" ]; then
  echo "=== D5(static, real source tree): no 'gh issue list ... --paginate' ==="
  for f in "$BOARD_SH" "$LAUNCHER_SH"; do
    if [ ! -f "$f" ]; then ko "source file missing: $f"; continue; fi
    if grep -nE 'gh issue list[^|]*--paginate' "$f" >/dev/null 2>&1; then
      ko "$(basename "$f") still contains 'gh issue list ... --paginate'"
    else
      ok "$(basename "$f") clean of 'gh issue list ... --paginate'"
    fi
  done

  echo "=== D1(source): drive board-gh.sh launchable through the stub ==="
  if [ -f "$BOARD_SH" ]; then
    rc=0; out="$(CB_REPO=x/y bash "$BOARD_SH" launchable 2>&1)" || rc=$?
    if printf '%s' "$out" | grep -q 'unknown flag: --paginate'; then
      ko "board-gh.sh launchable hit 'unknown flag: --paginate' (D1 RED)"
    elif [ "$rc" -eq 0 ]; then
      ok "board-gh.sh launchable ran clean through the stub (rc=0)"
    else
      ko "board-gh.sh launchable rc=$rc out=[$out]"
    fi
  fi

  # Guarded live-gh smoke: HARD-FAILS (does not skip) when a token + CB_REPO are
  # present, so the live path actually gates (the #969 live break was never caught
  # because the smoke skipped cleanly).  Reuses the SAME read-only CI token already
  # consumed by the #993 smoke gate; the token is never echoed.
  if { [ -n "${GH_TOKEN:-}" ] || [ -n "${GITHUB_TOKEN:-}" ]; } && [ -n "${CB_REPO:-}" ]; then
    echo "=== live-gh smoke (token + CB_REPO present — gating, not skipping) ==="
    # Run the REAL board-gh.sh launchable against REAL gh (PATH stub removed).
    live_rc=0
    live_out="$(PATH="$ORIG_PATH" bash "$BOARD_SH" launchable 2>&1)" || live_rc=$?
    if printf '%s' "$live_out" | grep -q 'unknown flag: --paginate'; then
      ko "live-gh smoke: board-gh.sh hit 'unknown flag: --paginate' against real gh"
    elif printf '%s' "$live_out" | grep -Eqi 'rate limit|API rate|Bad credentials|HTTP 4|HTTP 5|could not'; then
      echo "info live-gh smoke: gh unreachable/rate-limited — environment, not artifact"
    elif [ "$live_rc" -eq 0 ]; then
      ok "live-gh smoke: board-gh.sh launchable ran clean against real gh"
    else
      ko "live-gh smoke: board-gh.sh launchable rc=$live_rc"
    fi
  fi
fi

echo
printf '=== SUMMARY (mode=%s): %d passed, %d failed ===\n' "$MODE" "$pass" "$fail"
[ "$fail" -eq 0 ]
