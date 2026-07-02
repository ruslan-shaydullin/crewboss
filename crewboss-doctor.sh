#!/usr/bin/env bash
# crewboss-doctor.sh (repo-root entrypoint) — charter #1290, leaf #1306.
#
# `bash crewboss-doctor.sh` from the repo root runs the SAME runtime health
# checks the live box runs, by delegating to the canonical implementation at
# reference/runtime/crewboss-doctor.sh. No logic is duplicated here (single
# source of truth — the file under reference/runtime/ is the one sha-locked in
# reference/runtime-manifest.tsv and deployed to the box), so this wrapper can
# never drift from the deployed doctor.
#
# All arguments (e.g. --fix) and environment (CB_HOME, CB_API_PORT,
# CB_TUNNEL_CHECK) are forwarded verbatim.
#
# Exit: 0 = all checks pass, non-zero = problems detected (see runtime doctor).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$HERE/reference/runtime/crewboss-doctor.sh" "$@"
