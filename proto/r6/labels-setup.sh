#!/usr/bin/env bash
# labels-setup.sh — create the crewboss board-orchestration labels in THIS repo.
# Idempotent (create, else edit). `depends-on` is a BODY convention (`Depends-on: #X`),
# not a label. See ../board-orchestration.md.
mklabel() { gh label create "$1" --color "$2" --description "$3" 2>/dev/null \
  || gh label edit "$1" --color "$2" --description "$3" 2>/dev/null || true; }

# charter lifecycle
mklabel "type:charter"          "c2e0c6" "boss-authored goal (root for decomposition)"
mklabel "status:needs-plan"     "ededed" "charter: awaiting tech-lead decomposition"
mklabel "status:plan-review"    "fbca04" "charter: plan awaiting boss approval"
mklabel "status:approved"       "0e8a16" "charter: plan approved — leaves launchable"
mklabel "status:needs-analysis" "bfd4f2" "charter: awaiting solution analysis (manifest mode)"
mklabel "status:team-review"    "d4c5f9" "charter: composition awaiting approval (manifest mode)"
mklabel "composition:approved"  "0e8a16" "charter: composition approved — leaves may launch (manifest mode)"
# leaf lifecycle
mklabel "status:in-progress"  "1d76db" "leaf: claimed / executor running"
mklabel "status:review"       "5319e7" "leaf: PR open, awaiting approval+merge"
mklabel "status:blocked"      "b60205" "leaf: failed past retry-cap — needs tech-lead triage"
mklabel "status:needs-rework" "e4e669" "leaf: merge conflict — rebase needed before re-integration"
mklabel "hold"                "d93f0b" "veto: never launch (manual hold)"

echo "✓ crewboss board labels ready"
