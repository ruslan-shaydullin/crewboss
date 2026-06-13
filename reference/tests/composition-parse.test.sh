#!/usr/bin/env bash
# composition-parse.test.sh — unit tests for composition-parse.sh. Class: b (unit-bash).
#
# Fixtures over the REAL team-example/ (span_max=5, 14 roles including go-backend-dev,
# qa-engineer). No synthetic org.json; no network; no gh.
#
# RED-0 (what this catches): reference/runtime/composition-parse.sh does not exist —
#        the parser is entirely absent, and the whole test is genuinely red.
#
# Cases:
#   valid block (2 leaves: go-backend-dev, qa-engineer) → correct TSV, exit 0
#   no block → exit 1
#   est_cost_usd not a number → exit 1
#   6 leaf lines at span_max=5 → exit 4 (span exceeded)
#   role no-such-role → exit 4 (unknown role)
#   leaf assigned to role not in role: lines → exit 4 (undeclared role)
#   block in middle of long comment with other ## sections → parses only that block

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PARSER="$HERE/../runtime/composition-parse.sh"
MANIFEST="$HERE/../../team-example"

pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

# ── RED-0: parser must exist ─────────────────────────────────────────────────
[ -f "$PARSER" ] \
  && ok "RED-0: composition-parse.sh exists" \
  || ko "RED-0: composition-parse.sh NOT FOUND — parser missing entirely"

# ── fixtures ─────────────────────────────────────────────────────────────────

BODY_VALID="Charter: #131

## Composition (machine)
- approach: parallel executor tracks
- role: go-backend-dev
- role: qa-engineer
- leaf: 134 -> go-backend-dev
- leaf: 135 -> qa-engineer
- est_cost_usd: 0.80

## Notes
some other section"

BODY_NO_BLOCK="Charter: #131

Some description with no composition block here."

BODY_BAD_COST="Charter: #131

## Composition (machine)
- approach: something
- role: go-backend-dev
- leaf: 10 -> go-backend-dev
- est_cost_usd: not-a-number"

BODY_SPAN_OVER="Charter: #131

## Composition (machine)
- approach: too many leaves (6 > span_max=5)
- role: go-backend-dev
- leaf: 1 -> go-backend-dev
- leaf: 2 -> go-backend-dev
- leaf: 3 -> go-backend-dev
- leaf: 4 -> go-backend-dev
- leaf: 5 -> go-backend-dev
- leaf: 6 -> go-backend-dev
- est_cost_usd: 1.00"

BODY_UNKNOWN_ROLE="Charter: #131

## Composition (machine)
- approach: unknown role test
- role: no-such-role
- leaf: 10 -> no-such-role
- est_cost_usd: 0.50"

BODY_LEAF_UNDECLARED_ROLE="Charter: #131

## Composition (machine)
- approach: leaf points to undeclared role
- role: go-backend-dev
- leaf: 10 -> qa-engineer
- est_cost_usd: 0.50"

BODY_IN_MIDDLE="Charter: #131

## Summary
Just a summary here with some content.

## Composition (machine)
- approach: middle block
- role: go-backend-dev
- role: qa-engineer
- leaf: 20 -> go-backend-dev
- leaf: 21 -> qa-engineer
- est_cost_usd: 1.20

## Implementation Details
More text here that should be ignored.

## Acceptance (machine)
- test: reference/tests/composition-parse.test.sh
- check: test -f reference/runtime/composition-parse.sh"

# ── valid block → correct TSV, exit 0 ────────────────────────────────────────

OUT="$(printf '%s' "$BODY_VALID" | bash "$PARSER" "$MANIFEST" 2>/dev/null)"
EC=$?

[ "$EC" -eq 0 ] \
  && ok "valid block: exit 0" \
  || ko "valid block: expected exit 0, got $EC"

printf '%s\n' "$OUT" | grep -qF "$(printf 'approach\tparallel executor tracks')" \
  && ok "valid block: approach TSV line correct" \
  || ko "valid block: approach TSV wrong (got: $(printf '%s\n' "$OUT" | head -1))"

printf '%s\n' "$OUT" | grep -qF "$(printf 'role\tgo-backend-dev')" \
  && ok "valid block: role go-backend-dev in TSV" \
  || ko "valid block: role go-backend-dev missing from TSV"

printf '%s\n' "$OUT" | grep -qF "$(printf 'role\tqa-engineer')" \
  && ok "valid block: role qa-engineer in TSV" \
  || ko "valid block: role qa-engineer missing from TSV"

printf '%s\n' "$OUT" | grep -qF "$(printf 'leaf\t134\tgo-backend-dev')" \
  && ok "valid block: leaf 134 -> go-backend-dev in TSV" \
  || ko "valid block: leaf 134 TSV wrong (got: $(printf '%s\n' "$OUT"))"

printf '%s\n' "$OUT" | grep -qF "$(printf 'leaf\t135\tqa-engineer')" \
  && ok "valid block: leaf 135 -> qa-engineer in TSV" \
  || ko "valid block: leaf 135 TSV wrong"

printf '%s\n' "$OUT" | grep -qF "$(printf 'est_cost_usd\t0.80')" \
  && ok "valid block: est_cost_usd TSV correct" \
  || ko "valid block: est_cost_usd TSV wrong (got: $(printf '%s\n' "$OUT" | tail -1))"

# ── no block → exit 1 ────────────────────────────────────────────────────────

printf '%s' "$BODY_NO_BLOCK" | bash "$PARSER" "$MANIFEST" >/dev/null 2>&1
EC=$?
[ "$EC" -eq 1 ] \
  && ok "no block: exit 1" \
  || ko "no block: expected exit 1, got $EC"

# ── est_cost_usd not a number → exit 1 ───────────────────────────────────────

printf '%s' "$BODY_BAD_COST" | bash "$PARSER" "$MANIFEST" >/dev/null 2>&1
EC=$?
[ "$EC" -eq 1 ] \
  && ok "bad est_cost_usd (not a number): exit 1" \
  || ko "bad est_cost_usd: expected exit 1, got $EC"

# ── 6 leaf lines at span_max=5 → exit 4 ─────────────────────────────────────

printf '%s' "$BODY_SPAN_OVER" | bash "$PARSER" "$MANIFEST" >/dev/null 2>&1
EC=$?
[ "$EC" -eq 4 ] \
  && ok "span exceeded (6 leaves > span_max=5): exit 4" \
  || ko "span exceeded: expected exit 4, got $EC"

# ── role no-such-role (not in manifest) → exit 4 ─────────────────────────────

printf '%s' "$BODY_UNKNOWN_ROLE" | bash "$PARSER" "$MANIFEST" >/dev/null 2>&1
EC=$?
[ "$EC" -eq 4 ] \
  && ok "unknown role (no-such-role not in manifest): exit 4" \
  || ko "unknown role: expected exit 4, got $EC"

# ── leaf assigned to role not in role: lines → exit 4 ────────────────────────

printf '%s' "$BODY_LEAF_UNDECLARED_ROLE" | bash "$PARSER" "$MANIFEST" >/dev/null 2>&1
EC=$?
[ "$EC" -eq 4 ] \
  && ok "leaf role not declared in role: lines: exit 4" \
  || ko "leaf undeclared role: expected exit 4, got $EC"

# ── block in middle of long comment with other ## sections ───────────────────

OUT2="$(printf '%s' "$BODY_IN_MIDDLE" | bash "$PARSER" "$MANIFEST" 2>/dev/null)"
EC=$?

[ "$EC" -eq 0 ] \
  && ok "block in middle of comment: exit 0" \
  || ko "block in middle: expected exit 0, got $EC"

printf '%s\n' "$OUT2" | grep -qF "$(printf 'approach\tmiddle block')" \
  && ok "block in middle: approach parsed correctly" \
  || ko "block in middle: approach wrong (got: $(printf '%s\n' "$OUT2" | head -1))"

printf '%s\n' "$OUT2" | grep -qF "$(printf 'leaf\t20\tgo-backend-dev')" \
  && ok "block in middle: leaf 20 -> go-backend-dev parsed" \
  || ko "block in middle: leaf 20 not found in TSV"

printf '%s\n' "$OUT2" | grep -qF "$(printf 'leaf\t21\tqa-engineer')" \
  && ok "block in middle: leaf 21 -> qa-engineer parsed" \
  || ko "block in middle: leaf 21 not found in TSV"

# Verify no bleed from Acceptance (machine) section after block end
printf '%s\n' "$OUT2" | grep -qF "reference/tests/composition-parse.test.sh" \
  && ko "block in middle: leaked content from later ## section (Acceptance)" \
  || ok "block in middle: block stops at next ## section (no bleed)"

# ── summary ──────────────────────────────────────────────────────────────────
echo
echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
