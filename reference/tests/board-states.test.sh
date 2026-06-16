#!/usr/bin/env bash
# board-states.test.sh — charter manifest-pipeline state-machine tests (issue #133).
# Class: unit, real proto/r6/board-gh.sh + PATH-shim gh stub + file-board.
#
# RED-1: charter with status:needs-analysis → board-gh.sh get N state = "needs-analysis"
#        (before fix: falls through to "open").
# RED-2: charter with status:team-review    → board-gh.sh get N state = "team-review"
#        (before fix: falls through to "open").
# RED-3: full manifest-pipeline cycle via route outcomes:
#         needs-plan → analysis → team-review → plan (→ needs-plan)
#         reject branch: team-review → analysis (team-review label removed)
#        (before fix: route analysis|team-review|plan → exit 64 unknown outcome).
# RED-4 (regression pin, green today): charters in needs-analysis or team-review
#        do NOT appear in board-gh.sh plannable output.
# PRIO:  charter with needs-plan + needs-analysis simultaneously → state = "needs-plan".
#
# State is observed ONLY via board-gh.sh get/plannable — never by reading the board JSON directly.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
BOARD_GH_SRC="$HERE/../../proto/r6/board-gh.sh"

pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"; mkdir -p "$BIN"
SANDBOX="$ROOT/sb"; mkdir -p "$SANDBOX"
export BOARD_STATE="$SANDBOX/board.json"
export GH_LOG="$SANDBOX/gh.log"

# ── gh stub: stateful board mutations ─────────────────────────────────────────
cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
obj="$1"; verb="$2"; shift 2

# Strip -R / --repo / -L / --limit flags (and their values)
_args=()
while [ $# -gt 0 ]; do
  case "$1" in -R|--repo|-L|--limit) shift ;; *) _args+=("$1") ;; esac
  shift
done
set -- "${_args[@]+"${_args[@]}"}"

case "$obj $verb" in
  "issue list")
    cat "$BOARD_STATE" ;;

  "issue view")
    n="$1"; shift; jqf=""
    while [ $# -gt 0 ]; do case "$1" in --jq|-q) jqf="$2"; shift ;; esac; shift; done
    o="$(jq --argjson n "$n" 'map(select(.number==$n))[0] // {}' "$BOARD_STATE")"
    if [ -n "$jqf" ]; then printf '%s' "$o" | jq -r "$jqf"; else printf '%s\n' "$o"; fi ;;

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
    while [ $# -gt 0 ]; do case "$1" in -b|--body) body="$2"; shift ;; esac; shift; done
    jq --argjson n "$n" --arg b "$body" \
      'map(if .number==$n then .comments=((.comments//[])+[{body:$b}]) else . end)' \
      "$BOARD_STATE" > "$BOARD_STATE.t" && mv "$BOARD_STATE.t" "$BOARD_STATE"
    echo "comment #$n: $body" >> "$GH_LOG" ;;

  "label create")
    # ensure_label calls: no-op in tests
    ;;

  *)
    echo "gh-stub UNHANDLED: $obj $verb $*" >> "$GH_LOG" ;;
esac
exit 0
GH
chmod +x "$BIN/gh"

# ── helpers ───────────────────────────────────────────────────────────────────
reset_board(){ mkdir -p "$SANDBOX"; rm -f "$GH_LOG"; cat > "$BOARD_STATE"; }

# Read state only via board-gh.sh (never touch board JSON directly in asserts).
get_state(){  PATH="$BIN:$PATH" CB_REPO="test/repo" bash "$BOARD_GH_SRC" get "$1" state; }
plannable(){  PATH="$BIN:$PATH" CB_REPO="test/repo" bash "$BOARD_GH_SRC" plannable; }
do_route(){   PATH="$BIN:$PATH" CB_REPO="test/repo" bash "$BOARD_GH_SRC" route "$@" >/dev/null; }

# ═══════════════════════════════════════════════════════════════════════════════
# RED-1: status:needs-analysis → get state = "needs-analysis"
# ═══════════════════════════════════════════════════════════════════════════════
echo "== RED-1: status:needs-analysis → state =="

reset_board <<'JSON'
[
  {"number":7,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:needs-analysis"}],
   "body":"charter in analysis","comments":[]}
]
JSON

state=$(get_state 7)
[ "$state" = "needs-analysis" ] \
  && ok "RED-1: needs-analysis label → state='needs-analysis'" \
  || ko "RED-1: needs-analysis label → state='$state' (expected 'needs-analysis')"

# ═══════════════════════════════════════════════════════════════════════════════
# RED-2: status:team-review → get state = "team-review"
# ═══════════════════════════════════════════════════════════════════════════════
echo "== RED-2: status:team-review → state =="

reset_board <<'JSON'
[
  {"number":7,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:team-review"}],
   "body":"charter in team-review","comments":[]}
]
JSON

state=$(get_state 7)
[ "$state" = "team-review" ] \
  && ok "RED-2: team-review label → state='team-review'" \
  || ko "RED-2: team-review label → state='$state' (expected 'team-review')"

# ═══════════════════════════════════════════════════════════════════════════════
# PRIO: needs-plan + needs-analysis simultaneously → state = "needs-plan"
# (needs-plan sits higher in the elif ladder)
# ═══════════════════════════════════════════════════════════════════════════════
echo "== PRIO: needs-plan + needs-analysis → state = needs-plan =="

reset_board <<'JSON'
[
  {"number":7,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:needs-plan"},{"name":"status:needs-analysis"}],
   "body":"charter dual-label","comments":[]}
]
JSON

state=$(get_state 7)
[ "$state" = "needs-plan" ] \
  && ok "PRIO: needs-plan+needs-analysis → state='needs-plan' (needs-plan wins)" \
  || ko "PRIO: needs-plan+needs-analysis → state='$state' (expected 'needs-plan')"

# ═══════════════════════════════════════════════════════════════════════════════
# RED-3a: full forward cycle needs-plan → analysis → team-review → plan
# ═══════════════════════════════════════════════════════════════════════════════
echo "== RED-3a: forward cycle needs-plan → analysis → team-review → plan =="

reset_board <<'JSON'
[
  {"number":9,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:needs-plan"}],
   "body":"charter cycle test","comments":[]}
]
JSON

# needs-plan → analysis
do_route 9 analysis "entering manifest pipeline"
state=$(get_state 9)
[ "$state" = "needs-analysis" ] \
  && ok "RED-3a: route analysis → state='needs-analysis'" \
  || ko "RED-3a: route analysis → state='$state' (expected 'needs-analysis')"

# analysis → team-review
do_route 9 team-review
state=$(get_state 9)
[ "$state" = "team-review" ] \
  && ok "RED-3a: route team-review → state='team-review'" \
  || ko "RED-3a: route team-review → state='$state' (expected 'team-review')"

# team-review → plan (→ needs-plan)
do_route 9 plan
state=$(get_state 9)
[ "$state" = "needs-plan" ] \
  && ok "RED-3a: route plan → state='needs-plan'" \
  || ko "RED-3a: route plan → state='$state' (expected 'needs-plan')"

# ═══════════════════════════════════════════════════════════════════════════════
# RED-3b: reject branch — team-review → analysis (team-review label removed)
# ═══════════════════════════════════════════════════════════════════════════════
echo "== RED-3b: reject branch team-review → analysis =="

reset_board <<'JSON'
[
  {"number":11,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:team-review"}],
   "body":"charter reject test","comments":[]}
]
JSON

# team-review → analysis (reject)
do_route 11 analysis "composition rejected — back to analysis"
state=$(get_state 11)
[ "$state" = "needs-analysis" ] \
  && ok "RED-3b: reject route analysis → state='needs-analysis'" \
  || ko "RED-3b: reject route analysis → state='$state' (expected 'needs-analysis')"

# Verify team-review label is gone (observable only via state — can't be team-review)
[ "$state" != "team-review" ] \
  && ok "RED-3b: status:team-review removed after reject" \
  || ko "RED-3b: status:team-review still active after reject"

# ═══════════════════════════════════════════════════════════════════════════════
# RED-4 (regression pin): needs-analysis / team-review → NOT in plannable
# ═══════════════════════════════════════════════════════════════════════════════
echo "== RED-4: manifest-mode charters not in plannable =="

reset_board <<'JSON'
[
  {"number":20,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:needs-analysis"}],
   "body":"charter needs-analysis","comments":[]},
  {"number":21,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:team-review"}],
   "body":"charter team-review","comments":[]},
  {"number":22,"state":"OPEN",
   "labels":[{"name":"type:charter"},{"name":"status:needs-plan"}],
   "body":"charter needs-plan","comments":[]}
]
JSON

plan_out=$(plannable)

printf '%s\n' "$plan_out" | grep -qx "20" \
  && ko "RED-4: charter #20 (needs-analysis) wrongly appears in plannable" \
  || ok "RED-4: charter #20 (needs-analysis) correctly NOT in plannable"

printf '%s\n' "$plan_out" | grep -qx "21" \
  && ko "RED-4: charter #21 (team-review) wrongly appears in plannable" \
  || ok "RED-4: charter #21 (team-review) correctly NOT in plannable"

printf '%s\n' "$plan_out" | grep -qx "22" \
  && ok "RED-4: charter #22 (needs-plan) correctly IS in plannable" \
  || ko "RED-4: charter #22 (needs-plan) NOT in plannable (regression!)"

# ═══════════════════════════════════════════════════════════════════════════════
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
