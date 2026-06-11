#!/usr/bin/env bash
# build-provision.sh — assemble the self-contained provision.sh by embedding the validated
# runtime files as a base64 tarball into the template at __RUNTIME_PLACEHOLDER__.
#
# Sources files entirely from the repo checkout (reference/runtime/ + manifest-defined extras).
# No external paths required; $HOME/cbnet is never referenced.
set -euo pipefail

# Determine repo root from this script's location (proto/provision/ → ../../)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# CB_SRC: canonical runtime directory in the repo checkout
CB_SRC="${CB_SRC:-$REPO_ROOT/reference/runtime}"
MANIFEST="${MANIFEST:-$REPO_ROOT/reference/runtime-manifest.tsv}"
TEMPLATE="${1:-$REPO_ROOT/proto/provision/provision-template.sh}"
OUT="${2:-$REPO_ROOT/proto/provision/provision.sh}"

# Extra provision files from other repo paths that belong in the box runtime bundle.
# Format: "repo-relative-path:bundle-filename"
# Source of truth: reference/runtime-manifest.tsv (canonical entries below)
EXTRA_FILES=(
  "proto/net/bridge.py:bridge.py"
  "proto/r5/redact.pl:redact.pl"
  "proto/r5/crewboss-prep-spawn.sh:crewboss-prep-spawn.sh"
  "proto/r6/board-gh.sh:board-gh.sh"
  "reference/launcher/launchable.sh:launchable.sh"
  "reference/launcher/labels-setup.sh:labels-setup.sh"
  "proto/seccomp/gen-policy.sh:gen-policy.sh"
  "proto/provision/crewboss-doctor.sh:crewboss-doctor.sh"
  "ui/server/crewboss-api.py:crewboss-api.py"
)

# Validate CB_SRC
[ -d "$CB_SRC" ] || { echo "MISSING CB_SRC: $CB_SRC"; echo "build aborted — runtime source not found"; exit 1; }

# Build staging area: collect all bundle files into a single flat directory
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

# 1. Copy all files from CB_SRC (reference/runtime/) — includes charter-leaf-prep.sh,
#    rework-prep.sh, start-stack.sh, and all other canonical runtime files
for f in "$CB_SRC"/*; do
  [ -f "$f" ] && cp "$f" "$STAGING/"
done

# 2. Copy extra provision files from other repo locations
missing=0
for spec in "${EXTRA_FILES[@]}"; do
  src="$REPO_ROOT/${spec%%:*}"
  dst="${spec##*:}"
  if [ -f "$src" ]; then
    cp "$src" "$STAGING/$dst"
  else
    echo "MISSING $src"
    missing=1
  fi
done
[ "$missing" = 0 ] || { echo "build aborted — missing runtime files"; exit 1; }

# 3. Embed manifest copy in bundle (name + sha256; doctor uses this for verification — F0-4)
[ -f "$MANIFEST" ] || { echo "MISSING manifest: $MANIFEST"; exit 1; }
cp "$MANIFEST" "$STAGING/runtime-manifest.tsv"

# 4. Mandatory file gate (subset required by issue #66 / charter #60)
MANDATORY=(charter-leaf-prep.sh rework-prep.sh start-stack.sh crewboss-api.py runtime-manifest.tsv)
for f in "${MANDATORY[@]}"; do
  [ -f "$STAGING/$f" ] || { echo "MISSING mandatory bundle file: $f"; exit 1; }
done

# 5. Build flat tarball from staging and inject into template
[ -f "$TEMPLATE" ] || { echo "MISSING template: $TEMPLATE"; exit 1; }
FILES=()
for f in "$STAGING"/*; do
  [ -f "$f" ] && FILES+=("$(basename "$f")")
done
B64=$(tar -czC "$STAGING" "${FILES[@]}" | base64 -w0 2>/dev/null || \
      tar -czC "$STAGING" "${FILES[@]}" | base64)
# inject (awk: replace the placeholder line with the base64 blob)
awk -v blob="$B64" '/^__RUNTIME_PLACEHOLDER__$/{print blob; next} {print}' "$TEMPLATE" > "$OUT"
chmod +x "$OUT"
echo "built $OUT ($(wc -c < "$OUT") bytes, runtime ${#FILES[@]} files)"
