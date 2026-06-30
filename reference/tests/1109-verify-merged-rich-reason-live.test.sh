#!/usr/bin/env bash
# 1109-verify-merged-rich-reason-live.test.sh — charter #1048 / issue #1109.
#
# LIVE tier (charter Acceptance: "проверено на реальном RED-листе").  This is NOT a
# mock: it drives the REAL cmd_verify_merged against a REAL bare git remote, runs an
# ACTUAL failing engine-test PROCESS whose assertion is written to STDERR (the current
# integrator does `bash "$t" >/dev/null 2>&1`, discarding stderr — so the impl leaf
# MUST capture stderr for this to surface), and HARD-asserts the assertion text
# reaches the printed `RED_REASON:` line and the persisted `${cache}.reason`.
#
# RED now (assertion discarded -> basename-only). GREEN once the impl leaf captures &
# truncates the failing test's stderr into the per-test reason.
#
# Guard: requires real `git`. If git is unavailable the live tier SKIPs (exit 0) — a
# constrained sandbox must not produce a false failure for an environmental gap.
# When git IS present (the box / CI default) the tier runs and the assertions are
# HARD (no skip-on-detail-absent escape hatch — that is the whole point of "live").
#
# Drives cmd_verify_merged (recursive verify-merged) -> EXCLUDED in per-leaf-manifest.
#
# Fixture-creation pattern: temp-name then mv (no redirect onto test-file paths, #523).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
INTEGRATOR="${INTEGRATOR_OVERRIDE:-$HERE/../runtime/crewboss-integrator.sh}"

pass=0; fail=0
ok() { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko() { fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }
skip() { printf 'skip %s\n' "$1"; }

if ! command -v git >/dev/null 2>&1; then
  skip "live: git unavailable — skipping real RED-list tier (environmental)"
  printf 'passed=%d failed=%d\n' "$pass" "$fail"
  exit 0
fi

# Realistic, distinctive assertion emitted to STDERR by the real failing process.
LIVE_ASSERT="FAIL Pin-7 -- expected 'gh pr create --base charter/1048' in prompt, got none"
LIVE_TOKEN="Pin-7"

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

REMOTE="$ROOT/live.git"
CACHE="$ROOT/cache"
git init --bare -q "$REMOTE"
TMP="$(mktemp -d)"
git clone -q "$REMOTE" "$TMP" 2>/dev/null
git -C "$TMP" config user.email t@t
git -C "$TMP" config user.name T

mkdir -p "$TMP/reference/bin" "$TMP/reference/tests"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/reference/bin/regen-manifest.sh"
chmod +x "$TMP/reference/bin/regen-manifest.sh"

# Real failing engine test: writes the assertion to STDERR (the discarded stream),
# emits a small diagnostic to stdout too, then exits 1. ALLOW basename so the
# per-leaf filter actually runs it.
LT="$(mktemp)"
{
  printf '#!/usr/bin/env bash\n'
  printf 'echo "running role-spawn pin checks..."\n'
  printf 'printf "%%s\\n" "%s" >&2\n' "$LIVE_ASSERT"
  printf 'exit 1\n'
} > "$LT"
mv "$LT" "$TMP/reference/tests/role-spawn.test.sh"
chmod +x "$TMP/reference/tests/role-spawn.test.sh"

printf 'base\n' > "$TMP/README.md"
git -C "$TMP" add -A
git -C "$TMP" commit -qm base 2>/dev/null
git -C "$TMP" push -q origin "HEAD:refs/heads/charter/1048" 2>/dev/null
printf 'leaf\n' > "$TMP/leaf.txt"
git -C "$TMP" add -A
git -C "$TMP" commit -qm leaf 2>/dev/null
git -C "$TMP" push -q origin "HEAD:refs/heads/leaf/1109" 2>/dev/null
rm -rf "$TMP"

# Run the REAL verify-merged; confirm RED on the first round (N=1).
rc=0
out="$(CB_VERIFY_CACHE="$CACHE" CB_VERIFY_CONFIRM_N=1 \
  bash "$INTEGRATOR" verify-merged leaf/1109 charter/1048 --remote "$REMOTE" 2>/dev/null)" || rc=$?

[ "$rc" -eq 1 ] \
  && ok "live: real induced RED confirmed -> exit 1" \
  || ko "live: expected exit 1 from real verify-merged, got $rc"

rr="$(printf '%s\n' "$out" | sed -n 's/^RED_REASON: //p' | head -1)"

# Backwards-compat: basename present.
printf '%s' "$rr" | /usr/bin/grep -q 'role-spawn' \
  && ok "live: RED_REASON preserves basename (role-spawn)" \
  || ko "live: RED_REASON lost basename (got: $rr)"

# HARD live assertion: the real process's STDERR assertion surfaces in RED_REASON.
printf '%s' "$rr" | /usr/bin/grep -qE "FAIL|$LIVE_TOKEN" \
  && ok "live: real STDERR assertion surfaces in RED_REASON" \
  || ko "live: assertion text from real RED process NOT surfaced (got: $rr)"

# And in the persisted cache .reason.
rf="$(ls "$CACHE"/*.reason 2>/dev/null | head -1)"
if [ -n "$rf" ] && [ -f "$rf" ]; then
  /usr/bin/grep -qE "FAIL|$LIVE_TOKEN" "$rf" \
    && ok "live: cache .reason carries the real assertion text" \
    || ko "live: cache .reason missing real assertion ($(cat "$rf"))"
else
  ko "live: cache .reason file not written"
fi

printf '\npassed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
