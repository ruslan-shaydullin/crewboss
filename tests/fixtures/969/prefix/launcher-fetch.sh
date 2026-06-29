#!/usr/bin/env bash
# fixtures/969/prefix/launcher-fetch.sh — PRE-FIX launcher gh-fetch snippet (#969 defect #1).
#
# Mirrors reference/runtime/crewboss-launcher-gh.sh's ~20 call sites of the form:
#   gh issue list -R "$CB_REPO" --state all --paginate --json ... | jq ...
# `--paginate` does not exist on `gh issue list`; against the subcommand-aware stub the
# fetch fails and the launcher sees zero issues (idle loop / launcher sees no charters).
#
# Sourced by the test; exposes lf_fetch_issues -> issue numbers on stdout.
lf_fetch_issues() {
  gh issue list -R "$CB_REPO" --state all --paginate \
     --json number,state,labels,body 2>/dev/null \
    | jq -r '.[].number'
}
