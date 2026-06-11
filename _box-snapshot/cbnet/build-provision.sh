#!/usr/bin/env bash
# build-provision.sh — assemble the self-contained provision.sh by embedding the validated
# runtime files (from $CB_SRC) as a base64 tarball into the template at __RUNTIME_PLACEHOLDER__.
set -euo pipefail
CB_SRC="${CB_SRC:-$HOME/cbnet}"
TEMPLATE="${1:-/tmp/cbnet/provision-template.sh}"
OUT="${2:-/tmp/cbnet/provision.sh}"

# the crewboss runtime shipped to the box (must exist in $CB_SRC)
FILES=(
  proxy.py bridge.py redact.pl
  crewboss-spawn.sh crewboss-prep-spawn.sh crewboss-prep-spawn-gh.sh
  crewboss-launcher.sh crewboss-launcher-gh.sh
  board-gh.sh launchable.sh labels-setup.sh gen-policy.sh
  claude.kafel crewboss-doctor.sh
)
missing=0
for f in "${FILES[@]}"; do [ -f "$CB_SRC/$f" ] || { echo "MISSING $CB_SRC/$f"; missing=1; }; done
[ "$missing" = 0 ] || { echo "build aborted — missing runtime files"; exit 1; }

B64=$(tar -czC "$CB_SRC" "${FILES[@]}" | base64 -w0 2>/dev/null || tar -czC "$CB_SRC" "${FILES[@]}" | base64)
# inject (awk: replace the placeholder line with the base64 blob)
awk -v blob="$B64" '/^__RUNTIME_PLACEHOLDER__$/{print blob; next} {print}' "$TEMPLATE" > "$OUT"
chmod +x "$OUT"
echo "built $OUT ($(wc -c < "$OUT") bytes, runtime ${#FILES[@]} files)"
