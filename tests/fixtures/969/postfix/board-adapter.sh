#!/usr/bin/env bash
# fixtures/969/postfix/board-adapter.sh — POST-FIX board adapter snippet (charter #969 fix #1).
#
# Uses `gh api --paginate` (the one place --paginate is a real flag) instead of the
# invalid `gh issue list --paginate`. Against the subcommand-aware stub this succeeds,
# so `launchable` yields a NON-EMPTY set.
set -uo pipefail
REPO="${CB_REPO:?set CB_REPO=owner/repo}"
case "${1:-}" in
  launchable)
    gh api --paginate "/repos/$REPO/issues?state=all" \
      | jq -r '.[].number'
    ;;
  *) echo "usage: $0 launchable" >&2; exit 64 ;;
esac
