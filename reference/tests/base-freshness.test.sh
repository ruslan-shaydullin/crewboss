#!/usr/bin/env bash
# base-freshness.test.sh — git-base freshness tests (issue #155)
# Three test classes:
#   (a) stale charter/C: main advanced after creation, no own commits → ff-push
#   (b) stale cache: origin advanced after cache built → cache refresh sees fresh main
#   (c) invariant: prep never continues silently on default branch
#       (c1) cache mirror fetch fails → exit != 0
#       (c2) push-create of charter/C fails → exit != 0 (checkout guard)
#
# RED baseline (current code): (a) silently branches from stale charter/C;
#   (b) clone-once cache never refreshed; (c) || true + no checkout guard → exec on main.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$(cd "$HERE/../runtime" && pwd)"
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
export ROOT

pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

GIT_REAL="$(command -v git)"
export GIT_REAL

# ── helpers ───────────────────────────────────────────────────────────────────
init_bare(){
  # create a bare repo with initial commit on main; $1=path
  local repo="$1"
  git init --bare -q "$repo"
  local tmp; tmp="$(mktemp -d)"
  git init -q "$tmp"
  git -C "$tmp" config user.email t@t; git -C "$tmp" config user.name T
  printf 'init\n' > "$tmp/README.md"
  git -C "$tmp" add -A; git -C "$tmp" commit -qm init 2>/dev/null
  git -C "$tmp" remote add origin "$repo"
  git -C "$tmp" push -q origin HEAD:refs/heads/main 2>/dev/null
  git --git-dir "$repo" symbolic-ref HEAD refs/heads/main
  rm -rf "$tmp"
}

make_commit(){
  # add a commit to a bare repo's main branch; $1=bare-repo $2=msg
  local repo="$1" msg="$2"
  local tmp; tmp="$(mktemp -d)"
  git clone -q "$repo" "$tmp" 2>/dev/null
  git -C "$tmp" config user.email t@t; git -C "$tmp" config user.name T
  printf '%s\n' "$msg" >> "$tmp/log.txt"
  git -C "$tmp" add -A; git -C "$tmp" commit -qm "$msg" 2>/dev/null
  git -C "$tmp" push -q origin HEAD:refs/heads/main 2>/dev/null
  rm -rf "$tmp"
}

branch_sha(){ git ls-remote "$1" "refs/heads/$2" 2>/dev/null | awk '{print $1}'; }

# ─────────────────────────────────────────────────────────────────────────────
# (a) stale charter/C (main advanced, no own commits) → ff-push
# Tests charter-leaf-prep.sh (simpler setup, direct clone from remote).
# ─────────────────────────────────────────────────────────────────────────────
echo "== (a) stale charter/C: main advanced, no own commits → must ff =="

REMOTE_A="$ROOT/remote-a.git"
init_bare "$REMOTE_A"

# Create charter/5 at initial main SHA
MAIN_A0=$(branch_sha "$REMOTE_A" main)
_t="$(mktemp -d)"
git clone -q "$REMOTE_A" "$_t" 2>/dev/null
git -C "$_t" config user.email t@t; git -C "$_t" config user.name T
git -C "$_t" push -q origin "$MAIN_A0:refs/heads/charter/5" 2>/dev/null || true
rm -rf "$_t"

# Advance main — charter/5 stays behind (the stale-base bug)
make_commit "$REMOTE_A" "main-advance"
MAIN_A1=$(branch_sha "$REMOTE_A" main)

CB_HOME_A="$ROOT/cbhome-a"; mkdir -p "$CB_HOME_A/run"
cat > "$CB_HOME_A/crewboss-spawn.sh" << 'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$CB_HOME_A/crewboss-spawn.sh"

FAKEBIN_A="$ROOT/fakebin-a"; mkdir -p "$FAKEBIN_A"
export REMOTE_A
cat > "$FAKEBIN_A/gh" << 'GHEOF'
#!/usr/bin/env bash
case "$1 $2" in
  "auth token") printf 'fake-token\n'; exit 0;;
  "issue view") printf 'Charter: #5\nDo the thing.\n'; exit 0;;
esac
exit 0
GHEOF
chmod +x "$FAKEBIN_A/gh"

# git stub: redirect any github.com URL to REMOTE_A
cat > "$FAKEBIN_A/git" << 'GITEOF'
#!/usr/bin/env bash
args=()
for arg in "$@"; do
  if printf '%s' "$arg" | grep -q 'github\.com'; then
    args+=("$REMOTE_A")
  else
    args+=("$arg")
  fi
done
exec "$GIT_REAL" "${args[@]}"
GITEOF
chmod +x "$FAKEBIN_A/git"

SAVED_PATH="$PATH"
export PATH="$FAKEBIN_A:$PATH"
STDERR_A="$(CB_HOME="$CB_HOME_A" CB_REPO="test/repo-a" \
  bash "$SCRIPTS/charter-leaf-prep.sh" 10 executor 2>&1 >/dev/null)"
EXIT_A=$?
export PATH="$SAVED_PATH"

CHARTER5_AFTER=$(branch_sha "$REMOTE_A" "charter/5")

[ "$MAIN_A0" != "$MAIN_A1" ] \
  && ok "(a) setup: main advanced past initial charter/5 position" \
  || ko "(a) setup: main did not advance (test setup broken)"

if [ "$EXIT_A" = "0" ]; then
  [ "$CHARTER5_AFTER" = "$MAIN_A1" ] \
    && ok "(a) charter/5 fast-forwarded to fresh main" \
    || ko "(a) exited 0 but charter/5=$CHARTER5_AFTER != fresh main=$MAIN_A1 (stale base used)"
else
  # loud refusal also acceptable per spec (behind > 0)
  ok "(a) loud refusal (exit $EXIT_A) on stale charter/5 — acceptable"
fi

# ─────────────────────────────────────────────────────────────────────────────
# (b) stale cache → cache refresh on every dispatch, sees fresh main
# Tests crewboss-prep-spawn-gh.sh cache refresh logic.
# git-stub simulates the cache refresh (git fetch from local bare repos is
# broken in this sandbox; we intercept --git-dir ... fetch and replace the
# stale cache with a fresh bare clone of REMOTE_B).
# ─────────────────────────────────────────────────────────────────────────────
echo "== (b) stale cache: origin advanced → cache must be refreshed =="

REMOTE_B="$ROOT/remote-b.git"
init_bare "$REMOTE_B"
MAIN_B0=$(branch_sha "$REMOTE_B" main)

CB_HOME_B="$ROOT/cbhome-b"; mkdir -p "$CB_HOME_B/run" "$CB_HOME_B/repo-cache"

# Pre-build STALE cache (bare clone of REMOTE_B at MAIN_B0)
CACHE_NAME_B="test_user_repo_b"
CACHE_B="$CB_HOME_B/repo-cache/${CACHE_NAME_B}.git"
git clone --bare -q "$REMOTE_B" "$CACHE_B" 2>/dev/null

# Advance real remote AFTER building stale cache
make_commit "$REMOTE_B" "fresh-commit-b"
MAIN_B1=$(branch_sha "$REMOTE_B" main)

# board-gh.sh stub
cat > "$CB_HOME_B/board-gh.sh" << 'BOARDEOF'
#!/usr/bin/env bash
# Usage: board-gh.sh get <id> <field>
case "$3" in
  pr_repo)  printf 'test_user/repo_b\n';;
  charter)  printf '5\n';;
  prompt)   printf 'Do task %s\n' "$2";;
  *)        exit 1;;
esac
BOARDEOF
chmod +x "$CB_HOME_B/board-gh.sh"

# spawn stub: records origin/main SHA so we can verify the work tree is fresh
cat > "$CB_HOME_B/crewboss-spawn.sh" << 'EOF'
#!/usr/bin/env bash
git -C "$4" rev-parse origin/main > "$4/../main-sha.txt" 2>/dev/null || true
exit 0
EOF
chmod +x "$CB_HOME_B/crewboss-spawn.sh"

FAKEBIN_B="$ROOT/fakebin-b"; mkdir -p "$FAKEBIN_B"
export REMOTE_B CB_HOME_B CACHE_NAME_B
cat > "$FAKEBIN_B/gh" << 'GHEOF'
#!/usr/bin/env bash
case "$1 $2" in
  "auth token") printf 'fake-token\n'; exit 0;;
esac
exit 0
GHEOF
chmod +x "$FAKEBIN_B/gh"

# git stub for (b):
# - Intercepts `git --git-dir "$CACHE" fetch ...`: simulates cache refresh by
#   replacing the stale cache with a fresh bare clone of REMOTE_B. This models
#   the production behaviour of `git --git-dir "$CACHE" fetch --prune origin`.
# - Redirects github.com URLs to REMOTE_B (for push URL and any remaining clone).
cat > "$FAKEBIN_B/git" << 'GITEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--git-dir" ] && [ "${3:-}" = "fetch" ]; then
  CACHE_DIR="$2"
  # Simulate cache refresh: replace stale cache with fresh bare clone of real remote
  TMPCACHE="${CACHE_DIR}.refreshtmp.$$"
  rm -rf "$TMPCACHE"
  if "$GIT_REAL" clone --bare -q "$REMOTE_B" "$TMPCACHE" 2>/dev/null; then
    rm -rf "$CACHE_DIR"
    mv "$TMPCACHE" "$CACHE_DIR"
    exit 0
  else
    rm -rf "$TMPCACHE"
    exit 1
  fi
fi
# Redirect github.com URLs to REMOTE_B (push URL, any mirror clone)
args=()
for arg in "$@"; do
  if printf '%s' "$arg" | grep -q 'github\.com'; then
    args+=("$REMOTE_B")
  else
    args+=("$arg")
  fi
done
exec "$GIT_REAL" "${args[@]}"
GITEOF
chmod +x "$FAKEBIN_B/git"

export PATH="$FAKEBIN_B:$SAVED_PATH"
STDERR_B="$(CB_HOME="$CB_HOME_B" GH_TOKEN="fake-token" \
  bash "$SCRIPTS/crewboss-prep-spawn-gh.sh" 10 executor 2>&1 >/dev/null)"
EXIT_B=$?
export PATH="$SAVED_PATH"

MAIN_SHA_B="$(cat "$CB_HOME_B/run/work/10/repo/main-sha.txt" 2>/dev/null || true)"

[ "$MAIN_B0" != "$MAIN_B1" ] \
  && ok "(b) setup: origin main advanced past stale cache" \
  || ko "(b) setup: origin main did not advance (test setup broken)"

[ "$EXIT_B" = "0" ] \
  && ok "(b) crewboss-prep-spawn-gh exits 0" \
  || ko "(b) crewboss-prep-spawn-gh exited $EXIT_B (stderr: $STDERR_B)"

[ "$MAIN_SHA_B" = "$MAIN_B1" ] \
  && ok "(b) work tree origin/main = fresh main (cache refresh simulated correctly)" \
  || ko "(b) work tree origin/main=$MAIN_SHA_B != fresh main=$MAIN_B1 (stale cache NOT refreshed)"

# ─────────────────────────────────────────────────────────────────────────────
# (c) invariant: prep NEVER continues silently on default branch
# ─────────────────────────────────────────────────────────────────────────────
echo "== (c1) cache mirror fetch fails → exit != 0 =="

REMOTE_C1="$ROOT/remote-c1.git"
init_bare "$REMOTE_C1"

CB_HOME_C1="$ROOT/cbhome-c1"; mkdir -p "$CB_HOME_C1/run" "$CB_HOME_C1/repo-cache"

CACHE_NAME_C1="test_user_repo_c1"
CACHE_C1="$CB_HOME_C1/repo-cache/${CACHE_NAME_C1}.git"
git clone --bare -q "$REMOTE_C1" "$CACHE_C1" 2>/dev/null

# Break the cache's origin URL so the cache-refresh fetch definitively fails
git --git-dir "$CACHE_C1" remote set-url origin "/nonexistent/__no_such_path__.git"

cat > "$CB_HOME_C1/board-gh.sh" << 'BOARDEOF'
#!/usr/bin/env bash
case "$3" in
  pr_repo)  printf 'test_user/repo_c1\n';;
  charter)  printf '5\n';;
  prompt)   printf 'task\n';;
  *)        exit 1;;
esac
BOARDEOF
chmod +x "$CB_HOME_C1/board-gh.sh"

cat > "$CB_HOME_C1/crewboss-spawn.sh" << 'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$CB_HOME_C1/crewboss-spawn.sh"

FAKEBIN_C1="$ROOT/fakebin-c1"; mkdir -p "$FAKEBIN_C1"
cat > "$FAKEBIN_C1/gh" << 'GHEOF'
#!/usr/bin/env bash
case "$1 $2" in
  "auth token") printf 'fake-token\n'; exit 0;;
esac
exit 0
GHEOF
chmod +x "$FAKEBIN_C1/gh"

# git stub for c1: pass-through (no URL redirect needed; we want the real fetch to fail)
cat > "$FAKEBIN_C1/git" << 'GITEOF'
#!/usr/bin/env bash
exec "$GIT_REAL" "$@"
GITEOF
chmod +x "$FAKEBIN_C1/git"

export PATH="$FAKEBIN_C1:$SAVED_PATH"
CB_HOME="$CB_HOME_C1" GH_TOKEN="fake-token" \
  bash "$SCRIPTS/crewboss-prep-spawn-gh.sh" 10 executor >/dev/null 2>&1
EXIT_C1=$?
export PATH="$SAVED_PATH"

[ "$EXIT_C1" != "0" ] \
  && ok "(c1) exit != 0 when cache mirror fetch fails (broken origin URL)" \
  || ko "(c1) exit = 0 even though cache fetch failed — silent continue on default branch"

# ─────────────────────────────────────────────────────────────────────────────
echo "== (c2) push-create of charter/C fails → exit != 0 (checkout guard) =="

REMOTE_C2="$ROOT/remote-c2.git"
init_bare "$REMOTE_C2"

CB_HOME_C2="$ROOT/cbhome-c2"; mkdir -p "$CB_HOME_C2/run" "$CB_HOME_C2/repo-cache"
CACHE_NAME_C2="test_user_repo_c2"
CACHE_C2="$CB_HOME_C2/repo-cache/${CACHE_NAME_C2}.git"
git clone --bare -q "$REMOTE_C2" "$CACHE_C2" 2>/dev/null

cat > "$CB_HOME_C2/board-gh.sh" << 'BOARDEOF'
#!/usr/bin/env bash
case "$3" in
  pr_repo)  printf 'test_user/repo_c2\n';;
  charter)  printf '5\n';;
  prompt)   printf 'task\n';;
  *)        exit 1;;
esac
BOARDEOF
chmod +x "$CB_HOME_C2/board-gh.sh"

cat > "$CB_HOME_C2/crewboss-spawn.sh" << 'EOF'
#!/usr/bin/env bash
# If we reach here prep continued silently — record branch for diagnosis
git -C "$4" branch --show-current > "$4/../bad-branch.txt" 2>/dev/null || true
exit 0
EOF
chmod +x "$CB_HOME_C2/crewboss-spawn.sh"

FAKEBIN_C2="$ROOT/fakebin-c2"; mkdir -p "$FAKEBIN_C2"
export REMOTE_C2
cat > "$FAKEBIN_C2/gh" << 'GHEOF'
#!/usr/bin/env bash
case "$1 $2" in
  "auth token") printf 'fake-token\n'; exit 0;;
esac
exit 0
GHEOF
chmod +x "$FAKEBIN_C2/gh"

# git stub for c2:
# - Intercept cache fetch: simulate successful refresh (replace stale cache)
# - Redirect github.com URLs to REMOTE_C2 for everything EXCEPT push
# - FAIL all push operations (simulates push-create of charter/C failing)
cat > "$FAKEBIN_C2/git" << 'GITEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--git-dir" ] && [ "${3:-}" = "fetch" ]; then
  CACHE_DIR="$2"
  TMPCACHE="${CACHE_DIR}.refreshtmp.$$"
  rm -rf "$TMPCACHE"
  if "$GIT_REAL" clone --bare -q "$REMOTE_C2" "$TMPCACHE" 2>/dev/null; then
    rm -rf "$CACHE_DIR"; mv "$TMPCACHE" "$CACHE_DIR"; exit 0
  else
    rm -rf "$TMPCACHE"; exit 1
  fi
fi
# Fail all push operations (simulates create-charter/C push rejected)
if [ "${1:-}" = "push" ]; then
  printf 'stub: push refused (simulating push-create failure)\n' >&2
  exit 1
fi
# Redirect github.com URLs to REMOTE_C2
args=()
for arg in "$@"; do
  if printf '%s' "$arg" | grep -q 'github\.com'; then
    args+=("$REMOTE_C2")
  else
    args+=("$arg")
  fi
done
exec "$GIT_REAL" "${args[@]}"
GITEOF
chmod +x "$FAKEBIN_C2/git"

export PATH="$FAKEBIN_C2:$SAVED_PATH"
CB_HOME="$CB_HOME_C2" GH_TOKEN="fake-token" \
  bash "$SCRIPTS/crewboss-prep-spawn-gh.sh" 10 executor >/dev/null 2>&1
EXIT_C2=$?
export PATH="$SAVED_PATH"

[ "$EXIT_C2" != "0" ] \
  && ok "(c2) exit != 0 when push-create of charter/C fails (checkout guard fired)" \
  || ko "(c2) exit = 0 even though charter/C was never created — continued silently on default branch"

# ─────────────────────────────────────────────────────────────────────────────
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = "0" ]
