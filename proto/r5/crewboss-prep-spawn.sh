#!/usr/bin/env bash
# Prod adapter that satisfies the launcher's `$SPAWN <id> <role>` contract by doing the
# per-task prep the real crewboss-spawn.sh needs, then calling it with full args:
#   - read pr_repo + prompt from the board task
#   - §4.5 repo prep: mirror -> local clone -> push-fix remote (token) -> branch
#   - write prompt to a file
#   - crewboss-spawn.sh <id> <role> <prompt-file> <work-dir> <pr_repo>
# Exit code is crewboss-spawn.sh's (0 done | 2 fail | 3 budget) so routing works unchanged.
set -uo pipefail
CB_HOME="${CB_HOME:-/tmp/cbnet}"
RUN="$CB_HOME/run"; BOARD="$RUN/board"
ID="$1"; ROLE="$2"
T="$BOARD/$ID.json"
PR_REPO=$(jq -r '.pr_repo // empty' "$T")
PROMPT=$(jq -r '.prompt // empty' "$T")
[ -n "$PR_REPO" ] || { echo "adapter: #$ID has no pr_repo" >&2; exit 2; }
GH_TOKEN="${GH_TOKEN:-$(gh auth token)}"; export GH_TOKEN
TS=$(date +%s)
WA="$RUN/work/$ID/repo"; rm -rf "$RUN/work/$ID/repo" 2>/dev/null; mkdir -p "$WA"
PF="$RUN/work/$ID/task.prompt"; printf '%s\n' "$PROMPT" > "$PF"

# §4.5 prep (floor, host network — trusted)
git clone --mirror "https://github.com/$PR_REPO.git" "$WA/mirror.git" >/dev/null 2>&1
git clone --local "$WA/mirror.git" "$WA/work" >/dev/null 2>&1
cd "$WA/work"
git remote set-url --push origin "https://x-access-token:${GH_TOKEN}@github.com/$PR_REPO.git"
BR="task/$ID-$TS"
git checkout -q -b "$BR"
echo "$BR" > "$RUN/work/$ID/branch"
# spawn drops the prompt into the work dir as .task.prompt — never let it be committed
echo ".task.prompt" >> "$WA/work/.git/info/exclude"

exec "$CB_HOME/crewboss-spawn.sh" "$ID" "$ROLE" "$PF" "$WA/work" "$PR_REPO"
