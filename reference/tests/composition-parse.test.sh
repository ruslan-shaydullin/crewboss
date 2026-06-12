#!/usr/bin/env bash
# composition-parse.test.sh — unit tests for reference/runtime/composition-parse.sh
# Class b unit (no network, no gh). Fixtures built on top of real team-example/.
#
# RED-0: if reference/runtime/composition-parse.sh is absent the whole test is
# genuinely red — the first check exits 2 before any cases run.

HERE="$(cd "$(dirname "$0")" && pwd)"
PARSER="$HERE/../runtime/composition-parse.sh"
TEAM="$HERE/../../team-example"

# RED-0: parser must exist
[ -f "$PARSER" ] || { printf 'FATAL: %s not found\n' "$PARSER"; exit 2; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()   { printf 'ok   %s\n' "$*"; pass=$((pass+1)); }
fail() { printf 'FAIL %s\n' "$*"; fail=$((fail+1)); }

# run_parser <file> — run the parser against team-example, return stdout
run_parser() { bash "$PARSER" "$TEAM" "$1" 2>/dev/null; }

# check_exit <label> <exp_exit> <file>
check_exit() {
  local label="$1" exp="$2" file="$3"
  bash "$PARSER" "$TEAM" "$file" >/dev/null 2>&1; local rc=$?
  if [ "$rc" = "$exp" ]; then ok "$label (exit $exp)"
  else fail "$label: expected exit $exp, got $rc"; fi
}

# check_tsv_field <label> <file> <field> <expected_value>
# Grabs the FIRST matching field line and compares tab-delimited value.
check_tsv_field() {
  local label="$1" file="$2" field="$3" exp="$4"
  local got
  got=$(run_parser "$file" | awk -F'\t' -v f="$field" '$1==f{print $2; exit}')
  if [ "$got" = "$exp" ]; then ok "$label"
  else fail "$label: expected=[$exp] got=[$got]"; fi
}

# check_tsv_contains <label> <file> <grep_pattern>
# Checks that at least one line of TSV output matches the pattern.
check_tsv_contains() {
  local label="$1" file="$2" pattern="$3"
  if run_parser "$file" | grep -q "$pattern"; then ok "$label"
  else fail "$label: pattern [$pattern] not found in output"; fi
}

# ─────────────────────────────────────────────────────────────────────────────
echo "== valid block (2 leaves: go-backend-dev, qa-engineer) =="

cat > "$TMP/valid.txt" << 'EOF'
## Composition (machine)
- approach: parallel backend and QA
- role: go-backend-dev
- role: qa-engineer
- leaf: leaf/100 -> go-backend-dev
- leaf: leaf/101 -> qa-engineer
- est_cost_usd: 1.50
EOF

check_exit "valid block" 0 "$TMP/valid.txt"
check_tsv_field "valid: approach"      "$TMP/valid.txt" "approach"     "parallel backend and QA"
check_tsv_field "valid: est_cost_usd"  "$TMP/valid.txt" "est_cost_usd" "1.50"
check_tsv_contains "valid: role go-backend-dev" "$TMP/valid.txt" $'^role\tgo-backend-dev$'
check_tsv_contains "valid: role qa-engineer"    "$TMP/valid.txt" $'^role\tqa-engineer$'
check_tsv_contains "valid: leaf/100 -> go-backend-dev" "$TMP/valid.txt" $'^leaf\tleaf/100\tgo-backend-dev$'
check_tsv_contains "valid: leaf/101 -> qa-engineer"    "$TMP/valid.txt" $'^leaf\tleaf/101\tqa-engineer$'

# ─────────────────────────────────────────────────────────────────────────────
echo "== no block → exit 1 =="

cat > "$TMP/no_block.txt" << 'EOF'
Just a comment with no Composition block at all.

## Some Section
Some content here.
EOF

check_exit "no block" 1 "$TMP/no_block.txt"

# ─────────────────────────────────────────────────────────────────────────────
echo "== est_cost_usd not a number → exit 1 =="

cat > "$TMP/bad_cost.txt" << 'EOF'
## Composition (machine)
- approach: some approach
- role: go-backend-dev
- leaf: leaf/100 -> go-backend-dev
- est_cost_usd: not-a-number
EOF

check_exit "est_cost_usd not a number" 1 "$TMP/bad_cost.txt"

# ─────────────────────────────────────────────────────────────────────────────
echo "== 6 leaf-lines with span_max=5 → exit 4 (span!) =="

cat > "$TMP/span.txt" << 'EOF'
## Composition (machine)
- approach: overloaded composition
- role: go-backend-dev
- leaf: leaf/1 -> go-backend-dev
- leaf: leaf/2 -> go-backend-dev
- leaf: leaf/3 -> go-backend-dev
- leaf: leaf/4 -> go-backend-dev
- leaf: leaf/5 -> go-backend-dev
- leaf: leaf/6 -> go-backend-dev
- est_cost_usd: 3.00
EOF

check_exit "6 leaves span_max=5" 4 "$TMP/span.txt"

# ─────────────────────────────────────────────────────────────────────────────
echo "== role 'no-such-role' → exit 4 =="

cat > "$TMP/bad_role.txt" << 'EOF'
## Composition (machine)
- approach: risky composition
- role: no-such-role
- leaf: leaf/100 -> no-such-role
- est_cost_usd: 0.50
EOF

check_exit "unknown role no-such-role" 4 "$TMP/bad_role.txt"

# ─────────────────────────────────────────────────────────────────────────────
echo "== leaf assigned to role not in role: lines → exit 4 =="

cat > "$TMP/undeclared.txt" << 'EOF'
## Composition (machine)
- approach: mismatched roles
- role: go-backend-dev
- leaf: leaf/100 -> qa-engineer
- est_cost_usd: 0.50
EOF

check_exit "leaf role not declared" 4 "$TMP/undeclared.txt"

# ─────────────────────────────────────────────────────────────────────────────
echo "== block in the middle of a long comment with other ## sections =="

cat > "$TMP/multi.txt" << 'EOF'
# Long charter comment

## Summary
This is a big charter plan with multiple sections.

## Stakeholders
Alice, Bob, Carol.

## Composition (machine)
- approach: targeted delivery
- role: qa-engineer
- leaf: leaf/200 -> qa-engineer
- est_cost_usd: 0.75

## Acceptance (machine)
- test: some-test.sh
- check: test -f something

## Notes
End of document.
EOF

check_exit "multi-section: exit 0"       0 "$TMP/multi.txt"
check_tsv_field "multi-section: approach"      "$TMP/multi.txt" "approach"     "targeted delivery"
check_tsv_field "multi-section: est_cost_usd"  "$TMP/multi.txt" "est_cost_usd" "0.75"
check_tsv_contains "multi-section: role qa-engineer" "$TMP/multi.txt" $'^role\tqa-engineer$'
check_tsv_contains "multi-section: leaf/200"         "$TMP/multi.txt" $'^leaf\tleaf/200\tqa-engineer$'

# Confirm that content from OTHER sections is NOT in the TSV output
if run_parser "$TMP/multi.txt" | grep -q 'some-test\.sh'; then
  fail "multi-section: Acceptance content leaked into output"
else
  ok "multi-section: other sections not parsed"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = "0" ]
