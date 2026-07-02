#!/usr/bin/env bash
# prep-params.test.sh — unit tests for rework-prep.sh and charter-leaf-prep.sh
# parameterization: CB_REPO env var and charter number derived from issue body.
# Class ii: unit-bash helpers; stubs in PATH; throwaway bare-remote; reset_sandbox.
# Ref: issue #86.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$(cd "$HERE/../runtime" && pwd)"
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
export ROOT

pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

# ── bare remote: main + charter/7 ────────────────────────────────────────────
REMOTE="$ROOT/remote.git"
export REMOTE
git init --bare -q "$REMOTE"
_t="$(mktemp -d)"
git -C "$_t" init -q
git -C "$_t" config user.email t@t
git -C "$_t" config user.name T
printf 'base\n' > "$_t/README.md"
git -C "$_t" add -A
git -C "$_t" commit -qm init 2>/dev/null
git -C "$_t" remote add origin "$REMOTE"
git -C "$_t" push -q origin HEAD:refs/heads/main 2>/dev/null || true
git -C "$_t" push -q origin HEAD:refs/heads/charter/7 2>/dev/null || true
rm -rf "$_t"

# ── fake bin dir (stubs override gh and git) ──────────────────────────────────
FAKEBIN="$ROOT/fakebin"
mkdir -p "$FAKEBIN"
GIT_REAL="$(command -v git)"
export GIT_REAL
export PATH="$FAKEBIN:$PATH"

# gh stub: records the -R repo arg; returns canned issue bodies by ID.
# Uses $ROOT and single-quoted heredoc so $ROOT expands at runtime via env.
cat > "$FAKEBIN/gh" << 'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ROOT/gh-calls.log"
case "$1 $2" in
  "auth token")
    printf 'fake-token\n'
    exit 0
    ;;
  "issue view")
    ISSUE_ID="$3"
    args=("$@")
    for ((i=0; i<${#args[@]}; i++)); do
      if [ "${args[i]}" = "-R" ]; then
        printf '%s\n' "${args[i+1]}" >> "$ROOT/gh-R.log"
        break
      fi
    done
    case "$ISSUE_ID" in
      42) printf 'Charter: #7\nFix the thing.\n'; exit 0;;
      99) printf 'No charter info here.\n'; exit 0;;
    esac
    exit 0
    ;;
esac
exit 0
GHEOF
chmod +x "$FAKEBIN/gh"

# git stub: intercepts clone (records URL, substitutes local REMOTE), passes rest through.
cat > "$FAKEBIN/git" << 'GITEOF'
#!/usr/bin/env bash
if [ "$1" = "clone" ]; then
  shift
  newargs=()
  url_seen=0
  for arg in "$@"; do
    if [ "$url_seen" = "1" ] || [[ "$arg" = -* ]]; then
      newargs+=("$arg")
    else
      printf '%s\n' "$arg" >> "$ROOT/clone-urls.log"
      newargs+=("$REMOTE")
      url_seen=1
    fi
  done
  exec "$GIT_REAL" clone "${newargs[@]}"
fi
exec "$GIT_REAL" "$@"
GITEOF
chmod +x "$FAKEBIN/git"

# ── CB_HOME sandbox ───────────────────────────────────────────────────────────
CB_HOME="$ROOT/cbhome"
export CB_HOME

reset_sandbox(){
  rm -rf "$CB_HOME/run" \
         "$ROOT/gh-calls.log" "$ROOT/gh-R.log" \
         "$ROOT/clone-urls.log" "$ROOT/spawn-calls.log"
  mkdir -p "$CB_HOME/run"
  # Hermetic env: unset CB_GIT_REMOTE so charter-leaf-prep.sh builds the clone URL
  # from CB_REPO (the variable under test) rather than a host-env override.
  # Without this, a parent process (e.g. the launcher) that exports CB_GIT_REMOTE
  # causes RED-b to fail even when CB_REPO is correctly passed.
  unset CB_GIT_REMOTE
  # crewboss-spawn.sh stub: records args then exits 0.
  cat > "$CB_HOME/crewboss-spawn.sh" << 'SPAWNEOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$ROOT/spawn-calls.log"
exit 0
SPAWNEOF
  chmod +x "$CB_HOME/crewboss-spawn.sh"
}
reset_sandbox

# ─────────────────────────────────────────────────────────────────────────────
echo "== RED-a: rework-prep extracts charter from body, branches from origin/charter/7 =="
# Before fix: script hardcodes origin/charter/2 (absent in bare remote) → exit non-zero,
# no prompt file. After fix: extracts C=7 from body, checks out origin/charter/7, writes
# prompt containing charter/7 and NOT charter/2.
reset_sandbox

STDERR_a="$(bash "$SCRIPTS/rework-prep.sh" 42 2>&1 >/dev/null)"
EXIT_a=$?
PF_a="$CB_HOME/run/work/42/task.prompt"

[ "$EXIT_a" = "0" ] \
  && ok "RED-a: rework-prep.sh exits 0" \
  || ko "RED-a: rework-prep.sh exited $EXIT_a (stderr: $STDERR_a)"

[ -f "$PF_a" ] \
  && ok "RED-a: task.prompt created" \
  || ko "RED-a: task.prompt not found at $PF_a"

if [ -f "$PF_a" ]; then
  grep -qF 'charter/7' "$PF_a" \
    && ok "RED-a: prompt contains charter/7" \
    || ko "RED-a: prompt does NOT contain charter/7"
  grep -qF 'charter/2' "$PF_a" \
    && ko "RED-a: prompt still contains hardcoded charter/2" \
    || ok "RED-a: prompt contains no hardcoded charter/2"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "== RED-b: CB_REPO used for -R flag and clone URL in both scripts =="
# Before fix: -R and clone URL are hardcoded to ruslan-shaydullin/crewboss.

# rework-prep.sh with CB_REPO=acme/widget
reset_sandbox
CB_REPO=acme/widget bash "$SCRIPTS/rework-prep.sh" 42 2>/dev/null
EXIT_b_rework=$?

GH_R_REWORK="$(grep -F 'acme/widget' "$ROOT/gh-R.log" 2>/dev/null | head -1)"
CLONE_REWORK="$(grep -F 'acme/widget' "$ROOT/clone-urls.log" 2>/dev/null | head -1)"

[ "$EXIT_b_rework" = "0" ] \
  && ok "RED-b rework: exits 0 with CB_REPO=acme/widget" \
  || ko "RED-b rework: exited $EXIT_b_rework"

[ -n "$GH_R_REWORK" ] \
  && ok "RED-b rework: gh called with -R acme/widget" \
  || ko "RED-b rework: gh NOT called with -R acme/widget (gh-R.log: $(cat "$ROOT/gh-R.log" 2>/dev/null))"

[ -n "$CLONE_REWORK" ] \
  && ok "RED-b rework: clone URL contains acme/widget" \
  || ko "RED-b rework: clone URL missing acme/widget (log: $(cat "$ROOT/clone-urls.log" 2>/dev/null))"

# charter-leaf-prep.sh with CB_REPO=acme/widget
reset_sandbox
CB_REPO=acme/widget bash "$SCRIPTS/charter-leaf-prep.sh" 42 executor 2>/dev/null
EXIT_b_leaf=$?

GH_R_LEAF="$(grep -F 'acme/widget' "$ROOT/gh-R.log" 2>/dev/null | head -1)"
CLONE_LEAF="$(grep -F 'acme/widget' "$ROOT/clone-urls.log" 2>/dev/null | head -1)"

[ "$EXIT_b_leaf" = "0" ] \
  && ok "RED-b leaf: exits 0 with CB_REPO=acme/widget" \
  || ko "RED-b leaf: exited $EXIT_b_leaf"

[ -n "$GH_R_LEAF" ] \
  && ok "RED-b leaf: gh called with -R acme/widget" \
  || ko "RED-b leaf: gh NOT called with -R acme/widget (gh-R.log: $(cat "$ROOT/gh-R.log" 2>/dev/null))"

[ -n "$CLONE_LEAF" ] \
  && ok "RED-b leaf: clone URL contains acme/widget" \
  || ko "RED-b leaf: clone URL missing acme/widget (log: $(cat "$ROOT/clone-urls.log" 2>/dev/null))"

# ─────────────────────────────────────────────────────────────────────────────
echo "== RED-c: body without Charter: → rework-prep exits 2 with error on stderr =="
# Before fix: script ignores body, tries origin/charter/2 (absent) → exits 2 for wrong reason.
# After fix: exits 2 immediately with clear 'no Charter: #N in body' message.
reset_sandbox

STDERR_c="$(bash "$SCRIPTS/rework-prep.sh" 99 2>&1 >/dev/null)"
EXIT_c=$?

[ "$EXIT_c" = "2" ] \
  && ok "RED-c: exit code is 2" \
  || ko "RED-c: exit code is $EXIT_c (expected 2)"

[ -n "$STDERR_c" ] \
  && ok "RED-c: error message emitted to stderr" \
  || ko "RED-c: no error message on stderr"

# Verify the error mentions missing Charter header (not just a random failure)
printf '%s' "$STDERR_c" | grep -qi 'charter' \
  && ok "RED-c: error message mentions 'Charter'" \
  || ko "RED-c: error message does not mention 'Charter' (got: $STDERR_c)"

# ─────────────────────────────────────────────────────────────────────────────
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = "0" ]
