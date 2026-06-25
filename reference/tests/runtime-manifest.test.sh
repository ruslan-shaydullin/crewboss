#!/usr/bin/env bash
#
# runtime-manifest.test.sh — 4 tests for the runtime manifest (issue #62, class a/e unit-bash)
#
# Test 1: manifest exists and parses
#   RED condition (class e): manifest does not exist yet (absent before this leaf).
#   GREEN after: manifest has parseable 4-field tab-separated data rows.
#
# Test 2: full snapshot coverage (builds list from snapshot tree — NOT hardcoded)
#   Computes inventory from _box-snapshot/cbnet/; verifies every snapshot file is
#   present in the manifest (by filename match in repo_path column) OR in the exclude
#   file with a non-empty reason. RED if any file is uncovered (e.g. marker-grep-gate).
#   GREEN after: all 67 snapshot files accounted for.
#
# Test 3: canonical sha-lock (repo↔manifest drift detector)
#   For each manifest row with status=canonical: file must exist at repo_path AND
#   sha256 must match. Catches silent drift between repo files and manifest.
#
# Test 4: pending-backport sanity (known-minimum 18 names + marker-grep-gate = 19)
#   Each of the 19 known-minimum names must appear in the manifest.
#   run-gov-gatefire.sh (marker-grep-gate) must specifically have status=pending-backport.
#   Silent dropping is caught by Test 2; this is a named-subset sanity check.
#
# LEGACY-header check:
#   reference/launcher/crewboss-launcher.sh must carry the LEGACY comment
#   (two-launchers decision: canonical = crewboss-launcher-gh.sh; reversible).

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
  no "runtime-manifest.tsv does not exist (RED before this leaf)"
else
  rows=$(grep -v '^[[:space:]]*#' "$MANIFEST" | grep -v '^[[:space:]]*$' | \
         awk -F'\t' 'NF==4' | wc -l | tr -d ' ')
  if [ "${rows:-0}" -gt 0 ]; then
    ok "manifest exists with $rows data rows (4 tab-separated fields each)"
  else
    no "manifest exists but has no parseable 4-field tab-separated data rows"
  fi
fi

# ---------------------------------------------------------------------------
# Test 2: full snapshot coverage (inventory built from snapshot tree, not hardcoded)
# ---------------------------------------------------------------------------
echo "=== Test 2: full snapshot coverage ==="
if [ ! -d "$SNAP_DIR" ]; then
  no "snapshot directory not found: $SNAP_DIR — cannot verify coverage"
else
  t2_ok=0; t2_fail=0
  while IFS= read -r -d '' snap_file; do
    name=$(basename "$snap_file")
    # In manifest: check if any repo_path column (field 1) has this basename
    in_manifest=0
    if awk -F'\t' -v n="$name" '
         /^[[:space:]]*#/ { next }
         /^[[:space:]]*$/ { next }
         {
           p = $1; gsub(/\r/, "", p)
           sub(/.*\//, "", p)   # extract basename
           if (p == n) { found=1; exit }
         }
         END { exit !found }
       ' "$MANIFEST" 2>/dev/null; then
      in_manifest=1
    fi
    # In exclude: first whitespace-delimited field = filename
    in_exclude=0
    if awk -v n="$name" '
         /^[[:space:]]*#/ { next }
         /^[[:space:]]*$/ { next }
         {
           fname = $1; gsub(/\r/, "", fname)
           # must also have a non-empty reason (field 2+)
           rest = $0; sub(/^[^[:space:]]+[[:space:]]+/, "", rest)
           if (fname == n && length(rest) > 0) { found=1; exit }
         }
         END { exit !found }
       ' "$EXCLUDE" 2>/dev/null; then
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
    ok "all $t2_ok snapshot files accounted for (manifest OR exclude with reason)"
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
    # skip blank lines and comment lines
    case "${repo_path:-}" in ''|'#'*|[[:space:]]*'#'*) continue ;; esac
    [ "${repo_path:0:1}" = '#' ] && continue
    [ -z "${repo_path:-}" ] && continue
    [ "${status:-}" = "canonical" ] || continue
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
    ok "all $t3_ok canonical entries: file exists + sha256 matches"
  else
    no "$t3_fail canonical entry/entries failed sha-lock (repo drift detected)"
  fi
fi

# ---------------------------------------------------------------------------
# Test 4: backport completeness — NO pending-backport rows (tightened by #65)
# ---------------------------------------------------------------------------
# RED condition: any pending-backport row exists in the manifest (state before #65 backport)
# GREEN condition: all 13 reference/runtime/ files are canonical; zero pending-backport rows.
echo "=== Test 4: backport completeness (no pending-backport rows) ==="
if [ ! -f "$MANIFEST" ]; then
  no "manifest missing — skipping backport-completeness check"
else
  t4_fail=0
  # Check 1: no pending-backport rows in data (comment lines excluded)
  pending_rows=$(grep -v '^[[:space:]]*#' "$MANIFEST" | \
                 awk -F'\t' 'NF==4 && $3=="pending-backport"')
  if [ -n "$pending_rows" ]; then
    echo "$pending_rows" | while IFS=$'\t' read -r rp sha st pu; do
      printf '    STILL PENDING: %s\n' "$rp"
    done
    pending_count=$(echo "$pending_rows" | wc -l | tr -d ' ')
    no "$pending_count pending-backport row(s) remain — backport incomplete"
    t4_fail=$((t4_fail+1))
  fi
  # Check 2: all 13 reference/runtime/ canonical targets exist on disk + have canonical status
  RUNTIME_TARGETS=(
    charter-leaf-prep.sh
    claude.kafel
    crewboss-launcher-gh.sh
    crewboss-prep-spawn-gh.sh
    crewboss-spawn.sh
    proxy.py
    rework-prep.sh
    run-charter.sh
    run-gov-gatefire.sh
    run-rework.sh
    start-api.sh
    start-stack.sh
    watch-rework.sh
  )
  for name in "${RUNTIME_TARGETS[@]}"; do
    rp="reference/runtime/$name"
    status_in_manifest=$(grep -v '^[[:space:]]*#' "$MANIFEST" | \
      awk -F'\t' -v p="$rp" '$1==p {print $3; exit}')
    if [ -z "$status_in_manifest" ]; then
      printf '    NOT IN MANIFEST: %s\n' "$rp"
      t4_fail=$((t4_fail+1))
    elif [ "$status_in_manifest" != "canonical" ]; then
      printf '    WRONG STATUS: %s (got "%s", want "canonical")\n' "$rp" "$status_in_manifest"
      t4_fail=$((t4_fail+1))
    fi
    if [ ! -f "$REPO_ROOT/$rp" ]; then
      printf '    FILE MISSING ON DISK: %s\n' "$rp"
      t4_fail=$((t4_fail+1))
    fi
  done
  if [ "$t4_fail" -eq 0 ]; then
    ok "no pending-backport rows; all 13 reference/runtime/ files present + canonical in manifest"
  else
    no "backport completeness check failed ($t4_fail assertion(s))"
  fi
fi

# ---------------------------------------------------------------------------
# LEGACY-header check: reference/launcher/crewboss-launcher.sh
# ---------------------------------------------------------------------------
echo "=== LEGACY-header check: crewboss-launcher.sh ==="
if [ ! -f "$LEGACY_LAUNCHER" ]; then
  no "reference/launcher/crewboss-launcher.sh not found"
elif grep -q 'LEGACY' "$LEGACY_LAUNCHER"; then
  ok "LEGACY marker present in reference/launcher/crewboss-launcher.sh (two-launchers decision)"
else
  no "LEGACY marker missing from reference/launcher/crewboss-launcher.sh"
fi

# ---------------------------------------------------------------------------
echo
printf '=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
