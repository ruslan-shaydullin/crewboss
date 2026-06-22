#!/usr/bin/env bash
# Unit test for _detect_ui_artifact() — git-diff detection logic in isolation.
# Zero network calls, zero browser: calls _detect_ui_artifact() directly,
# NOT cmd_verify_merged.  Charter #524 artifact-type-aware verify-merged.
set -euo pipefail

INTEGRATOR="$(cd "$(dirname "$0")/../runtime" && pwd)/crewboss-integrator.sh"

# Precondition: integrator-artifact-detect leaf adds BASH_SOURCE guard.
# Skip gracefully if absent to prevent false-red during phased rollout.
grep -q '"${BASH_SOURCE\[0\]}" == "${0}"' "$INTEGRATOR" || {
  echo "SKIP: BASH_SOURCE guard not yet in crewboss-integrator.sh"
  exit 0
}

# Source integrator (BASH_SOURCE guard prevents dispatch block from running)
source "$INTEGRATOR"

pass=0; fail=0
ok()  { echo "ok: $*";   pass=$((pass+1)); }
ko()  { echo "FAIL: $*"; fail=$((fail+1)); }

# Setup: minimal temp git repo
tmp_dir=$(mktemp -d)
tmp_cache=$(mktemp)
trap 'rm -rf "$tmp_dir" "$tmp_cache" "${tmp_cache}.artifact_type"' EXIT

git -C "$tmp_dir" init -q
git -C "$tmp_dir" config user.email "ci@test"
git -C "$tmp_dir" config user.name "CI"
echo "base" > "$tmp_dir/README.md"
git -C "$tmp_dir" add . && git -C "$tmp_dir" commit -q -m "base"
git -C "$tmp_dir" update-ref ORIG_HEAD "$(git -C "$tmp_dir" rev-parse HEAD)"

# Test 1: UI-touching diff
mkdir -p "$tmp_dir/ui"
echo "change" > "$tmp_dir/ui/App.svelte"
git -C "$tmp_dir" add . && git -C "$tmp_dir" commit -q -m "ui change"
git -C "$tmp_dir" update-ref MERGE_HEAD "$(git -C "$tmp_dir" rev-parse HEAD)"

_detect_ui_artifact "$tmp_dir" "$tmp_cache"; ret=$?
[ "$ret" -eq 1 ] && ok "UI diff: returns 1" || ko "UI diff: expected 1 got $ret"
[ -f "${tmp_cache}.artifact_type" ] && [ "$(cat "${tmp_cache}.artifact_type")" = "ui" ] \
  && ok "UI diff: artifact_type sidecar = ui" || ko "UI diff: sidecar missing or wrong"
rm -f "${tmp_cache}.artifact_type"

# CRITICAL: advance ORIG_HEAD to the UI commit before Test 2.
# Without this, Test 2 diff spans both commits (UI+engine) and grep '^ui/' matches,
# causing _detect_ui_artifact to return 1 when it should return 0.
git -C "$tmp_dir" update-ref ORIG_HEAD "$(git -C "$tmp_dir" rev-parse HEAD)"

# Test 2: non-UI diff (reference/ only)
mkdir -p "$tmp_dir/reference"
echo "change" > "$tmp_dir/reference/engine.sh"
git -C "$tmp_dir" add . && git -C "$tmp_dir" commit -q -m "engine change"
git -C "$tmp_dir" update-ref MERGE_HEAD "$(git -C "$tmp_dir" rev-parse HEAD)"

_detect_ui_artifact "$tmp_dir" "$tmp_cache"; ret=$?
[ "$ret" -eq 0 ] && ok "non-UI diff: returns 0" || ko "non-UI diff: expected 0 got $ret"
[ ! -f "${tmp_cache}.artifact_type" ] \
  && ok "non-UI diff: no sidecar written" || ko "non-UI diff: sidecar should NOT be written"

echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
