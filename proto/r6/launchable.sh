#!/usr/bin/env bash
# launchable.sh — compute the launchable leaf set from a board snapshot (Arch-2).
#
# stdin : JSON array of issues, e.g. from
#         gh issue list --state all --json number,state,labels,body
#         [{ "number":N, "state":"OPEN|CLOSED", "labels":[{"name":..}], "body":".." }, ...]
# stdout: launchable leaf issue numbers, one per line.
#
# launchable(leaf) =
#   leaf is OPEN
#   AND body has "Charter: #N"  (it's a managed leaf; leading markdown like **/-/>/# is tolerated,
#                                 since an LLM tech-lead naturally writes **Charter: #N**)
#   AND charter #N is OPEN and labeled status:approved   (plan-approval gate)
#   AND every "Depends-on: #X" issue is CLOSED           (ordering)
#   AND leaf is NOT labeled status:in-progress|status:review|status:blocked|hold
#
# Pure function — NO network. The real launcher pipes `gh issue list ... --json ...`
# into this; the test harness pipes a synthetic board. See ../board-orchestration.md.
jq -r '
  def numsAfter($body; $kw):
    [ ($body // "") | split("\n")[] | select(test("(?i)^[\\s*_>#-]*" + $kw + "\\s*:")) ] | join(" ")
    | [ scan("\\d+") | tonumber ];
  def has_acceptance_block:
    (. // "") | split("\n") |
    reduce .[] as $line (
      {in_block: false, done: false, valid: false};
      if .done then .
      elif (.in_block | not) then
        if ($line | test("^## Acceptance \\(machine\\)")) then .in_block = true else . end
      else
        if ($line | test("^## ")) then .done = true
        elif ($line | test("^- (test|check): .+")) then .valid = true
        else .
        end
      end
    ) | .valid;
  (map({key:(.number|tostring), value:.}) | from_entries) as $by
  | .[]
  | select(.state == "OPEN")
  | . as $leaf
  | (numsAfter(.body; "Charter") | first) as $cN
  | select($cN != null)
  | select( ([.labels[].name] | any(. == "status:in-progress" or . == "status:review" or . == "status:blocked" or . == "hold")) | not )
  | ($by[$cN|tostring]) as $c
  | select($c != null and $c.state == "OPEN" and ([$c.labels[].name] | any(. == "status:approved")) and ([$c.labels[].name] | any(. == "type:charter")))
  | select( numsAfter(.body; "Depends-on") | all( ($by[(.|tostring)]) | (. != null and .state == "CLOSED") ) )
  | select( .body | has_acceptance_block )
  | .number
'
