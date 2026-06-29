#!/usr/bin/env bash
# fixtures/969/postfix/launcher-fetch.sh — POST-FIX launcher gh-fetch snippet (#969 fix #1).
#
# Replaces the invalid `gh issue list --paginate` with `gh api --paginate`, the only
# surface where --paginate is a real flag. Against the subcommand-aware stub the fetch
# succeeds and the launcher sees the full issue set.
#
# Sourced by the test; exposes lf_fetch_issues -> issue numbers on stdout.
lf_fetch_issues() {
  gh api --paginate "/repos/$CB_REPO/issues?state=all" 2>/dev/null \
    | jq -r '.[].number'
}
