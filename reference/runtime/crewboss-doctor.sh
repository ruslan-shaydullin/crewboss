#!/usr/bin/env bash
# crewboss-doctor.sh — box-side drift detection.
#
# Compares every deployed file against the release manifest that was embedded
# in the provision bundle (CB_HOME/runtime-manifest.tsv, placed there by
# build-provision.sh step 3 / proto/provision/build-provision.sh F0-3).
#
# Usage:  CB_HOME=~/cbnet bash crewboss-doctor.sh
#
# Checks:
#   MISSING  — a canonical file listed in the manifest is absent from CB_HOME
#   MISMATCH — file is present but sha256 does not match the manifest entry
#   EXTRA    — a regular file exists in CB_HOME top-level but is not listed
#              in the manifest (untracked deployed file = potential drift)
#
# Exit 0 = no drift; Exit 1 = one or more drift items detected.
# All drifting file names are printed to stdout (one tag+name per line).

set -uo pipefail

CB_HOME="${CB_HOME:-$HOME/cbnet}"
MANIFEST="$CB_HOME/runtime-manifest.tsv"

if [ ! -f "$MANIFEST" ]; then
  printf 'FAIL: runtime-manifest.tsv not found at %s\n' "$MANIFEST"
  printf '      (provision bundle should have placed it there at deploy time)\n'
  exit 1
fi

fails=0
# drift_names is a plain string; appended per item for the summary line.
drift_names=""

# Build associative map: basename → expected sha256  (canonical entries only)
declare -A expected_sha
while IFS=$'\t' read -r repo_path sha256 status _purpose; do
  case "${repo_path:-}" in ''|'#'*) continue ;; esac
  [ "${status:-}" = "canonical" ] || continue
  bname="$(basename "$repo_path")"
  expected_sha["$bname"]="$sha256"
done < "$MANIFEST"

# ── Pass 1: verify every manifest entry ──────────────────────────────────────
for bname in "${!expected_sha[@]}"; do
  deployed="$CB_HOME/$bname"
  want="${expected_sha[$bname]}"
  if [ ! -f "$deployed" ]; then
    printf 'MISSING: %s\n' "$bname"
    drift_names="$drift_names $bname"
    fails=$((fails+1))
  else
    actual="$(sha256sum "$deployed" | awk '{print $1}')"
    if [ "$actual" != "$want" ]; then
      printf 'MISMATCH: %s\n' "$bname"
      drift_names="$drift_names $bname"
      fails=$((fails+1))
    fi
  fi
done

# ── Pass 2: detect extra (untracked) files at top level of CB_HOME ────────────
# Only regular files at top level are considered (skip directories, manifest copy).
for f in "$CB_HOME"/*; do
  [ -f "$f" ] || continue                           # skip non-regular (dirs, symlinks)
  bname="$(basename "$f")"
  [ "$bname" = "runtime-manifest.tsv" ] && continue # skip manifest itself
  if [ -z "${expected_sha[$bname]+x}" ]; then
    printf 'EXTRA: %s\n' "$bname"
    drift_names="$drift_names $bname"
    fails=$((fails+1))
  fi
done

# ── Summary ───────────────────────────────────────────────────────────────────
if [ "$fails" -eq 0 ]; then
  printf 'doctor: no drift (%d files verified)\n' "${#expected_sha[@]}"
  exit 0
else
  # shellcheck disable=SC2086
  printf 'doctor: drift detected (%d):%s\n' "$fails" "$drift_names"
  exit 1
fi
