#!/usr/bin/env bash
# Shared fixtures for tests that exercise launcher logic with a file-backed board.
# The Linux sandbox is covered separately by runtime-portability and integration.
cb_fixture_runtime() {
  local destination="$1" source_dir
  source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../runtime" && pwd)"
  mkdir -p "$destination"
  cp "$source_dir/run-env.sh" "$source_dir/launcher-board.sh" \
    "$source_dir/reviewer-verdict.py" "$destination/"
  printf '#!/usr/bin/env bash\n[ "${1:-}" = --preflight ]\n' > "$destination/crewboss-doctor.sh"
}

cb_fixture_gh_api() {
  local arg include=0 issues=0 state=all
  for arg; do
    case "$arg" in
      --include|-i) include=1 ;;
      /repos/*/issues|repos/*/issues) issues=1 ;;
      state=*) state="${arg#state=}" ;;
    esac
  done
  [ "$issues" -eq 1 ] || { echo 'fixture: unsupported gh api request' >&2; return 97; }
  [ "$include" -ne 1 ] || printf 'HTTP/2.0 200 OK\n\n'
  jq --arg state "$state" 'map(select($state == "all" or (.state | ascii_downcase) == $state))' "$BOARD_STATE"
}
