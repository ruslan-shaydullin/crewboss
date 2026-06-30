#!/usr/bin/env bash
# role-spawn.test.sh — role-resolved spawn tests (issue #137).
# Class spawn-unit + integration-stub:
#   stub crewboss-spawn.sh journals args and snapshots work-tree path;
#   gh-stub + board-gh.sh stub serve a charter leaf with label role:go-backend-dev + Charter: #7;
#   CB_MANIFEST = copy of team-example; local bare-remote plays "GitHub".
#
# RED-1: task.prompt contains unique phrase from go-backend-dev.md
#         (today: generic executor prompt, no role body)
# RED-2: work-tree has .claude/agents/go-backend-dev.md identical to manifest copy
#         (today: .claude/agents/ absent in work-tree)
# RED-3: ROLE=no-such-role + CB_MANIFEST → exit 2
#         (today: silently falls through to generic executor prompt)
# Pin-1: branch = leaf/<id>-<ts>         (regression guard — already green)
# Pin-2: base   = charter/<C>             (regression guard — already green)
# Pin-3: hard-rules block in prompt       (regression guard — already green)
# Pin-4: without CB_MANIFEST, prompt has original executor format (no manifest content)
#
# EXCLUDED (invokes real prep-spawn with git/flock): reference/runtime/per-leaf-manifest
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PREP="${PREP_OVERRIDE:-$HERE/../runtime/crewboss-prep-spawn-gh.sh}"
TEAM_EXAMPLE="$(cd "$HERE/../../team-example" && pwd)"
MANIFEST_LIB_SRC="$HERE/../launcher/manifest.sh"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

LEAF_ID=42
CHARTER_ID=7
CB_REPO_VAL="owner/repo"
export LEAF_ID CHARTER_ID CB_REPO_VAL

# ── CB_MANIFEST: copy of team-example ─────────────────────────────────────────
CB_MANIFEST_DIR="$ROOT/manifest"
cp -r "$TEAM_EXAMPLE/." "$CB_MANIFEST_DIR"

# ── bare remote (local "GitHub" for git clone redirect) ───────────────────────
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
git -C "$_t" push -q origin HEAD:refs/heads/"charter/$CHARTER_ID" 2>/dev/null || true
rm -rf "$_t"
export REMOTE

# ── fake bin: gh + git stubs ──────────────────────────────────────────────────
FAKEBIN="$ROOT/bin"
mkdir -p "$FAKEBIN"
GIT_REAL="$(command -v git)"
export GIT_REAL

# gh stub: returns fake-token for auth; no-op for all other calls
cat > "$FAKEBIN/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "auth token") printf 'fake-token\n'; exit 0 ;;
  *) exit 0 ;;
esac
GHEOF
chmod +x "$FAKEBIN/gh"

# git stub: redirect GitHub HTTPS URLs → local bare REMOTE; pass everything else through
cat > "$FAKEBIN/git" <<'GITEOF'
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

# sudo stub: passthrough (avoids permission issues in CI)
cat > "$FAKEBIN/sudo" <<'SUDOEOF'
#!/usr/bin/env bash
exec "$@"
SUDOEOF
chmod +x "$FAKEBIN/sudo"

# ── CB_HOME setup ─────────────────────────────────────────────────────────────
CB_HOME_DIR="$ROOT/cbhome"
mkdir -p "$CB_HOME_DIR"

# board-gh.sh stub in CB_HOME: returns fixed fields for issue $LEAF_ID.
# Variables ($CB_REPO_VAL, $CHARTER_ID) are exported → expand at stub runtime.
cat > "$CB_HOME_DIR/board-gh.sh" <<'BRDEOF'
#!/usr/bin/env bash
[ "$1" = "get" ] || exit 0
case "$3" in
  pr_repo)  printf '%s\n' "$CB_REPO_VAL" ;;
  charter)  printf '%s\n' "$CHARTER_ID" ;;
  prompt)   printf 'Charter: #%s\nFix some backend Go service.\n' "$CHARTER_ID" ;;
  role)     printf 'go-backend-dev\n' ;;
  *)        printf '' ;;
esac
BRDEOF
chmod +x "$CB_HOME_DIR/board-gh.sh"

# crewboss-spawn.sh stub: journals prompt content and work-tree path for assertions.
# PROMPT_SAVED and WORKDIR_FILE are exported from the test.
PROMPT_SAVED="$ROOT/prompt-saved.txt"
WORKDIR_FILE="$ROOT/workdir.txt"
export PROMPT_SAVED WORKDIR_FILE

cat > "$CB_HOME_DIR/crewboss-spawn.sh" <<'SPAWNEOF'
#!/usr/bin/env bash
# Args: <id> <role> <prompt-file> <workdir> <repo>
cat "$3" > "$PROMPT_SAVED"
printf '%s\n' "$4" > "$WORKDIR_FILE"
exit 0
SPAWNEOF
chmod +x "$CB_HOME_DIR/crewboss-spawn.sh"

# ── runner helpers ─────────────────────────────────────────────────────────────

# run_prep_manifest: run prep-spawn with CB_MANIFEST set
run_prep_manifest(){
  local id="$1" role="$2"
  : > "$PROMPT_SAVED"; : > "$WORKDIR_FILE"
  PATH="$FAKEBIN:$PATH" \
    CB_HOME="$CB_HOME_DIR" \
    CB_REPO="$CB_REPO_VAL" \
    CB_MANIFEST="$CB_MANIFEST_DIR" \
    CB_MANIFEST_LIB="$MANIFEST_LIB_SRC" \
    GH_TOKEN="fake-token" \
    bash "$PREP" "$id" "$role" >"$ROOT/run.log" 2>"$ROOT/run.err" || true
}

# run_prep_no_manifest: run prep-spawn WITHOUT CB_MANIFEST (legacy path)
run_prep_no_manifest(){
  local id="$1" role="$2"
  : > "$PROMPT_SAVED"; : > "$WORKDIR_FILE"
  env -u CB_MANIFEST \
    PATH="$FAKEBIN:$PATH" \
    CB_HOME="$CB_HOME_DIR" \
    CB_REPO="$CB_REPO_VAL" \
    GH_TOKEN="fake-token" \
    bash "$PREP" "$id" "$role" >"$ROOT/run.log" 2>"$ROOT/run.err" || true
}

# run_prep_manifest_exit: returns exit code of prep-spawn (for fail-fast tests)
run_prep_manifest_exit(){
  local id="$1" role="$2" _rc=0
  PATH="$FAKEBIN:$PATH" \
    CB_HOME="$CB_HOME_DIR" \
    CB_REPO="$CB_REPO_VAL" \
    CB_MANIFEST="$CB_MANIFEST_DIR" \
    CB_MANIFEST_LIB="$MANIFEST_LIB_SRC" \
    GH_TOKEN="fake-token" \
    bash "$PREP" "$id" "$role" >/dev/null 2>"$ROOT/run.err" || _rc=$?
  printf '%d' "$_rc"
}

# =============================================================================
# RED-1: prompt contains unique phrase from go-backend-dev.md role body
#   Before fix: generic executor prompt has no role body.
#   After fix:  manifest_role_prompt body injected before ---- TASK ----.
# =============================================================================
echo "=== RED-1: prompt has go-backend-dev.md unique phrase ('Ultra-narrow zone') ==="
run_prep_manifest "$LEAF_ID" "go-backend-dev"

grep -q "Ultra-narrow zone" "$PROMPT_SAVED" \
  && ok "RED-1: prompt contains 'Ultra-narrow zone' (go-backend-dev.md role body injected)" \
  || ko "RED-1: prompt missing 'Ultra-narrow zone' (role body not injected into charter-leaf prompt)"

grep -q "Implements ONE Go web-service" "$PROMPT_SAVED" \
  && ok "RED-1: prompt contains 'Implements ONE Go web-service' (role body verified)" \
  || ko "RED-1: prompt missing 'Implements ONE Go web-service' (role body absent)"

# =============================================================================
# RED-2: work-tree has .claude/agents/go-backend-dev.md identical to manifest copy
#   Before fix: no .claude/agents/ directory in work-tree.
#   After fix:  manifest roles/go-backend-dev.md copied into work-tree .claude/agents/.
# =============================================================================
echo "=== RED-2: .claude/agents/go-backend-dev.md in work-tree ==="
WORKDIR=$(cat "$WORKDIR_FILE" 2>/dev/null || true)

[ -n "$WORKDIR" ] \
  && ok "RED-2: spawn stub captured work-tree path ('$WORKDIR')" \
  || ko "RED-2: spawn stub did not capture work-tree path"

if [ -n "$WORKDIR" ]; then
  AGENT_FILE="$WORKDIR/.claude/agents/go-backend-dev.md"
  [ -f "$AGENT_FILE" ] \
    && ok "RED-2: .claude/agents/go-backend-dev.md exists in work-tree" \
    || ko "RED-2: .claude/agents/go-backend-dev.md MISSING in work-tree (agent injection not implemented)"

  if [ -f "$AGENT_FILE" ]; then
    diff -q "$AGENT_FILE" "$CB_MANIFEST_DIR/roles/go-backend-dev.md" >/dev/null 2>&1 \
      && ok "RED-2: agent file is byte-for-byte identical to manifest roles/go-backend-dev.md" \
      || ko "RED-2: agent file content differs from manifest copy"
  fi
fi

# =============================================================================
# RED-3: unknown role + CB_MANIFEST → exit 2 with diagnostic on stderr
#   Before fix: silently falls through to generic executor prompt.
#   After fix:  fail-fast exit 2 with "not found in manifest" message.
# =============================================================================
echo "=== RED-3: unknown role + CB_MANIFEST → exit 2 ==="
_rc3=$(run_prep_manifest_exit "$LEAF_ID" "no-such-role")

[ "$_rc3" -eq 2 ] \
  && ok "RED-3: exit code 2 for unknown role with CB_MANIFEST" \
  || ko "RED-3: exit code $_rc3 (expected 2 — typo in role: label not caught, silently executor)"

grep -qi "no-such-role\|not found\|manifest" "$ROOT/run.err" 2>/dev/null \
  && ok "RED-3: stderr mentions unknown role or 'not found in manifest'" \
  || ko "RED-3: no useful diagnostic on stderr (got: $(cat "$ROOT/run.err" 2>/dev/null | head -3))"

# =============================================================================
# Pin-1+Pin-2+Pin-3: branch=leaf/<id>-<ts>, base=charter/<C>, hard-rules block
#   Regression guards — verify manifest mode preserves charter hard-rules verbatim.
# =============================================================================
echo "=== Pins 1-3: branch/base/hard-rules preserved in manifest-mode prompt ==="
run_prep_manifest "$LEAF_ID" "go-backend-dev"

grep -q "leaf/$LEAF_ID-" "$PROMPT_SAVED" \
  && ok "Pin-1: prompt contains leaf/$LEAF_ID-<ts> branch name" \
  || ko "Pin-1: prompt missing leaf/$LEAF_ID-<ts> branch name"

grep -q "charter/$CHARTER_ID" "$PROMPT_SAVED" \
  && ok "Pin-2: prompt contains charter/$CHARTER_ID base" \
  || ko "Pin-2: prompt missing charter/$CHARTER_ID base (charter hard-rules missing)"

grep -qF "git push -u origin HEAD" "$PROMPT_SAVED" \
  && ok "Pin-3: prompt contains 'git push -u origin HEAD' (hard-rules push instruction)" \
  || ko "Pin-3: prompt missing 'git push -u origin HEAD'"

grep -qF -e "---- TASK (issue #$LEAF_ID) ----" "$PROMPT_SAVED" \
  && ok "Pin-3: prompt contains '---- TASK (issue #$LEAF_ID) ----' marker" \
  || ko "Pin-3: prompt missing ---- TASK marker"

grep -qF "cb_pr_create --base charter/$CHARTER_ID" "$PROMPT_SAVED" \
  && ok "Pin-3: prompt contains 'cb_pr_create --base charter/$CHARTER_ID' (PR base hard-rule)" \
  || ko "Pin-3: prompt missing 'cb_pr_create --base charter/$CHARTER_ID'"

# =============================================================================
# Pin-4: without CB_MANIFEST, prompt is original executor format — no role body
#   Regression guard (HD-1): manifest mode must NOT touch the legacy path.
# =============================================================================
echo "=== Pin-4: without CB_MANIFEST, prompt unchanged (HD-1 pin) ==="
run_prep_no_manifest "$LEAF_ID" "go-backend-dev"

grep -qF "You are the executor for issue #$LEAF_ID" "$PROMPT_SAVED" \
  && ok "Pin-4: prompt has original 'You are the executor' intro (no-manifest path)" \
  || ko "Pin-4: prompt missing original executor intro (log: $(cat "$ROOT/run.err" | head -3))"

grep -q "Ultra-narrow zone" "$PROMPT_SAVED" \
  && ko "Pin-4: role body leaked into prompt without CB_MANIFEST (HD-1 violation)" \
  || ok "Pin-4: role body absent without CB_MANIFEST (legacy path unchanged, HD-1 holds)"

grep -q "leaf/$LEAF_ID-" "$PROMPT_SAVED" \
  && ok "Pin-4: branch leaf/$LEAF_ID-<ts> present in no-manifest charter-leaf prompt" \
  || ko "Pin-4: branch leaf/$LEAF_ID-<ts> missing in no-manifest charter-leaf prompt"

grep -qF -e "---- TASK (issue #$LEAF_ID) ----" "$PROMPT_SAVED" \
  && ok "Pin-4: ---- TASK marker present without CB_MANIFEST" \
  || ko "Pin-4: ---- TASK marker missing without CB_MANIFEST"

# =============================================================================
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
