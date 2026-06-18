#!/usr/bin/env bash
# Validate the gh-mode launcher loop end-to-end against the REAL board with a STUB spawn
# (no jail, no spend): claim->review, retry->blocked, reconcile, budget-stop.
set -u
# ── self-install: copy scripts from our own directory to /tmp/cbnet ────────────
_HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p /tmp/cbnet
for _f in crewboss-launcher-gh.sh board-gh.sh stub-spawn.sh launchable.sh; do
  [ -f "$_HERE/$_f" ] && cp "$_HERE/$_f" "/tmp/cbnet/$_f" && chmod +x "/tmp/cbnet/$_f"
done
unset _HERE _f
# ────────────────────────────────────────────────────────────────────────────────
export CB_REPO=stratch1989/crewboss-proto CB_HOME=/tmp/cbnet
export CB_SPAWN=/tmp/cbnet/stub-spawn.sh CB_RETRY_CAP=2 CB_MAX_PARALLEL=5 CB_LAUNCHER_ID=cbtest
L=/tmp/cbnet/crewboss-launcher-gh.sh; BG=/tmp/cbnet/board-gh.sh
RUN=$CB_HOME/run
pass=0; fail=0; created=()
ok(){ echo "  PASS $1"; pass=$((pass+1)); }
no(){ echo "  FAIL $1"; fail=$((fail+1)); }
reset(){ rm -rf "$RUN/state" "$RUN/stub-ctl" "$RUN/stub-calls.log" "$RUN/launcher.lock"; mkdir -p "$RUN/state" "$RUN/stub-ctl"; : > "$RUN/stub-calls.log"; }
mkleaf(){ local n; n=$(gh issue create -R $CB_REPO -t "$1 $(date +%s%N)" -b "$2" | grep -oE '[0-9]+$' | tail -1); created+=("$n"); echo "$n"; }
st(){ bash "$BG" get "$1" state; }
cleanup(){ for n in "${created[@]}"; do gh issue close "$n" -R $CB_REPO >/dev/null 2>&1; done; }
trap cleanup EXIT

for l in type:charter status:approved status:in-progress status:review status:blocked hold; do
  gh label create "$l" -R $CB_REPO --color ededed 2>/dev/null || true; done
CH=$(gh issue create -R $CB_REPO -t "CHARTER ghloop $(date +%s)" -b root -l type:charter -l status:approved | grep -oE '[0-9]+$' | tail -1); created+=("$CH")
echo "charter=#$CH (approved)"

echo "=== T1: success -> claim + review ==="
reset
A=$(mkleaf "ghloop-ok" "Charter: #$CH")
bash "$L" once >/dev/null 2>&1
grep -qx "$A" "$RUN/stub-calls.log" && ok "#$A spawned" || no "#$A not spawned"
[ "$(st "$A")" = "review" ] && ok "#$A -> review" || no "#$A state=$(st "$A")"

echo "=== T2: fail -> retry then blocked at cap ==="
reset
B=$(mkleaf "ghloop-fail" "Charter: #$CH")
echo 2 > "$RUN/stub-ctl/$B"
bash "$L" once >/dev/null 2>&1
[ "$(st "$B")" = "open" ] && ok "1st fail -> requeued (open)" || no "state=$(st "$B")"
bash "$L" once >/dev/null 2>&1
[ "$(st "$B")" = "blocked" ] && ok "2nd fail -> blocked at cap" || no "state=$(st "$B")"
bash "$L" once >/dev/null 2>&1
grep -cx "$B" "$RUN/stub-calls.log" | grep -qx 2 && ok "blocked task not re-spawned (2 calls total)" || no "blocked task call count=$(grep -cx "$B" "$RUN/stub-calls.log")"

echo "=== T3: reconcile requeues orphaned in-progress (dead pid) ==="
reset
C=$(mkleaf "ghloop-orphan" "Charter: #$CH")
bash "$BG" claim "$C" cbtest >/dev/null      # mark in-progress on the board
mkdir -p "$RUN/state/$C"; echo 999999 > "$RUN/state/$C/pid"   # dead pid
bash "$L" reconcile >/dev/null 2>&1
[ "$(st "$C")" = "open" ] && ok "orphan -> requeued (open)" || no "state=$(st "$C")"

echo "=== T4: budget hard-stop ends cycle, requeues task ==="
reset
D=$(mkleaf "ghloop-after"  "Charter: #$CH")   # created first -> lower number
E=$(mkleaf "ghloop-budget" "Charter: #$CH")   # created last  -> newest -> first in launchable
echo 3 > "$RUN/stub-ctl/$E"                    # E returns budget-stop
bash "$L" once >/dev/null 2>&1
[ "$(st "$E")" = "open" ] && ok "budget-stopped task requeued (open)" || no "E state=$(st "$E")"
grep -qx "$D" "$RUN/stub-calls.log" && no "#$D spawned after budget stop" || ok "cycle stopped — #$D not spawned"

echo "=== SUMMARY: $pass passed, $fail failed ==="
echo "=== done ==="
