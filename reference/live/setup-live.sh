#!/usr/bin/env bash
# crewboss — set up an ISOLATED live sandbox on GitHub to exercise the one thing the harnesses
# can't: launcher -> real `claude --agent executor` -> real PR -> merge against branch protection.
# Creates a PRIVATE throwaway repo with the crewboss config committed (TRACKED, so worktrees see
# it), seed labels/issues, a trivial CI check, and branch protection. Idempotent-ish.
#
# Usage: bash setup-live.sh [repo-name] [local-dir]
#   defaults: repo-name=crewboss-live  local-dir=$HOME/<repo-name>
# Requires: gh (auth, repo+workflow scopes), git, jq.
set -euo pipefail

REF="$(cd "$(dirname "$0")/.." && pwd)"          # …/reference
OWNER="$(gh api user --jq '.login')"
REPO="${1:-crewboss-live}"
DIR="${2:-$HOME/$REPO}"
SLUG="$OWNER/$REPO"

echo "owner=$OWNER  repo=$SLUG  dir=$DIR"
[ -e "$DIR" ] && { echo "ABORT: $DIR already exists — remove it or pass another dir"; exit 1; }
gh repo view "$SLUG" >/dev/null 2>&1 && { echo "ABORT: repo $SLUG already exists — delete it first (gh repo delete $SLUG)"; exit 1; }

# ── 1. local repo + crewboss config (committed, so launched worktrees inherit hook+agents) ──
mkdir -p "$DIR"/.claude/hooks "$DIR"/.claude/agents "$DIR"/src "$DIR"/.github/workflows
cp "$REF"/.claude/agents/*.md "$DIR"/.claude/agents/
cp "$REF"/.claude/hooks/crewboss-gate.sh "$DIR"/.claude/hooks/
chmod +x "$DIR"/.claude/hooks/crewboss-gate.sh

# permissions.allow is REQUIRED for unattended ("launch and sleep") operation: a headless
# `claude -p` executor with default perms stalls on the approval prompt for every Bash/Edit and
# does nothing. Allowing the tools lets them run; the crewboss hook is still the gate (eval order
# hooks -> deny -> mode -> ask -> allow, so the hook's deny on gated verbs wins over allow).
cat > "$DIR/.claude/settings.json" <<'JSON'
{
  "permissions": {
    "allow": ["Bash", "Edit", "Write", "Read"]
  },
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/crewboss-gate.sh" } ] }
    ]
  }
}
JSON

cat > "$DIR/src/math.js" <<'JS'
// tiny utils — executors extend this
module.exports = {};
JS
cat > "$DIR/package.json" <<'PKG'
{ "name": "crewboss-live", "version": "0.0.0", "scripts": { "test": "node -e \"require('./src/math.js'); console.log('ok')\"" } }
PKG
cat > "$DIR/.github/workflows/ci.yml" <<'YML'
name: ci
on: [pull_request]
jobs:
  ci:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: npm test
YML
cat > "$DIR/README.md" <<MD
# $REPO — crewboss live sandbox

Throwaway repo to exercise the crewboss launcher end-to-end. Safe to delete:
\`gh repo delete $SLUG --yes\`  then  \`rm -rf $DIR\`
MD

( cd "$DIR"
  git init -q
  git add -A
  git commit -qm "chore: crewboss live sandbox (config + ci + seed)"
  git branch -M master
)

# ── 2. create the private repo + push ───────────────────────────────────────────────────
echo "creating private repo $SLUG …"
( cd "$DIR" && gh repo create "$SLUG" --private --source=. --remote=origin --push )

# ── 3. labels (state-machine) ────────────────────────────────────────────────────────────
echo "labels …"
mklabel(){ gh label create "$1" --repo "$SLUG" --color "$2" --force >/dev/null 2>&1 || true; }
mklabel type:charter 5319e7; mklabel type:agent 1d76db; mklabel type:human-decision b60205
mklabel status:approved 0e8a16; mklabel status:plan-review fbca04; mklabel status:in-progress d4c5f9
mklabel status:review 0052cc; mklabel status:blocked b60205; mklabel status:hold 000000

# ── 4. seed issues: 1 approved charter + 2 launchable leaves ──────────────────────────────
echo "issues …"
CH=$(gh issue create --repo "$SLUG" --title "Charter: tiny math utils" \
  --body "Goal: a couple of pure math helpers in src/math.js, each shipped via its own PR." \
  --label type:charter --label status:approved | grep -oE '[0-9]+$')
echo "  charter #$CH"
L1=$(gh issue create --repo "$SLUG" --title "add add(a,b)" \
  --body "Implement \`add(a,b)\` in src/math.js returning a+b (CommonJS export). Keep it minimal.

Charter: #$CH" --label type:agent | grep -oE '[0-9]+$')
L2=$(gh issue create --repo "$SLUG" --title "add sub(a,b)" \
  --body "Implement \`sub(a,b)\` in src/math.js returning a-b (CommonJS export). Keep it minimal.

Charter: #$CH" --label type:agent | grep -oE '[0-9]+$')
echo "  leaves #$L1 #$L2"

# ── 5. branch protection on master (server-side anchor; non-fatal — private BP needs a paid plan) ──
echo "branch protection …"
if gh api -X PUT "repos/$SLUG/branches/master/protection" -H "Accept: application/vnd.github+json" --input - <<'JSON' >/dev/null 2>&1
{
  "required_status_checks": null,
  "enforce_admins": true,
  "required_pull_request_reviews": { "required_approving_review_count": 1, "dismiss_stale_reviews": true },
  "restrictions": null
}
JSON
then echo "  ✓ protection set (require PR + 1 non-author approval, enforce_admins=true)"
else echo "  ⚠ branch protection NOT set (private-repo plan limitation?). The hook-side merge-gate still"
     echo "    works; to demo the server-side anchor too, recreate the repo --public (BP is free there)."
fi

cat <<DONE

✓ live sandbox ready: $SLUG  (clone at $DIR)
  predicate should see leaves #$L1 #$L2 launchable under approved charter #$CH.

NEXT (your hands — these spend an agent session; run from the clone):
  cd "$DIR"
  # dry-run first — confirm the launcher plans to launch the two leaves:
  bash "$REF/launcher/crewboss-launcher.sh" --once --dry-run
  # live: launches a real \`claude --agent executor\` per leaf -> opens a PR, stops at review:
  bash "$REF/launcher/crewboss-launcher.sh" --once

  Then verify the merge-gate (see live/README.md): a tech-lead merge with NO approval must be
  DENIED by the hook; branch protection blocks a direct push to master.

Teardown:  gh repo delete $SLUG --yes && rm -rf "$DIR"
DONE
