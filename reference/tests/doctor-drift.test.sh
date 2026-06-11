#!/usr/bin/env bash
#
# doctor-drift.test.sh — smoke tests for crewboss-doctor.sh drift detection
#                        (issue #69, class d — smoke with fixture)
#
# Creates a fixture "box" directory (mktemp) containing a mini
# runtime-manifest.tsv and a handful of tracked files.  Exercises three
# scenarios:
#
#   (a) all files match manifest sha256      → doctor exit 0
#   (b) one file is tampered (sha mismatch)  → exit ≠ 0 + file name in output
#   (c) file absent + extra untracked file   → exit ≠ 0 + both names in output
#
# RED now:  reference/runtime/crewboss-doctor.sh performs no drift-check at
#           all (it does not read the manifest).
# GREEN after: drift-check implemented in reference/runtime/crewboss-doctor.sh.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DOCTOR="$HERE/../runtime/crewboss-doctor.sh"

pass=0; fail=0
ok() { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

# ── pre-flight ─────────────────────────────────────────────────────────────────
if [ ! -f "$DOCTOR" ]; then
  printf 'SKIP: crewboss-doctor.sh not found at %s\n' "$DOCTOR"
  printf '=== SUMMARY: 0 passed, 1 failed ===\n'
  exit 1
fi

# ── fixture setup ──────────────────────────────────────────────────────────────
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT

# Create three tracked test files with deterministic content
printf 'content-alpha\n' > "$FIXTURE/alpha.sh"
printf 'content-beta\n'  > "$FIXTURE/beta.py"
printf 'content-gamma\n' > "$FIXTURE/gamma.sh"

SHA_ALPHA="$(sha256sum "$FIXTURE/alpha.sh" | awk '{print $1}')"
SHA_BETA="$(sha256sum  "$FIXTURE/beta.py"  | awk '{print $1}')"
SHA_GAMMA="$(sha256sum "$FIXTURE/gamma.sh" | awk '{print $1}')"

# Mini manifest (tab-separated: repo_path <TAB> sha256 <TAB> status <TAB> purpose)
# The doctor uses basenames of repo_path for lookups inside CB_HOME.
{
  printf '# test mini-manifest for doctor-drift.test.sh\n'
  printf '# repo_path\tsha256\tstatus\tpurpose\n'
  printf 'test/alpha.sh\t%s\tcanonical\ttest file alpha\n' "$SHA_ALPHA"
  printf 'test/beta.py\t%s\tcanonical\ttest file beta\n'  "$SHA_BETA"
  printf 'test/gamma.sh\t%s\tcanonical\ttest file gamma\n' "$SHA_GAMMA"
} > "$FIXTURE/runtime-manifest.tsv"

# ===========================================================================
echo "=== Scenario (a): all files match → doctor exit 0 ==="

out_a="$(CB_HOME="$FIXTURE" bash "$DOCTOR" 2>&1)"
rc_a=$?

if [ "$rc_a" -eq 0 ]; then
  ok "doctor exits 0 when all files match manifest"
else
  no "doctor exited $rc_a (expected 0) — output: $out_a"
fi

# ===========================================================================
echo "=== Scenario (b): one file tampered (sha mismatch) → exit ≠ 0 + name in output ==="

# Overwrite beta.py so its sha256 no longer matches the manifest entry
printf 'TAMPERED content — different from original\n' > "$FIXTURE/beta.py"

out_b="$(CB_HOME="$FIXTURE" bash "$DOCTOR" 2>&1)"
rc_b=$?

if [ "$rc_b" -ne 0 ]; then
  ok "doctor exits non-zero when a file sha mismatches"
else
  no "doctor exited 0 (expected non-zero) — should have detected sha mismatch"
fi

if printf '%s\n' "$out_b" | grep -q 'beta\.py'; then
  ok "doctor output contains the mismatched file name (beta.py)"
else
  no "doctor output does NOT mention 'beta.py' — output: $out_b"
fi

# Restore beta.py for subsequent scenarios
printf 'content-beta\n' > "$FIXTURE/beta.py"

# ===========================================================================
echo "=== Scenario (c): file absent + extra untracked file → exit ≠ 0 + both names in output ==="

# Remove alpha.sh (absent from box)
rm "$FIXTURE/alpha.sh"
# Add extra.sh (not in manifest — untracked deployment artifact)
printf 'extra untracked content\n' > "$FIXTURE/extra.sh"

out_c="$(CB_HOME="$FIXTURE" bash "$DOCTOR" 2>&1)"
rc_c=$?

if [ "$rc_c" -ne 0 ]; then
  ok "doctor exits non-zero when file absent + extra file present"
else
  no "doctor exited 0 (expected non-zero) — should detect absent/extra"
fi

if printf '%s\n' "$out_c" | grep -q 'alpha\.sh'; then
  ok "doctor output contains absent file name (alpha.sh)"
else
  no "doctor output does NOT mention 'alpha.sh' — output: $out_c"
fi

if printf '%s\n' "$out_c" | grep -q 'extra\.sh'; then
  ok "doctor output contains extra file name (extra.sh)"
else
  no "doctor output does NOT mention 'extra.sh' — output: $out_c"
fi

# ===========================================================================
echo
printf '=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
