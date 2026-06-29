#!/usr/bin/env bash
# fixtures/969/prefix/board-adapter.sh — PRE-FIX board adapter snippet (charter #969 defect #1).
#
# Reproduces the live-observed bug: `gh issue list --paginate` — `--paginate` is a
# non-existent flag on `gh issue list`. Against the subcommand-aware stub this exits
# non-zero ("unknown flag: --paginate"), so `launchable` yields an EMPTY set.
#
# Mirrors proto/r6/board-gh.sh launchable's fetch shape (gh issue list ... --paginate | jq).
set -uo pipefail
REPO="${CB_REPO:?set CB_REPO=owner/repo}"
case "${1:-}" in
  launchable)
    gh issue list -R "$REPO" --state all --paginate --json number,state,labels,body \
      | jq -r '.[].number'
    ;;
  *) echo "usage: $0 launchable" >&2; exit 64 ;;
esac
