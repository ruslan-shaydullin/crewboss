#!/usr/bin/env bash
# HERMETIC RED fixture (charter #993 / catches #969): a shell artifact that calls
# `gh` with a NON-EXISTENT flag.  Real `gh` rejects `--paginate` at parse time with
# "unknown flag" BEFORE any network call, so this is hermetic by nature (no mock,
# no token, no network).  smoke-runner.sh MUST detect the broken invocation and
# report exit 1 (FAIL) with a SMOKE_REASON.
set -euo pipefail

# `--paginate` is not a real flag of `gh issue list` -> dies "unknown flag".
gh issue list --paginate --state open
