#!/usr/bin/env bash
# role-spawn.test.sh — role-resolved spawn: manifest role prompt + agent injection (issue #137)
#
# Tests crewboss-prep-spawn-gh.sh with CB_MANIFEST set:
#   RED-1: task.prompt includes manifest role body (unique phrase from go-backend-dev.md)
#   RED-2: .claude/agents/go-backend-dev.md injected into work-tree, identical to manifest copy
#   RED-3: unknown role label with CB_MANIFEST → exit 2 (fail-fast typo guard)
#   PINS : regression guards (branch leaf/<id>-<ts>, base charter/<C>, hard-rules block,
#           no-CB_MANIFEST path is byte-for-byte unchanged — role phrase absent)
#
# Class: spawn-unit + integration-stub
# Precedents: spawn-unit.test.sh (spawn primitive), prep-params.test.sh (git/gh stub pattern),
#             charter-branch.test.sh (branch naming), run-liveness.test.sh (setup_remote)

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
PREP_SPAWN="$REPO_ROOT/reference/runtime/crewboss-prep-spawn-gh.sh"
BOARD_SRC="$REPO_ROOT/proto/r6/board-gh.sh"
MANIFEST_LIB="$REPO_ROOT/reference/launcher/manifest.sh"
TEAM_EXAMPLE="$REPO_ROOT/team-example"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
export ROOT

pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

ISSUE_ID=50
CHARTER_ID=9
PR_REPO="test/repo"
# Unique phrase from team-example/roles/go-backend-dev.md body (after frontmatter):
ROLE_UNIQUE="Ultra-narrow zone"
export ISSUE_ID CHARTER_ID PR_REPO

# ── CB_MANIFEST: copy of team-example ────────────────────────────────────────
CB_MANIFEST_DIR="$ROOT/manifest"
cp -r "$TEAM_EXAMPLE" "$CB_MANIFEST_DIR"
export CB_MANIFEST_DIR

# ── board state JSON ─────────────────────────────────────────────────────────
BOARD_STATE="$ROOT/board.json"
cat > "$BOARD_STATE" << JSON
[
  {"number":$CHARTER_ID,"state":"OPEN","labels":[{"name":"type:charter"},{"name":"status:approved"}],"body":"charter body","comments":[]},
  {"number":$ISSUE_ID,"state":"OPEN","labels":[{"name":"type:agent"},{"name":"role:go-backend-dev"}],"body":"Charter: #$CHARTER_ID\nDo the Go backend work.","comments":[]}
]
JSON
export BOARD_STATE

# ── bare remote ──────────────────────────────────────────────────────────────
REMOTE="$ROOT/remote.git"
export REMOTE

setup_remote(){
  rm -rf "$REMOTE"
  git init --bare -q "$REMOTE"
  local tmp; tmp="$(mktemp -d)"
  git clone -q "$REMOTE" "$tmp" 2>/dev/null
  git -C "$tmp" config user.email t@t
  git -C "$tmp" config user.name T
  printf 'base\n' > "$tmp/README.md"
  git -C "$tmp" add -A
  git -C "$tmp" commit -qm init 2>/dev/null
  git -C "$tmp" push -q origin HEAD:refs/heads/main 2>/dev/null || true
  rm -rf "$tmp"
}
setup_remote

# ── fakebin: gh stub + git stub ───────────────────────────────────────────────
FAKEBIN="$ROOT/fakebin"
mkdir -p "$FAKEBIN"
GIT_REAL="$(command -v git)"
export GIT_REAL

# gh stub: returns issue data from BOARD_STATE; handles auth token
cat > "$FAKEBIN/gh" << 'GHEOF'
#!/usr/bin/env bash
case "$1 $2" in
  "auth token") printf 'fake-token\n'; exit 0 ;;
  "issue view")
    n=""
    for a in "$@"; do
      case "$a" in [0-9]*) n="$a"; break ;; esac
    done
    jq --argjson n "${n:-0}" 'map(select(.number==$n))[0] // {}' "$BOARD_STATE"
    exit 0 ;;
  "label create") exit 0 ;;
esac
exit 0
GHEOF
chmod +x "$FAKEBIN/gh"

# git stub: redirects git clone URLs to local REMOTE (avoids real GitHub access);
# also redirects push URL from GitHub to REMOTE so git push succeeds in tests.
cat > "$FAKEBIN/git" << 'GITEOF'
#!/usr/bin/env bash
case "$1" in
  clone)
    shift
    newargs=(); url_seen=0
    for arg in "$@"; do
      if [ "$url_seen" = "1" ] || [[ "$arg" = -* ]]; then
        newargs+=("$arg")
      else
        # Replace any URL (github or local cache path) with the test REMOTE
        newargs+=("$REMOTE"); url_seen=1
      fi
    done
    exec "$GIT_REAL" clone "${newargs[@]}"
    ;;
  remote)
    # Redirect push URL from GitHub to test REMOTE so git push goes to local bare repo
    if [ "${2:-}" = "set-url" ] && [ "${3:-}" = "--push" ]; then
      exec "$GIT_REAL" remote set-url --push "${4:-origin}" "$REMOTE"
    fi
    exec "$GIT_REAL" "$@"
    ;;
  *)
    exec "$GIT_REAL" "$@"
    ;;
esac
GITEOF
chmod +x "$FAKEBIN/git"

# ── CB_HOME setup ─────────────────────────────────────────────────────────────
CB_HOME="$ROOT/cbhome"
export CB_HOME

reset_cbhome(){
  rm -rf "$CB_HOME"
  mkdir -p "$CB_HOME"
  cp "$BOARD_SRC" "$CB_HOME/board-gh.sh"
  chmod +x "$CB_HOME/board-gh.sh"
  # spawn stub: records args to log, exits 0 (work-tree persists for inspection)
  cat > "$CB_HOME/crewboss-spawn.sh" << 'SPAWNEOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$ROOT/spawn-calls.log"
exit 0
SPAWNEOF
  chmod +x "$CB_HOME/crewboss-spawn.sh"
  : > "$ROOT/spawn-calls.log"
  setup_remote
}

run_prep(){
  local role="$1"; shift
  PATH="$FAKEBIN:$PATH" \
    CB_HOME="$CB_HOME" \
    CB_REPO="$PR_REPO" \
    CB_MANIFEST_LIB="$MANIFEST_LIB" \
    "$@" \
    bash "$PREP_SPAWN" "$ISSUE_ID" "$role"
}

# =============================================================================
# RED-1: manifest role prompt body inserted into task.prompt
# =============================================================================
echo "=== RED-1: manifest role prompt inserted into task.prompt ==="
reset_cbhome
CB_MANIFEST="$CB_MANIFEST_DIR" run_prep "go-backend-dev" 2>/dev/null || true

PF="$CB_HOME/run/work/$ISSUE_ID/task.prompt"
[ -f "$PF" ] \
  && ok "RED-1: task.prompt created" \
  || ko "RED-1: task.prompt not found at $PF"

if [ -f "$PF" ]; then
  grep -qF "$ROLE_UNIQUE" "$PF" \
    && ok "RED-1: task.prompt contains role-unique phrase ('$ROLE_UNIQUE')" \
    || ko "RED-1: task.prompt MISSING role phrase — expected '$ROLE_UNIQUE'"

  grep -qF -- "---- TASK" "$PF" \
    && ok "RED-1: '---- TASK' separator present" \
    || ko "RED-1: '---- TASK' separator missing"

  grep -qF "Hard rules for THIS run" "$PF" \
    && ok "RED-1: hard-rules block present" \
    || ko "RED-1: hard-rules block missing"
fi

# =============================================================================
# RED-2: .claude/agents/go-backend-dev.md injected into work-tree
# =============================================================================
echo "=== RED-2: .claude/agents/<role>.md injected into work-tree ==="
AGENT_FILE="$CB_HOME/run/work/$ISSUE_ID/repo/work/.claude/agents/go-backend-dev.md"
[ -f "$AGENT_FILE" ] \
  && ok "RED-2: .claude/agents/go-backend-dev.md exists in work-tree" \
  || ko "RED-2: .claude/agents/go-backend-dev.md MISSING from work-tree"

if [ -f "$AGENT_FILE" ] && [ -f "$CB_MANIFEST_DIR/roles/go-backend-dev.md" ]; then
  diff -q "$AGENT_FILE" "$CB_MANIFEST_DIR/roles/go-backend-dev.md" >/dev/null 2>&1 \
    && ok "RED-2: agent file is byte-identical to manifest role file" \
    || ko "RED-2: agent file differs from manifest role file"
fi

EXCLUDE_FILE="$CB_HOME/run/work/$ISSUE_ID/repo/work/.git/info/exclude"
if [ -f "$EXCLUDE_FILE" ]; then
  grep -qF ".claude" "$EXCLUDE_FILE" \
    && ok "RED-2: .claude entry in .git/info/exclude" \
    || ko "RED-2: .claude NOT in .git/info/exclude"
else
  ko "RED-2: .git/info/exclude not found"
fi

# =============================================================================
# PINS 1-3: regression guards — checked now while RED-1 task.prompt is still live
# =============================================================================
echo "=== PINS 1-3: regression guards (branch/base/hard-rules) ==="

# PIN-1: branch name in prompt is leaf/<id>-<ts>
[ -f "$PF" ] && grep -qE "leaf/$ISSUE_ID-[0-9]+" "$PF" \
  && ok "PIN-1: branch name is leaf/$ISSUE_ID-<ts>" \
  || ko "PIN-1: branch name not found or wrong prefix (expected leaf/$ISSUE_ID-<ts>)"

# PIN-2: charter/<C> base in prompt hard-rules
[ -f "$PF" ] && grep -qF "charter/$CHARTER_ID" "$PF" \
  && ok "PIN-2: charter/$CHARTER_ID base in prompt" \
  || ko "PIN-2: charter/$CHARTER_ID NOT in prompt"

# PIN-3: hard-rules PR base constraint verbatim
[ -f "$PF" ] && grep -qF "The PR base MUST be" "$PF" \
  && ok "PIN-3: hard-rules PR base MUST be constraint present" \
  || ko "PIN-3: hard-rules PR base constraint MISSING"

# =============================================================================
# RED-3: unknown role label + CB_MANIFEST → exit 2 (typo guard)
# =============================================================================
echo "=== RED-3: unknown role with CB_MANIFEST → exit 2 ==="
reset_cbhome
EXIT3=0
CB_MANIFEST="$CB_MANIFEST_DIR" run_prep "no-such-role" 2>/dev/null || EXIT3=$?
[ "$EXIT3" = "2" ] \
  && ok "RED-3: exit code 2 on unknown role label" \
  || ko "RED-3: expected exit 2, got $EXIT3 (typo guard not firing)"

# =============================================================================
# PIN-4: without CB_MANIFEST → role phrase NOT in prompt (no regression to legacy path)
# =============================================================================
echo "=== PIN-4: without CB_MANIFEST, legacy path unchanged ==="
reset_cbhome
run_prep "go-backend-dev" 2>/dev/null || true
PF4="$CB_HOME/run/work/$ISSUE_ID/task.prompt"
if [ -f "$PF4" ]; then
  ! grep -qF "$ROLE_UNIQUE" "$PF4" \
    && ok "PIN-4: without CB_MANIFEST, role phrase NOT in prompt (legacy path unchanged)" \
    || ko "PIN-4: REGRESSION — role phrase found in prompt without CB_MANIFEST"
  grep -qF "Hard rules for THIS run" "$PF4" \
    && ok "PIN-4: without CB_MANIFEST, hard-rules still present" \
    || ko "PIN-4: without CB_MANIFEST, hard-rules MISSING"
else
  ko "PIN-4: task.prompt not created without CB_MANIFEST"
fi

# =============================================================================
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
