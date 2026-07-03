#!/usr/bin/env bash
# dep-radius-wire.test.sh — post-approval dep-analysis gate wiring (charter #341, C7).
# Class integration-stub: gh file-board stub + a launcher-tick model that mirrors the
# cmd_once dispatch loop (reference/runtime/crewboss-launcher-gh.sh:1806-1819) with the
# dep-analysis gate inserted immediately before leaf dispatch (line 1808).
#
# Why a tick model (not the real launcher): the dep-analysis gate + dependency-analyst
# wiring are sibling leaves of charter #341 not yet merged into charter/341. This leaf
# owns the tests and pins the exact contract the wiring must satisfy — the model encodes
# that contract (dep-analysis spawn condition, blast-radius label landing, override guard,
# per-leaf `board get "$id" charter` resolution, and the `$_block` serialization guard).
#
# Board (RED-1/2 + GREEN-guards):
#   Charter A (#10): status:approved, no blast-radius, leaves #11/#12 — files overlap B
#   Charter B (#20): status:approved, no blast-radius, leaves #21/#22 — overlapping files
#   Charter C (#30): status:approved, pre-set blast-radius:high
#
# RED-1: first tick with dep_analysis_role → dep-analysis spawned for A and B (SPAWN_LOG);
#        leaf dispatch does NOT fire (no executor spawns).
# RED-2: after dep_done=1 for A and B → blast-radius:high lands on A and B.
# GREEN-guard:   C retains its pre-set blast-radius:high — no duplicate gh issue edit.
# GREEN-guard-2: after dep_done=1 for A and B → leaf dispatch fires normally.
# RED-3: stale $cid — A(dep_done=1) leaf dispatched; B(dep in-flight) leaf held.
# RED-4: missing blast-radius guard — dep-analysis for $_block charter only; slot not stolen.
#
# Self-classification: integration-stub → EXCLUDED from per-leaf verify-merged suite. [#341]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

export BOARD_STATE="$ROOT/board.json"
export GH_LOG="$ROOT/gh.log"
export SPAWN_LOG="$ROOT/spawn.log"
export CB_REPO="test/repo"
STATE="$ROOT/state"                       # run-state dir: $STATE/<cid>/dep_done

BIN="$ROOT/bin"; mkdir -p "$BIN"

# ── gh stub: stateful file-board (issue list / view / edit) ────────────────────
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
    state_filter="all"
    while [ $# -gt 0 ]; do
      case "$1" in --state) state_filter="$2"; shift ;; --json) ;; esac; shift
    done
    if [ "$state_filter" = "open" ]; then
      jq '[.[] | select(.state=="OPEN")]' "$BOARD_STATE"
    else
      cat "$BOARD_STATE"
    fi ;;

  "issue view")
    n="$1"; shift
    jq --argjson n "$n" 'map(select(.number==$n))[0] // {}' "$BOARD_STATE" ;;

  "issue edit")
    n="$1"; shift
    adds=(); rems=()
    while [ $# -gt 0 ]; do
      case "$1" in --add-label) adds+=("$2"); shift ;; --remove-label) rems+=("$2"); shift ;; esac
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
    { printf 'edit #%s' "$n"
      [ "${#adds[@]}" -gt 0 ] && printf ' +[%s]' "${adds[*]}"
      [ "${#rems[@]}" -gt 0 ] && printf ' -[%s]' "${rems[*]}"
      printf '\n'; } >> "$GH_LOG" ;;

  "label create") ;;
  *) echo "gh-stub UNHANDLED: $obj $verb $*" >> "$GH_LOG" ;;
esac
exit 0
GHEOF
chmod +x "$BIN/gh"

# ── board / run-state accessors (mirror the launcher's board helpers) ──────────
approved_charters(){
  jq -r '.[] | select(.state=="OPEN")
             | select([.labels[].name] | index("type:charter") != null)
             | select([.labels[].name] | index("status:approved") != null)
             | .number' "$BOARD_STATE" | sort -n
}
dispatchable_leaves(){
  jq -r '.[] | select(.state=="OPEN")
             | select([.labels[].name] | index("type:agent") != null)
             | .number' "$BOARD_STATE" | sort -n
}
# board get "$id" charter — resolve a leaf's charter from its body (NOT a stale $cid).
charter_of(){
  jq -r --argjson n "$1" 'map(select(.number==$n))[0].body // ""' "$BOARD_STATE" \
    | grep -oiE 'Charter:[[:space:]]*#?[0-9]+' | grep -oE '[0-9]+' | head -1
}
has_blast(){
  jq -e --argjson n "$1" 'map(select(.number==$n))[0] | [.labels[].name]
                          | any(startswith("blast-radius:"))' "$BOARD_STATE" >/dev/null 2>&1
}
dep_done(){ [ "$(cat "$STATE/$1/dep_done" 2>/dev/null)" = "1" ]; }
set_dep_done(){ mkdir -p "$STATE/$1"; printf '%s' "$2" > "$STATE/$1/dep_done"; }

files_of_charter(){
  jq -r --arg c "$1" '.[] | select([.labels[].name] | index("type:agent") != null)
                          | select((.body // "") | test("Charter:\\s*#?" + $c + "\\b"))
                          | .body' "$BOARD_STATE" \
    | grep -iE '^Files:' | sed -E 's/^[Ff]iles:[[:space:]]*//' \
    | tr ' ' '\n' | grep -v '^$' | sort -u
}
overlaps_charter(){
  local c="$1" fc fo other
  fc="$(files_of_charter "$c")"; [ -z "$fc" ] && return 1
  for other in $(approved_charters); do
    [ "$other" = "$c" ] && continue
    fo="$(files_of_charter "$other")"; [ -z "$fo" ] && continue
    [ -n "$(comm -12 <(printf '%s\n' "$fc") <(printf '%s\n' "$fo"))" ] && return 0
  done
  return 1
}

# ── the launcher tick model (cmd_once + dep-analysis gate) ─────────────────────
# _BLOCK: blast-radius serialization block (empty unless a high charter serializes).
# MAXP:   parallel cap.
dep_gate_tick(){
  local _block="${_BLOCK:-}" MAXP="${MAXP:-8}" running=0 cid id r
  export PATH="$BIN:$PATH"

  # ── dep-analysis gate (post-approval, before leaf dispatch) ──────────────────
  for cid in $(approved_charters); do
    if dep_done "$cid"; then
      # dep-analysis finished → land blast-radius label (override guard: skip if labelled)
      if ! has_blast "$cid"; then
        r=low; overlaps_charter "$cid" && r=high
        gh issue edit "$cid" -R "$CB_REPO" --add-label "blast-radius:$r"
      fi
      continue
    fi
    # dep-analysis not done → spawn it, honouring the $_block serialization guard (RED-4).
    [ -n "$_block" ] && [ "$cid" != "$_block" ] && continue
    [ "$running" -ge "$MAXP" ] && break
    echo "dep-analysis $cid" >> "$SPAWN_LOG"
    running=$((running+1))
  done

  # ── leaf dispatch (mirrors cmd_once 1808-1819) ───────────────────────────────
  for id in $(dispatchable_leaves); do
    # board get "$id" charter — per-leaf resolution; a stale $cid would misroute (RED-3).
    cid="$(charter_of "$id")"
    [ -n "$cid" ] || continue
    dep_done "$cid" || continue                       # hold leaf until dep-analysis done
    [ -n "$_block" ] && [ "$cid" != "$_block" ] && continue
    [ "$running" -ge "$MAXP" ] && break
    echo "executor $id" >> "$SPAWN_LOG"
    running=$((running+1))
  done
}

reset(){ : > "$GH_LOG"; : > "$SPAWN_LOG"; rm -rf "$STATE"; mkdir -p "$STATE"; cat > "$BOARD_STATE"; }
spawned(){ grep -q "^$1 $2$" "$SPAWN_LOG" 2>/dev/null; }

# ── shared board for RED-1/2 + GREEN-guards ────────────────────────────────────
MAIN_BOARD='[
  {"number":10,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],"body":"charter A"},
  {"number":11,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"leaf A1\nCharter: #10\nFiles: src/api.go src/a1.go"},
  {"number":12,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"leaf A2\nCharter: #10\nFiles: src/a2.go"},
  {"number":20,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],"body":"charter B"},
  {"number":21,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"leaf B1\nCharter: #20\nFiles: src/api.go src/b1.go"},
  {"number":22,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"leaf B2\nCharter: #20\nFiles: src/b2.go"},
  {"number":30,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"},{"name":"blast-radius:high"}],"body":"charter C"}
]'

# =============================================================================
# RED-1: first tick → dep-analysis spawned for A and B; no leaf dispatch yet.
# =============================================================================
echo "== RED-1: dep-analysis gate spawns for A/B; leaf dispatch held pre-dep_done =="
reset <<< "$MAIN_BOARD"

dep_gate_tick

spawned "dep-analysis" 10 \
  && ok "RED-1: dep-analysis spawned for charter A (#10)" \
  || ko "RED-1: dep-analysis NOT spawned for charter A (#10)"

spawned "dep-analysis" 20 \
  && ok "RED-1: dep-analysis spawned for charter B (#20)" \
  || ko "RED-1: dep-analysis NOT spawned for charter B (#20)"

grep -q "^executor " "$SPAWN_LOG" \
  && ko "RED-1: leaf dispatch fired before dep_done — gate not blocking dispatch" \
  || ok "RED-1: no executor spawns (leaf dispatch held until dep-analysis done)"

# =============================================================================
# RED-2 + GREEN-guard + GREEN-guard-2: after dep_done=1 for A and B.
#   RED-2:         blast-radius:high lands on A and B (overlapping file-sets).
#   GREEN-guard:   C keeps pre-set blast-radius:high — no duplicate gh issue edit.
#   GREEN-guard-2: leaf dispatch fires for A's and B's leaves.
# =============================================================================
echo "== RED-2 / GREEN-guard / GREEN-guard-2: dep_done → labels land + dispatch resumes =="
reset <<< "$MAIN_BOARD"
set_dep_done 10 1
set_dep_done 20 1

dep_gate_tick

# RED-2
grep -q "^edit #10 .*blast-radius:high" "$GH_LOG" \
  && ok "RED-2: blast-radius:high landed on charter A (#10)" \
  || ko "RED-2: blast-radius:high did NOT land on charter A (#10)"
grep -q "^edit #20 .*blast-radius:high" "$GH_LOG" \
  && ok "RED-2: blast-radius:high landed on charter B (#20)" \
  || ko "RED-2: blast-radius:high did NOT land on charter B (#20)"

# GREEN-guard: C retains pre-set label, no duplicate add-label edit
grep -q "^edit #30" "$GH_LOG" \
  && ko "GREEN-guard: duplicate gh issue edit for #30 despite pre-set blast-radius:high" \
  || ok "GREEN-guard: no gh issue edit for #30 (override guard kept pre-set blast-radius:high)"
has_blast 30 \
  && ok "GREEN-guard: charter C (#30) still carries blast-radius:high" \
  || ko "GREEN-guard: charter C (#30) lost its blast-radius:high"

# GREEN-guard-2: leaf dispatch fires normally
spawned "executor" 11 && spawned "executor" 12 \
  && ok "GREEN-guard-2: charter A leaves (#11,#12) dispatched after dep_done" \
  || ko "GREEN-guard-2: charter A leaves NOT dispatched after dep_done"
spawned "executor" 21 && spawned "executor" 22 \
  && ok "GREEN-guard-2: charter B leaves (#21,#22) dispatched after dep_done" \
  || ko "GREEN-guard-2: charter B leaves NOT dispatched after dep_done"

# =============================================================================
# RED-3 (stale $cid): A has dep_done=1 (leaf approved), B dep-analysis in-flight
#   (dep_done unset). A's leaf MUST dispatch; B's leaf MUST NOT. Without a per-leaf
#   `board get "$id" charter`, a stale $cid checks dep_done of the wrong charter.
# =============================================================================
echo "== RED-3: per-leaf charter resolution — A leaf dispatched, B leaf held =="
reset <<'JSON'
[
  {"number":10,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],"body":"charter A"},
  {"number":11,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"leaf A1\nCharter: #10\nFiles: src/a.go"},
  {"number":20,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],"body":"charter B"},
  {"number":21,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"leaf B1\nCharter: #20\nFiles: src/b.go"}
]
JSON
set_dep_done 10 1                          # A's dep-analysis done; B still in-flight

dep_gate_tick

spawned "executor" 11 \
  && ok "RED-3: charter A leaf (#11) dispatched (dep_done=1, correct per-leaf charter)" \
  || ko "RED-3: charter A leaf (#11) NOT dispatched — stale \$cid misrouted dep_done check"

spawned "executor" 21 \
  && ko "RED-3: charter B leaf (#21) dispatched while B dep-analysis in-flight — stale \$cid" \
  || ok "RED-3: charter B leaf (#21) held (dep_done unset — dep-analysis still running)"

# =============================================================================
# RED-4 (blast-radius guard): X (blast-radius:high, dep_done=0) is the $_block that
#   serializes; Y (no blast-radius, dep_done=0). dep-analysis MUST run for X only —
#   without the $_block guard in the dep-analysis loop, Y steals a running slot and
#   could starve X's leaf dispatch at MAXP=2.
# =============================================================================
echo "== RED-4: \$_block guard in dep-analysis loop — X spawned, Y slot not stolen =="
reset <<'JSON'
[
  {"number":10,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"},{"name":"blast-radius:high"}],"body":"charter X"},
  {"number":11,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"leaf X1\nCharter: #10\nFiles: src/x.go"},
  {"number":20,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],"body":"charter Y"},
  {"number":21,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"leaf Y1\nCharter: #20\nFiles: src/y.go"}
]
JSON
set_dep_done 10 0
set_dep_done 20 0

_BLOCK=10 MAXP=2 dep_gate_tick             # X (#10) serializes

spawned "dep-analysis" 10 \
  && ok "RED-4: dep-analysis spawned for the serializing charter X (#10)" \
  || ko "RED-4: dep-analysis NOT spawned for X (#10) — \$_block charter starved"

spawned "dep-analysis" 20 \
  && ko "RED-4: dep-analysis spawned for Y (#20) — \$_block guard missing, slot stolen" \
  || ok "RED-4: dep-analysis NOT spawned for Y (#20) — \$_block guard held the slot"

# =============================================================================
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
