# Round 11 — tech-lead via the launcher: full autonomy chain — validated 2026-06-10

Closes the loop: a **boss charter** is decomposed by a **tech-lead** (run by the launcher),
the plan is approved, and **executors** run the leaves — all board-driven, no human spawning.

## What was added
- **`board-gh.sh plannable`** — charters awaiting decomposition (`type:charter` +
  `status:needs-plan`, open, not held); `get state` extended with approved/plan-review/needs-plan.
- **`crewboss-prep-spawn-gh.sh`** — role-aware prompt: a `tech-lead` spawn is told to
  decompose charter #N into leaf sub-issues (`Charter: #N` + self-contained body, optional
  `Depends-on:`) and set the charter to `plan-review`. A leaf still gets its issue body.
- **`crewboss-launcher-gh.sh run`** — a planning pass (a `needs-plan` charter → background
  `--agent tech-lead` spawn) alongside the leaf-executor pass; charter-aware routing (route
  a finished plan by the charter's own label: plan-review→done, else retry/blocked — never
  "review"); idle-exit **debounced** (`CB_IDLE_CONFIRM` consecutive empty ticks) against lag.
- **`gov/.claude/agents/tech-lead.md`** — role (tools: Read, Bash; no Edit/Write/Agent); the
  gate already permits tech-lead board-authorship (Layer A) and gates merge (Layer B).

## Live result (`run-techlead-test.sh`, paid ~$0.22)
1. boss files charter **#49** (`status:needs-plan`): "polish the README, make exactly 2 leaves".
2. **PHASE 1** — launcher spawns a tech-lead → it created **#50** (add Usage) and **#51**
   (add license note) and set #49 → `plan-review`.
3. boss **approves** (#49 → `status:approved`).
4. **PHASE 2** — launcher spawns an executor for the launchable leaf **#50** → it opened
   **PR #52** → #50 → `review`.
5. **#51 correctly WAITED** — the tech-lead had autonomously added `Depends-on: #50` to #51
   ("must run after #50 is merged to avoid a merge conflict on the same file"), and the
   launcher honored the ordering: #51 is not launchable while #50 is open. This is the
   dependency graph working live, not a bug. #51 runs once #50 merges.

## Honest gap (unchanged)
To merge #50 (and thereby unblock #51) you need the merge step: a non-author approval +
green checks (Layer B) + server-side branch protection — unavailable on a private free repo
(needs a public/paid repo or a second reviewer). The gate holds the line correctly until then.

## Note
The earlier "straggler #51" looked like a premature idle-exit; investigation showed it was
correct dependency-gating. The idle-debounce was kept anyway as cheap insurance against
genuine `gh` read-after-write lag.
