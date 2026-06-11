#!/usr/bin/env bash
#
# runtime-manifest.test.sh — 4 tests for the runtime manifest (issue #62, class a/e unit-bash)
#
# Test 1: manifest exists and parses
#   RED condition (class e): manifest does not exist yet.
#   GREEN: manifest has data rows with 4 tab-separated fields.
#
# Test 2: full snapshot coverage
#   Builds inventory from _box-snapshot/cbnet/ tree; verifies every snapshot file
#   is present in the manifest (by filename match against repo_path column) OR listed
#   in the exclude file (with a non-empty reason). List NOT hardcoded — built from snapshot.
#   RED: any snapshot file (e.g. the marker-grep-gate run-gov-gatefire.sh) not accounted for.
#
# Test 3: canonical sha-lock (repo↔manifest drift detector)
#   For each manifest row with status=canonical: the file at repo_path must exist
#   in the repo AND its sha256 must match the manifest. Catches silent repo drift.
#
# Test 4: pending-backport sanity
#   The known minimum of 19 names (18 from charter #60 analysis + marker-grep-gate)
#   must appear in the manifest. marker-grep-gate (run-gov-gatefire.sh) must be
#   specifically present with status=pending-backport. Silent dropping is caught by
#   Test 2 (full coverage); this test is a named-subset sanity check.
#
# LEGACY-header grep-test:
#   reference/launcher/crewboss-launcher.sh must carry the LEGACY comment (two-launchers
#   decision; tech-lead 2026-06-11).

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
MANIFEST="$HERE/../runtime-manifest.tsv"
EXCLUDE="$HERE/../runtime-manifest.exclude"
SNAP_DIR="$REPO_ROOT/_box-snapshot/cbnet"
LEGACY_LAUNCHER="$HERE/../launcher/crewboss-launcher.sh"

pass=0; fail=0
ok() { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

# ---------------------------------------------------------------------------
# Test 1: manifest exists and parses
# ---------------------------------------------------------------------------
echo "=== Test 1: manifest exists and parses ==="
if [ ! -f "$MANIFEST" ]; then
  no "runtime-manifest.tsv does not exist (RED before leaf: file absent)"
else
  rows=$(grep -v '^[[:space:]]*#' "$MANIFEST" | grep -v '^[[:space:]]*$' | \
         awk -F'\t' 'NF==4' | wc -l | tr -d ' ')
  if [ "${rows:-0}" -gt 0 ]; then
    ok "manifest exists with $rows data rows (4 tab-separated fields)"
  else
    no "manifest exists but has no parseable 4-field tab-separated data rows"
  fi
fi

# ---------------------------------------------------------------------------
# Test 2: full snapshot coverage (builds list from snapshot, not hardcoded)
# ---------------------------------------------------------------------------
echo "=== Test 2: full snapshot coverage ==="
if [ ! -d "$SNAP_DIR" ]; then
  no "snapshot directory not found: $SNAP_DIR — cannot verify coverage"
else
  t2_ok=0; t2_fail=0
  while IFS= read -r -d '' snap_file; do
    name=$(basename "$snap_file")
    # In manifest: repo_path column (field 1) ends with /<name> or is just <name>
    in_manifest=0
    if grep -v '^[[:space:]]*#' "$MANIFEST" 2>/dev/null | \
       awk -F'\t' -v n="$name" '
         { p=$1; gsub(/\r/,"",p)
           # match if repo_path basename equals filename
           sub(/.*\//, "", p)
           if (p == n) { found=1; exit }
         }
         END { exit !found }
       '; then
      in_manifest=1
    fi
    # In exclude: first field (whitespace-delimited) = filename
    in_exclude=0
    if grep -v '^[[:space:]]*#' "$EXCLUDE" 2>/dev/null | \
       awk -v n="$name" '
         { fname=$1; gsub(/\r/,"",fname)
           if (fname == n) { found=1; exit }
         }
         END { exit !found }
       '; then
      in_exclude=1
    fi
    if [ "$in_manifest" -eq 1 ] || [ "$in_exclude" -eq 1 ]; then
      t2_ok=$((t2_ok+1))
    else
      printf '    UNCOVERED: %s\n' "$name"
      t2_fail=$((t2_fail+1))
    fi
  done < <(find "$SNAP_DIR" -maxdepth 1 -type f -print0 | sort -z)
  if [ "$t2_fail" -eq 0 ]; then
    ok "all $t2_ok snapshot files accounted for (manifest + exclude)"
  else
    no "$t2_fail snapshot file(s) not covered by manifest or exclude list"
  fi
fi

# ---------------------------------------------------------------------------
# Test 3: canonical sha-lock (CI drift detector — canonical rows only)
# ---------------------------------------------------------------------------
echo "=== Test 3: canonical sha-lock ==="
if [ ! -f "$MANIFEST" ]; then
  no "manifest missing — skipping sha-lock"
else
  t3_ok=0; t3_fail=0
  while IFS=$'\t' read -r repo_path sha256 status purpose; do
    # skip blank lines and comments
    [[ "${repo_path:-}" =~ ^[[:space:]]*# ]] && continue
    [ -z "${repo_path:-}" ] && continue
    [ "$status" = "canonical" ] || continue
    full="$REPO_ROOT/$repo_path"
    if [ ! -f "$full" ]; then
      printf '    MISSING: %s\n' "$repo_path"
      t3_fail=$((t3_fail+1))
    else
      actual=$(sha256sum "$full" | cut -d' ' -f1)
      if [ "$actual" = "$sha256" ]; then
        t3_ok=$((t3_ok+1))
      else
        printf '    SHA MISMATCH: %s\n    want: %s\n    got:  %s\n' \
               "$repo_path" "$sha256" "$actual"
        t3_fail=$((t3_fail+1))
      fi
    fi
  done < "$MANIFEST"
  if [ "$t3_fail" -eq 0 ]; then
    ok "all $t3_ok canonical entries: file present + sha256 matches"
  else
    no "$t3_fail canonical entry/entries failed sha-lock (repo drift detected)"
  fi
fi

# ---------------------------------------------------------------------------
# Test 4: pending-backport sanity (known-minimum 18 + marker-grep-gate)
# ---------------------------------------------------------------------------
echo "=== Test 4: pending-backport sanity ==="
# Known minimum: 18 names from charter #60 + marker-grep-gate (19 total)
KNOWN_MIN=(
  proxy.py
  bridge.py
  redact.pl
  crewboss-spawn.sh
  crewboss-prep-spawn.sh
  crewboss-prep-spawn-gh.sh
  crewboss-launcher.sh
  crewboss-launcher-gh.sh
  board-gh.sh
  launchable.sh
  labels-setup.sh
  gen-policy.sh
  claude.kafel
  crewboss-doctor.sh
  charter-leaf-prep.sh
  rework-prep.sh
  start-stack.sh
  crewboss-api.py
  run-gov-gatefire.sh
)
if [ ! -f "$MANIFEST" ]; then
  no "manifest missing — skipping known-minimum check"
else
  t4_fail=0
  for name in "${KNOWN_MIN[@]}"; do
    # match by basename: the repo_path column's last path component equals $name
    found=$(grep -v '^[[:space:]]*#' "$MANIFEST" | \
            awk -F'\t' -v n="$name" '
              { p=$1; gsub(/\r/,"",p)
                # extract basename from repo_path
                sub(/.*\//, "", p)
                if (p == n) { print; exit }
              }')
    if [ -z "$found" ]; then
      printf '    MISSING from manifest: %s\n' "$name"
      t4_fail=$((t4_fail+1))
    fi
  done
  # marker-grep-gate must be pending-backport specifically
  mggate_status=$(grep -v '^[[:space:]]*#' "$MANIFEST" | \
    awk -F'\t' '
      { p=$1; gsub(/\r/,"",p); sub(/.*\//, "", p)
        if (p == "run-gov-gatefire.sh") print $3
      }' | \
    head -1 | tr -d '[:space:]')
  if [ -z "$mggate_status" ]; then
    printf '    marker-grep-gate (run-gov-gatefire.sh) not found in manifest\n'
    t4_fail=$((t4_fail+1))
  elif [ "$mggate_status" != "pending-backport" ]; then
    printf '    marker-grep-gate (run-gov-gatefire.sh) status is "%s", want pending-backport\n' \
           "$mggate_status"
    t4_fail=$((t4_fail+1))
  fi
  if [ "$t4_fail" -eq 0 ]; then
    ok "all 19 known-minimum names in manifest; marker-grep-gate is pending-backport"
  else
    no "$t4_fail known-minimum name(s) missing or marker-grep-gate not pending-backport"
  fi
fi

# ---------------------------------------------------------------------------
# LEGACY-header check for reference/launcher/crewboss-launcher.sh
# ---------------------------------------------------------------------------
echo "=== LEGACY-header check: crewboss-launcher.sh ==="
if [ ! -f "$LEGACY_LAUNCHER" ]; then
  no "reference/launcher/crewboss-launcher.sh not found"
elif grep -q 'LEGACY' "$LEGACY_LAUNCHER"; then
  ok "LEGACY marker present in reference/launcher/crewboss-launcher.sh"
else
  no "LEGACY marker missing from reference/launcher/crewboss-launcher.sh (two-launchers decision)"
fi

# ---------------------------------------------------------------------------
echo
printf '=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
