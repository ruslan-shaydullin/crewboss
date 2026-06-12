#!/usr/bin/env bash
# needs-rework.test.sh — state-machine, predicate, and rework-dispatch tests (issue #87).
# Class ii — unit-bash; uses board-JSON-on-stdin and a stateful gh stub.
#
# Test cases:
#   LOCK-a : needs-rework leaf IS launchable; blocked is NOT (both predicates).
#            Contract-lock — green before AND after the fix.
#   RED-b  : board-gh.sh route 12 needs-rework → label set, in-progress/claimed-by removed,
#            comment recorded; get state = needs-rework. Red before fix (unknown outcome).
#   RED-c  : crewboss-launcher-gh.sh dispatches needs-rework leaf via CB_REWORK_SPAWN stub,
#            normal leaf via CB_SPAWN stub (assert by stub logs). Red before fix (no branch).
#   RED-d  : lifecycle: after launcher claim, status:needs-rework REMOVED, in-progress +
#            claimed-by SET (captured by spy stub). Priority: review+needs-rework → "review".
#            Red before fix (claim did not strip needs-rework; get state lacked priority).
#
# Requires: jq, bash, flock (util-linux).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PRED_PROTO="$HERE/../../proto/r6/launchable.sh"
PRED_REF="$HERE/../launcher/launchable.sh"
BOARD_GH_SRC="$HERE/../../proto/r6/board-gh.sh"
LAUNCHER_GH="$HERE/../runtime/crewboss-launcher-gh.sh"

pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"
SANDBOX="$ROOT/sb"
export BOARD_STATE="$SANDBOX/board.json"
export GH_LOG="$SANDBOX/gh.log"
mkdir -p "$BIN" "$SANDBOX"

# ── gh stub: stateful board mutations ─────────────────────────────────────────
# Handles multiple --add-label and --remove-label flags per call.
cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
obj="$1"; verb="$2"; shift 2

# Strip -R / --repo flags
_args=()
while [ $# -gt 0 ]; do
  case "$1" in -R|--repo) shift ;; *) _args+=("$1") ;; esac
  shift
done
set -- "${_args[@]+"${_args[@]}"}"

case "$obj $verb" in
  "issue list")
    cat "$BOARD_STATE" ;;

  "issue view")
    n="$1"
    jq --argjson n "$n" 'map(select(.number==$n))[0] // {}' "$BOARD_STATE" ;;

  "issue edit")
    n="$1"; shift
    adds=(); rems=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --add-label)    adds+=("$2"); shift ;;
        --remove-label) rems+=("$2"); shift ;;
      esac
      shift
    done
    # Build JSON arrays from bash arrays (handle empty arrays)
    adds_json="$(printf '%s\n' "${adds[@]+"${adds[@]}"}" | jq -R . | jq -s .)"
    rems_json="$(printf '%s\n' "${rems[@]+"${rems[@]}"}" | jq -R . | jq -s .)"
    jq --argjson n "$n" --argjson adds "$adds_json" --argjson rems "$rems_json" '
      map(if .number == $n then
        .labels = [(.labels // [])[] | select(.name as $nm | ($rems | index($nm)) == null)]
        | reduce $adds[] as $a (.;
            if ([.labels[].name] | index($a)) == null
            then .labels += [{name: $a}] else . end)
      else . end)' \
      "$BOARD_STATE" > "$BOARD_STATE.t" && mv "$BOARD_STATE.t" "$BOARD_STATE"
    {
      printf 'edit #%s' "$n"
      [ "${#adds[@]}" -gt 0 ] && printf ' +[%s]' "${adds[*]}"
      [ "${#rems[@]}" -gt 0 ] && printf ' -[%s]' "${rems[*]}"
      printf '\n'
    } >> "$GH_LOG" ;;

  "issue comment")
    n="$1"; shift; body=""
    while [ $# -gt 0 ]; do
      case "$1" in -b|--body) body="$2"; shift ;; esac
      shift
    done
    jq --argjson n "$n" --arg b "$body" \
      'map(if .number==$n then .comments=((.comments//[])+[{body:$b}]) else . end)' \
      "$BOARD_STATE" > "$BOARD_STATE.t" && mv "$BOARD_STATE.t" "$BOARD_STATE"
    echo "comment #$n: $body" >> "$GH_LOG" ;;

  "label create")
    # no-op in tests (ensure_label calls this; silently ignore)
    ;;

  *)
    echo "stub gh UNHANDLED: $obj $verb $*" >> "$GH_LOG" ;;
esac
exit 0
GH
chmod +x "$BIN/gh"

reset_board(){ # board JSON on stdin
  mkdir -p "$SANDBOX"
  rm -f "$GH_LOG"
  cat > "$BOARD_STATE"
}
has_label(){ [ "$(jq -r --argjson n "$1" \
  'map(select(.number==$n))[0].labels[]?.name' "$BOARD_STATE" | grep -c "^$2$")" -ge 1 ]; }
no_label(){ ! has_label "$1" "$2"; }
board_get_state(){ PATH="$BIN:$PATH" CB_REPO="test/repo" bash "$BOARD_GH_SRC" get "$1" state; }

# ═══════════════════════════════════════════════════════════════════════════════
# LOCK-a: needs-rework leaf IS launchable; blocked is NOT (both predicates).
# This is a CONTRACT LOCK — must be green before AND after the fix.
# ═══════════════════════════════════════════════════════════════════════════════
echo "== LOCK-a: needs-rework launchable; blocked not (both predicates) =="

BOARD_NR='[
  {"number":5,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:approved"}],"body":"charter"},
  {"number":12,"state":"OPEN",
   "labels":[{"name":"type:agent"},{"name":"status:needs-rework"}],"body":"Charter: #5\n## Acceptance (machine)\n- check: true"}
]'
BOARD_BLOCKED='[
  {"number":5,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:approved"}],"body":"charter"},
  {"number":12,"state":"OPEN",
   "labels":[{"name":"type:agent"},{"name":"status:blocked"}],"body":"Charter: #5\n## Acceptance (machine)\n- check: true"}
]'

# proto/r6/launchable.sh — needs-rework is launchable
got=$(printf '%s' "$BOARD_NR" | bash "$PRED_PROTO" | tr '\n' ' ' | sed 's/ *$//')
[ "$got" = "12" ] \
  && ok "LOCK-a (proto): needs-rework leaf #12 is launchable" \
  || ko "LOCK-a (proto): needs-rework leaf #12 NOT launchable (got='$got')"

# proto/r6/launchable.sh — blocked is NOT launchable
got=$(printf '%s' "$BOARD_BLOCKED" | bash "$PRED_PROTO" | tr '\n' ' ' | sed 's/ *$//')
[ -z "$got" ] \
  && ok "LOCK-a (proto): blocked leaf #12 is NOT launchable" \
  || ko "LOCK-a (proto): blocked leaf #12 should not be launchable (got='$got')"

# reference/launcher/launchable.sh — needs-rework is launchable
got=$(printf '%s' "$BOARD_NR" | bash "$PRED_REF" | tr '\n' ' ' | sed 's/ *$//')
[ "$got" = "12" ] \
  && ok "LOCK-a (ref): needs-rework leaf #12 is launchable" \
  || ko "LOCK-a (ref): needs-rework leaf #12 NOT launchable (got='$got')"

# reference/launcher/launchable.sh — blocked is NOT launchable
got=$(printf '%s' "$BOARD_BLOCKED" | bash "$PRED_REF" | tr '\n' ' ' | sed 's/ *$//')
[ -z "$got" ] \
  && ok "LOCK-a (ref): blocked leaf #12 is NOT launchable" \
  || ko "LOCK-a (ref): blocked leaf #12 should not be launchable (got='$got')"

# ═══════════════════════════════════════════════════════════════════════════════
# RED-b: board-gh.sh route 12 needs-rework
#   - status:needs-rework label added
#   - status:in-progress and claimed-by:* removed
#   - comment recorded
#   - get 12 state → "needs-rework"
# Before fix: unknown outcome (exit 64).
# ═══════════════════════════════════════════════════════════════════════════════
echo "== RED-b: board-gh.sh route needs-rework =="

reset_board <<'JSON'
[
  {"number":5,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:approved"}],"body":"charter","comments":[]},
  {"number":12,"state":"OPEN",
   "labels":[{"name":"type:agent"},{"name":"status:in-progress"},{"name":"claimed-by:cb1"}],
   "body":"Charter: #5\n## Acceptance (machine)\n- check: true","comments":[]}
]
JSON

PATH="$BIN:$PATH" CB_REPO="test/repo" \
  bash "$BOARD_GH_SRC" route 12 needs-rework "conflict: ui/app/src/App.tsx"

has_label 12 "status:needs-rework" \
  && ok "RED-b: status:needs-rework added" \
  || ko "RED-b: status:needs-rework NOT added"

no_label 12 "status:in-progress" \
  && ok "RED-b: status:in-progress removed" \
  || ko "RED-b: status:in-progress NOT removed"

no_label 12 "claimed-by:cb1" \
  && ok "RED-b: claimed-by:cb1 removed" \
  || ko "RED-b: claimed-by:cb1 NOT removed"

jq -r --argjson n 12 'map(select(.number==$n))[0].comments[]?.body' "$BOARD_STATE" \
  | grep -q "conflict" \
  && ok "RED-b: conflict comment recorded" \
  || ko "RED-b: conflict comment NOT recorded"

state=$(board_get_state 12)
[ "$state" = "needs-rework" ] \
  && ok "RED-b: get state = needs-rework" \
  || ko "RED-b: get state = '$state' (expected needs-rework)"

# ═══════════════════════════════════════════════════════════════════════════════
# RED-c: crewboss-launcher-gh.sh dispatches via CB_REWORK_SPAWN for needs-rework
#        leaf, and via CB_SPAWN for a regular leaf.
# Before fix: no branch selection — both go through CB_SPAWN.
# ═══════════════════════════════════════════════════════════════════════════════
echo "== RED-c: launcher spawn path selection =="

CB_HOME_RC="$ROOT/cbhome_rc"
mkdir -p "$CB_HOME_RC"
# Copy updated board-gh.sh and its companion launchable.sh into CB_HOME
cp "$BOARD_GH_SRC" "$CB_HOME_RC/board-gh.sh"
cp "$(dirname "$BOARD_GH_SRC")/launchable.sh" "$CB_HOME_RC/launchable.sh"

SPAWN_LOG_RC="$SANDBOX/spawn-rc.log"
REWORK_LOG_RC="$SANDBOX/rework-rc.log"

SPAWN_STUB_RC="$ROOT/spawn-rc.sh"
cat > "$SPAWN_STUB_RC" <<STUB
#!/usr/bin/env bash
echo "spawn \$1 \$2" >> "$SPAWN_LOG_RC"
exit 0
STUB
chmod +x "$SPAWN_STUB_RC"

REWORK_STUB_RC="$ROOT/rework-rc.sh"
cat > "$REWORK_STUB_RC" <<STUB
#!/usr/bin/env bash
echo "rework-spawn \$1 \$2" >> "$REWORK_LOG_RC"
exit 0
STUB
chmod +x "$REWORK_STUB_RC"

# Board: #10 regular leaf, #12 needs-rework leaf (both under approved charter #5)
reset_board <<'JSON'
[
  {"number":5,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:approved"}],"body":"charter","comments":[]},
  {"number":10,"state":"OPEN",
   "labels":[{"name":"type:agent"}],"body":"Charter: #5\n## Acceptance (machine)\n- check: true","comments":[]},
  {"number":12,"state":"OPEN",
   "labels":[{"name":"type:agent"},{"name":"status:needs-rework"}],"body":"Charter: #5\n## Acceptance (machine)\n- check: true","comments":[]}
]
JSON

PATH="$BIN:$PATH" \
  CB_REPO="test/repo" \
  CB_HOME="$CB_HOME_RC" \
  CB_SPAWN="$SPAWN_STUB_RC" \
  CB_REWORK_SPAWN="$REWORK_STUB_RC" \
  CB_RETRY_CAP=2 \
  CB_MAX_PARALLEL=5 \
  bash "$LAUNCHER_GH" once 2>/dev/null

# #10 (regular) must go through CB_SPAWN
grep -q "^spawn 10" "$SPAWN_LOG_RC" 2>/dev/null \
  && ok "RED-c: regular leaf #10 dispatched via CB_SPAWN" \
  || ko "RED-c: regular leaf #10 NOT in CB_SPAWN log (log: $(cat "$SPAWN_LOG_RC" 2>/dev/null))"

# #12 (needs-rework) must go through CB_REWORK_SPAWN
grep -q "^rework-spawn 12" "$REWORK_LOG_RC" 2>/dev/null \
  && ok "RED-c: needs-rework leaf #12 dispatched via CB_REWORK_SPAWN" \
  || ko "RED-c: needs-rework leaf #12 NOT in CB_REWORK_SPAWN log (log: $(cat "$REWORK_LOG_RC" 2>/dev/null))"

# #12 must NOT go through CB_SPAWN
grep -q "^spawn 12" "$SPAWN_LOG_RC" 2>/dev/null \
  && ko "RED-c: needs-rework leaf #12 wrongly dispatched via CB_SPAWN" \
  || ok "RED-c: needs-rework leaf #12 correctly NOT in CB_SPAWN log"

# ═══════════════════════════════════════════════════════════════════════════════
# RED-d: lifecycle and priority.
#
#   Sub-case 1 (lifecycle): leaf #12 in needs-rework → launcher dispatches rework →
#     spy stub captures board state right after claim (before route) →
#     assert: status:needs-rework REMOVED, status:in-progress + claimed-by SET.
#
#   Sub-case 2 (priority): leaf with BOTH status:review and status:needs-rework →
#     get state = "review" (review > needs-rework).
#
# Before fix: claim did not strip needs-rework; get state lacked priority check.
# ═══════════════════════════════════════════════════════════════════════════════
echo "== RED-d: lifecycle (claim strips needs-rework) + priority (review > needs-rework) =="

CB_HOME_RD="$ROOT/cbhome_rd"
mkdir -p "$CB_HOME_RD"
cp "$BOARD_GH_SRC" "$CB_HOME_RD/board-gh.sh"
cp "$(dirname "$BOARD_GH_SRC")/launchable.sh" "$CB_HOME_RD/launchable.sh"

SNAP_RD="$SANDBOX/after-claim-rd.json"

# Spy REWORK_SPAWN: captures board state right after claim (during spawn = after claim,
# before the launcher calls 'route review'). Then exits 0 so route fires normally.
REWORK_SPY_RD="$ROOT/rework-spy-rd.sh"
printf '#!/usr/bin/env bash\ncp "$BOARD_STATE" "%s"\nexit 0\n' "$SNAP_RD" > "$REWORK_SPY_RD"
chmod +x "$REWORK_SPY_RD"

SPAWN_STUB_RD="$ROOT/spawn-rd.sh"
cat > "$SPAWN_STUB_RD" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$SPAWN_STUB_RD"

# Board: leaf #12 in needs-rework only
reset_board <<'JSON'
[
  {"number":5,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:approved"}],"body":"charter","comments":[]},
  {"number":12,"state":"OPEN",
   "labels":[{"name":"type:agent"},{"name":"status:needs-rework"}],"body":"Charter: #5\n## Acceptance (machine)\n- check: true","comments":[]}
]
JSON

PATH="$BIN:$PATH" \
  CB_REPO="test/repo" \
  CB_HOME="$CB_HOME_RD" \
  CB_SPAWN="$SPAWN_STUB_RD" \
  CB_REWORK_SPAWN="$REWORK_SPY_RD" \
  CB_RETRY_CAP=2 \
  CB_MAX_PARALLEL=5 \
  bash "$LAUNCHER_GH" once 2>/dev/null

# Check the snapshot taken right after claim (sub-case 1: lifecycle)
if [ ! -f "$SNAP_RD" ]; then
  ko "RED-d(1): spy snapshot missing — rework path not taken"
else
  # status:needs-rework must be REMOVED (claim strips it)
  nr_present=$(jq -r --argjson n 12 \
    '[map(select(.number==$n))[0].labels[]?.name] | any(.=="status:needs-rework")' "$SNAP_RD")
  [ "$nr_present" = "false" ] \
    && ok "RED-d(1): status:needs-rework REMOVED after claim" \
    || ko "RED-d(1): status:needs-rework still present after claim"

  # status:in-progress must be SET
  ip_present=$(jq -r --argjson n 12 \
    '[map(select(.number==$n))[0].labels[]?.name] | any(.=="status:in-progress")' "$SNAP_RD")
  [ "$ip_present" = "true" ] \
    && ok "RED-d(1): status:in-progress SET after claim" \
    || ko "RED-d(1): status:in-progress NOT set after claim"

  # claimed-by:* must be SET (some claimed-by label)
  claimed_present=$(jq -r --argjson n 12 \
    '[map(select(.number==$n))[0].labels[]?.name | select(startswith("claimed-by:"))] | length > 0' \
    "$SNAP_RD")
  [ "$claimed_present" = "true" ] \
    && ok "RED-d(1): claimed-by label SET after claim" \
    || ko "RED-d(1): claimed-by label NOT set after claim"
fi

# Sub-case 2: priority — review+needs-rework → state = "review"
reset_board <<'JSON'
[
  {"number":5,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:approved"}],"body":"charter","comments":[]},
  {"number":12,"state":"OPEN",
   "labels":[{"name":"type:agent"},{"name":"status:review"},{"name":"status:needs-rework"}],
   "body":"Charter: #5\n## Acceptance (machine)\n- check: true","comments":[]}
]
JSON

prio_state=$(board_get_state 12)
[ "$prio_state" = "review" ] \
  && ok "RED-d(2): priority — review+needs-rework → state='review'" \
  || ko "RED-d(2): priority — expected 'review', got '$prio_state'"

# ═══════════════════════════════════════════════════════════════════════════════
echo
echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
