# crewboss — live sandbox run

Exercises the one thing the harnesses can't: **launcher → real `claude --agent executor` → real PR
→ merge against the hook's proof-gate + branch protection.** Everything else (role+hook gating,
Layer-A/B verdicts, launcher mechanics, the data-loss fix) is already locked by the test suite.

## 0. Create the sandbox (done by `setup-live.sh`)

```
bash reference/live/setup-live.sh        # creates a PRIVATE repo + issues + config + BP
```
Prints the clone dir (default `$HOME/crewboss-live`) and the seeded issue numbers.

## 1. Dry-run — confirm the planner

```
cd "$HOME/crewboss-live"
bash <ref>/launcher/crewboss-launcher.sh --once --dry-run
```
Expect: `DRY launch #<leaf1>` and `DRY launch #<leaf2>` (the two leaves under the approved charter).

## 2. Live — launcher spawns a real executor per leaf (spends agent sessions)

```
bash <ref>/launcher/crewboss-launcher.sh --once
```
No trust prompt: `claude -p` (print mode) disables folder-trust verification, so a fresh worktree
runs unattended. The committed `.claude/settings.json` carries **both** the PreToolUse hook **and**
`permissions.allow` — the allowlist lets the executor's tools run without a prompt (headless has no
one to approve), while the hook still gates the dangerous subset (it runs first; an exit-2 hook
deny beats any allow rule). Without the allowlist, an unattended `claude -p` stalls on every
approval prompt and does nothing — that is exactly what a first run surfaced. What to watch / verify:
- a `task/<n>` branch + worktree is created, the executor implements the issue and opens a PR;
- the issue label flips `status:in-progress → status:review`;
- the executor **stops at "PR opened"** — if it *tries* to merge, the hook BLOCKS it
  (`crewboss BLOCK [executor]: board-authorship/merge is tech-lead-only`). That block is the point.

## 3. Merge-gate (deny path) — no 2nd reviewer needed

With a PR open and unapproved, a tech-lead merge must be refused by the hook:
```
claude --agent tech-lead -p "Merge PR #<n>."
# expect the session to hit: crewboss BLOCK [tech-lead]: merge gate: not APPROVED by a non-author (§5.2)
```
And branch protection refuses a direct push to master:
```
git push origin HEAD:master    # expect: protected branch / PR required (if BP was set)
```

## 4. Merge-gate (allow path) — OPTIONAL, needs a 2nd account

You can't approve your own PR. With a second reviewer approving + CI green, the same tech-lead
merge should SUCCEED — that's the happy-path proof. Skip if solo; note it as un-run.

## Teardown

```
gh repo delete <owner>/crewboss-live --yes && rm -rf "$HOME/crewboss-live"
```
(`gh repo delete` needs the `delete_repo` scope: `gh auth refresh -s delete_repo`.)
