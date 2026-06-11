#!/usr/bin/env bash
# board-gh.sh — real GitHub board adapter (gh issues+labels <-> launcher state machine).
# Canonical labels (labels-setup.sh): type:charter, status:{needs-plan,plan-review,approved,
# in-progress,review,blocked}, hold. Body conventions: "Charter: #N", "Depends-on: #X".
# Run-state (pid/starttime/tries) is NOT on gh — it's launcher-local (status.json); gh holds
# only the canonical board state, per design §9.
#
# Usage:
#   board-gh.sh launchable                       -> launchable leaf numbers (canonical predicate)
#   board-gh.sh get <id> <field>                 -> state|kind|role|charter|deps|held|pr_repo|prompt
#   board-gh.sh claim <id> [launcher-id]         -> +status:in-progress (+claimed-by:<id>)
#   board-gh.sh route <id> review|blocked|requeue [comment]
set -uo pipefail
REPO="${CB_REPO:?set CB_REPO=owner/repo}"
HERE="$(cd "$(dirname "$0")" && pwd)"
LAUNCHABLE="${CB_LAUNCHABLE:-$HERE/launchable.sh}"
ensure_label(){ gh label create "$1" -R "$REPO" --color "${2:-ededed}" 2>/dev/null || true; }
iview(){ gh issue view "$1" -R "$REPO" --json number,state,labels,body; }
haslabel(){ jq -e --arg l "$1" '[.labels[].name]|any(.==$l)' >/dev/null; }

cmd="${1:?need subcommand}"; shift || true
case "$cmd" in
  launchable)
    gh issue list -R "$REPO" --state all -L 200 --json number,state,labels,body | bash "$LAUNCHABLE" ;;

  plannable)  # charters awaiting decomposition: type:charter + status:needs-plan, open, not held
    gh issue list -R "$REPO" --state open -L 200 --json number,labels | jq -r '
      .[] | select([.labels[].name] as $l
        | ($l|index("type:charter")) and ($l|index("status:needs-plan")) and (($l|index("hold"))|not))
      | .number' ;;

  get)
    id="$1"; field="$2"; j=$(iview "$id")
    case "$field" in
      kind)   echo "$j" | jq -r 'if ([.labels[].name]|any(.=="type:charter")) then "charter" else "leaf" end' ;;
      role)   echo "$j" | jq -r '([.labels[].name[]? | select(startswith("role:"))] | .[0] // "role:executor") | sub("^role:";"")' ;;
      charter)echo "$j" | jq -r '[ (.body//"")|split("\n")[] | select(test("(?i)^[\\s*_>#-]*Charter\\s*:")) ] | join(" ") | (scan("\\d+")//empty)' | head -1 ;;
      deps)   echo "$j" | jq -r '[ (.body//"")|split("\n")[] | select(test("(?i)^[\\s*_>#-]*Depends-on\\s*:")) ] | join(" ") | [scan("\\d+")] | join(" ")' ;;
      held)   echo "$j" | jq -r 'if ([.labels[].name]|any(.=="hold")) then "true" else "false" end' ;;
      pr_repo)echo "$REPO" ;;
      prompt) echo "$j" | jq -r '.body // ""' ;;
      state)  echo "$j" | jq -r '
                if .state=="CLOSED" then "done"
                elif ([.labels[].name]|any(.=="status:blocked")) then "blocked"
                elif ([.labels[].name]|any(.=="status:review")) then "review"
                elif ([.labels[].name]|any(.=="status:in-progress")) then "in-progress"
                elif ([.labels[].name]|any(.=="status:approved")) then "approved"
                elif ([.labels[].name]|any(.=="status:plan-review")) then "plan-review"
                elif ([.labels[].name]|any(.=="status:needs-plan")) then "needs-plan"
                else "open" end' ;;
      *) echo "unknown field: $field" >&2; exit 64 ;;
    esac ;;

  claim)
    id="$1"; lid="${2:-cb}"
    ensure_label "claimed-by:$lid" "bfdadc"
    gh issue edit "$id" -R "$REPO" --add-label status:in-progress --add-label "claimed-by:$lid" >/dev/null
    echo "claimed #$id by $lid" ;;

  route)
    id="$1"; outcome="$2"; comment="${3:-}"
    case "$outcome" in
      review)  gh issue edit "$id" -R "$REPO" --remove-label status:in-progress --add-label status:review >/dev/null
               echo "#$id -> review" ;;
      blocked) gh issue edit "$id" -R "$REPO" --remove-label status:in-progress --add-label status:blocked >/dev/null
               [ -n "$comment" ] && gh issue comment "$id" -R "$REPO" -b "$comment" >/dev/null
               echo "#$id -> blocked" ;;
      requeue) # back to open: drop in-progress + any claimed-by:* labels
               labs=$(iview "$id" | jq -r '.labels[].name | select(startswith("claimed-by:") or .=="status:in-progress")')
               for l in $labs; do gh issue edit "$id" -R "$REPO" --remove-label "$l" >/dev/null; done
               echo "#$id -> open (requeued)" ;;
      *) echo "unknown outcome: $outcome" >&2; exit 64 ;;
    esac ;;

  *) echo "usage: $0 {launchable|get|claim|route}" >&2; exit 64 ;;
esac
