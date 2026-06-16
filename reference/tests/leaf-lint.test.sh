#!/usr/bin/env bash
#
# leaf-lint.test.sh — tests for reference/bin/leaf-lint.sh (issue #218)
#
# TDD: this file was written BEFORE the implementation (red -> green).
#
# Cases:
#   1. Charter: #217 only                        -> exit 0
#   2. body with NO Charter line                 -> exit 1
#   3. body with TWO Charter lines               -> exit 1
#   4. Charter: #1 + Depends-on: 5 (missing #)  -> exit 1
#   5. Charter: #1 + Depends-on: #5, #9 (good)  -> exit 0
#   6. stdin mode: pipe valid body, no args      -> exit 0
#   7. exit-1 case emits >=1 line on stderr      -> assert non-empty stderr

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LINTER="$HERE/../bin/leaf-lint.sh"

pass=0; fail=0
ok() { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

# ---------------------------------------------------------------------------
# Case 1: valid body — Charter line only
# ---------------------------------------------------------------------------
echo "=== Case 1: Charter line only -> exit 0 ==="
body1="Charter: #217"
if echo "$body1" | bash "$LINTER" >/dev/null 2>&1; then
  ok "valid Charter-only body exits 0"
else
  no "valid Charter-only body should exit 0, got non-zero"
fi

# ---------------------------------------------------------------------------
# Case 2: no Charter line -> exit 1
# ---------------------------------------------------------------------------
echo "=== Case 2: no Charter line -> exit 1 ==="
body2="Some random content
Depends-on: #5"
if echo "$body2" | bash "$LINTER" >/dev/null 2>&1; then
  no "missing Charter should exit 1, got 0"
else
  ok "missing Charter exits 1"
fi

# ---------------------------------------------------------------------------
# Case 3: two Charter lines -> exit 1
# ---------------------------------------------------------------------------
echo "=== Case 3: duplicate Charter -> exit 1 ==="
body3="Charter: #1
Charter: #2"
if echo "$body3" | bash "$LINTER" >/dev/null 2>&1; then
  no "duplicate Charter should exit 1, got 0"
else
  ok "duplicate Charter exits 1"
fi

# ---------------------------------------------------------------------------
# Case 4: Depends-on missing # prefix -> exit 1
# ---------------------------------------------------------------------------
echo "=== Case 4: Depends-on without # prefix -> exit 1 ==="
body4="Charter: #1
Depends-on: 5"
if echo "$body4" | bash "$LINTER" >/dev/null 2>&1; then
  no "malformed Depends-on (missing #) should exit 1, got 0"
else
  ok "malformed Depends-on exits 1"
fi

# ---------------------------------------------------------------------------
# Case 5: well-formed Charter + Depends-on -> exit 0
# ---------------------------------------------------------------------------
echo "=== Case 5: Charter + well-formed Depends-on -> exit 0 ==="
body5="Charter: #1
Depends-on: #5, #9"
if echo "$body5" | bash "$LINTER" >/dev/null 2>&1; then
  ok "valid Charter + Depends-on exits 0"
else
  no "valid Charter + Depends-on should exit 0, got non-zero"
fi

# ---------------------------------------------------------------------------
# Case 6: stdin mode (no file argument) -> exit 0 for valid body
# ---------------------------------------------------------------------------
echo "=== Case 6: stdin mode with valid body -> exit 0 ==="
body6="Charter: #42"
if echo "$body6" | bash "$LINTER" >/dev/null 2>&1; then
  ok "stdin mode with valid body exits 0"
else
  no "stdin mode with valid body should exit 0, got non-zero"
fi

# ---------------------------------------------------------------------------
# Case 7: exit-1 case emits >=1 line on stderr
# ---------------------------------------------------------------------------
echo "=== Case 7: error case emits non-empty stderr ==="
body7="no charter here"
stderr_out=$(echo "$body7" | bash "$LINTER" 2>&1 >/dev/null || true)
if [ -n "$stderr_out" ]; then
  ok "error case emits non-empty stderr"
else
  no "error case should emit non-empty stderr, got empty"
fi

# ---------------------------------------------------------------------------
echo
printf '=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
