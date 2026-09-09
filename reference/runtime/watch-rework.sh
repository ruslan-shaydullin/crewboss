#!/usr/bin/env bash
# Observe explicitly selected local task statuses; no GitHub or provider calls.
set -euo pipefail
[ "$#" -gt 0 ] || { echo 'usage: watch-rework.sh ISSUE_NUMBER [ISSUE_NUMBER ...]' >&2; exit 2; }
for issue; do
  [[ "$issue" =~ ^[0-9]+$ ]] || { echo 'watch-rework: every issue must be numeric' >&2; exit 2; }
done
# shellcheck source=run-env.sh
. "$(dirname "${BASH_SOURCE[0]}")/run-env.sh"
interval="${CB_WATCH_INTERVAL:-20}"
[[ "$interval" =~ ^[1-9][0-9]*$ ]] || { echo 'watch-rework: CB_WATCH_INTERVAL must be a positive integer' >&2; exit 2; }
done_set=","
while true; do
  all_terminal=1
  for issue; do
    case "$done_set" in *",$issue,"*) continue ;; esac
    status="$CB_HOME/run/work/$issue/status.json"
    phase="$(jq -r '.phase // ""' "$status" 2>/dev/null || true)"
    case "$phase" in
      done|failed|budget-stop|canceled|cancelled)
        pr="$(jq -r '.pr // ""' "$status" 2>/dev/null || true)"
        printf 'rework #%s -> %s %s\n' "$issue" "$phase" "$pr"
        done_set="$done_set$issue,"
        ;;
      *) all_terminal=0 ;;
    esac
  done
  [ "$all_terminal" -ne 1 ] || { echo 'all selected rework terminal'; exit 0; }
  sleep "$interval"
done
