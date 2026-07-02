#!/usr/bin/env bash
# 1290-triage-storm-retry.test.sh — charter #1290 / issue #1302 (qa-engineer test-writer leaf).
#
# P2 of charter #1290: the triage intercept must SURVIVE an RL-storm. A triage session
# that CRASH-DIES (short lifetime / abnormal exit — the observed 39s pattern of leaf
# #787) is NOT the same as an agent that deliberately declined to post a verdict.
#   * crash-death  -> retry up to CB_TRIAGE_RETRY_CAP (backoff), NEVER a permanent
#                     triage_done=1 + term=1 on the FIRST death (that is the eternal
#                     status:blocked parking the incident showed).
#   * deliberate no-verdict (agent lived, chose not to verdict) -> the CURRENT charter
#                     #1049 recovery routing must stay intact (needs-recovery when a
#                     RED_REASON is carried; blocked when the manager is blind).
#
# HARNESS: deterministic stub board (identical structure to triage.test.sh) driving the
# REAL crewboss-launcher-gh.sh completion handler. No triage agent runs; the "session"
# is a reaped dead pid + injected run-state. gh is a stateful stub; no network.
#
# CONVENTION (tests-first, runnable standalone / GREEN now):
#   * REGRESSION assertions (deliberate no-verdict -> #1049 recovery / blocked) are
#     asserted NOW and MUST stay green.
#   * NEW-behaviour assertions (crash-death retry) are gated behind the presence of the
#     CB_TRIAGE_RETRY_CAP knob in the launcher. Before the P2 impl lands they SKIP
#     (never a silent pass); once it lands they assert the retry contract.
#
# Pinned crash-death seam (what the P2 impl must add):
#   run-state `triage_spawn_ts` (epoch seconds, set when triage is spawned) +
#   CB_TRIAGE_MIN_LIFETIME (default 60) discriminate crash-death (now-ts < min) from a
#   deliberate no-verdict (now-ts >= min). run-state `triage_n` counts retries, bounded
#   by CB_TRIAGE_RETRY_CAP (default 2).
#
# CLASSIFICATION: EXCLUDED in reference/runtime/per-leaf-manifest — drives the REAL
# launcher completion handler (launcher-context), same class as triage / recovery-cap.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER="$HERE/../runtime/crewboss-launcher-gh.sh"
TRIAGE_PARSE="$HERE/../runtime/triage-parse.sh"
BOARD_GH_SRC="$HERE/../../proto/r6/board-gh.sh"
LAUNCHABLE_SRC="$HERE/../../proto/r6/launchable.sh"

pass=0; fail=0; skip=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }
sk(){ skip=$((skip+1)); printf 'SKIP %s\n' "$1"; }

# Feature probe: does the launcher carry the crash-death retry knob?
TRIAGE_RETRY_PRESENT=0
grep -q 'CB_TRIAGE_RETRY_CAP' "$LAUNCHER" 2>/dev/null && TRIAGE_RETRY_PRESENT=1

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"; SANDBOX="$ROOT/sb"
BOARD_STATE="$SANDBOX/board.json"; GH_LOG="$SANDBOX/gh.log"
export BOARD_STATE GH_LOG
mkdir -p "$BIN" "$SANDBOX"

# ── gh stub (stateful board mutations) — same shape as triage.test.sh ─────────────
cat > "$BIN/gh" << 'GHEOF'
#!/usr/bin/env bash
obj="$1"; verb="$2"; shift 2
_args=()
while [ $# -gt 0 ]; do
  case "$1" in -R|--repo|-L|--limit) shift ;; *) _args+=("$1") ;; esac; shift
done
set -- "${_args[@]+"${_args[@]}"}"
case "$obj $verb" in
  "issue list") cat "$BOARD_STATE" ;;
  "issue view")
    n="$1"; shift; jqf=""
    while [ $# -gt 0 ]; do case "$1" in --jq|-q) jqf="$2"; shift ;; --json) shift ;; esac; shift; done
    o="$(jq --argjson n "$n" 'map(select(.number==$n))[0] // {}' "$BOARD_STATE")"
    if [ -n "$jqf" ]; then printf '%s' "$o" | jq -r "$jqf"; else printf '%s\n' "$o"; fi ;;
  "issue edit")
    n="$1"; shift; adds=(); rems=()
    while [ $# -gt 0 ]; do
      case "$1" in --add-label) adds+=("$2"); shift ;; --remove-label) rems+=("$2"); shift ;; esac; shift
    done
    adds_json="$(printf '%s\n' "${adds[@]+"${adds[@]}"}" | jq -R . | jq -s .)"
    rems_json="$(printf '%s\n' "${rems[@]+"${rems[@]}"}" | jq -R . | jq -s .)"
    jq --argjson n "$n" --argjson adds "$adds_json" --argjson rems "$rems_json" '
      map(if .number == $n then
        .labels = [(.labels // [])[] | select(.name as $nm | ($rems | index($nm)) == null)]
        | reduce $adds[] as $a (.;
            if ([.labels[].name] | index($a)) == null then .labels += [{name: $a}] else . end)
      else . end)' "$BOARD_STATE" > "$BOARD_STATE.t" && mv "$BOARD_STATE.t" "$BOARD_STATE"
    { printf 'edit #%s' "$n"
      [ "${#adds[@]}" -gt 0 ] && printf ' +[%s]' "${adds[*]}"
      [ "${#rems[@]}" -gt 0 ] && printf ' -[%s]' "${rems[*]}"
      printf '\n'; } >> "$GH_LOG" ;;
  "issue comment")
    n="$1"; shift; body=""
    while [ $# -gt 0 ]; do case "$1" in --body|-b) body="$2"; shift ;; esac; shift; done
    jq --argjson n "$n" --arg b "$body" \
      'map(if .number==$n then .comments=((.comments//[])+[{body:$b}]) else . end)' \
      "$BOARD_STATE" > "$BOARD_STATE.t" && mv "$BOARD_STATE.t" "$BOARD_STATE"
    printf 'comment #%s: %s\n' "$n" "$body" >> "$GH_LOG" ;;
  "label create") ;;
  "auth token") printf 'fake-token\n' ;;
  *) printf 'gh-stub UNHANDLED: %s %s %s\n' "$obj" "$verb" "$*" >> "$GH_LOG" ;;
esac
exit 0
GHEOF
chmod +x "$BIN/gh"

has_label(){ [ "$(jq -r --argjson n "$1" 'map(select(.number==$n))[0].labels[]?.name' "$BOARD_STATE" | grep -c "^${2}\$")" -ge 1 ]; }
no_label(){ ! has_label "$1" "$2"; }
reset_board(){ rm -f "$GH_LOG"; cat > "$BOARD_STATE"; }
mk_cbhome(){ local h="$1"; mkdir -p "$h"; cp "$BOARD_GH_SRC" "$h/board-gh.sh"; cp "$LAUNCHABLE_SRC" "$h/launchable.sh"; chmod +x "$h/board-gh.sh" "$h/launchable.sh"; }
t_sget(){ cat "$1/run/state/$2/$3" 2>/dev/null || printf ''; }
t_sset(){ mkdir -p "$1/run/state/$2"; printf '%s' "$4" > "$1/run/state/$2/$3"; }
mk_dead_pid(){ ( exit 0 ) & local p=$!; wait "$p" 2>/dev/null; printf '%s' "$p"; }

# Recovery/triage spawn stubs: log invocation, exit fast (no real agent).
RECOVERY_LOG="$ROOT/recovery-spawn.log"; TRIAGE_LOG="$ROOT/triage-spawn.log"
RECOVERY_STUB="$ROOT/recovery-stub.sh"; TRIAGE_STUB="$ROOT/triage-stub.sh"
printf '#!/usr/bin/env bash\nprintf "recovery-spawn %%s\\n" "$1" >> "%s"\n' "$RECOVERY_LOG" > "$RECOVERY_STUB"
printf '#!/usr/bin/env bash\nprintf "triage-spawn %%s\\n" "$1" >> "%s"\nsleep 20\n' "$TRIAGE_LOG" > "$TRIAGE_STUB"
chmod +x "$RECOVERY_STUB" "$TRIAGE_STUB"

run_completion_tick(){
  local cbhome="$1"
  PATH="$BIN:$PATH" CB_REPO="test/repo" CB_HOME="$cbhome" \
    CB_TRIAGE_PARSE="$TRIAGE_PARSE" CB_TRIAGE_SPAWN="$TRIAGE_STUB" \
    CB_RECOVERY_SPAWN="$RECOVERY_STUB" \
    CB_POLL=0 CB_MAX_TICKS=1 CB_IDLE_CONFIRM=1 CB_MAX_PARALLEL=0 \
    CB_RETRY_CAP=2 CB_GIT_REMOTE="" \
    bash "$LAUNCHER" run 2>/dev/null
}

# ═══════════════════════════════════════════════════════════════════════════════
echo "== T1 (REGRESSION): deliberate no-verdict + RED_REASON -> #1049 recovery routing =="
# ═══════════════════════════════════════════════════════════════════════════════
# Triage lived and posted NO verdict; a RED_REASON is carried. Current #1049 behaviour:
# escalate to the recovery-lead (status:needs-recovery), NOT status:blocked.
CB1="$ROOT/cb1"; mk_cbhome "$CB1"
reset_board << 'JSON'
[
  {"number":5,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],"body":"charter","comments":[]},
  {"number":10,"state":"OPEN","labels":[{"name":"type:agent"},{"name":"status:needs-triage"}],
   "body":"Charter: #5\n## Acceptance (machine)\n- check: true","comments":[]}
]
JSON
dp1=$(mk_dead_pid)
t_sset "$CB1" 10 kind "triage"
t_sset "$CB1" 10 pid  "$dp1"
t_sset "$CB1" 10 red_reason "smoke:api-state-invalid"
run_completion_tick "$CB1"

has_label 10 "status:needs-recovery" \
  && ok "T1: deliberate no-verdict + reason -> escalated to status:needs-recovery" \
  || ko "T1: deliberate no-verdict + reason -> NOT escalated (labels: $(jq -c 'map(select(.number==10))[0].labels' "$BOARD_STATE"))"
no_label 10 "status:blocked" \
  && ok "T1: deliberate no-verdict + reason -> NOT blocked (#1049 intact)" \
  || ko "T1: deliberate no-verdict + reason -> wrongly blocked"
[ "$(t_sget "$CB1" 10 kind)" = "recovery" ] \
  && ok "T1: deliberate no-verdict -> kind=recovery" \
  || ko "T1: deliberate no-verdict -> kind='$(t_sget "$CB1" 10 kind)' (expected recovery)"

# ═══════════════════════════════════════════════════════════════════════════════
echo "== T2 (REGRESSION): deliberate no-verdict, manager blind (no RED_REASON) -> blocked =="
# ═══════════════════════════════════════════════════════════════════════════════
CB2="$ROOT/cb2"; mk_cbhome "$CB2"
reset_board << 'JSON'
[
  {"number":5,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],"body":"charter","comments":[]},
  {"number":10,"state":"OPEN","labels":[{"name":"type:agent"},{"name":"status:needs-triage"}],
   "body":"Charter: #5\n## Acceptance (machine)\n- check: true","comments":[]}
]
JSON
dp2=$(mk_dead_pid)
t_sset "$CB2" 10 kind "triage"
t_sset "$CB2" 10 pid  "$dp2"
# no red_reason set -> _recovery_escalate returns 1 -> falls through to blocked
run_completion_tick "$CB2"
has_label 10 "status:blocked" \
  && ok "T2: manager-blind no-verdict -> status:blocked (documented fall-through)" \
  || ko "T2: manager-blind no-verdict -> NOT blocked (labels: $(jq -c 'map(select(.number==10))[0].labels' "$BOARD_STATE"))"
[ "$(t_sget "$CB2" 10 term)" = "1" ] \
  && ok "T2: manager-blind no-verdict -> term=1 (terminal, as today)" \
  || ko "T2: manager-blind no-verdict -> term='$(t_sget "$CB2" 10 term)' (expected 1)"

# ═══════════════════════════════════════════════════════════════════════════════
echo "== T3 (NEW): crash-death (39s pattern) retries, no permanent term=1 on 1st death =="
# ═══════════════════════════════════════════════════════════════════════════════
if [ "$TRIAGE_RETRY_PRESENT" -ne 1 ]; then
  sk "T3: CB_TRIAGE_RETRY_CAP not present in launcher — P2 impl pending; crash-death assertions skipped"
else
  CB3="$ROOT/cb3"; mk_cbhome "$CB3"
  reset_board << 'JSON'
[
  {"number":5,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],"body":"charter","comments":[]},
  {"number":10,"state":"OPEN","labels":[{"name":"type:agent"},{"name":"status:needs-triage"}],
   "body":"Charter: #5\n## Acceptance (machine)\n- check: true","comments":[]}
]
JSON
  dp3=$(mk_dead_pid)
  t_sset "$CB3" 10 kind "triage"
  t_sset "$CB3" 10 pid  "$dp3"
  t_sset "$CB3" 10 red_reason "smoke:api-state-invalid"
  # Crash-death signature: session was spawned ~now and already dead (39s pattern).
  t_sset "$CB3" 10 triage_spawn_ts "$(date +%s)"
  t_sset "$CB3" 10 triage_n "0"
  CB_TRIAGE_RETRY_CAP=2 CB_TRIAGE_MIN_LIFETIME=60 run_completion_tick "$CB3"
  # Kill any lingering re-spawned triage stub so it doesn't leak.
  _rp=$(t_sget "$CB3" 10 pid); [ -n "$_rp" ] && kill "$_rp" 2>/dev/null || true

  [ "$(t_sget "$CB3" 10 term)" != "1" ] \
    && ok "T3: crash-death -> NOT terminal on first death (term != 1)" \
    || ko "T3: crash-death -> wrongly parked terminal (term=1) on first death"
  no_label 10 "status:blocked" \
    && ok "T3: crash-death -> NOT status:blocked on first death" \
    || ko "T3: crash-death -> wrongly status:blocked on first death"
  [ "$(t_sget "$CB3" 10 triage_n)" -ge 1 ] 2>/dev/null \
    && ok "T3: crash-death -> triage_n incremented (retry counted)" \
    || ko "T3: crash-death -> triage_n NOT incremented (got '$(t_sget "$CB3" 10 triage_n)')"
  { grep -q 'triage-spawn 10' "$TRIAGE_LOG" 2>/dev/null; } \
    && ok "T3: crash-death -> triage re-spawned (retry with backoff)" \
    || ko "T3: crash-death -> triage NOT re-spawned (log: $(cat "$TRIAGE_LOG" 2>/dev/null))"
fi

# ═══════════════════════════════════════════════════════════════════════════════
echo
printf 'passed=%d failed=%d skipped=%d\n' "$pass" "$fail" "$skip"
[ "$fail" = 0 ]
