#!/usr/bin/env bash
#
# provision-build.test.sh — smoke tests for build-provision.sh (issue #66, class d)
#
# Test 1: build-provision.sh in a clean environment (HOME=$(mktemp -d), no ~/cbnet)
#   assembles provision.sh from the repo checkout; output file contains an embedded
#   base64 tarball instead of __RUNTIME_PLACEHOLDER__.
#   RED now: CB_SRC defaults to $HOME/cbnet → "MISSING … build aborted".
#   GREEN after: CB_SRC defaults to reference/runtime/ (repo-relative).
#
# Test 2: the tarball extracted from provision.sh covers the full runtime, including
#   charter-leaf-prep.sh, rework-prep.sh, start-stack.sh, crewboss-api.py + manifest copy.
#   RED now: FILES list omits these four files.
#   GREEN after: all files from reference/runtime/ + extras + manifest copy are bundled.
#
# Test 3: grep provision build scripts: no references to sources outside the repo
#   ($HOME/cbnet, ~/cbnet).
#   RED now: build-provision.sh:5  CB_SRC="${CB_SRC:-$HOME/cbnet}".
#   GREEN after: only repo-relative paths in CB_SRC default.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
BUILD_SCRIPT="$REPO_ROOT/proto/provision/build-provision.sh"
MANIFEST="$REPO_ROOT/reference/runtime-manifest.tsv"

pass=0; fail=0
ok() { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

# ---------------------------------------------------------------------------
# Test 1: build in clean environment (no ~/cbnet)
# ---------------------------------------------------------------------------
echo "=== Test 1: build in clean HOME (no ~/cbnet) ==="

CLEAN_HOME="$(mktemp -d)"
WORK_DIR="$(mktemp -d)"
OUT_PROVISION="$WORK_DIR/provision.sh"
trap 'rm -rf "$CLEAN_HOME" "$WORK_DIR"' EXIT

build_rc=0
HOME="$CLEAN_HOME" bash "$BUILD_SCRIPT" \
    "$REPO_ROOT/proto/provision/provision-template.sh" \
    "$OUT_PROVISION" \
    >"$WORK_DIR/build.log" 2>&1 || build_rc=$?

if [ "$build_rc" -ne 0 ]; then
  no "build-provision.sh failed (rc=$build_rc) in clean HOME — see log:"
  sed 's/^/    /' "$WORK_DIR/build.log"
else
  ok "build-provision.sh exited 0 in clean HOME without ~/cbnet"
fi

# Verify output file exists
if [ ! -f "$OUT_PROVISION" ]; then
  no "output provision.sh was not created"
else
  ok "provision.sh output file exists"
fi

# Verify __RUNTIME_PLACEHOLDER__ was replaced (output should NOT contain it)
if [ -f "$OUT_PROVISION" ] && grep -q '^__RUNTIME_PLACEHOLDER__$' "$OUT_PROVISION"; then
  no "provision.sh still contains __RUNTIME_PLACEHOLDER__ — tarball not injected"
else
  [ -f "$OUT_PROVISION" ] && ok "provision.sh does not contain __RUNTIME_PLACEHOLDER__ (tarball injected)"
fi

# Verify __RUNTIME_B64__ markers are present (the heredoc wrapper with blob)
if [ -f "$OUT_PROVISION" ] && grep -q '^__RUNTIME_B64__$' "$OUT_PROVISION"; then
  ok "provision.sh contains __RUNTIME_B64__ heredoc markers"
else
  [ -f "$OUT_PROVISION" ] && no "provision.sh missing __RUNTIME_B64__ markers — tarball not embedded"
fi

# ---------------------------------------------------------------------------
# Test 2: tarball covers full runtime + manifest copy
# ---------------------------------------------------------------------------
echo "=== Test 2: tarball covers runtime manifest (incl. charter-leaf-prep, rework-prep, start-stack, crewboss-api, manifest copy) ==="

if [ ! -f "$OUT_PROVISION" ]; then
  no "provision.sh not available — skipping tarball coverage check"
else
  # Extract base64 blob: the line immediately before the standalone __RUNTIME_B64__ terminator
  # (the inline <<'__RUNTIME_B64__' opener does NOT match ^__RUNTIME_B64__$)
  BLOB_LINE=$(grep -B1 '^__RUNTIME_B64__$' "$OUT_PROVISION" | head -1)

  if [ -z "$BLOB_LINE" ]; then
    no "could not extract base64 blob from provision.sh"
  else
    EXTRACT_DIR="$(mktemp -d)"
    extract_rc=0
    printf '%s\n' "$BLOB_LINE" | base64 -d | tar -xzC "$EXTRACT_DIR" 2>/dev/null || extract_rc=$?
    if [ "$extract_rc" -ne 0 ]; then
      no "failed to decode/extract embedded tarball (rc=$extract_rc)"
    else
      ok "embedded tarball decoded and extracted successfully"

      # Check mandatory files that were previously missing
      for f in charter-leaf-prep.sh rework-prep.sh start-stack.sh crewboss-api.py; do
        if [ -f "$EXTRACT_DIR/$f" ]; then
          ok "tarball contains $f"
        else
          no "tarball MISSING $f"
        fi
      done

      # Check manifest copy is embedded
      if [ -f "$EXTRACT_DIR/runtime-manifest.tsv" ]; then
        ok "tarball contains runtime-manifest.tsv (manifest copy for doctor)"
      else
        no "tarball MISSING runtime-manifest.tsv (manifest copy)"
      fi

      # Check all reference/runtime/ files from the manifest are present
      t2_miss=0
      while IFS=$'\t' read -r repo_path sha256 status purpose; do
        case "${repo_path:-}" in ''|'#'*) continue ;; esac
        [ "${repo_path:0:1}" = '#' ] && continue
        [ "${status:-}" = "canonical" ] || continue
        # Only check files from reference/runtime/
        case "$repo_path" in
          reference/runtime/*) ;;
          *) continue ;;
        esac
        fname=$(basename "$repo_path")
        if [ ! -f "$EXTRACT_DIR/$fname" ]; then
          printf '    MISSING from tarball: %s (from %s)\n' "$fname" "$repo_path"
          t2_miss=$((t2_miss+1))
        fi
      done < "$MANIFEST"
      if [ "$t2_miss" -eq 0 ]; then
        ok "all reference/runtime/ canonical entries present in tarball"
      else
        no "$t2_miss reference/runtime/ file(s) missing from tarball"
      fi
    fi
    rm -rf "$EXTRACT_DIR"
  fi
fi

# ---------------------------------------------------------------------------
# Test 3: no $HOME/cbnet or ~/cbnet references as build sources in provision scripts
# ---------------------------------------------------------------------------
echo "=== Test 3: no \$HOME/cbnet or ~/cbnet references in build-provision.sh ==="

if [ ! -f "$BUILD_SCRIPT" ]; then
  no "build-provision.sh not found: $BUILD_SCRIPT"
else
  t3_fail=0
  # Check for literal $HOME/cbnet or ~/cbnet in non-comment lines (awk skips comment lines)
  matches=$(awk '!/^[[:space:]]*#/ && (/\$HOME\/cbnet/ || /~\/cbnet/) {print NR": "$0}' "$BUILD_SCRIPT" || true)
  if [ -n "$matches" ]; then
    printf '    FOUND external source reference(s) in non-comment lines:\n'
    printf '%s\n' "$matches" | while IFS= read -r m; do printf '      %s\n' "$m"; done
    t3_fail=1
  fi
  if [ "$t3_fail" -eq 0 ]; then
    ok "build-provision.sh: no \$HOME/cbnet or ~/cbnet in executable lines (all paths are repo-relative)"
  else
    no "build-provision.sh still references \$HOME/cbnet or ~/cbnet in non-comment lines"
  fi
fi

# ---------------------------------------------------------------------------
echo
printf '=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
