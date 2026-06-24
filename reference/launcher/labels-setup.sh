#!/usr/bin/env bash
# labels-setup.sh — create the crewboss board-orchestration labels in THIS repo.
# Idempotent (create, else edit). `depends-on` is a BODY convention (`Depends-on: #X`),
# not a label. See ../board-orchestration.md.
CB_REPO="${CB_REPO:-stratch1989/crewboss}"
mklabel() { gh label create "$1" -R "$CB_REPO" --color "$2" --description "$3" 2>/dev/null \
  || gh label edit "$1" -R "$CB_REPO" --color "$2" --description "$3" 2>/dev/null || true; }

# charter lifecycle
mklabel "type:charter"          "c2e0c6" "boss-authored goal (root for decomposition)"
mklabel "status:needs-plan"     "ededed" "charter: awaiting tech-lead decomposition"
mklabel "status:plan-review"    "fbca04" "charter: plan awaiting boss approval"
mklabel "status:approved"       "0e8a16" "charter: plan approved — leaves launchable"
mklabel "status:needs-analysis" "bfd4f2" "charter: awaiting solution analysis (manifest mode)"
mklabel "status:team-review"    "d4c5f9" "charter: composition awaiting approval (manifest mode)"
mklabel "composition:approved"  "0e8a16" "charter: composition approved — leaves may launch (manifest mode)"
# leaf lifecycle
mklabel "status:in-progress" "1d76db" "leaf: claimed / executor running"
mklabel "status:review"      "5319e7" "leaf: PR open, awaiting approval+merge"
mklabel "status:blocked"     "b60205" "leaf: failed past retry-cap — needs tech-lead triage"
mklabel "status:needs-rework" "e4e669" "leaf: needs rework before re-integration"
mklabel "status:needs-conflict-resolution" "e11d48" "charter: merge conflicts with main — needs manual resolution"
mklabel "hold"               "d93f0b" "veto: never launch (manual hold)"

# blast-radius labels (#262): high serializes all other charter dispatches
mklabel "blast-radius:high"  "b60205" "charter: active high blast-radius — serializes launcher (unscoped)"
mklabel "blast-radius:low"   "c5def5" "charter: normal parallel launch (default if no blast-radius label)"

# per-charter auto-gate labels (#401)
mklabel "auto:plan-approve" "0075ca" "per-charter: auto-approve plan gate"
mklabel "auto:merge"        "0075ca" "per-charter: auto-merge on green CI"

# test-quality gate routing labels (#597)
# status:test-broken: qa-engineer leaf routing signal (test is broken — re-dispatch for rework)
# status:impl-broken: executor leaf routing signal (impl is broken — re-dispatch for rework)
mklabel "status:test-broken" "e4e669" "tqg: qa-engineer leaf re-dispatch — test is broken"
mklabel "status:impl-broken" "b60205" "tqg: executor leaf re-dispatch — impl is broken"

echo "✓ crewboss board labels ready"
