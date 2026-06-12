#!/usr/bin/env bash
# launchable.sh — compute the launchable leaf set from a board snapshot (Arch-2).
#
# stdin : JSON array of issues, e.g. from
#         gh issue list --state all --json number,state,labels,body
#         [{ "number":N, "state":"OPEN|CLOSED", "labels":[{"name":..}], "body":".." }, ...]
# stdout: launchable leaf issue numbers, one per line.
#
# Options:
#   --charter N   scope output to leaves of charter N only (also: env CREWBOSS_CHARTER=N)
#
# launchable(leaf) =
#   leaf is OPEN
#   AND body has "Charter: #N"  (it's a managed leaf; leading markdown like **/-/>/# is tolerated,
#                                 since an LLM tech-lead naturally writes **Charter: #N**)
#   AND charter #N is OPEN and labeled status:approved   (plan-approval gate)
#   AND every "Depends-on: #X" issue is CLOSED           (ordering)
#   AND leaf is NOT labeled status:in-progress|status:review|status:blocked|hold
#   AND (if --charter N / CREWBOSS_CHARTER=N) charter #N matches the scope
#
# NOTE: status:needs-rework is intentionally NOT in the exclusion list — a needs-rework leaf
#   remains launchable so the launcher re-dispatches it via the rework path (rebase cycle).
#   Contrast with status:blocked (hard stop, needs tech-lead triage) and status:hold (veto).
#
# Pure function — NO network. The real launcher pipes `gh issue list ... --json ...`
# into this; the test harness pipes a synthetic board. See ../board-orchestration.md.
CHARTER_SCOPE="${CREWBOSS_CHARTER:-}"
while [ $# -gt 0 ]; do
  case "$1" in --charter) CHARTER_SCOPE="$2"; shift ;; esac; shift
done
jq -r --argjson charter_scope "${CHARTER_SCOPE:-0}" '
  def numsAfter($body; $kw):
    [ ($body // "") | split("\n")[] | select(test("(?i)^[\\s*_>#-]*" + $kw + "\\s*:")) ] | join(" ")
    | [ scan("\\d+") | tonumber ];
  (map({key:(.number|tostring), value:.}) | from_entries) as $by
  | .[]
  | select(.state == "OPEN")
  | select([.labels[].name] | any(. == "type:agent"))
  | . as $leaf
  | (numsAfter(.body; "Charter") | first) as $cN
  | select($cN != null)
  | select( ([.labels[].name] | any(. == "status:in-progress" or . == "status:review" or . == "status:blocked" or . == "hold")) | not )
  | ($by[$cN|tostring]) as $c
  | select($c != null and $c.state == "OPEN" and ([$c.labels[].name] | any(. == "status:approved")) and ([$c.labels[].name] | any(. == "type:charter")))
  | select( numsAfter(.body; "Depends-on") | all( ($by[(.|tostring)]) | (. != null and .state == "CLOSED") ) )
  | select( $charter_scope == 0 or $cN == $charter_scope )
  | .number
'
