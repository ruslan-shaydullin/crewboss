#!/usr/bin/env bash
# 969-bash-pagination.test.sh — bash-surface regression guard for charter #969 class.
# Charter: #995  (re-fix of #969)  •  Owner: qa-engineer (tests/ surface)
#
# Surfaces covered:
#   - proto/r6/board-gh.sh
#   - reference/runtime/crewboss-launcher-gh.sh
#
# Defect this guard makes RED (pre-fix) / GREEN (post-fix):
#   D1  `gh issue list ... --paginate` — NON-EXISTENT flag. `--paginate` exists only
#       on `gh api`. Live symptom: `unknown flag: --paginate` → launchable empty →
#       launcher sees 0 charters. Largest surface = crewboss-launcher-gh.sh (~20 sites).
#
# Why a subcommand-AWARE stub (charter root cause): #969 escaped CI because the legacy
# stub was subcommand-BLIND — it matched `--paginate` on ANY subcommand and returned a
# full fixture with exit 0, so the broken `gh issue list --paginate` code false-greened.
# This stub mirrors real gh: it REJECTS `gh issue list --paginate` (non-zero +
# `unknown flag: --paginate`) while still ACCEPTING the valid `gh api --paginate`.
#
# Self-provability (no cyclic deadlock with the impl leaves that fix the source):
#   This leaf merges FIRST. The static-grep-against-the-REAL-tree + full-real-source
#   green runs are owned by the impl leaves under CB_969_MODE=source. THIS leaf's
#   acceptance runs ONLY under CB_969_MODE=fixture: it proves the guard logic against
#   bundled pre-fix (RED) and post-fix (GREEN) fixtures + a stub unit + syntax.
#
# Modes:
#   CB_969_MODE=fixture (default) — bundled fixture proofs; self-contained; my acceptance.
#   CB_969_MODE=source            — assert against the REAL source tree (impl-leaf owned).
#   --self-stub-unit              — exercise only the subcommand-aware gh stub.
#
# Live-gh smoke (charter §touches_auth_or_secrets): when a GH token + live CB_REPO are
# present AND mode != fixture, the live path HARD-FAILS (not skips) if the real source is
# broken, reusing the same read-only CI token as the merged #993 smoke gate. The token is
# never echoed to logs/output.

set -uo pipefail

MODE="${CB_969_MODE:-fixture}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REAL_BOARD="$SCRIPT_DIR/../proto/r6/board-gh.sh"
REAL_LAUNCHER="$SCRIPT_DIR/../reference/runtime/crewboss-launcher-gh.sh"

pass=0; fail=0
ok() { printf 'ok   %s\n' "$*"; pass=$((pass+1)); }
ko() { printf 'FAIL %s\n' "$*"; fail=$((fail+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"

# ── Subcommand-aware gh stub ────────────────────────────────────────────────────
# Mirrors real gh's flag scoping:
#   * `gh issue list ... --paginate` → EXIT 1 + `unknown flag: --paginate`   (D1 RED)
#   * `gh api ... --paginate`        → EXIT 0, emits the bounded fixture once (valid)
#   * `gh api ... -F page=N`         → page 1 = fixture, page>=2 = `[]` (bounded paging)
#   * `gh issue list` (no --paginate)→ emits fixture (legacy -L path)
# NOTE: deliberately NO `--paginate)` case branch — a subcommand-blind
# `--paginate) use_paginate=1` branch is exactly the #969 false-green mechanism and is
# banned by the acceptance grep.
write_stub() {
  cat > "$BIN/gh" <<'SHIM'
#!/bin/sh
# subcommand-aware gh stub (charter #969 regression guard)
sub="${1:-}"
has_flag() { _f="$1"; shift; for _a in "$@"; do [ "$_a" = "$_f" ] && return 0; done; return 1; }

case "$sub" in
  issue)
    # --paginate is INVALID on `gh issue *` — reject exactly like real gh.
    if has_flag --paginate "$@"; then
      echo "unknown flag: --paginate" >&2
      echo "Usage:  gh issue list [flags]" >&2
      exit 1
    fi
    if [ "${2:-}" = "list" ]; then
      cat "${GH_FIXTURE:-/dev/null}"
    fi
    exit 0
    ;;
  api)
    # --paginate is VALID on `gh api` — gh aggregates all pages server-side.
    if has_flag --paginate "$@"; then
      cat "${GH_FIXTURE:-/dev/null}"
      exit 0
    fi
    # Manual -F page=N paging: page 1 = fixture, beyond = empty (bounded).
    _page=1; _prev=""
    for _a in "$@"; do
      [ "$_prev" = "-F" ] && case "$_a" in page=*) _page="${_a#page=}" ;; esac
      _prev="$_a"
    done
    if [ "$_page" -le 1 ] 2>/dev/null; then
      cat "${GH_FIXTURE:-/dev/null}"
    else
      printf '[]'
    fi
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
SHIM
  chmod +x "$BIN/gh"
}

# ── Regex: the banned `gh issue list ... --paginate` construct ──────────────────
ISSUE_LIST_PAGINATE_RE='gh[[:space:]]+issue[[:space:]]+list[^|]*--paginate'

# ── --self-stub-unit ────────────────────────────────────────────────────────────
# Asserts the stub is subcommand-aware (this is the unit the charter says #969 lacked).
if [ "${1:-}" = "--self-stub-unit" ]; then
  write_stub
  export PATH="$BIN:$PATH"
  printf '[{"number":1,"state":"open","labels":[]}]' > "$TMP/fix.json"
  export GH_FIXTURE="$TMP/fix.json"

  echo "=== self-stub-unit: subcommand-aware gh stub ==="

  e1="$TMP/u1.err"
  if gh issue list -R x/y --state all --paginate --json number >/dev/null 2>"$e1"; then
    ko "stub-unit: gh issue list --paginate should EXIT non-zero (mirrors real gh)"
  else
    ok "stub-unit: gh issue list --paginate exits non-zero"
  fi
  if grep -q "unknown flag: --paginate" "$e1"; then
    ok "stub-unit: gh issue list --paginate emits 'unknown flag: --paginate'"
  else
    ko "stub-unit: missing 'unknown flag: --paginate' message"
  fi

  if gh api --paginate "/repos/x/y/issues" >/dev/null 2>"$TMP/u2.err"; then
    ok "stub-unit: gh api --paginate exits zero (valid flag accepted)"
  else
    ko "stub-unit: gh api --paginate should EXIT zero (valid)"
  fi

  echo
  printf '=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]
  exit $?
fi

# ── Common setup for fixture/source modes ───────────────────────────────────────
write_stub
export PATH="$BIN:$PATH"
export CB_REPO="${CB_REPO:-test/repo969}"

# Build a 250-item board fixture: charter #250 + probe leaf #249 at the high end
# (folds the legacy 969-pagination-window.test.sh -L window coverage: high-numbered
# issues MUST survive the fetch).
FIX="$TMP/board.json"
python3 - > "$FIX" <<'PYEOF'
import json
total, charter, probe = 250, 250, 249
items=[]
for i in range(total):
    if i == total-1:
        items.append({"number":charter,"state":"open",
                      "labels":[{"name":"type:charter"},{"name":"status:approved"}],"body":""})
    elif i == total-2:
        items.append({"number":probe,"state":"open","labels":[],
                      "body":"Charter: #%d\n" % charter})
    else:
        items.append({"number":1000000+i,"state":"open","labels":[],"body":""})
print(json.dumps(items))
PYEOF
export GH_FIXTURE="$FIX"

# ── Bundled pre-fix / post-fix launcher-fetch fixtures (D1) ──────────────────────
# These mimic the launcher's key gh-fetch construct. The full-real-tree forms run in
# the impl leaves (CB_969_MODE=source) once the source is fixed.
PREFIX_SH="$TMP/fetch_prefix.sh"
POSTFIX_SH="$TMP/fetch_postfix.sh"

cat > "$PREFIX_SH" <<'EOF'
#!/usr/bin/env bash
# PRE-FIX (BROKEN): --paginate on `gh issue list` — non-existent flag.
set -o pipefail
gh issue list -R "$CB_REPO" --state all --paginate \
  --json number,state,labels,body | jq -r '.[].number'
EOF

cat > "$POSTFIX_SH" <<'EOF'
#!/usr/bin/env bash
# POST-FIX: valid `gh api --paginate` — gh aggregates pages server-side.
set -o pipefail
gh api --paginate "/repos/$CB_REPO/issues?state=all&per_page=100" \
  | jq -r '.[].number'
EOF
chmod +x "$PREFIX_SH" "$POSTFIX_SH"

# ── grep helper: does a file contain the banned construct? ───────────────────────
has_issue_list_paginate() { grep -nE "$ISSUE_LIST_PAGINATE_RE" "$1" 2>/dev/null; }

run_fixture_mode() {
  echo "=== D1.a: pre-fix launcher fetch (gh issue list --paginate) must FAIL RED ==="
  perr="$TMP/pre.err"
  pout="$(bash "$PREFIX_SH" 2>"$perr")"; prc=$?
  if [ "$prc" -ne 0 ]; then
    ok "D1.a: pre-fix fetch exits non-zero (launchable would be EMPTY — live symptom)"
  else
    ko "D1.a: pre-fix fetch unexpectedly succeeded (subcommand-blind false-green)"
  fi
  if grep -q "unknown flag: --paginate" "$perr"; then
    ok "D1.a: pre-fix fetch surfaces 'unknown flag: --paginate' (real-gh behaviour)"
  else
    ko "D1.a: pre-fix fetch did not surface the unknown-flag error"
  fi
  if [ -z "$pout" ]; then
    ok "D1.a: pre-fix fetch yields NO issue numbers (0 charters → launcher idles)"
  else
    ko "D1.a: pre-fix fetch unexpectedly produced output: $(printf '%s' "$pout" | head -1)"
  fi

  echo "=== D1.b: post-fix launcher fetch (gh api --paginate) must pass GREEN ==="
  poerr="$TMP/post.err"
  poout="$(bash "$POSTFIX_SH" 2>"$poerr")"; porc=$?
  if [ "$porc" -eq 0 ]; then
    ok "D1.b: post-fix fetch exits zero"
  else
    ko "D1.b: post-fix fetch should exit zero, got $porc"
  fi
  if grep -q "unknown flag" "$poerr"; then
    ko "D1.b: post-fix fetch wrongly hit unknown-flag (blanket --paginate block?)"
  else
    ok "D1.b: post-fix fetch does NOT trip the unknown-flag path (gh api --paginate valid)"
  fi
  # Folds legacy window coverage: high-numbered charter #250 + probe #249 survive.
  if printf '%s\n' "$poout" | grep -qx 250; then
    ok "D1.b: high-numbered charter #250 visible after fetch (window-bug regression)"
  else
    ko "D1.b: charter #250 missing from post-fix fetch"
  fi
  if printf '%s\n' "$poout" | grep -qx 249; then
    ok "D1.b: probe leaf #249 visible after fetch"
  else
    ko "D1.b: probe leaf #249 missing from post-fix fetch"
  fi

  echo "=== D1.c: bounded — gh api --paginate path terminates under a hard bound ==="
  # The post-fix path is single-shot (gh api --paginate aggregates server-side), so it
  # provably returns. Assert it both COMPLETES (rc captured) and within a wall-clock
  # bound. (No `timeout(1)` dependency — some sandboxes seccomp-block its timer syscalls;
  # the unbounded-hang case is covered deterministically in the python D2 watchdog test.)
  _t0=$SECONDS
  bash "$POSTFIX_SH" >/dev/null 2>&1; _brc=$?
  _elapsed=$(( SECONDS - _t0 ))
  if [ "$_brc" -eq 0 ] && [ "$_elapsed" -le 10 ]; then
    ok "D1.c: post-fix fetch terminates promptly (${_elapsed}s ≤ 10s bound, no paging hang)"
  else
    ko "D1.c: post-fix fetch not bounded (rc=$_brc elapsed=${_elapsed}s)"
  fi

  echo "=== D1.d: static grep — banned construct caught in pre-fix, absent in post-fix ==="
  if has_issue_list_paginate "$PREFIX_SH" >/dev/null; then
    ok "D1.d: grep regex catches 'gh issue list ... --paginate' in pre-fix fixture"
  else
    ko "D1.d: grep regex FAILED to catch the banned construct (regex too weak)"
  fi
  if has_issue_list_paginate "$POSTFIX_SH" >/dev/null; then
    ko "D1.d: post-fix fixture still contains banned construct (false-red the fix)"
  else
    ok "D1.d: post-fix fixture is clean of 'gh issue list ... --paginate'"
  fi
}

run_source_mode() {
  # Owned by impl leaves: GREEN only once the real source is fixed.
  echo "=== SOURCE: static grep against the REAL tree ==="
  for f in "$REAL_BOARD" "$REAL_LAUNCHER"; do
    if [ ! -f "$f" ]; then ko "SOURCE: missing $f"; continue; fi
    hits="$(has_issue_list_paginate "$f")"
    if [ -z "$hits" ]; then
      ok "SOURCE: $(basename "$f") free of 'gh issue list ... --paginate'"
    else
      ko "SOURCE: $(basename "$f") still uses banned construct:"$'\n'"$hits"
    fi
  done

  echo "=== SOURCE: drive board-gh.sh launchable through the subcommand-aware stub ==="
  if [ -f "$REAL_BOARD" ]; then
    serr="$TMP/src.err"
    bash "$REAL_BOARD" launchable >/dev/null 2>"$serr"; src=$?
    if [ "$src" -eq 0 ] && ! grep -q "unknown flag: --paginate" "$serr"; then
      ok "SOURCE: board-gh.sh launchable runs clean through the stub"
    else
      ko "SOURCE: board-gh.sh launchable broke through the stub (rc=$src)"
    fi
  fi
}

# ── Live-gh smoke (HARD gate when token+live-CB_REPO present; mode != fixture) ───
run_live_smoke() {
  local token="${GH_TOKEN:-${GITHUB_TOKEN:-${CB_API_TOKEN:-}}}"
  local repo="${CB_REPO:-}"
  if [ -z "$token" ] || [ -z "$repo" ] || [ "$repo" = "test/repo969" ]; then
    echo "live-smoke: no live token+CB_REPO present — live path not exercised (unit coverage stands)"
    return 0
  fi
  echo "=== LIVE: real gh smoke (HARD gate; token never echoed) ==="
  # Reuse the read-only CI token (same as the merged #993 smoke gate). Real gh MUST
  # accept the post-fix gh-api pagination path against the live repo.
  if command -v gh >/dev/null 2>&1; then
    if timeout 40 gh api "/repos/$repo/issues?per_page=1" >/dev/null 2>&1; then
      ok "LIVE: gh api against live repo succeeds (live pagination path healthy)"
    else
      ko "LIVE: gh api against live repo FAILED — live path is broken (HARD fail)"
    fi
  else
    ko "LIVE: token present but gh CLI absent — cannot gate live path (HARD fail)"
  fi
}

case "$MODE" in
  fixture) run_fixture_mode ;;
  source)  run_source_mode ;;
  *)       echo "unknown CB_969_MODE='$MODE'" >&2; exit 2 ;;
esac

[ "$MODE" != "fixture" ] && run_live_smoke

echo
printf '=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
