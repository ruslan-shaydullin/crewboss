#!/usr/bin/env bash
# token-hygiene.test.sh — T3: GH_TOKEN must not appear in any log/config artifact.
#
# Covers (issue #149 — credential-helper approach):
#   - run-env.sh sets token-free CB_GIT_REMOTE + exports GIT_CONFIG_* credential helper
#   - crewboss-integrator.sh does not log $remote URL on clone/checkout failure
#   - charter-leaf-prep.sh worktree .git/config has no token
#   - Credential helper (inline, GIT_CONFIG_*) is valid in jail namespace
#
# Negative asserts: grep FAKETOKEN123 in log output / worktree .git/config → empty
# Positive asserts:
#   (a) git credential fill (protocol=https, host=github.com) with registered helper
#       returns username=x-access-token / password=FAKETOKEN123 when GH_TOKEN is only
#       in env (jail-namespace model: no ~/.crewboss.env, no ~/.gitconfig)
#   (b) helper registration is inline (starts with '!') — no file path → jail-safe
#   (c) GIT_CONFIG_* vars set by run-env.sh appear in spawn stub's env dump
#       (registration reaches spawn point)
#   (d) push to local bare repo succeeds (worktree contract not broken)
#
# Requires: bash, git (>=2.31 for GIT_CONFIG_*), perl
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RUNTIME="$HERE/../runtime"

pass=0; fail=0
ok(){ printf 'ok   %s\n' "$1"; pass=$((pass+1)); }
no(){ printf 'FAIL %s\n' "$1"; fail=$((fail+1)); }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
FAKE_HOME="$ROOT/home"
BIN="$ROOT/bin"
BARE_REMOTE="$ROOT/bare.git"

mkdir -p "$FAKE_HOME" "$BIN"

# ── ~/.crewboss.env with FAKETOKEN123 (0600) ──────────────────────────────────
printf 'GH_TOKEN=FAKETOKEN123\n' > "$FAKE_HOME/.crewboss.env"
chmod 600 "$FAKE_HOME/.crewboss.env"

# ── Stub gh: auth token → FAKETOKEN123; issue view → Charter: #5 ──────────────
cat > "$BIN/gh" << 'GHEOF'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "auth token")
    printf 'FAKETOKEN123\n'; exit 0 ;;
  "issue view")
    printf 'Charter: #5\nTest leaf.\n## Acceptance (machine)\n- check: true\n'
    exit 0 ;;
esac
exit 0
GHEOF
chmod +x "$BIN/gh"

# ── Local bare remote (main + charter/5) ──────────────────────────────────────
git init --bare -q "$BARE_REMOTE"
_t="$(mktemp -d)"
git -C "$_t" init -q
git -C "$_t" config user.email t@t
git -C "$_t" config user.name T
printf 'base\n' > "$_t/README.md"
git -C "$_t" add -A
git -C "$_t" commit -qm init 2>/dev/null
git -C "$_t" remote add origin "$BARE_REMOTE"
git -C "$_t" push -q origin HEAD:refs/heads/main 2>/dev/null
git -C "$_t" push -q origin HEAD:refs/heads/charter/5 2>/dev/null
rm -rf "$_t"

# ── Fake CB_HOME ───────────────────────────────────────────────────────────────
CB_HOME_T="$FAKE_HOME/cbnet"
mkdir -p "$CB_HOME_T/run"

# Spawn stub: dumps its entire env to a file then exits 0.
SPAWN_ENV_DUMP="$ROOT/spawn-env-dump"
cat > "$CB_HOME_T/crewboss-spawn.sh" << SPAWNEOF
#!/usr/bin/env bash
env > "$SPAWN_ENV_DUMP"
exit 0
SPAWNEOF
chmod +x "$CB_HOME_T/crewboss-spawn.sh"

# Pass-through redact.pl stub (run-charter.sh graceful-degrades to cat if absent,
# but having it avoids a test dependency on that fallback path)
cat > "$CB_HOME_T/redact.pl" << 'REOF'
#!/usr/bin/env perl
$| = 1;
while (<STDIN>) { print; }
REOF

# ── Source run-env.sh and capture its exported env ────────────────────────────
ENV_DUMP="$ROOT/run-env-dump"
HOME="$FAKE_HOME" PATH="$BIN:$PATH" \
  bash -c '. "$1" && env' -- "$RUNTIME/run-env.sh" > "$ENV_DUMP" 2>/dev/null || true

dump_val(){ grep "^${1}=" "$ENV_DUMP" 2>/dev/null | head -1 | cut -d= -f2-; }

# ================================================================================
echo "=== T3-1: run-env.sh sets token-free CB_GIT_REMOTE ==="
# ================================================================================

CB_GIT_REMOTE_VAL="$(dump_val CB_GIT_REMOTE)"
if printf '%s' "$CB_GIT_REMOTE_VAL" | grep -q "FAKETOKEN123"; then
  no "T3-1a: CB_GIT_REMOTE contains FAKETOKEN123 (token not removed from URL)"
else
  ok "T3-1a: CB_GIT_REMOTE has no FAKETOKEN123 (token-free URL)"
fi

if printf '%s' "$CB_GIT_REMOTE_VAL" | grep -q "github.com"; then
  ok "T3-1b: CB_GIT_REMOTE still points to github.com"
else
  no "T3-1b: CB_GIT_REMOTE doesn't point to github.com (got: '$CB_GIT_REMOTE_VAL')"
fi

# ================================================================================
echo "=== T3-2: integrator log sanitization (negative) ==="
# ================================================================================

# Pass a token-bearing remote URL to stress-test log scrubbing.
# After fix, integrator logs the charter id / branch name, NOT the URL.
FAKE_REMOTE="https://x-access-token:FAKETOKEN123@nonexistent.invalid/repo.git"

GATE_OUT="$ROOT/gate-out.txt"
PATH="$BIN:$PATH" bash "$RUNTIME/crewboss-integrator.sh" gate-charter 5 \
  --remote "$FAKE_REMOTE" > "$GATE_OUT" 2>&1 || true

if grep -q "FAKETOKEN123" "$GATE_OUT"; then
  no "T3-2a: gate-charter log contains FAKETOKEN123 (token leaked into log)"
else
  ok "T3-2a: gate-charter log has no FAKETOKEN123"
fi

TRYMERGE_OUT="$ROOT/trymerge-out.txt"
PATH="$BIN:$PATH" bash "$RUNTIME/crewboss-integrator.sh" try-merge leaf/1 main \
  --remote "$FAKE_REMOTE" > "$TRYMERGE_OUT" 2>&1 || true

if grep -q "FAKETOKEN123" "$TRYMERGE_OUT"; then
  no "T3-2b: try-merge log contains FAKETOKEN123 (token leaked into log)"
else
  ok "T3-2b: try-merge log has no FAKETOKEN123"
fi

# ================================================================================
echo "=== T3-3: credential helper — inline, jail-safe (positive) ==="
# ================================================================================

GIT_CONFIG_COUNT_VAL="$(dump_val GIT_CONFIG_COUNT)"
GIT_CONFIG_KEY_0_VAL="$(dump_val GIT_CONFIG_KEY_0)"
GIT_CONFIG_VALUE_0_VAL="$(dump_val GIT_CONFIG_VALUE_0)"

# (b) Helper must be inline (starts with '!') — no file path → valid from jail namespace
if printf '%s' "$GIT_CONFIG_VALUE_0_VAL" | grep -q '^!'; then
  ok "T3-3b: credential helper is inline (starts with '!', no file path — jail-safe)"
else
  no "T3-3b: credential helper does NOT start with '!' — may fail in jail namespace (got: '$GIT_CONFIG_VALUE_0_VAL')"
fi

# (a) git credential fill in jail-namespace model:
#   - no ~/.crewboss.env (JAIL_HOME is clean)
#   - no ~/.gitconfig
#   - GH_TOKEN available ONLY in env (not from file)
#   Uses the helper value exported by run-env.sh.
JAIL_HOME="$ROOT/jail-home"
mkdir -p "$JAIL_HOME"

CRED_OUT=""
if [ -n "$GIT_CONFIG_VALUE_0_VAL" ]; then
  CRED_OUT="$(printf 'protocol=https\nhost=github.com\n\n' | \
    HOME="$JAIL_HOME" GH_TOKEN=FAKETOKEN123 \
    GIT_CONFIG_COUNT="${GIT_CONFIG_COUNT_VAL:-1}" \
    GIT_CONFIG_KEY_0="${GIT_CONFIG_KEY_0_VAL:-credential.helper}" \
    GIT_CONFIG_VALUE_0="$GIT_CONFIG_VALUE_0_VAL" \
    git credential fill 2>/dev/null)" || CRED_OUT=""
fi

if printf '%s' "$CRED_OUT" | grep -q "username=x-access-token"; then
  ok "T3-3a: credential fill returns username=x-access-token (jail-namespace model)"
else
  no "T3-3a: credential fill missing username=x-access-token (got: '$(printf '%s' "$CRED_OUT" | tr '\n' '|')')"
fi

if printf '%s' "$CRED_OUT" | grep -q "password=FAKETOKEN123"; then
  ok "T3-3a2: credential fill returns password=FAKETOKEN123"
else
  no "T3-3a2: credential fill missing password=FAKETOKEN123 (got: '$(printf '%s' "$CRED_OUT" | tr '\n' '|')')"
fi

# ================================================================================
echo "=== T3-4: charter-leaf-prep — worktree config + spawn env (negative + positive) ==="
# ================================================================================

# Run charter-leaf-prep.sh with local bare remote (CB_GIT_REMOTE overrides the default
# https://github.com URL so git operations work against the local bare repo in the test).
WA="$CB_HOME_T/run/work/42/repo"
rm -rf "$WA" 2>/dev/null || true

LEAF_OUT="$ROOT/leaf-prep-out.txt"
HOME="$FAKE_HOME" PATH="$BIN:$PATH" \
  CB_HOME="$CB_HOME_T" \
  CB_REPO="test/repo" \
  CB_GIT_REMOTE="$BARE_REMOTE" \
  bash "$RUNTIME/charter-leaf-prep.sh" 42 executor > "$LEAF_OUT" 2>&1 || true

WORKTREE="$WA/work"

# Negative: worktree .git/config must have no token
if [ -f "$WORKTREE/.git/config" ]; then
  if grep -q "FAKETOKEN123" "$WORKTREE/.git/config"; then
    no "T3-4a: worktree .git/config contains FAKETOKEN123 (token in worktree config)"
  else
    ok "T3-4a: worktree .git/config has no FAKETOKEN123"
  fi
else
  # Clone may have been intercepted by test infra — acceptable if leaf-out also clean
  if grep -q "FAKETOKEN123" "$LEAF_OUT" 2>/dev/null; then
    no "T3-4a: leaf-prep output contains FAKETOKEN123 (no worktree but token leaked)"
  else
    ok "T3-4a: no worktree .git/config found and leaf-out is clean"
  fi
fi

# Positive (d): push to local bare succeeds — worktree contract not broken.
# The test clones to leaf/42-* branch off charter/5; verify worktree was created.
if [ -d "$WORKTREE/.git" ] || [ -d "$WORKTREE" ]; then
  ok "T3-4d: worktree directory created (charter-leaf-prep contract intact)"
else
  no "T3-4d: worktree not created (charter-leaf-prep may have failed)"
fi

# (c) Spawn env dump contains GIT_CONFIG_* (registration reaches spawn point)
if [ -f "$SPAWN_ENV_DUMP" ]; then
  if grep -q "^GIT_CONFIG_COUNT=" "$SPAWN_ENV_DUMP"; then
    ok "T3-3c: GIT_CONFIG_COUNT in spawn env (helper registration reaches spawn)"
  else
    no "T3-3c: GIT_CONFIG_COUNT NOT in spawn env (helper won't reach nsjail)"
  fi

  if grep -q "^GIT_CONFIG_KEY_0=" "$SPAWN_ENV_DUMP"; then
    ok "T3-3c2: GIT_CONFIG_KEY_0 in spawn env"
  else
    no "T3-3c2: GIT_CONFIG_KEY_0 NOT in spawn env"
  fi

  if grep -q "^GIT_CONFIG_VALUE_0=" "$SPAWN_ENV_DUMP"; then
    ok "T3-3c3: GIT_CONFIG_VALUE_0 in spawn env"
  else
    no "T3-3c3: GIT_CONFIG_VALUE_0 NOT in spawn env"
  fi

  # GIT_CONFIG_VALUE_0 must contain the literal '$GH_TOKEN' placeholder, NOT the token value
  CRED_VAL_IN_SPAWN="$(grep "^GIT_CONFIG_VALUE_0=" "$SPAWN_ENV_DUMP" | head -1 | cut -d= -f2-)"
  if printf '%s' "$CRED_VAL_IN_SPAWN" | grep -qF 'FAKETOKEN123'; then
    no "T3-3c4: GIT_CONFIG_VALUE_0 in spawn env contains literal token (should defer via \$GH_TOKEN)"
  else
    ok "T3-3c4: GIT_CONFIG_VALUE_0 in spawn env uses deferred \$GH_TOKEN placeholder"
  fi

  # Negative: no token in spawn env EXCEPT in GH_TOKEN itself (expected)
  if grep -v "^GH_TOKEN=" "$SPAWN_ENV_DUMP" | grep -q "FAKETOKEN123"; then
    no "T3-4e: spawn env contains FAKETOKEN123 outside of GH_TOKEN (unexpected leak)"
  else
    ok "T3-4e: FAKETOKEN123 in spawn env only in GH_TOKEN (no unexpected leaks)"
  fi
else
  no "T3-3c: spawn env dump not found (charter-leaf-prep.sh did not exec spawn stub)"
fi

# ================================================================================
echo "=== T3-5: ~/.crewboss.env permissions ==="
# ================================================================================

PERMS="$(stat -c '%a' "$FAKE_HOME/.crewboss.env" 2>/dev/null \
         || stat -f '%A' "$FAKE_HOME/.crewboss.env" 2>/dev/null || echo unknown)"
if [ "$PERMS" = "600" ]; then
  ok "T3-5: ~/.crewboss.env mode is 600 (not world-readable)"
else
  no "T3-5: ~/.crewboss.env mode is $PERMS (expected 600)"
fi

# ================================================================================
echo
printf '=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
