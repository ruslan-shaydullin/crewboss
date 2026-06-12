#!/usr/bin/env bash
# acceptance-block.test.sh — unit tests for acceptance-parse.sh and the
# acceptance-block gate in launchable.sh.  Class: ii (unit-bash).
#
# RED-a: body without block → acceptance-parse.sh exits non-zero
# RED-b: body with block (1 test-line + 1 check-line) → exit 0, 2 output lines,
#        correct translation
# RED-c: board leaf WITHOUT block → predicate does NOT emit it;
#        same leaf WITH block → predicate emits it
# RED-d: empty block (header, no valid lines) → fail;
#        garbage-only block (non test:/check: lines) → fail
# RED-e: grandfathering — launchable.test.sh AND integrator.test.sh still green
#        after enforcement is active

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PARSER="$HERE/../runtime/acceptance-parse.sh"
LAUNCHABLE_REF="$HERE/../launcher/launchable.sh"
LAUNCHABLE_R6="$HERE/../../proto/r6/launchable.sh"

pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

# Minimal charter JSON (body irrelevant for leaf predicate; charter itself does not
# need an acceptance block — the gate only applies to type:agent leaves).
CHARTER='{"number":1,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],"body":"charter goal"}'

# ── fixtures ────────────────────────────────────────────────────────────────────

BODY_WITH_BLOCK="Charter: #1

## Acceptance (machine)
- test: reference/tests/foo.sh
- check: echo hello

## Notes
some other section"

BODY_NO_BLOCK="Charter: #1

Some description with no acceptance block here."

BODY_EMPTY_BLOCK="Charter: #1

## Acceptance (machine)

## Notes
next section"

BODY_GARBAGE_BLOCK="Charter: #1

## Acceptance (machine)
- foo: bar
- baz: qux"

# ── RED-a ────────────────────────────────────────────────────────────────────────
printf '%s' "$BODY_NO_BLOCK" | bash "$PARSER" >/dev/null 2>&1 \
  && ko "RED-a: body without block should exit non-zero (exit 0 is wrong)" \
  || ok "RED-a: body without block → parser exits non-zero"

# ── RED-b ────────────────────────────────────────────────────────────────────────
OUT="$(printf '%s' "$BODY_WITH_BLOCK" | bash "$PARSER" 2>/dev/null)"
EC=$?
[ "$EC" -eq 0 ] \
  && ok "RED-b: body with block → exit 0" \
  || ko "RED-b: body with block → expected exit 0, got $EC"

LINE_COUNT="$(printf '%s\n' "$OUT" | grep -c .)"
[ "$LINE_COUNT" -eq 2 ] \
  && ok "RED-b: exactly 2 output lines" \
  || ko "RED-b: expected 2 output lines, got $LINE_COUNT"

FIRST_LINE="$(printf '%s\n' "$OUT" | sed -n '1p')"
SECOND_LINE="$(printf '%s\n' "$OUT" | sed -n '2p')"

[ "$FIRST_LINE" = "bash reference/tests/foo.sh" ] \
  && ok "RED-b: test: line translated to 'bash <path>'" \
  || ko "RED-b: test: wrong translation — got: [$FIRST_LINE]"

[ "$SECOND_LINE" = "echo hello" ] \
  && ok "RED-b: check: line passed through as-is" \
  || ko "RED-b: check: wrong translation — got: [$SECOND_LINE]"

# ── RED-c ────────────────────────────────────────────────────────────────────────
LEAF_WITH='{"number":10,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"Charter: #1\n## Acceptance (machine)\n- check: true"}'
LEAF_WITHOUT='{"number":10,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"Charter: #1\nno block here"}'

BOARD_WITH="[$CHARTER,$LEAF_WITH]"
BOARD_WITHOUT="[$CHARTER,$LEAF_WITHOUT]"

for tag in ref r6; do
  if [ "$tag" = ref ]; then PRED="$LAUNCHABLE_REF"; else PRED="$LAUNCHABLE_R6"; fi

  GOT_WITH="$(printf '%s' "$BOARD_WITH" | bash "$PRED" 2>/dev/null)"
  GOT_WITHOUT="$(printf '%s' "$BOARD_WITHOUT" | bash "$PRED" 2>/dev/null)"

  [ -n "$GOT_WITH" ] \
    && ok "RED-c ($tag): leaf WITH block is launchable" \
    || ko "RED-c ($tag): leaf WITH block should be launchable (got nothing)"

  [ -z "$GOT_WITHOUT" ] \
    && ok "RED-c ($tag): leaf WITHOUT block is NOT launchable" \
    || ko "RED-c ($tag): leaf WITHOUT block should NOT be launchable (got: [$GOT_WITHOUT])"
done

# ── RED-d ────────────────────────────────────────────────────────────────────────
printf '%s' "$BODY_EMPTY_BLOCK" | bash "$PARSER" >/dev/null 2>&1 \
  && ko "RED-d: empty block should fail" \
  || ok "RED-d: empty block (header but no valid lines) → parser exits non-zero"

printf '%s' "$BODY_GARBAGE_BLOCK" | bash "$PARSER" >/dev/null 2>&1 \
  && ko "RED-d: garbage-only block should fail" \
  || ok "RED-d: garbage-only block (no test:/check: lines) → parser exits non-zero"

# ── RED-e (grandfathering) ────────────────────────────────────────────────────────
bash "$HERE/launchable.test.sh" >/dev/null 2>&1 \
  && ok "RED-e: launchable.test.sh still green with acceptance-block enforcement" \
  || ko "RED-e: launchable.test.sh FAILED — grandfathering broken or predicate regression"

bash "$HERE/integrator.test.sh" >/dev/null 2>&1 \
  && ok "RED-e: integrator.test.sh still green with acceptance-block enforcement" \
  || ko "RED-e: integrator.test.sh FAILED — grandfathering broken or predicate regression"

# ── summary ──────────────────────────────────────────────────────────────────────
echo
echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
