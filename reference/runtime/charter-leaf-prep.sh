#!/usr/bin/env bash
# charter-aware leaf dispatch (CB_SPAWN override for the launcher).
# Runs an executor for leaf $ID on its charter's INTEGRATION branch charter/C
# (C derived from the issue body "Charter: #C"). The leaf branches OFF charter/C
# and opens its PR INTO charter/C — never main. charter/C is created off main on
# first use (under a per-charter flock). Honors the "review = whole charter" model.
# Usage (matches launcher contract): charter-leaf-prep.sh <id> <role>
set -uo pipefail
CB_HOME="${CB_HOME:-$HOME/cbnet}"; RUN="$CB_HOME/run"
CB_REPO="${CB_REPO:-stratch1989/crewboss}"
ID="$1"; ROLE="${2:-executor}"
GH_TOKEN="$(gh auth token)"; export GH_TOKEN
# Token-free URL: CB_GIT_REMOTE from run-env.sh if set; else build from CB_REPO.
# Credential helper (GIT_CONFIG_*) provides GH_TOKEN at git call time — no token in URL.
URL="${CB_GIT_REMOTE:-https://github.com/${CB_REPO}.git}"
# Register inline credential helper if not already done by a parent (e.g. run-env.sh).
# Inline function: no file path → valid in both host and jail namespaces.
# nsjail keep_env (-e, crewboss-spawn.sh:82) + --env GH_TOKEN (spawn.sh:62) carry both
# this registration and the token into the jail on every spawn.
# shellcheck disable=SC2016
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=credential.helper
export GIT_CONFIG_VALUE_0='!f(){ echo username=x-access-token; echo password=$GH_TOKEN; }; f'
BODY="$(gh issue view "$ID" -R "$CB_REPO" --json body --jq .body 2>/dev/null)"
C="$(printf '%s' "$BODY" | grep -oiE 'charter:[[:space:]]*#?[0-9]+' | head -1 | grep -oE '[0-9]+')"
[ -n "$C" ] || { echo "leaf #$ID: no 'Charter: #N' in body" >&2; exit 2; }
CB="charter/$C"

WA="$RUN/work/$ID/repo"
rm -rf "$WA" 2>/dev/null || sudo rm -rf "$WA" 2>/dev/null || true
mkdir -p "$WA"
git clone -q "$URL" "$WA/work" || { echo "leaf #$ID: clone failed" >&2; exit 2; }
cd "$WA/work"
# Push URL also token-free; credential helper provides GH_TOKEN at push time.
git remote set-url --push origin "$URL"

# ensure charter/C exists on origin (create off origin/main if absent), serialized per charter
mkdir -p "$RUN"
( flock 9
  if ! git ls-remote --exit-code --heads origin "$CB" >/dev/null 2>&1; then
    main_sha="$(git rev-parse origin/main)"
    git push -q origin "$main_sha:refs/heads/$CB" 2>/dev/null || true
  fi
) 9>"$RUN/charter-$C.lock"

git fetch -q origin "$CB" 2>/dev/null || true
TS="$(date +%s)"
# Freshness guard: if charter/C is behind main with no own commits → fast-forward push;
# if it has own commits and is stale → loud dispatch refusal.
if git rev-parse --verify -q "origin/$CB" >/dev/null 2>&1; then
  behind=$(git rev-list --count "origin/$CB..origin/main" 2>/dev/null || echo 0)
  if [ "$behind" -gt 0 ]; then
    own=$(git rev-list --count "origin/main..origin/$CB" 2>/dev/null || echo 0)
    if [ "$own" -eq 0 ]; then
      main_sha="$(git rev-parse origin/main)"
      git push -q origin "$main_sha:refs/heads/$CB" 2>/dev/null \
        || { echo "leaf #$ID: ff push of $CB failed" >&2; exit 2; }
      git fetch -q origin "$CB" 2>/dev/null || true
    else
      echo "leaf #$ID: $CB is behind origin/main by $behind commits with $own own commits — stale base, dispatch refused" >&2
      exit 2
    fi
  fi
fi
if git rev-parse --verify -q "origin/$CB" >/dev/null; then
  git checkout -q -b "leaf/$ID-$TS" "origin/$CB"
else
  echo "leaf #$ID: $CB missing after create attempt" >&2; exit 2
fi

PROMPT="You are the executor for issue #$ID in repo $CB_REPO.
Hard rules for THIS run:
- You are ALREADY on branch leaf/$ID-$TS, based on the charter integration branch '$CB' (NOT main). Sibling leaves of charter #$C may already be merged into '$CB'. Commit your work on THIS branch. Do NOT create or switch to any other branch.
- When the work is done and the verification gate is green, push this branch (git push -u origin HEAD) and open ONE pull request: gh pr create --base $CB --title '<short>' --body 'Closes #$ID'. The PR base MUST be '$CB', NOT main. Then STOP — do not merge, do not touch other issues.
- This issue is self-contained; everything you need is below.

---- TASK (issue #$ID) ----
$BODY"
PF="$RUN/work/$ID/task.prompt"; printf '%s' "$PROMPT" > "$PF"
exec "$CB_HOME/crewboss-spawn.sh" "$ID" "$ROLE" "$PF" "$WA/work" "$CB_REPO"
