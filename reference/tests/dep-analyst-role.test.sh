#!/usr/bin/env bash
# dep-analyst-role.test.sh — dependency-analyst role output unit tests (charter #341, C7).
# Class b (role-unit / dry-run): mock-gh records calls + returns controlled JSON.
#
# The dependency-analyst role (kind:analyst, fs_cbnet:rw) reads OPEN charter leaf
# bodies, builds a cross-charter file-overlap matrix, and directly applies
# blast-radius:high / blast-radius:low labels via `gh issue edit`. An override guard
# inside the role skips any charter that is already blast-radius labelled.
#
# A reference implementation of the role is embedded below (dep-analyst.sh). It is the
# executable contract this leaf owns; the launcher-side wiring is covered by the sibling
# dep-radius-wire.test.sh. Test files under reference/tests/ are owned by this leaf —
# executor/infra-engineer are gate-prohibited from touching them.
#
# Test cases:
#   OVERLAP        two charters share a file → earlier charter gets blast-radius:high
#   DISJOINT       two charters, disjoint file-sets → blast-radius:low on both
#   OVERRIDE-GUARD charter already blast-radius:high → NO gh issue edit (override guard)
#
# Self-classification: role-unit (no real launcher loop) → EXCLUDED from per-leaf
# verify-merged suite. [#341]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

export BOARD_STATE="$ROOT/board.json"
export GH_LOG="$ROOT/gh.log"
export CB_REPO="test/repo"

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

# ── dependency-analyst role (reference implementation, owned by this leaf) ──────
# Reads OPEN charter leaf bodies → file-overlap matrix → blast-radius labels.
# Override guard: skip any charter already carrying a blast-radius:* label.
ROLE="$ROOT/dep-analyst.sh"
cat > "$ROLE" <<'RLEOF'
#!/usr/bin/env bash
set -u
REPO="${CB_REPO:-test/repo}"
board="$(gh issue list -R "$REPO" --state open --json number,body,labels --limit 500)"

charters=$(printf '%s' "$board" | jq -r '
  .[] | select([.labels[].name] | index("type:charter") != null) | .number' | sort -n)

# files_of <charter> — union of `Files:` lines across that charter's leaf bodies
files_of(){
  local c="$1"
  printf '%s' "$board" | jq -r --arg c "$c" '
    .[] | select([.labels[].name] | index("type:agent") != null)
        | select((.body // "") | test("Charter:\\s*#?" + $c + "\\b"))
        | .body' \
    | grep -iE '^Files:' \
    | sed -E 's/^[Ff]iles:[[:space:]]*//' \
    | tr ' ' '\n' | grep -v '^$' | sort -u
}

# override guard: charter already blast-radius labelled?
has_blast(){
  printf '%s' "$board" | jq -e --arg c "$1" '
    .[] | select(.number == ($c | tonumber))
        | [.labels[].name] | any(startswith("blast-radius:"))' >/dev/null 2>&1
}

# overlaps <charter> — does it share any file with another OPEN charter?
overlaps(){
  local c="$1" other fc fo
  fc="$(files_of "$c")"
  [ -z "$fc" ] && return 1
  for other in $charters; do
    [ "$other" = "$c" ] && continue
    fo="$(files_of "$other")"
    [ -z "$fo" ] && continue
    if [ -n "$(comm -12 <(printf '%s\n' "$fc") <(printf '%s\n' "$fo"))" ]; then
      return 0
    fi
  done
  return 1
}

for c in $charters; do
  if has_blast "$c"; then
    # override guard: leave operator/prior classification intact — no gh issue edit.
    echo "dep-analyst: #$c already blast-radius labelled — override guard, skip" >&2
    continue
  fi
  if overlaps "$c"; then
    gh issue edit "$c" -R "$REPO" --add-label blast-radius:high
  else
    gh issue edit "$c" -R "$REPO" --add-label blast-radius:low
  fi
done
RLEOF
chmod +x "$ROLE"

run_role(){ PATH="$BIN:$PATH" CB_REPO="$CB_REPO" bash "$ROLE" >/dev/null 2>&1 || true; }
reset(){ : > "$GH_LOG"; cat > "$BOARD_STATE"; }

# =============================================================================
# OVERLAP: two charters with overlapping file-sets → blast-radius:high applied.
#   Charter #10 leaf touches src/api.go; charter #20 leaf also touches src/api.go.
#   Earlier charter (#10) must be labelled blast-radius:high.
# =============================================================================
echo "== OVERLAP: shared file across charters → blast-radius:high on earlier charter =="
reset <<'JSON'
[
  {"number":10,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],"body":"charter A"},
  {"number":11,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"leaf A1\nCharter: #10\nFiles: src/api.go src/a.go"},
  {"number":20,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],"body":"charter B"},
  {"number":21,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"leaf B1\nCharter: #20\nFiles: src/api.go src/b.go"}
]
JSON

run_role

grep -q "^edit #10 .*blast-radius:high" "$GH_LOG" \
  && ok "OVERLAP: earlier charter #10 labelled blast-radius:high (shared src/api.go)" \
  || ko "OVERLAP: charter #10 NOT labelled blast-radius:high (overlap not detected)"

grep -q "^edit #20 .*blast-radius:high" "$GH_LOG" \
  && ok "OVERLAP: overlapping charter #20 also labelled blast-radius:high" \
  || ko "OVERLAP: charter #20 NOT labelled blast-radius:high (overlap not detected)"

grep -q "blast-radius:low" "$GH_LOG" \
  && ko "OVERLAP: blast-radius:low applied despite file overlap (matrix wrong)" \
  || ok "OVERLAP: no blast-radius:low applied (overlap correctly classified high)"

# =============================================================================
# DISJOINT: two charters with disjoint file-sets → blast-radius:low on both.
# =============================================================================
echo "== DISJOINT: disjoint file-sets → blast-radius:low on both charters =="
reset <<'JSON'
[
  {"number":10,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],"body":"charter A"},
  {"number":11,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"leaf A1\nCharter: #10\nFiles: src/a1.go src/a2.go"},
  {"number":20,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],"body":"charter B"},
  {"number":21,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"leaf B1\nCharter: #20\nFiles: src/b1.go src/b2.go"}
]
JSON

run_role

grep -q "^edit #10 .*blast-radius:low" "$GH_LOG" \
  && ok "DISJOINT: charter #10 labelled blast-radius:low (no shared files)" \
  || ko "DISJOINT: charter #10 NOT labelled blast-radius:low"

grep -q "^edit #20 .*blast-radius:low" "$GH_LOG" \
  && ok "DISJOINT: charter #20 labelled blast-radius:low (no shared files)" \
  || ko "DISJOINT: charter #20 NOT labelled blast-radius:low"

grep -q "blast-radius:high" "$GH_LOG" \
  && ko "DISJOINT: blast-radius:high applied to disjoint charters (false overlap)" \
  || ok "DISJOINT: no blast-radius:high (disjoint correctly classified low)"

# =============================================================================
# OVERRIDE-GUARD: charter already blast-radius:high → role makes NO gh issue edit.
#   The override guard inside the role must not re-label / clobber a pre-set value,
#   even though #10 overlaps #20 on src/api.go.
# =============================================================================
echo "== OVERRIDE-GUARD: pre-set blast-radius:high → no gh issue edit (override guard) =="
reset <<'JSON'
[
  {"number":10,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"},{"name":"blast-radius:high"}],"body":"charter A"},
  {"number":11,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"leaf A1\nCharter: #10\nFiles: src/api.go"},
  {"number":20,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],"body":"charter B"},
  {"number":21,"state":"OPEN","labels":[{"name":"type:agent"}],"body":"leaf B1\nCharter: #20\nFiles: src/api.go"}
]
JSON

run_role

grep -q "^edit #10" "$GH_LOG" \
  && ko "OVERRIDE-GUARD: gh issue edit issued for #10 despite pre-set blast-radius:high (guard missing)" \
  || ok "OVERRIDE-GUARD: no gh issue edit for #10 (override guard honoured pre-set label)"

# #20 (unlabelled, overlapping) should still be classified high — guard is per-charter.
grep -q "^edit #20 .*blast-radius:high" "$GH_LOG" \
  && ok "OVERRIDE-GUARD: unlabelled overlapping #20 still labelled blast-radius:high (guard is per-charter)" \
  || ko "OVERRIDE-GUARD: #20 not labelled — override guard over-applied to other charters"

# =============================================================================
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
