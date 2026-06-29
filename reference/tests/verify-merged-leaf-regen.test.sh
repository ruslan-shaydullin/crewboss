#!/usr/bin/env bash
# verify-merged-leaf-regen.test.sh — #909 fixes: sha-drift regen guard + redcount
# accumulation across base_sha rotation.
#
# T1: sha-drift + regen succeeds → exit 0  (regen fixes stale TSV; test passes)
# T2: sha-drift + regen exits 1  → exit 2  (Part A: failed regen = infra, not red)
# T3: genuine red + 2 rounds with base_sha rotation → exit 3 then exit 1
#     (Part B: redcount keyed on leaf_sha only; accumulates despite base_sha rotation)
# T4: genuine red + 3 rounds (no rotation) → exit 3, exit 3, exit 1
#     (N-confirmation counter increments each call until >= CB_VERIFY_CONFIRM_N)
#
# Fixture-creation pattern: write test scripts to a temp name then mv — avoids
# shell redirections directly naming test-file paths.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
INTEGRATOR="${INTEGRATOR_OVERRIDE:-$HERE/../runtime/crewboss-integrator.sh}"
REGEN_TOOL="$HERE/../bin/regen-manifest.sh"

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

pass=0; fail=0
ok() { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko() { fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

# ── seed_drift_remote ──────────────────────────────────────────────────────────
# Creates a bare remote whose merged tree has sha-drift (stale runtime-manifest.tsv)
# plus a fixture runtime-manifest.test.sh (ALLOW in the real per-leaf-manifest).
# regen_rc=0: installs real regen-manifest.sh (will fix the stale sha → test green)
# regen_rc=1: installs a stub that exits 1 (mktemp failure sim; Part A → exit 2)
seed_drift_remote() {
  local remote="$1" regen_rc="${2:-0}"
  rm -rf "$remote"
  git init --bare -q "$remote"
  local tmp; tmp="$(mktemp -d)"
  git clone -q "$remote" "$tmp" 2>/dev/null
  git -C "$tmp" config user.email t@t
  git -C "$tmp" config user.name T

  mkdir -p "$tmp/reference/runtime" "$tmp/reference/bin"
  mkdir -p "$tmp/reference/runtime"
  printf 'echo hello world\n' > "$tmp/reference/runtime/sample.sh"

  printf '# fixture runtime-manifest\n' > "$tmp/reference/runtime-manifest.tsv"
  printf 'reference/runtime/sample.sh\t%s\tcanonical\tsample\n' \
    '0000000000000000000000000000000000000000000000000000000000000000' \
    >> "$tmp/reference/runtime-manifest.tsv"

  if [ "$regen_rc" -eq 0 ]; then
    cp "$REGEN_TOOL" "$tmp/reference/bin/regen-manifest.sh"
  else
    printf '#!/usr/bin/env bash\nexit 1\n' > "$tmp/reference/bin/regen-manifest.sh"
  fi
  chmod +x "$tmp/reference/bin/regen-manifest.sh"

  mkdir -p "$tmp/reference"
  mkdir -p "$tmp/reference/tests"
  local _ts; _ts="$tmp/_rm_fixture.sh"
  printf '#!/usr/bin/env bash\n' > "$_ts"
  printf 'HERE="$(cd "$(dirname "$0")" && pwd)"\n' >> "$_ts"
  printf 'REPO="$(cd "$HERE/../.." && pwd)"\n' >> "$_ts"
  printf 'M="$HERE/../runtime-manifest.tsv"\n' >> "$_ts"
  printf '[ -f "$M" ] || exit 1\n' >> "$_ts"
  printf 'p=0; f=0\n' >> "$_ts"
  printf 'while IFS=$(printf "\\t") read -r rp sha st _x; do\n' >> "$_ts"
  printf '  case "$rp" in "#"*|"") continue ;; esac\n' >> "$_ts"
  printf '  [ "$st" = "canonical" ] || continue\n' >> "$_ts"
  printf '  [ -f "$REPO/$rp" ] || { f=$((f+1)); continue; }\n' >> "$_ts"
  printf '  a=$(sha256sum "$REPO/$rp" | cut -d" " -f1)\n' >> "$_ts"
  printf '  [ "$a" = "$sha" ] && p=$((p+1)) || f=$((f+1))\n' >> "$_ts"
  printf 'done < "$M"\n' >> "$_ts"
  printf '[ "$p" -gt 0 ] && [ "$f" -eq 0 ]\n' >> "$_ts"
  mv "$_ts" "$tmp/reference/tests/runtime-manifest.test.sh"
  chmod +x "$tmp/reference/tests/runtime-manifest.test.sh"

  printf 'base\n' > "$tmp/README.md"
  git -C "$tmp" add -A
  git -C "$tmp" commit -qm "base" 2>/dev/null
  git -C "$tmp" push -q origin "HEAD:refs/heads/charter/5" 2>/dev/null
  printf 'leaf change\n' > "$tmp/leaf.txt"
  git -C "$tmp" add -A
  git -C "$tmp" commit -qm "leaf" 2>/dev/null
  git -C "$tmp" push -q origin "HEAD:refs/heads/leaf/42" 2>/dev/null
  rm -rf "$tmp"
}

# ── seed_fail_remote ──────────────────────────────────────────────────────────
# Creates a bare remote whose merged tree has a genuinely-failing test
# (acceptance-block exits 1) plus a no-op regen stub (exits 0) so that
# Part A's absent-regen guard does NOT fire before the red path runs.
seed_fail_remote() {
  local remote="$1"
  rm -rf "$remote"
  git init --bare -q "$remote"
  local tmp; tmp="$(mktemp -d)"
  git clone -q "$remote" "$tmp" 2>/dev/null
  git -C "$tmp" config user.email t@t
  git -C "$tmp" config user.name T

  mkdir -p "$tmp/reference/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/reference/bin/regen-manifest.sh"
  chmod +x "$tmp/reference/bin/regen-manifest.sh"

  mkdir -p "$tmp/reference"
  mkdir -p "$tmp/reference/tests"
  local _ts; _ts="$tmp/_ab.sh"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$_ts"
  mv "$_ts" "$tmp/reference/tests/acceptance-block.test.sh"
  chmod +x "$tmp/reference/tests/acceptance-block.test.sh"

  printf 'base\n' > "$tmp/README.md"
  git -C "$tmp" add -A
  git -C "$tmp" commit -qm "base" 2>/dev/null
  git -C "$tmp" push -q origin "HEAD:refs/heads/charter/5" 2>/dev/null
  printf 'leaf change\n' > "$tmp/leaf.txt"
  git -C "$tmp" add -A
  git -C "$tmp" commit -qm "leaf" 2>/dev/null
  git -C "$tmp" push -q origin "HEAD:refs/heads/leaf/42" 2>/dev/null
  rm -rf "$tmp"
}

# ── advance_target ────────────────────────────────────────────────────────────
# Pushes a no-op commit to charter/5 to rotate base_sha (simulates a sibling
# leaf merging into charter/C between verify-merged calls).
advance_target() {
  local remote="$1"
  local tmp; tmp="$(mktemp -d)"
  git clone -q "$remote" "$tmp" 2>/dev/null
  git -C "$tmp" config user.email t@t
  git -C "$tmp" config user.name T
  git -C "$tmp" checkout -q charter/5 2>/dev/null || \
    git -C "$tmp" checkout -q -b charter/5 origin/charter/5 2>/dev/null
  printf 'noop\n' > "$tmp/noop-advance.txt"
  git -C "$tmp" add -A
  git -C "$tmp" commit -qm "noop: advance base_sha" 2>/dev/null
  git -C "$tmp" push -q origin "HEAD:refs/heads/charter/5" 2>/dev/null
  rm -rf "$tmp"
}

# ==============================================================================
# T1: sha-drift + regen success → exit 0
# ==============================================================================
echo "=== T1: sha-drift + regen success → exit 0 ==="
REMOTE1="$ROOT/remote1.git"
CACHE1="$ROOT/cache1"
seed_drift_remote "$REMOTE1" 0

rc1=0
CB_VERIFY_CACHE="$CACHE1" bash "$INTEGRATOR" verify-merged leaf/42 charter/5 \
  --remote "$REMOTE1" 2>/dev/null || rc1=$?
[ "$rc1" -eq 0 ] \
  && ok "T1: sha-drift regen success → exit 0 (regen fixed stale TSV sha)" \
  || ko "T1: expected exit 0 after regen, got $rc1"

# ==============================================================================
# T2: sha-drift + regen exits 1 → exit 2 (Part A infra classification)
# ==============================================================================
echo "=== T2: sha-drift + regen exits 1 → exit 2 (infra) ==="
REMOTE2="$ROOT/remote2.git"
CACHE2="$ROOT/cache2"
seed_drift_remote "$REMOTE2" 1

rc2=0
CB_VERIFY_CACHE="$CACHE2" bash "$INTEGRATOR" verify-merged leaf/42 charter/5 \
  --remote "$REMOTE2" 2>/dev/null || rc2=$?
[ "$rc2" -eq 2 ] \
  && ok "T2: regen exits 1 → exit 2 (Part A: failed regen = infra, not test red)" \
  || ko "T2: expected exit 2, got $rc2"

# ==============================================================================
# T3: genuine red + base_sha rotation (Part B: redcount accumulates)
#   Round 1: exit 3 (1/2 — retryable)
#   advance_target rotates base_sha
#   Round 2: exit 1 (2/2 — confirmed; redcount accumulated despite base_sha change)
# ==============================================================================
echo "=== T3: genuine red + base_sha rotation → exit 3 then exit 1 ==="
REMOTE3="$ROOT/remote3.git"
CACHE3="$ROOT/cache3"
seed_fail_remote "$REMOTE3"

rc3a=0
CB_VERIFY_CACHE="$CACHE3" CB_VERIFY_CONFIRM_N=2 bash "$INTEGRATOR" \
  verify-merged leaf/42 charter/5 --remote "$REMOTE3" 2>/dev/null || rc3a=$?
[ "$rc3a" -eq 3 ] \
  && ok "T3-round1: exit 3 (retryable, 1/2)" \
  || ko "T3-round1: expected exit 3, got $rc3a"

advance_target "$REMOTE3"

rc3b=0
CB_VERIFY_CACHE="$CACHE3" CB_VERIFY_CONFIRM_N=2 bash "$INTEGRATOR" \
  verify-merged leaf/42 charter/5 --remote "$REMOTE3" 2>/dev/null || rc3b=$?
[ "$rc3b" -eq 1 ] \
  && ok "T3-round2: exit 1 (confirmed red 2/2 — redcount accumulated across base_sha rotation)" \
  || ko "T3-round2: expected exit 1 (confirmed), got $rc3b"

# ==============================================================================
# T4: genuine red + 3 rounds (no rotation) → exit 3, exit 3, exit 1
# ==============================================================================
echo "=== T4: genuine red + 3 rounds (no rotation) → exit 3, exit 3, exit 1 ==="
REMOTE4="$ROOT/remote4.git"
CACHE4="$ROOT/cache4"
seed_fail_remote "$REMOTE4"

rc4a=0
CB_VERIFY_CACHE="$CACHE4" CB_VERIFY_CONFIRM_N=3 bash "$INTEGRATOR" \
  verify-merged leaf/42 charter/5 --remote "$REMOTE4" 2>/dev/null || rc4a=$?
[ "$rc4a" -eq 3 ] \
  && ok "T4-round1: exit 3 (retryable, 1/3)" \
  || ko "T4-round1: expected exit 3, got $rc4a"

rc4b=0
CB_VERIFY_CACHE="$CACHE4" CB_VERIFY_CONFIRM_N=3 bash "$INTEGRATOR" \
  verify-merged leaf/42 charter/5 --remote "$REMOTE4" 2>/dev/null || rc4b=$?
[ "$rc4b" -eq 3 ] \
  && ok "T4-round2: exit 3 (retryable, 2/3)" \
  || ko "T4-round2: expected exit 3, got $rc4b"

rc4c=0
CB_VERIFY_CACHE="$CACHE4" CB_VERIFY_CONFIRM_N=3 bash "$INTEGRATOR" \
  verify-merged leaf/42 charter/5 --remote "$REMOTE4" 2>/dev/null || rc4c=$?
[ "$rc4c" -eq 1 ] \
  && ok "T4-round3: exit 1 (confirmed red 3/3)" \
  || ko "T4-round3: expected exit 1, got $rc4c"

# ==============================================================================
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
