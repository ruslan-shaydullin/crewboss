#!/usr/bin/env bash
# The former query-token smoke test is replaced by the authenticated HTTP suite.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec python3 "$ROOT/tests/test_api_auth.py"
