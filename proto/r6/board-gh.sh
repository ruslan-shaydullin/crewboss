#!/usr/bin/env bash
# board-gh.sh — real GitHub board adapter (gh issues+labels <-> launcher state machine).
# Canonical labels (labels-setup.sh): type:charter, status:{needs-plan,plan-review,approved,
# in-progress,review,blocked}, hold. Body conventions: "Charter: #N", "Depends-on: #X".
# Run-state (pid/starttime/tries) is NOT on gh — it's launcher-local (status.json); gh holds
# only the canonical board state, per design §9.
#
# Usage:
#   board-gh.sh launchable                       -> launchable leaf numbers (canonical predicate)
#   board-gh.sh review-leaves                    -> open agent leaves in status:review
#   board-gh.sh get <id> <field>                 -> state|kind|role|charter|deps|held|pr_repo|prompt
#   board-gh.sh claim <id> [launcher-id]         -> +status:in-progress (+claimed-by:<id>)
#   board-gh.sh route <id> review|blocked|requeue|needs-rework [comment]
set -uo pipefail
REPO="${CB_REPO:?set CB_REPO=owner/repo}"
HERE="$(cd "$(dirname "$0")" && pwd)"
LAUNCHABLE="${CB_LAUNCHABLE:-$HERE/launchable.sh}"
ensure_label(){ gh label create "$1" -R "$REPO" --color "${2:-ededed}" 2>/dev/null || true; }
iview(){ gh issue view "$1" -R "$REPO" --json number,state,labels,body; }
haslabel(){ jq -e --arg l "$1" '[.labels[].name]|any(.==$l)' >/dev/null; }
_read_board_cache() {
  local cache="$CB_HOME/run/board-cache.json"
  local ttl="${CB_BOARD_TTL:-5}"
  # check mtime freshness via stat
  if [[ -f "$cache" ]] && (( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || echo 0) < ttl )); then
    cat "$cache"
  else
    # canonical fallback: ALWAYS --state all -L 200, NEVER --state open
    gh issue list -R "$REPO" --state all -L 200 --json number,title,state,labels,body \
      | tee "$cache.tmp" && mv "$cache.tmp" "$cache" && cat "$cache"
  fi
}

cmd="${1:?need subcommand}"; shift || true
case "$cmd" in
  launchable)
    _read_board_cache \
      | bash "$LAUNCHABLE" ${CREWBOSS_CHARTER:+--charter "$CREWBOSS_CHARTER"} ${CB_MANIFEST:+--require-composition} ;;

  plannable)  # charters awaiting decomposition: type:charter + status:needs-plan, open, not held
    _read_board_cache | jq -r '
      .[] | select(.state == "OPEN") | select([.labels[].name] as $l
        | ($l|index("type:charter")) and ($l|index("status:needs-plan")) and (($l|index("hold"))|not))
      | .number' ;;

  review-leaves)  # open agent leaves currently in status:review (awaiting integrator merge)
    # body is fetched to parse Charter: line; CREWBOSS_CHARTER scopes to one charter if set.
    _read_board_cache | jq -r \
        --argjson cs "${CREWBOSS_CHARTER:-0}" '
      .[] | select(.state == "OPEN")
           | select([.labels[].name] | (any(. == "type:agent") and any(. == "status:review")))
           | . as $i
           | ( [ ($i.body // "") | split("\n")[]
                  | select(test("(?i)^[\\s*_>#-]*Charter\\s*:"))
                ] | join(" ") | ( scan("\\d+") | tonumber ) // 0
             ) as $cN
           | select($cs == 0 or $cN == $cs)
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
                elif ([.labels[].name]|any(.=="status:needs-rework")) then "needs-rework"
                elif ([.labels[].name]|any(.=="status:in-progress")) then "in-progress"
                elif ([.labels[].name]|any(.=="status:approved")) then "approved"
                elif ([.labels[].name]|any(.=="status:plan-review")) then "plan-review"
                elif ([.labels[].name]|any(.=="status:needs-plan")) then "needs-plan"
                elif ([.labels[].name]|any(.=="status:team-review")) then "team-review"
                elif ([.labels[].name]|any(.=="status:needs-analysis")) then "needs-analysis"
                else "open" end' ;;
      *) echo "unknown field: $field" >&2; exit 64 ;;
    esac ;;

  claim)
    id="$1"; lid="${2:-cb}"
    ensure_label "claimed-by:$lid" "bfdadc"
    gh issue edit "$id" -R "$REPO" --add-label status:in-progress --add-label "claimed-by:$lid" >/dev/null
    # Lifecycle: transitioning out of needs-rework — strip the label so the leaf never
    # carries needs-rework simultaneously with in-progress (spec §5 lifecycle).
    gh issue edit "$id" -R "$REPO" --remove-label status:needs-rework 2>/dev/null || true
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
      needs-rework)
               # Integrator detected a merge conflict: drop in-progress/review/claimed-by:*,
               # add status:needs-rework so the launcher re-dispatches via rework path.
               ensure_label "status:needs-rework" "e4e669"
               nrlabs=$(iview "$id" | jq -r '.labels[].name | select(startswith("claimed-by:") or .=="status:in-progress" or .=="status:review")')
               for nrl in $nrlabs; do gh issue edit "$id" -R "$REPO" --remove-label "$nrl" >/dev/null; done
               gh issue edit "$id" -R "$REPO" --add-label status:needs-rework >/dev/null
               [ -n "$comment" ] && gh issue comment "$id" -R "$REPO" -b "$comment" >/dev/null
               echo "#$id -> needs-rework" ;;
      analysis)
               # Enter analysis stage OR return to analysis on reject.
               # Ensure both manifest-mode status labels exist on the board.
               ensure_label "status:needs-analysis" "bfd4f2"
               ensure_label "status:team-review"    "d4c5f9"
               # Remove statuses that should not coexist with needs-analysis.
               gh issue edit "$id" -R "$REPO" \
                 --remove-label status:needs-plan \
                 --remove-label status:team-review \
                 --add-label    status:needs-analysis >/dev/null
               [ -n "$comment" ] && gh issue comment "$id" -R "$REPO" -b "$comment" >/dev/null
               echo "#$id -> needs-analysis" ;;
      team-review)
               # Composition drafted; move to team approval.
               gh issue edit "$id" -R "$REPO" \
                 --remove-label status:needs-analysis \
                 --add-label    status:team-review >/dev/null
               echo "#$id -> team-review" ;;
      plan)
               # Composition approved; exit manifest stages into needs-plan pipeline.
               gh issue edit "$id" -R "$REPO" \
                 --remove-label status:needs-analysis \
                 --remove-label status:team-review \
                 --add-label    status:needs-plan >/dev/null
               echo "#$id -> needs-plan" ;;
      *) echo "unknown outcome: $outcome" >&2; exit 64 ;;
    esac ;;

  *) echo "usage: $0 {launchable|review-leaves|get|claim|route}" >&2; exit 64 ;;
esac
