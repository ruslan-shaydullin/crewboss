#!/usr/bin/env bash
# test-lint.sh — anti-pattern linter for .test.sh files (Stage 3 of test-quality gate)
#
# Usage:
#   test-lint.sh <file> [<file> ...]
#   test-lint.sh --dir <dir>        # scan all *.test.sh under dir
#
# Exit codes:
#   0 — no anti-patterns found (lint clean)
#   1 — one or more anti-patterns found; findings printed to stdout
#   2 — usage error
#
# Routing signal when anti-patterns found: status:test-broken
# The gate (run-test-quality-gate.sh) applies status:test-broken to the
# qa-engineer leaf issue when this linter exits non-zero.
#
# Anti-patterns detected:
#   A. grep -c ... || echo 0
#      grep -c exits 1 on no-match; the || silences it but "0\n" output from
#      echo can cause integer-context errors when count spans multiple lines.
#      Fix: use count=$(grep -c "pattern" file 2>/dev/null); count=${count:-0}
#
#   B. BIN (or similar vars) used in PATH but not exported
#      Background subshells inherit only exported variables. If BIN is set but
#      not exported before PATH is constructed from it, stubs silently disappear
#      from child processes (near-miss on #522: BIN not exported → stub failed).
#      Fix: add `export BIN` before constructing PATH from $BIN.
#
#   C. flock calls in determinism-sensitive paths
#      flock is a noop on some filesystems (e.g. NFS, overlayfs) and can cause
#      races in parallel test runs if lock acquisition silently succeeds without
#      mutual exclusion. Flag any flock usage for review.

set -uo pipefail

# ── Usage / argument parsing ─────────────────────────────────────────────────
_files=()
_scan_dir=""

if [ $# -eq 0 ]; then
  echo "test-lint.sh: no input specified" >&2
  echo "Usage: test-lint.sh <file> [<file> ...] | --dir <dir>" >&2
  exit 2
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) _scan_dir="$2"; shift 2 ;;
    -*)    echo "test-lint.sh: unknown option: $1" >&2; exit 2 ;;
    *)     _files+=("$1"); shift ;;
  esac
done

if [ -n "$_scan_dir" ]; then
  if [ ! -d "$_scan_dir" ]; then
    echo "test-lint.sh: directory not found: $_scan_dir" >&2
    exit 2
  fi
  while IFS= read -r -d '' _f; do
    _files+=("$_f")
  done < <(find "$_scan_dir" -name "*.test.sh" -print0 2>/dev/null)
fi

if [ ${#_files[@]} -eq 0 ]; then
  echo "test-lint.sh: no .test.sh files to lint" >&2
  exit 0
fi

# ── Lint each file ────────────────────────────────────────────────────────────
_total_findings=0

lint_file() {
  local _f="$1"
  local _findings=0

  if [ ! -f "$_f" ]; then
    echo "[test-lint] ERROR: file not found: $_f" >&2
    return 1
  fi

  local _base
  _base="$(basename "$_f")"

  # Anti-pattern A: grep -c ... || echo 0
  #   Matches: grep -c <args> || echo 0
  #   The '|| echo 0' silences the grep exit-1-on-no-match but the string "0"
  #   can cause integer errors when used in arithmetic context with multi-line
  #   output.  Fix: use ${var:-0} or 2>/dev/null with an explicit default.
  if grep -qE 'grep[[:space:]]+-c[[:space:]].*\|\|[[:space:]]*echo[[:space:]]+0' "$_f" 2>/dev/null; then
    echo "[stage3] FAIL: anti-pattern A (grep -c ... || echo 0) in ${_base}"
    echo "  routing: status:test-broken"
    echo "  fix: replace with: count=\$(grep -c \"pattern\" file 2>/dev/null); count=\${count:-0}"
    _findings=$((_findings+1))
  fi

  # Anti-pattern B: PATH uses \$BIN (or similar) but BIN is not exported
  #   Background subshells (started with & or $(...) or process substitution)
  #   only inherit exported variables.  If BIN is assigned but not exported,
  #   PATH in the child may silently drop the stub directory.
  if grep -qE 'PATH=.*\$BIN' "$_f" 2>/dev/null && \
     ! grep -qE '^[[:space:]]*(export[[:space:]]+BIN|export[[:space:]]+.*\bBIN\b)' "$_f" 2>/dev/null; then
    echo "[stage3] FAIL: anti-pattern B (PATH uses \$BIN but BIN not exported) in ${_base}"
    echo "  routing: status:test-broken"
    echo "  fix: add 'export BIN' before using \$BIN in PATH"
    _findings=$((_findings+1))
  fi

  # Anti-pattern C: flock usage (flag for review — may be noop on some FSes)
  if grep -qE '[[:space:]]flock[[:space:]]' "$_f" 2>/dev/null; then
    echo "[stage3] FAIL: anti-pattern C (flock call — may be noop on NFS/overlayfs) in ${_base}"
    echo "  routing: status:test-broken"
    echo "  fix: remove flock or document that the test does not depend on its exclusivity"
    _findings=$((_findings+1))
  fi

  if [ "$_findings" -eq 0 ]; then
    echo "[stage3] PASS: ${_base} — no anti-patterns found"
  fi

  return "$_findings"
}

for _file in "${_files[@]}"; do
  lint_file "$_file" || _total_findings=$((_total_findings + $?))
done

if [ "$_total_findings" -gt 0 ]; then
  exit 1
fi

exit 0
