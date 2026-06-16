#!/usr/bin/env bash
# launchable-composition.test.sh — composition:approved gate tests (issue #139).
#
# Class: ALLOW (pure-predicate unit test; no launcher loop, no background processes,
# no timing/poll/sleep, no recursive verify-merged). Verdict = f(merged content only).
#
# Layer 1: pure predicate (stdin fixture → launchable.sh → stdout)
#   Tests both proto/r6/launchable.sh and reference/launcher/launchable.sh.
#   RED  (main use case): --require-composition + charter without composition:approved
#        → leaf must NOT be emitted (today the flag is silently ignored → leaf emitted).
#   GREEN-1: --require-composition + charter WITH composition:approved → leaf emitted.
#   GREEN-2: no flag (legacy HD-1) → leaf emitted regardless of composition:approved.
#   GREEN-3: env CREWBOSS_REQUIRE_COMPOSITION=1 equivalent to --require-composition.
#   GREEN-4: orthogonality pins (hold/in-progress still excluded regardless of gate).
#
# Layer 2: board-gh.sh + gh stub (real board adapter, CB_MANIFEST triggers the flag)
#   RED  (main use case): CB_MANIFEST set, charter without composition:approved → empty.
#   GREEN: CB_MANIFEST set, charter WITH composition:approved → leaf emitted.
#   LEGACY: no CB_MANIFEST → leaf emitted without composition:approved (HD-1).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PRED_R6="$HERE/../../proto/r6/launchable.sh"
PRED_REF="$HERE/../launcher/launchable.sh"
BOARD_GH="$HERE/../../proto/r6/board-gh.sh"

pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

# ── fixtures ──────────────────────────────────────────────────────────────────

# Charter approved but WITHOUT composition:approved
CHARTER_NO_COMP='{"number":1,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],"body":"charter goal"}'
# Charter approved WITH composition:approved
CHARTER_WITH_COMP='{"number":1,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"},{"name":"composition:approved"}],"body":"charter goal"}'

# Standard open leaf with acceptance block (JSON \n = newline escape)
LEAF='{"number":10,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"Charter: #1\n## Acceptance (machine)\n- check: true"}'

BOARD_NO_COMP="[$CHARTER_NO_COMP,$LEAF]"
BOARD_WITH_COMP="[$CHARTER_WITH_COMP,$LEAF]"

# ── Layer 1: pure predicate ───────────────────────────────────────────────────

for tag in r6 ref; do
  if [ "$tag" = r6 ]; then PRED="$PRED_R6"; else PRED="$PRED_REF"; fi

  # RED (main use case): --require-composition, charter WITHOUT composition:approved
  # → leaf must NOT be emitted (flag was silently ignored before fix)
  GOT=$(printf '%s' "$BOARD_NO_COMP" | bash "$PRED" --require-composition 2>/dev/null)
  [ -z "$GOT" ] \
    && ok "L1-$tag: --require-composition: no composition:approved → leaf NOT emitted" \
    || ko "L1-$tag: --require-composition: no composition:approved → got [$GOT] (expected empty)"

  # GREEN-1: --require-composition + charter WITH composition:approved → leaf emitted
  GOT=$(printf '%s' "$BOARD_WITH_COMP" | bash "$PRED" --require-composition 2>/dev/null)
  [ -n "$GOT" ] \
    && ok "L1-$tag: --require-composition: composition:approved present → leaf emitted" \
    || ko "L1-$tag: --require-composition: composition:approved present → leaf NOT emitted (pred broken)"

  # GREEN-2: no --require-composition (legacy HD-1) → leaf emitted even without composition:approved
  GOT=$(printf '%s' "$BOARD_NO_COMP" | bash "$PRED" 2>/dev/null)
  [ -n "$GOT" ] \
    && ok "L1-$tag: legacy (no flag): leaf emitted without composition:approved (HD-1 compat)" \
    || ko "L1-$tag: legacy (no flag): leaf NOT emitted (HD-1 regression)"

  # GREEN-3: env CREWBOSS_REQUIRE_COMPOSITION=1 also gates (same as --require-composition flag)
  GOT=$(printf '%s' "$BOARD_NO_COMP" | CREWBOSS_REQUIRE_COMPOSITION=1 bash "$PRED" 2>/dev/null)
  [ -z "$GOT" ] \
    && ok "L1-$tag: CREWBOSS_REQUIRE_COMPOSITION=1 env gates (equiv to --require-composition)" \
    || ko "L1-$tag: CREWBOSS_REQUIRE_COMPOSITION=1 did not gate → got [$GOT] (expected empty)"

  # GREEN-3b: env=1 + composition:approved → leaf emitted
  GOT=$(printf '%s' "$BOARD_WITH_COMP" | CREWBOSS_REQUIRE_COMPOSITION=1 bash "$PRED" 2>/dev/null)
  [ -n "$GOT" ] \
    && ok "L1-$tag: CREWBOSS_REQUIRE_COMPOSITION=1 + composition:approved → leaf emitted" \
    || ko "L1-$tag: CREWBOSS_REQUIRE_COMPOSITION=1 + composition:approved → leaf NOT emitted"

done

# GREEN-4: composition gate does NOT affect hold/in-progress exclusion logic (pins orthogonal)
CHARTER_C='{"number":1,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"},{"name":"composition:approved"}],"body":"charter goal"}'
LEAF_HOLD='{"number":11,"state":"OPEN","labels":[{"name":"type:agent"},{"name":"hold"}],"body":"Charter: #1\n## Acceptance (machine)\n- check: true"}'
LEAF_IP='{"number":12,"state":"OPEN","labels":[{"name":"type:agent"},{"name":"status:in-progress"}],"body":"Charter: #1\n## Acceptance (machine)\n- check: true"}'
BOARD_PINS="[$CHARTER_C,$LEAF,$LEAF_HOLD,$LEAF_IP]"

GOT=$(printf '%s' "$BOARD_PINS" | bash "$PRED_R6" --require-composition 2>/dev/null \
      | sort -n | tr '\n' ' ' | sed 's/ *$//')
[ "$GOT" = "10" ] \
  && ok "L1-r6: pins orthogonal — hold/in-progress excluded, only #10 emitted with composition gate" \
  || ko "L1-r6: pins orthogonal — expected [10] got [$GOT]"

# ── Layer 2: board-gh.sh + gh stub ───────────────────────────────────────────

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"; mkdir -p "$BIN"
BOARD_STATE="$ROOT/board.json"
export BOARD_STATE

# Minimal gh stub: issue list --state all → full board; other commands silently succeed
cat > "$BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
obj="$1"; verb="$2"; shift 2
_args=()
while [ $# -gt 0 ]; do
  case "$1" in -R|--repo|-L|--limit) shift ;; *) _args+=("$1") ;; esac; shift
done
set -- "${_args[@]+"${_args[@]}"}"
case "$obj $verb" in
  "issue list")
    while [ $# -gt 0 ]; do
      case "$1" in --state) shift ;; --json) shift ;; esac; shift
    done
    cat "$BOARD_STATE" ;;
  "label create") ;;
  "auth token") echo "fake-token" ;;
  *) ;;
esac
exit 0
GHEOF
chmod +x "$BIN/gh"

# CB_MANIFEST dir (non-empty path triggers --require-composition in board-gh.sh)
CB_MANIFEST_DIR="$ROOT/manifest"; mkdir -p "$CB_MANIFEST_DIR"

LEAF_BODY='Charter: #1\n## Acceptance (machine)\n- check: true'

# L2-RED: CB_MANIFEST set, charter WITHOUT composition:approved → leaf must NOT be emitted
printf '[{"number":1,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],"body":"charter goal"},{"number":10,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"%s"}]\n' \
  "$LEAF_BODY" > "$BOARD_STATE"

GOT=$(PATH="$BIN:$PATH" CB_REPO="test/repo" CB_MANIFEST="$CB_MANIFEST_DIR" \
  CREWBOSS_CHARTER= bash "$BOARD_GH" launchable 2>/dev/null)
[ -z "$GOT" ] \
  && ok "L2: CB_MANIFEST set + no composition:approved → leaf NOT emitted" \
  || ko "L2: CB_MANIFEST set + no composition:approved → got [$GOT] (expected empty; flag not passed)"

# L2-GREEN: add composition:approved → leaf IS emitted
printf '[{"number":1,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"},{"name":"composition:approved"}],"body":"charter goal"},{"number":10,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"%s"}]\n' \
  "$LEAF_BODY" > "$BOARD_STATE"

GOT=$(PATH="$BIN:$PATH" CB_REPO="test/repo" CB_MANIFEST="$CB_MANIFEST_DIR" \
  CREWBOSS_CHARTER= bash "$BOARD_GH" launchable 2>/dev/null)
[ -n "$GOT" ] \
  && ok "L2: CB_MANIFEST set + composition:approved present → leaf emitted" \
  || ko "L2: CB_MANIFEST set + composition:approved present → leaf NOT emitted (pred broken)"

# L2-LEGACY: no CB_MANIFEST → leaf emitted without composition:approved (HD-1 compat)
printf '[{"number":1,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],"body":"charter goal"},{"number":10,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"%s"}]\n' \
  "$LEAF_BODY" > "$BOARD_STATE"

GOT=$(PATH="$BIN:$PATH" CB_REPO="test/repo" \
  CREWBOSS_CHARTER= bash "$BOARD_GH" launchable 2>/dev/null)
[ -n "$GOT" ] \
  && ok "L2: no CB_MANIFEST (legacy) → leaf emitted without composition:approved (HD-1)" \
  || ko "L2: no CB_MANIFEST (legacy) → leaf NOT emitted (HD-1 regression)"

# ── Acceptance check from issue spec ─────────────────────────────────────────
grep -q "composition:approved" "$PRED_R6" \
  && ok "check: composition:approved present in proto/r6/launchable.sh" \
  || ko "check: composition:approved NOT found in proto/r6/launchable.sh"

# ── summary ──────────────────────────────────────────────────────────────────
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
