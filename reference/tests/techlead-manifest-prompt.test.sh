#!/usr/bin/env bash
# techlead-manifest-prompt.test.sh — tech-lead ROLE=tech-lead + CB_MANIFEST prompt augmentation
# (issue #141). Class b prompt-unit.
#
# RED-1: CB_MANIFEST set → prompt contains both composition roles (go-backend-dev,
#        qa-engineer), leaf-id map entries (L-1, L-2), and a role:-label instruction.
#        Before fix: no CB_MANIFEST branch exists → prompt has none of this.
#
# RED-2 (HD-1 pin, negative control): no CB_MANIFEST → prompt has the HD-1 anchor
#        substrings of the existing tech-lead prompt and contains NO composition data.
#
# Requires: bash, git, jq, flock.
# Run: bash reference/tests/techlead-manifest-prompt.test.sh

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../runtime/crewboss-prep-spawn-gh.sh"
BOARD_SRC="$HERE/../../proto/r6/board-gh.sh"
TEAM_EXAMPLE="$(cd "$HERE/../../team-example" && pwd)"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

CID=10
CB_REPO_VAL="test/repo"

# ── bare remote (plays role of "GitHub" for git clone) ────────────────────────
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
rm -rf "$_t"

# ── Composition block (2 leaves with roles from team-example) ─────────────────
COMP_BODY="## Composition (machine)
- approach: parallel execution
- role: go-backend-dev
- role: qa-engineer
- leaf: L-1 -> go-backend-dev
- leaf: L-2 -> qa-engineer
- est_cost_usd: 1.0"

# Build JSON payloads (export so gh stub can read them)
COMMENTS_JSON="$(jq -cn --arg b "$COMP_BODY" '{"comments":[{"body":$b}]}')"
CHARTER_JSON='{"number":10,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:needs-plan"}],"body":"Charter test goal."}'

export REMOTE CID CB_REPO_VAL COMMENTS_JSON CHARTER_JSON ROOT

# ── fake bin ──────────────────────────────────────────────────────────────────
FAKEBIN="$ROOT/bin"
mkdir -p "$FAKEBIN"
GIT_REAL="$(command -v git)"
export GIT_REAL FAKEBIN

# gh stub: handles auth token + board get (issue body) + composition fetch (comments)
cat > "$FAKEBIN/gh" << 'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ROOT/gh.log"
case "$1 ${2:-}" in
  "auth token") printf 'fake-token\n'; exit 0 ;;
  "issue view")
    # Distinguish --json comments (composition fetch) vs --json number,... (board get)
    json_field=""
    prev=""
    for arg in "$@"; do
      [ "$prev" = "--json" ] && json_field="$arg" && break
      prev="$arg"
    done
    case "$json_field" in
      *comments*) printf '%s\n' "$COMMENTS_JSON"; exit 0 ;;
      *)          printf '%s\n' "$CHARTER_JSON";  exit 0 ;;
    esac
    ;;
esac
exit 0
GHEOF
chmod +x "$FAKEBIN/gh"

# git stub: redirect GitHub HTTPS URLs to local REMOTE; pass everything else through
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

# crewboss-spawn.sh stub: save prompt content for assertions then exit 0
PROMPT_SAVED="$ROOT/prompt-saved.txt"
export PROMPT_SAVED
cat > "$CB_HOME_DIR/crewboss-spawn.sh" << 'SPAWNEOF'
#!/usr/bin/env bash
# Args: <id> <role> <prompt-file> <workdir> <repo>
cat "$3" > "$PROMPT_SAVED"
exit 0
SPAWNEOF
chmod +x "$CB_HOME_DIR/crewboss-spawn.sh"

# ── CB_MANIFEST: copy of team-example ─────────────────────────────────────────
CB_MANIFEST_DIR="$ROOT/manifest"
cp -r "$TEAM_EXAMPLE/." "$CB_MANIFEST_DIR"

# ── Runner helper ─────────────────────────────────────────────────────────────
# Run with CB_MANIFEST set
run_with_manifest(){
  : > "$PROMPT_SAVED"
  PATH="$FAKEBIN:$PATH" \
    CB_HOME="$CB_HOME_DIR" \
    CB_REPO="$CB_REPO_VAL" \
    CB_MANIFEST="$CB_MANIFEST_DIR" \
    GH_TOKEN="fake-token" \
    bash "$SCRIPT" "$CID" tech-lead > "$ROOT/run.log" 2>&1 || true
}

# Run without CB_MANIFEST (unset in environment)
run_without_manifest(){
  : > "$PROMPT_SAVED"
  env -u CB_MANIFEST \
    PATH="$FAKEBIN:$PATH" \
    CB_HOME="$CB_HOME_DIR" \
    CB_REPO="$CB_REPO_VAL" \
    GH_TOKEN="fake-token" \
    bash "$SCRIPT" "$CID" tech-lead > "$ROOT/run.log" 2>&1 || true
}

# =============================================================================
echo "== RED-1: CB_MANIFEST → prompt has roles, leaf-id map, role: label instruction =="
# =============================================================================
: > "$ROOT/gh.log"
run_with_manifest

# Both composition roles must be present
grep -qF "go-backend-dev" "$PROMPT_SAVED" \
  && ok "RED-1: prompt contains role go-backend-dev" \
  || ko "RED-1: prompt missing role go-backend-dev (log: $(cat "$ROOT/run.log" 2>/dev/null | tail -5))"

grep -qF "qa-engineer" "$PROMPT_SAVED" \
  && ok "RED-1: prompt contains role qa-engineer" \
  || ko "RED-1: prompt missing role qa-engineer"

# Both leaf-id map entries must be present
grep -qF "L-1" "$PROMPT_SAVED" \
  && ok "RED-1: prompt contains leaf-id L-1" \
  || ko "RED-1: prompt missing leaf-id L-1"

grep -qF "L-2" "$PROMPT_SAVED" \
  && ok "RED-1: prompt contains leaf-id L-2" \
  || ko "RED-1: prompt missing leaf-id L-2"

# role: label instruction must be present
grep -q "role:" "$PROMPT_SAVED" \
  && ok "RED-1: prompt contains role: label instruction" \
  || ko "RED-1: prompt missing role: label instruction"

# =============================================================================
echo "== RED-2: no CB_MANIFEST → HD-1 anchors present, no composition data =="
# =============================================================================
: > "$ROOT/gh.log"
run_without_manifest

# HD-1 anchor substrings of the existing tech-lead prompt
grep -qF "You are the tech-lead." "$PROMPT_SAVED" \
  && ok "RED-2: prompt has HD-1 anchor 'You are the tech-lead.'" \
  || ko "RED-2: prompt missing HD-1 anchor 'You are the tech-lead.' (log: $(cat "$ROOT/run.log" 2>/dev/null | tail -5))"

grep -qF "type:agent" "$PROMPT_SAVED" \
  && ok "RED-2: prompt has HD-1 anchor 'type:agent'" \
  || ko "RED-2: prompt missing HD-1 anchor 'type:agent'"

grep -qF "status:plan-review" "$PROMPT_SAVED" \
  && ok "RED-2: prompt has HD-1 anchor 'status:plan-review'" \
  || ko "RED-2: prompt missing HD-1 anchor 'status:plan-review'"

# Must NOT contain any composition data
grep -qF "go-backend-dev" "$PROMPT_SAVED" \
  && ko "RED-2: prompt contains 'go-backend-dev' without CB_MANIFEST — composition leaked" \
  || ok "RED-2: prompt does NOT contain composition role without CB_MANIFEST"

grep -qF "Approved composition" "$PROMPT_SAVED" \
  && ko "RED-2: prompt contains 'Approved composition' without CB_MANIFEST" \
  || ok "RED-2: prompt does NOT contain 'Approved composition' without CB_MANIFEST"

# =============================================================================
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
