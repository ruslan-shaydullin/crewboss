#!/usr/bin/env bash
# role-spawn.test.sh — role-resolved spawn: CB_MANIFEST + role: label → agent injection
# (issue #137). Class b spawn-unit + integration-stub.
#
# RED-1: task.prompt contains unique phrase from go-backend-dev role body.
#        Before fix: generic executor prompt has no such phrase.
# RED-2: .claude/agents/go-backend-dev.md present in work-tree and identical to manifest file.
#        Before fix: .claude/agents/ is never created (role injection absent).
# RED-3: ROLE=no-such-role with CB_MANIFEST → exit 2.
#        Before fix: silently falls through to generic executor prompt.
# Pins (regression guards — already green before fix):
#   branch = leaf/<id>-<ts>, base = charter/<C>, hard-rules block in prompt,
#   without CB_MANIFEST prompt is unchanged (no role section).
#
# Requires: bash, git, jq, flock.
# Run: bash reference/tests/role-spawn.test.sh

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../runtime/crewboss-prep-spawn-gh.sh"
BOARD_SRC="$HERE/../../proto/r6/board-gh.sh"
TEAM_EXAMPLE="$(cd "$HERE/../../team-example" && pwd)"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

LEAF_ID=50
CHARTER_ID=5
CB_REPO_VAL="test/repo"

# ── bare remote (plays role of "GitHub" for git operations) ──────────────────
REMOTE="$ROOT/remote.git"
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
# Pre-create charter/5 so prep-spawn skips the GitHub push attempt.
git -C "$_t" push -q origin HEAD:refs/heads/charter/5 2>/dev/null || true
rm -rf "$_t"
export REMOTE

# ── leaf issue JSON ───────────────────────────────────────────────────────────
# Real labels: type:agent + role:go-backend-dev; body has Charter: #5 line.
LEAF_BODY="Do the Go backend task.\\nCharter: #${CHARTER_ID}\\n## Acceptance (machine)\\n- check: true"
LEAF_JSON="{\"number\":${LEAF_ID},\"state\":\"OPEN\",\"labels\":[{\"name\":\"type:agent\"},{\"name\":\"role:go-backend-dev\"},{\"name\":\"status:approved\"}],\"body\":\"${LEAF_BODY}\"}"
export LEAF_JSON ROOT LEAF_ID

# ── fake bin ─────────────────────────────────────────────────────────────────
FAKEBIN="$ROOT/bin"
mkdir -p "$FAKEBIN"
GIT_REAL="$(command -v git)"
export GIT_REAL FAKEBIN

# gh stub: handles auth token + issue view (returns leaf JSON for any issue view call)
cat > "$FAKEBIN/gh" << 'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ROOT/gh.log"
case "$1 ${2:-}" in
  "auth token") printf 'fake-token\n'; exit 0 ;;
  "issue view") printf '%s\n' "$LEAF_JSON"; exit 0 ;;
esac
exit 0
GHEOF
chmod +x "$FAKEBIN/gh"

# git stub: redirect https://github.com/ URLs to local REMOTE; pass everything else through.
cat > "$FAKEBIN/git" << 'GITEOF'
#!/usr/bin/env bash
args=()
for arg in "$@"; do
  if [[ "$arg" == "https://github.com/"* ]]; then
    args+=("$REMOTE")
  else
    args+=("$arg")
  fi
done
exec "$GIT_REAL" "${args[@]}"
GITEOF
chmod +x "$FAKEBIN/git"

# ── CB_HOME setup ─────────────────────────────────────────────────────────────
CB_HOME_DIR="$ROOT/cbhome"
mkdir -p "$CB_HOME_DIR"
cp "$BOARD_SRC" "$CB_HOME_DIR/board-gh.sh"
chmod +x "$CB_HOME_DIR/board-gh.sh"

# spawn stub: logs args and snapshots .claude/agents/ from work-tree.
SPAWN_LOG="$ROOT/spawn.log"
AGENTS_SNAP="$ROOT/agents-snap"
export SPAWN_LOG AGENTS_SNAP

cat > "$CB_HOME_DIR/crewboss-spawn.sh" << 'SPAWNEOF'
#!/usr/bin/env bash
# Args: <id> <role> <prompt-file> <workdir> <repo>
printf '%s\n' "$@" > "$SPAWN_LOG"
mkdir -p "$AGENTS_SNAP"
if [ -d "$4/.claude/agents" ]; then
  cp -r "$4/.claude/agents/." "$AGENTS_SNAP/"
fi
exit 0
SPAWNEOF
chmod +x "$CB_HOME_DIR/crewboss-spawn.sh"

# ── CB_MANIFEST: copy of team-example ─────────────────────────────────────────
CB_MANIFEST_DIR="$ROOT/manifest"
cp -r "$TEAM_EXAMPLE/." "$CB_MANIFEST_DIR"

# ── Helpers ───────────────────────────────────────────────────────────────────
reset_run(){
  rm -rf "$CB_HOME_DIR/run" "$ROOT/gh.log" "$AGENTS_SNAP"
  mkdir -p "$CB_HOME_DIR/run" "$AGENTS_SNAP"
}

PROMPT_FILE="$CB_HOME_DIR/run/work/$LEAF_ID/task.prompt"

run_with_manifest(){
  reset_run
  PATH="$FAKEBIN:$PATH" \
    CB_HOME="$CB_HOME_DIR" \
    CB_REPO="$CB_REPO_VAL" \
    CB_MANIFEST="$CB_MANIFEST_DIR" \
    GH_TOKEN="fake-token" \
    bash "$SCRIPT" "$LEAF_ID" "go-backend-dev" > "$ROOT/run.log" 2>&1
  echo $?
}

run_without_manifest(){
  reset_run
  env -u CB_MANIFEST \
    PATH="$FAKEBIN:$PATH" \
    CB_HOME="$CB_HOME_DIR" \
    CB_REPO="$CB_REPO_VAL" \
    GH_TOKEN="fake-token" \
    bash "$SCRIPT" "$LEAF_ID" "go-backend-dev" > "$ROOT/run.log" 2>&1
  echo $?
}

run_bad_role(){
  reset_run
  PATH="$FAKEBIN:$PATH" \
    CB_HOME="$CB_HOME_DIR" \
    CB_REPO="$CB_REPO_VAL" \
    CB_MANIFEST="$CB_MANIFEST_DIR" \
    GH_TOKEN="fake-token" \
    bash "$SCRIPT" "$LEAF_ID" "no-such-role" 2>"$ROOT/err.log" >"$ROOT/run2.log"
  echo $?
}

# =============================================================================
echo "== RED-1: task.prompt contains role body phrase (CB_MANIFEST set, role:go-backend-dev) =="
# =============================================================================
EXIT_1="$(run_with_manifest)"

[ "$EXIT_1" = "0" ] \
  && ok "RED-1: prep-spawn exits 0 with CB_MANIFEST" \
  || ko "RED-1: prep-spawn failed (exit $EXIT_1; log: $(tail -5 "$ROOT/run.log" 2>/dev/null))"

[ -f "$PROMPT_FILE" ] \
  && ok "RED-1: task.prompt created" \
  || ko "RED-1: task.prompt missing at $PROMPT_FILE"

if [ -f "$PROMPT_FILE" ]; then
  # "Ultra-narrow zone" is a unique phrase in team-example/roles/go-backend-dev.md body.
  grep -qF "Ultra-narrow zone" "$PROMPT_FILE" \
    && ok "RED-1: prompt contains go-backend-dev role phrase 'Ultra-narrow zone'" \
    || ko "RED-1: prompt missing go-backend-dev role phrase (first 10 lines: $(head -10 "$PROMPT_FILE" 2>/dev/null))"
fi

# =============================================================================
echo "== RED-2: .claude/agents/go-backend-dev.md in work-tree == manifest role file =="
# =============================================================================
AGENT_FILE="$AGENTS_SNAP/go-backend-dev.md"

[ -f "$AGENT_FILE" ] \
  && ok "RED-2: .claude/agents/go-backend-dev.md present in work-tree snapshot" \
  || ko "RED-2: .claude/agents/go-backend-dev.md missing (snap: $(ls "$AGENTS_SNAP" 2>/dev/null || echo 'empty'))"

if [ -f "$AGENT_FILE" ]; then
  diff -q "$AGENT_FILE" "$CB_MANIFEST_DIR/roles/go-backend-dev.md" >/dev/null 2>&1 \
    && ok "RED-2: agent file identical to manifest role file" \
    || ko "RED-2: agent file differs from manifest role file"
fi

# Pin: hard-rules block must be in the manifest-run prompt (before checking RED-3)
if [ -f "$PROMPT_FILE" ]; then
  grep -qF "Hard rules for THIS run" "$PROMPT_FILE" \
    && ok "Pin: hard-rules block present in manifest-run prompt" \
    || ko "Pin: hard-rules block missing from manifest-run prompt"

  grep -qE "leaf/${LEAF_ID}-[0-9]+" "$PROMPT_FILE" \
    && ok "Pin: branch is leaf/<id>-<ts>" \
    || ko "Pin: branch pattern leaf/${LEAF_ID}-<ts> not found in prompt"

  grep -qF "charter/${CHARTER_ID}" "$PROMPT_FILE" \
    && ok "Pin: base charter/${CHARTER_ID} in prompt" \
    || ko "Pin: base charter/${CHARTER_ID} missing from prompt"
fi

# =============================================================================
echo "== RED-3: ROLE=no-such-role + CB_MANIFEST → exit 2 (fail-fast on typo) =="
# =============================================================================
EXIT_3="$(run_bad_role)"

[ "$EXIT_3" = "2" ] \
  && ok "RED-3: exit code 2 for unknown role" \
  || ko "RED-3: exit code $EXIT_3 (expected 2)"

[ -s "$ROOT/err.log" ] \
  && ok "RED-3: error message emitted to stderr" \
  || ko "RED-3: no error message on stderr (err.log empty)"

grep -qiF 'no-such-role' "$ROOT/err.log" 2>/dev/null \
  && ok "RED-3: error message mentions the bad role name" \
  || ko "RED-3: error message does not mention role name (got: $(cat "$ROOT/err.log" 2>/dev/null))"

# =============================================================================
echo "== Pin: without CB_MANIFEST → prompt has hard-rules but no role section =="
# =============================================================================
EXIT_NOMF="$(run_without_manifest)"

[ "$EXIT_NOMF" = "0" ] \
  && ok "Pin (no CB_MANIFEST): prep-spawn exits 0" \
  || ko "Pin (no CB_MANIFEST): prep-spawn failed (exit $EXIT_NOMF; log: $(tail -5 "$ROOT/run.log" 2>/dev/null))"

if [ -f "$PROMPT_FILE" ]; then
  grep -qF "Ultra-narrow zone" "$PROMPT_FILE" \
    && ko "Pin (no CB_MANIFEST): prompt contains role phrase without CB_MANIFEST — leaked!" \
    || ok "Pin (no CB_MANIFEST): prompt does NOT contain role phrase (correct)"

  grep -qF "Hard rules for THIS run" "$PROMPT_FILE" \
    && ok "Pin (no CB_MANIFEST): hard-rules block still present" \
    || ko "Pin (no CB_MANIFEST): hard-rules block missing"

  grep -qF -- "---- TASK " "$PROMPT_FILE" \
    && ok "Pin (no CB_MANIFEST): ---- TASK ---- section present" \
    || ko "Pin (no CB_MANIFEST): ---- TASK ---- section missing"
fi

# =============================================================================
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
