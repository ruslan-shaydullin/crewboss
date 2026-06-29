#!/usr/bin/env bash
# VALID-PASS fixture (charter #993, gated lane): uses only real, existing `gh`
# flags.  In the live-gated lane this resolves against the real board (200 OK).
set -euo pipefail

gh issue list --state open --limit 1
