#!/usr/bin/env bash
# 969-pagination-window.test.sh — regression guard for the gh -L 200 window bug
# Charter: #969
#
# Guards against reintroduction of: gh issue list -L 200 silently dropping
# high-numbered issues, causing the launcher to see 0 launchable leaves and
# idle-loop forever.
#
# S1: 250-item board — charter #250 must be visible (FAILS on pre-fix -L 200 code)
# S2: 600-item board — charter #614 must be visible (production-scale sanity)
#
# gh is stubbed via PATH override; no live CB_REPO required.

set -uo pipefail

pass=0; fail=0
ok() { printf 'ok   %s\n' "$*"; pass=$((pass+1)); }
ko() { printf 'FAIL %s\n' "$*"; fail=$((fail+1)); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOARD_SH="$SCRIPT_DIR/../proto/r6/board-gh.sh"

# ── Prerequisites ──────────────────────────────────────────────────────────────
if [ ! -f "$BOARD_SH" ]; then
  printf 'SKIP: proto/r6/board-gh.sh not found at %s\n' "$BOARD_SH"
  exit 0
fi
for cmd in jq python3; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    printf 'SKIP: %s not found\n' "$cmd"
    exit 0
  fi
done

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

BIN="$TMP/bin"; mkdir -p "$BIN"
export PATH="$BIN:$PATH"
export CB_REPO="test/repo969"

# ── gh stub ───────────────────────────────────────────────────────────────────
# --paginate (post-fix): emits the full fixture array.
# -L N       (pre-fix) : emits only the first N items, simulating the window bug.
cat > "$BIN/gh" << 'SHIM'
#!/bin/sh
use_paginate=0
limit=9999999
saw_L=0
for arg in "$@"; do
  if [ "$saw_L" = "1" ]; then
    limit="$arg"; saw_L=0; continue
  fi
  case "$arg" in
    --paginate) use_paginate=1 ;;
    -L)         saw_L=1        ;;
  esac
done

fixture="${GH_FIXTURE:-}"
[ -z "$fixture" ] || [ ! -f "$fixture" ] && { echo "[]"; exit 0; }

if [ "$use_paginate" = "1" ]; then
  cat "$fixture"
else
  python3 -c "
import json
with open('${fixture}') as f:
    data = json.load(f)
print(json.dumps(data[:${limit}]))
"
fi
SHIM
chmod +x "$BIN/gh"

# ── Fixture builder ────────────────────────────────────────────────────────────
# make_board <out_file> <total_items> <charter_num>
#   Positions: total-2 = probe leaf (number=charter_num-1),
#              total-1 = charter (number=charter_num).
#   Everything else gets filler numbers (1000000+index) with no Charter: body.
make_board() {
  local out="$1" total="$2" charter_num="$3"
  local probe_num=$((charter_num - 1))
  python3 - > "$out" <<PYEOF
import json
total, charter_num, probe_num = $total, $charter_num, $probe_num
items = []
for i in range(total):
    if i == total - 1:
        items.append({
            "number": charter_num,
            "state": "OPEN",
            "labels": [{"name": "type:charter"}, {"name": "status:approved"}],
            "body": ""
        })
    elif i == total - 2:
        items.append({
            "number": probe_num,
            "state": "OPEN",
            "labels": [],
            "body": "Charter: #%d\n\n## Acceptance (machine)\n\n- check: echo probe-ok\n" % charter_num
        })
    else:
        items.append({
            "number": 1000000 + i,
            "state": "OPEN",
            "labels": [],
            "body": ""
        })
print(json.dumps(items))
PYEOF
}

run_launchable() {
  GH_FIXTURE="$1" bash "$BOARD_SH" launchable 2>/dev/null || true
}

# ── S1: 250-item board, charter #250 ─────────────────────────────────────────
echo "=== S1: 250-item board (charter #250, regression case) ==="

F1="$TMP/board_s1.json"
make_board "$F1" 250 250

OUT1=$(run_launchable "$F1")
if [ -n "$OUT1" ]; then
  ok "S1: launchable output non-empty — charter #250 visible to launchable logic"
  echo "$OUT1" | grep -qx "249" \
    && ok "S1: probe leaf #249 is in the launchable set" \
    || ko "S1: probe leaf #249 absent from launchable output (got: $(printf '%s' "$OUT1" | head -3))"
else
  ko "S1: launchable output EMPTY — charter #250 was dropped (regression: -L 200 window bug)"
  ko "S1: probe leaf #249 unreachable when charter #250 is invisible"
fi

# ── S2: 600-item board, charter #614 ─────────────────────────────────────────
echo "=== S2: 600-item board (charter #614, production-scale sanity) ==="

F2="$TMP/board_s2.json"
make_board "$F2" 600 614

OUT2=$(run_launchable "$F2")
if [ -n "$OUT2" ]; then
  ok "S2: launchable output non-empty — charter #614 visible at 600-item scale"
  echo "$OUT2" | grep -qx "613" \
    && ok "S2: probe leaf #613 is in the launchable set" \
    || ko "S2: probe leaf #613 absent from launchable output (got: $(printf '%s' "$OUT2" | head -3))"
else
  ko "S2: launchable output EMPTY — charter #614 dropped in 600-item board"
  ko "S2: probe leaf #613 unreachable when charter #614 is invisible"
fi

# ── Summary ────────────────────────────────────────────────────────────────────
echo
printf '=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
