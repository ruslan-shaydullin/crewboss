#!/usr/bin/env bash
# legacy-smoke.test.sh — characterisation pin HD-1 (charter #131)
#
# Verifies that WITHOUT CB_MANIFEST the launcher cmd_run behaves identically to
# the pre-manifest baseline:
#   charter(needs-plan) → bg-spawn tech-lead → plan-review
#   → (boss approves) → approved → bg-spawn executor(leaf)
#   → status.json phase=done → leaf status:review
#
# Stand:
#   gh-stub (file-board, no network) + REAL proto/r6/board-gh.sh
#   + REAL proto/r6/crewboss-launcher-gh.sh cmd_run, CB_MANIFEST unset
#   + spawn-stub (logs <id> <role>, transitions board, writes task.prompt)
#
# Negative control: assert functions produce non-zero exit when fed poisoned data.
#
# Requires: bash 4+, jq, flock (all available on the CI runner).

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
R6="$HERE/../../proto/r6"
LAUNCHER="$R6/crewboss-launcher-gh.sh"
BOARD_SH="$R6/board-gh.sh"
LAUNCHABLE_SH="$R6/launchable.sh"

pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

# ── Fixed issue IDs ───────────────────────────────────────────────────────────
# Known up-front so the leaf body can embed branch/base hard-rule strings.
CHARTER_ID=5
LEAF_ID=10

# ── Temp sandbox ──────────────────────────────────────────────────────────────
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"
mkdir -p "$BIN"

export BOARD_STATE="$ROOT/board.json"
export SPAWN_LOG="$ROOT/spawns.log"
export BIN                          # spawn-stub inherits this for PATH

export CB_REPO="test/smoke"
export CB_HOME="$ROOT/cbhome"
export CB_SPAWN="$ROOT/stub-spawn.sh"
export CB_POLL="0.2"                # 200 ms/tick — gives boss time to approve
export CB_MAX_TICKS="60"
export CB_IDLE_CONFIRM="20"         # 20 idle ticks × 0.2 s = 4 s boss window
export CB_MAX_PARALLEL="4"
export CB_RETRY_CAP="2"
export CB_LAUNCHER_ID="smoke"
unset  CB_MANIFEST                  # pin: legacy path, no manifest active

RUN="$CB_HOME/run"
mkdir -p "$RUN/state"

# Place real board-gh.sh + launchable.sh where the launcher expects them
cp "$BOARD_SH"      "$CB_HOME/board-gh.sh"
cp "$LAUNCHABLE_SH" "$CB_HOME/launchable.sh"

# ── Board fixture ─────────────────────────────────────────────────────────────
# Charter : type:charter + status:needs-plan  (triggers tech-lead spawn)
# Leaf    : type:agent, Charter: #CHARTER_ID, hard-rule strings leaf/LEAF_ID- and
#           charter/CHARTER_ID, valid ## Acceptance (machine) block, no manifest refs
cat > "$BOARD_STATE" <<FIXTURE
[
  {
    "number": $CHARTER_ID,
    "state": "OPEN",
    "labels": [
      {"name": "type:charter"},
      {"name": "status:needs-plan"}
    ],
    "body": "Charter goal: implement the feature."
  },
  {
    "number": $LEAF_ID,
    "state": "OPEN",
    "labels": [
      {"name": "type:agent"}
    ],
    "body": "Charter: #${CHARTER_ID}\n\nImplement output.txt.\n\nHard rules for THIS run:\n- Work on branch leaf/${LEAF_ID}-<ts>, based on charter/${CHARTER_ID} (NOT main).\n- Open exactly one PR targeting charter/${CHARTER_ID}.\n\n## Acceptance (machine)\n- check: test -f output.txt"
  }
]
FIXTURE
: > "$SPAWN_LOG"    # ensure empty log before run

# ── gh stub (file-board, zero network) ───────────────────────────────────────
# Supports the board-gh.sh call surface:
#   issue list  [--state open|all]   → JSON array from BOARD_STATE
#   issue view  <id>                 → single JSON object
#   issue edit  <id> [--add-label X] [--remove-label Y]  → mutate BOARD_STATE
#   label create  (ignored)
cat > "$BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
set -uo pipefail
obj="${1:-}"; verb="${2:-}"; shift 2 || true

id=""; state_filter="all"
declare -a add_labels=()
declare -a rem_labels=()

# Consume flags; inner shift eats value, outer shift (end of loop) eats key.
while [ $# -gt 0 ]; do
  case "$1" in
    --add-label)    shift; add_labels+=("${1:-}") ;;
    --remove-label) shift; rem_labels+=("${1:-}") ;;
    --state)        shift; state_filter="${1:-all}" ;;
    -R|--repo|--json|-L|-b|--body|-t|--title|-l|--label|--color)
                    [ $# -gt 1 ] && shift ;;   # skip flag value
    --*) ;;         # unknown --flag, no value consumed
    -*) ;;          # unknown -f, no value consumed
    *) [ -z "$id" ] && id="$1" ;;
  esac
  shift
done

case "$obj $verb" in
  "issue list")
    if [ "$state_filter" = "open" ]; then
      jq '[.[] | select(.state == "OPEN")]' "$BOARD_STATE"
    else
      cat "$BOARD_STATE"
    fi ;;
  "issue view")
    jq --argjson n "$id" '.[] | select(.number == $n)' "$BOARD_STATE" ;;
  "issue edit")
    tmp=$(mktemp)
    cp "$BOARD_STATE" "$tmp"
    for l in "${rem_labels[@]}"; do
      [ -z "${l:-}" ] && continue
      jq --argjson n "$id" --arg l "$l" \
        'map(if .number == $n then .labels = [.labels[]? | select(.name != $l)] else . end)' \
        "$tmp" > "${tmp}.n" && mv "${tmp}.n" "$tmp"
    done
    for l in "${add_labels[@]}"; do
      [ -z "${l:-}" ] && continue
      jq --argjson n "$id" --arg l "$l" \
        'map(if .number == $n and ([.labels[]?.name] | index($l) | not)
             then .labels += [{name:$l}] else . end)' \
        "$tmp" > "${tmp}.n" && mv "${tmp}.n" "$tmp"
    done
    cp "$tmp" "$BOARD_STATE"
    rm -f "$tmp" "${tmp}.n" 2>/dev/null || true ;;
  "label create") ;;   # no-op: labels pre-exist in fixture
  *) printf 'gh-stub: unhandled: %s %s\n' "$obj" "$verb" >&2 ;;
esac
exit 0
GHEOF
chmod +x "$BIN/gh"

# ── spawn stub ────────────────────────────────────────────────────────────────
# Contract: $CB_SPAWN <id> <role>
#
# tech-lead : logs call + moves charter needs-plan → plan-review via gh stub.
# executor  : logs call + writes task.prompt from board body + status.json(done).
#
# All env vars (CB_HOME, BOARD_STATE, SPAWN_LOG, PATH incl. $BIN) are inherited
# from the launcher process.
cat > "$ROOT/stub-spawn.sh" <<'SPAWNEOF'
#!/usr/bin/env bash
set -uo pipefail
ID="$1"; ROLE="$2"
BOARD="$CB_HOME/board-gh.sh"
WORKDIR="$CB_HOME/run/work/$ID"
mkdir -p "$WORKDIR"

printf '%s %s\n' "$ID" "$ROLE" >> "$SPAWN_LOG"

if [ "$ROLE" = "tech-lead" ]; then
  # Simulate tech-lead decomposition: charter needs-plan → plan-review
  gh issue edit "$ID" \
    --remove-label "status:needs-plan" \
    --add-label    "status:plan-review"
  exit 0
fi

# executor: materialise task.prompt from board body + signal completion
PROMPT=$(bash "$BOARD" get "$ID" prompt)
printf '%s\n' "$PROMPT" > "$WORKDIR/task.prompt"
printf '{"phase":"done"}\n' > "$WORKDIR/status.json"
exit 0
SPAWNEOF
chmod +x "$ROOT/stub-spawn.sh"

# ── Assert helpers (also used by negative-control section) ───────────────────

# assert_spawn_exact <log> <charter_id> <leaf_id>
# Pass iff log contains EXACTLY two lines: "<cid> tech-lead" then "<lid> executor"
assert_spawn_exact() {
  local log="$1" cid="$2" lid="$3"
  local exp got
  exp=$(printf '%s tech-lead\n%s executor' "$cid" "$lid")
  got=$(cat "$log" 2>/dev/null || true)   # $() strips trailing newlines
  [ "$got" = "$exp" ]
}

# assert_no_forbidden <board_json>
# Fail (return 1) if any manifest-specific label appears anywhere in the board.
assert_no_forbidden() {
  local board="$1" bad=0
  for lbl in "status:needs-analysis" "status:team-review" "composition:approved"; do
    if jq -e --arg l "$lbl" \
         '[.[].labels[]?.name] | any(. == $l)' "$board" >/dev/null 2>&1; then
      printf 'forbidden label found: %s\n' "$lbl" >&2
      bad=1
    fi
  done
  return "$bad"
}

# ── Positive scenario ─────────────────────────────────────────────────────────
echo "=== positive: cmd_run without CB_MANIFEST ==="

# All subprocesses (launcher, board-gh, spawns, boss) share the stub gh via PATH
export PATH="$BIN:$PATH"

# Boss: poll charter state; approve as soon as tech-lead sets it to plan-review
(
  for _ in $(seq 1 400); do
    st=$(bash "$CB_HOME/board-gh.sh" get "$CHARTER_ID" state 2>/dev/null || true)
    if [ "$st" = "plan-review" ]; then
      gh issue edit "$CHARTER_ID" \
        --remove-label "status:plan-review" \
        --add-label    "status:approved"
      exit 0
    fi
    sleep 0.05
  done
  printf 'boss: timeout waiting for plan-review\n' >&2; exit 1
) &
BOSS_PID=$!

# Start the REAL launcher (cmd_run, CB_MANIFEST unset → legacy path)
bash "$LAUNCHER" run > "$ROOT/launcher.log" 2>&1 &
LAUNCHER_PID=$!

# Poll leaf state via board-gh until it reaches review (max 20 s)
leaf_st="unknown"
for _ in $(seq 1 200); do
  leaf_st=$(bash "$CB_HOME/board-gh.sh" get "$LEAF_ID" state 2>/dev/null || true)
  [ "$leaf_st" = "review" ] && break
  sleep 0.1
done

# ── Assertions (checked as soon as leaf reaches review) ──────────────────────
PROMPT_FILE="$RUN/work/$LEAF_ID/task.prompt"

# 1. Spawn sequence: exactly <charter> tech-lead → <leaf> executor, nothing more
if assert_spawn_exact "$SPAWN_LOG" "$CHARTER_ID" "$LEAF_ID"; then
  ok "spawn sequence: ${CHARTER_ID} tech-lead then ${LEAF_ID} executor (exact)"
else
  ko "spawn sequence wrong (got: $(cat "$SPAWN_LOG" 2>/dev/null))"
fi

# 2. No manifest-specific labels appear in any board snapshot
if assert_no_forbidden "$BOARD_STATE"; then
  ok "board: no forbidden labels (needs-analysis / team-review / composition:approved)"
else
  ko "board: forbidden label found"
fi

# 3. task.prompt content: no manifest refs; hard-rule branch and base present
if [ -f "$PROMPT_FILE" ]; then
  if ! grep -qi "manifest\|CB_MANIFEST" "$PROMPT_FILE"; then
    ok "task.prompt: no manifest/CB_MANIFEST reference"
  else
    ko "task.prompt: unexpected manifest reference found"
  fi
  if grep -qF "leaf/${LEAF_ID}-" "$PROMPT_FILE"; then
    ok "task.prompt: hard-rule branch ref leaf/${LEAF_ID}-"
  else
    ko "task.prompt: missing hard-rule branch ref leaf/${LEAF_ID}-"
  fi
  if grep -qF "charter/${CHARTER_ID}" "$PROMPT_FILE"; then
    ok "task.prompt: hard-rule base ref charter/${CHARTER_ID}"
  else
    ko "task.prompt: missing hard-rule base ref charter/${CHARTER_ID}"
  fi
else
  ko "task.prompt: file not found at $PROMPT_FILE"
  ko "task.prompt: no-manifest check skipped (file missing)"
  ko "task.prompt: hard-rule checks skipped (file missing)"
fi

# 4. Leaf reached status:review (integrator handoff is out of scope for this pin)
if [ "$leaf_st" = "review" ]; then
  ok "leaf #${LEAF_ID} reached status:review"
else
  ko "leaf #${LEAF_ID} did not reach status:review (state: $leaf_st)"
fi

# Allow launcher to wind down cleanly (idle-count CB_IDLE_CONFIRM ticks)
wait "$LAUNCHER_PID" 2>/dev/null || true
wait "$BOSS_PID"     2>/dev/null || true

# ── Negative control ──────────────────────────────────────────────────────────
# Prove the detector CAN go RED: feed poisoned data through the same assert functions
# and verify they return non-zero.
echo "=== negative control: detector must go RED on poisoned data ==="

# Poisoned spawn log: first spawn has role solution-analyst (should be tech-lead)
NEG_LOG="$ROOT/neg-spawns.log"
printf '%s solution-analyst\n%s executor\n' "$CHARTER_ID" "$LEAF_ID" > "$NEG_LOG"

# Poisoned board: inject status:needs-analysis into charter issue
NEG_BOARD="$ROOT/neg-board.json"
jq --argjson n "$CHARTER_ID" --arg l "status:needs-analysis" \
   'map(if .number == $n then .labels += [{name:$l}] else . end)' \
   "$BOARD_STATE" > "$NEG_BOARD"

# assert_spawn_exact MUST fail: wrong first role (solution-analyst ≠ tech-lead)
if assert_spawn_exact "$NEG_LOG" "$CHARTER_ID" "$LEAF_ID"; then
  ko "neg: spawn detector did NOT catch wrong first role (should fail)"
else
  ok "neg: spawn detector rejects solution-analyst as first role"
fi

# assert_no_forbidden MUST fail: status:needs-analysis is a forbidden label
if assert_no_forbidden "$NEG_BOARD"; then
  ko "neg: forbidden-label detector did NOT catch status:needs-analysis (should fail)"
else
  ok "neg: forbidden-label detector catches status:needs-analysis"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = "0" ]
