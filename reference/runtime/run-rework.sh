#!/usr/bin/env bash
# Start rework for explicitly selected issue numbers. Optional CB_REWORK_ROLE
# selects the owning role; CB_OLD_BRANCH retains rework-prep's integration mode.
set -euo pipefail
[ "$#" -gt 0 ] || { echo 'usage: run-rework.sh ISSUE_NUMBER [ISSUE_NUMBER ...]' >&2; exit 2; }
for issue; do
  [[ "$issue" =~ ^[0-9]+$ ]] || { echo 'run-rework: every issue must be numeric' >&2; exit 2; }
done
# shellcheck source=run-env.sh
. "$(dirname "${BASH_SOURCE[0]}")/run-env.sh"
bash "$CB_HOME/crewboss-doctor.sh" --preflight
umask 077
export GH_REPO="$CB_REPO"
mkdir -p "$CB_HOME/run/rework-logs"
for issue; do
  nohup bash "$CB_HOME/rework-prep.sh" "$issue" "${CB_REWORK_ROLE:-executor}" \
    > "$CB_HOME/run/rework-logs/$issue.out" 2>&1 < /dev/null &
  printf 'dispatched rework #%s (PID %s)\n' "$issue" "$!"
done
