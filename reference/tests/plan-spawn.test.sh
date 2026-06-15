#!/usr/bin/env bash
# plan-spawn.test.sh — regression: crewboss-prep-spawn-gh.sh must not crash on the
# tech-lead / plan-spawn path (issue: surfaced by the first end-to-end autonomous
# control run — the plan path was previously only exercised operator-side, so a
# `set -u` "BRANCH: unbound variable" at the git-checkout sat latent).
#
# Class ii (integration, stubs in PATH): drives the REAL prep-spawn script with a
# stubbed board / gh / git / crewboss-spawn so we test the script's own role
# branching + variable setup, NOT the jail/clone.
#
# RED before fix: ROLE=tech-lead → BRANCH never set → `git checkout -b "$BRANCH"`
#   aborts under `set -u` → spawn never reached.
# GREEN after fix: BRANCH is defaulted for the plan path → the prep reaches the
#   crewboss-spawn exec for BOTH tech-lead (plan) and executor roles.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PREP="$HERE/../runtime/crewboss-prep-spawn-gh.sh"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

# ── stub CB_HOME (board-gh.sh + crewboss-spawn.sh live here) ──────────────────
CBH="$ROOT/cbhome"; mkdir -p "$CBH"

# board-gh.sh stub: `get <id> <field>` → canned values.
#   pr_repo → owner/repo · prompt → charter goal · charter → empty (a charter has
#   no parent charter, so the executor branch would also take the no-CB path).
cat > "$CBH/board-gh.sh" <<'BRD'
#!/usr/bin/env bash
# usage: board-gh.sh get <id> <field>
[ "$1" = "get" ] || { echo ""; exit 0; }
case "$3" in
  pr_repo) echo "owner/repo" ;;
  prompt)  echo "decompose this charter into leaves" ;;
  charter) echo "" ;;
  *)       echo "" ;;
esac
BRD
chmod +x "$CBH/board-gh.sh"

# crewboss-spawn.sh stub: the prep `exec`s this last. Reaching it == the prep got
# past the BRANCH-using git checkout without a `set -u` crash.
cat > "$CBH/crewboss-spawn.sh" <<'SPN'
#!/usr/bin/env bash
echo "SPAWN_REACHED role=$2"
exit 0
SPN
chmod +x "$CBH/crewboss-spawn.sh"

# ── fake bin (gh + git stubs) ────────────────────────────────────────────────
FB="$ROOT/fakebin"; mkdir -p "$FB"
cat > "$FB/gh" <<'GH'
#!/usr/bin/env bash
[ "$1 $2" = "auth token" ] && { echo "fake-token"; exit 0; }
exit 0
GH
chmod +x "$FB/gh"

# git stub: only the calls the prep makes on the plan/executor-no-charter path.
#   clone --mirror URL DEST.tmp  → create DEST.tmp dir (script then mv's it)
#   clone --local  SRC  DEST     → create DEST + DEST/.git (the `-e .git` check)
#   everything else (remote/checkout/--git-dir fetch/...) → no-op success
cat > "$FB/git" <<'GIT'
#!/usr/bin/env bash
if [ "$1" = "clone" ]; then
  dest="${!#}"            # last positional = destination
  mkdir -p "$dest"
  [ "$2" = "--local" ] && mkdir -p "$dest/.git"
  exit 0
fi
exit 0
GIT
chmod +x "$FB/git"

# flock stub (no-op): the prep wraps the cache clone in `( flock 9; ... )`; real
# flock is util-linux (absent on macOS) and we need no real locking in the stub.
# sudo stub (no-op): defensive — the rm -rf fallback should never reach sudo here.
printf '#!/usr/bin/env bash\nexit 0\n' > "$FB/flock"; chmod +x "$FB/flock"
printf '#!/usr/bin/env bash\nexec "$@"\n'  > "$FB/sudo";  chmod +x "$FB/sudo"

run_prep() {  # <id> <role> → stdout+stderr to $ROOT/out, returns rc
  ( cd "$ROOT" && CB_HOME="$CBH" PATH="$FB:$PATH" bash "$PREP" "$1" "$2" ) \
    > "$ROOT/out" 2>&1
}

# ── Test 1: tech-lead (plan) path reaches the spawn, no unbound-var crash ─────
echo "=== Test 1: tech-lead plan spawn — no BRANCH unbound crash ==="
rc=0; run_prep 217 tech-lead || rc=$?
if grep -q "unbound variable" "$ROOT/out"; then
  ko "tech-lead: hit 'unbound variable' (regression) — $(grep unbound "$ROOT/out" | head -1)"
elif [ "$rc" -eq 0 ] && grep -q "SPAWN_REACHED role=tech-lead" "$ROOT/out"; then
  ok "tech-lead: prep reached crewboss-spawn (BRANCH defaulted, no set -u crash)"
else
  ko "tech-lead: did not reach spawn (rc=$rc): $(tail -3 "$ROOT/out")"
fi

# ── Test 2: executor path still reaches the spawn (no regression) ─────────────
echo "=== Test 2: executor spawn still works ==="
rc=0; run_prep 218 executor || rc=$?
if [ "$rc" -eq 0 ] && grep -q "SPAWN_REACHED role=executor" "$ROOT/out"; then
  ok "executor: prep reached crewboss-spawn"
else
  ko "executor: did not reach spawn (rc=$rc): $(tail -3 "$ROOT/out")"
fi

echo
printf '=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
