#!/usr/bin/env bash
# Validate the gh board adapter against a REAL repo with synthetic issues. No claude spend.
set -u
export CB_REPO=stratch1989/crewboss-proto
B=/tmp/cbnet/board-gh.sh
pass=0; fail=0
ok(){ echo "  PASS $1"; pass=$((pass+1)); }
no(){ echo "  FAIL $1"; fail=$((fail+1)); }
has(){ printf '%s\n' "$1" | grep -qx "$2"; }   # has <multiline> <exact-line>

echo "=== setup: labels + synthetic board ==="
# create every board label explicitly with -R (cwd here is not a git repo, so the
# bare labels-setup.sh can't infer the repo). Idempotent.
for l in type:charter status:needs-plan status:plan-review status:approved \
         status:in-progress status:review status:blocked hold; do
  gh label create "$l" -R $CB_REPO --color ededed 2>/dev/null || true; done

CH=$(gh issue create -R $CB_REPO -t "CHARTER board-test $(date +%s)" -b "charter root" -l type:charter -l status:plan-review | grep -oE '[0-9]+$' | tail -1)
DEP=$(gh issue create -R $CB_REPO -t "DEP leaf $(date +%s)" -b "Charter: #$CH" | grep -oE '[0-9]+$' | tail -1)
RDY=$(gh issue create -R $CB_REPO -t "READY leaf $(date +%s)" -b "Charter: #$CH" | grep -oE '[0-9]+$' | tail -1)
BLK=$(gh issue create -R $CB_REPO -t "BLOCKED-by-dep leaf $(date +%s)" -b "Charter: #$CH
Depends-on: #$DEP" | grep -oE '[0-9]+$' | tail -1)
echo "charter=#$CH dep=#$DEP ready=#$RDY blocked-by-dep=#$BLK"
cleanup(){ for n in "$CH" "$DEP" "$RDY" "$BLK"; do gh issue close "$n" -R $CB_REPO >/dev/null 2>&1; done; }
trap cleanup EXIT

echo "=== T1: charter NOT approved -> nothing launchable ==="
L=$(bash "$B" launchable)
has "$L" "$RDY" && no "ready leaf launchable under unapproved charter" || ok "unapproved charter -> ready leaf not launchable"

echo "=== T2: approve charter -> ready launchable, dep-blocked not ==="
gh issue edit "$CH" -R $CB_REPO --remove-label status:plan-review --add-label status:approved >/dev/null
L=$(bash "$B" launchable)
has "$L" "$RDY" && ok "ready leaf launchable after approve" || no "ready leaf still not launchable"
has "$L" "$BLK" && no "dep-blocked leaf launchable (dep open!)" || ok "dep-blocked leaf held by open dep"

echo "=== T3: close dep -> blocked-by-dep becomes launchable ==="
gh issue close "$DEP" -R $CB_REPO >/dev/null
L=$(bash "$B" launchable)
has "$L" "$BLK" && ok "leaf launchable after dep closed" || no "leaf still blocked after dep closed"

echo "=== T4: get fields ==="
[ "$(bash "$B" get "$RDY" kind)" = "leaf" ] && ok "kind=leaf" || no "kind wrong"
[ "$(bash "$B" get "$RDY" charter)" = "$CH" ] && ok "charter=#$CH parsed" || no "charter parse wrong: $(bash "$B" get "$RDY" charter)"
[ "$(bash "$B" get "$RDY" state)" = "open" ] && ok "state=open" || no "state wrong"
[ "$(bash "$B" get "$RDY" pr_repo)" = "$CB_REPO" ] && ok "pr_repo=$CB_REPO" || no "pr_repo wrong"

echo "=== T5: claim -> in-progress + not launchable + state ==="
bash "$B" claim "$RDY" cb1 >/dev/null
[ "$(bash "$B" get "$RDY" state)" = "in-progress" ] && ok "claim -> state in-progress" || no "claim state wrong"
L=$(bash "$B" launchable); has "$L" "$RDY" && no "in-progress leaf still launchable" || ok "in-progress leaf not launchable"

echo "=== T6: route review ==="
bash "$B" route "$RDY" review >/dev/null
[ "$(bash "$B" get "$RDY" state)" = "review" ] && ok "route review -> state review" || no "review state wrong"

echo "=== T7: route blocked + comment ==="
bash "$B" claim "$BLK" cb1 >/dev/null
bash "$B" route "$BLK" blocked "retry-cap exceeded (board-test)" >/dev/null
[ "$(bash "$B" get "$BLK" state)" = "blocked" ] && ok "route blocked -> state blocked" || no "blocked state wrong"
gh issue view "$BLK" -R $CB_REPO --json comments -q '.comments[].body' | grep -q "retry-cap exceeded" && ok "blocked comment posted" || no "no blocked comment"

echo "=== T8: hold veto ==="
RDY2=$(gh issue create -R $CB_REPO -t "HELD leaf $(date +%s)" -b "Charter: #$CH" -l hold | grep -oE '[0-9]+$' | tail -1)
L=$(bash "$B" launchable); has "$L" "$RDY2" && no "held leaf launchable" || ok "held leaf vetoed"
gh issue close "$RDY2" -R $CB_REPO >/dev/null 2>&1

echo "=== SUMMARY: $pass passed, $fail failed ==="
echo "=== done ==="
