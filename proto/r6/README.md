# Round 6 — real GitHub board adapter (gh issues+labels ⇄ launcher) — validated 2026-06-10

Round 5b proved the launcher state machine on a local-JSON board. Round 6 swaps that for
the **real GitHub board**: canonical state lives in issue labels (per `board-orchestration.md`),
run-state (pid/starttime/tries) stays launcher-local. Reuses the canonical predicate
`launchable.sh` from `reference/launcher/` verbatim.

## Pieces
- **`board-gh.sh`** — the adapter. `launchable` (pipes `gh issue list --json` through the
  canonical `launchable.sh`), `get <id> <field>` (state/kind/role/charter/deps/held/pr_repo/
  prompt — labels + body markers `Charter: #N` / `Depends-on: #X`), `claim` (+`status:in-progress`
  +`claimed-by:<id>`), `route review|blocked|requeue` (label flips + a triage comment on
  blocked). Run-state never touches gh — only canonical board state does (§9).
- **`crewboss-launcher-gh.sh`** — the loop driving the real board: same state machine as 5b
  but board ops go through `board-gh.sh`; pid/starttime/tries under `run/state/<id>/`.
- **`crewboss-prep-spawn-gh.sh`** — gh-twin of the 5c adapter: reads pr_repo+prompt from the
  board (the **issue body is the prompt** — design: issues must be self-contained), does the
  §4.5 repo prep, calls `crewboss-spawn.sh`.

## Validation (all against the real `stratch1989/crewboss-proto`)
- **`run-board-gh-test.sh` 14/14** (adapter, no spend): charter-approval gate, dep gate
  (open dep blocks → closing it unblocks), `get` fields, claim→in-progress (drops from
  launchable), route→review, route→blocked+comment, hold veto.
- **`run-launcher-gh-test.sh` 8/8** (loop with stub spawn, no spend): success→claim+review,
  fail→retry→blocked at cap (+ blocked task not re-spawned), reconcile orphaned in-progress
  (dead pid → requeue), budget hard-stop ends the cycle and requeues.
- **`run-gh-e2e.sh` (capstone, one paid run $0.191):** a real issue #25 (`Charter: #24`,
  charter approved) → **`launcher-gh once`** → claim → real adapter → **hardened jail** →
  agent edits+commits+pushes+opens PR → route → **issue #25 ends in `status:review`**. Real
  **[PR #26](https://github.com/stratch1989/crewboss-proto/pull/26)** (only README.md);
  status.json done/cost/pr, budget incremented, **0 OAuth-token leaks**. A real GitHub issue,
  picked up by the loop, became a real PR — fully sandboxed, no human in the loop.

## Notes / grables
- **Transient `gh` 401:** GitHub's API returned `401 Requires authentication` on a graphql
  call mid-run once (token was fine — `gh api user` healthy seconds later). The e2e wraps
  issue creation in `ghretry` (5×, 3s backoff); a prod launcher should retry idempotent gh
  reads similarly rather than treat a blip as a hard failure.
- **`review` vs `done`:** the loop routes a successful spawn to `status:review` (executor
  opened a PR — awaiting the merge-gate), NOT `done`. Closing the issue/charter happens at
  merge (merge-gate §5.2 / scope-completion §5.1), which is the governance layer — not the
  launcher's job.
- Fixed a benign `cp same file` when the adapter's prompt path equals the spawn's
  (`-ef` guard in `crewboss-spawn.sh`).

## Still open
- merge-gate + `--agent executor` role-gating (governance, validated on the roles branch)
  wired on top; backgrounded parallel spawns (loop is synchronous per task); the real
  Quarter repo (node→20/Expo → re-capture seccomp policy; fine-grained PAT; charter branches).
