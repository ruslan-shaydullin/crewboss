# Leaf #1332 — lint-catalog-rollout (runbook + report)

**Charter:** #1291  **Depends-on (all merged):** #1329, #1330, #1331
**Role:** infra-engineer

P4 of charter #1291 (label-taxonomy lint) + team-catalog sync in deploy + live
rollout of the merged charter changes.

## Incident context (cold start)

- **2026-07-02** — two zombie charters (#306, #291) stormed the finale scan; a
  bare-`hold` operator veto sat on both.
- Separately, issue **#1281** was routed into role `triage` whose file was **absent
  from the box** because the live **team catalog was never part of the deploy
  process** — roles `triage` / `reviewer` / `recovery-lead` reached the box only by
  operator hand. The spawned session silently crash-died.

## 1. Label-taxonomy lint (report-only)

Implemented in `reference/runtime/crewboss-doctor.sh` as `--lint-labels` — a doctor
**WARNING**, never a mutation.

### Canonical decision (FIXED, no alternative)

The **bare `hold`** label is the canonical operator veto. It matches the six live
launcher filters `index("hold")` (`crewboss-launcher-gh.sh` :2478, :2507, :2714,
:2762, :2850, :2871) and the board label description «veto: never launch».
Therefore:

- **bare `hold` is NEVER flagged** — it is a live control signal, not a taxonomy typo;
- the orphan **`status:hold`** (empty description, zero runtime consumers) **IS flagged**;
- the doctor pins the canonical `status:*` taxonomy set as an **explicit artifact**
  (`CB_STATUS_TAXONOMY`) — the source of truth (none existed in the runtime before);
- any `status:*`-shaped label **outside** the pinned set is flagged
  (e.g. `status:frobnicate`).

The pinned set (16 labels), derived from the live runtime consumers:

```
status:needs-triage  status:needs-plan  status:plan-review  status:needs-analysis
status:approved      status:in-progress status:review       status:team-review
status:acceptance-review  status:needs-rework  status:test-broken  status:impl-broken
status:blocked       status:deferred    status:needs-conflict-resolution  status:needs-recovery
```

### Behaviour / output

```
CB_REPO=<owner/repo> bash reference/runtime/crewboss-doctor.sh --lint-labels
```

reads the board **read-only** (`gh issue list --json labels`), then prints one line
per off-taxonomy label:

```
LINT-FLAG: status:hold  (status:*-shaped label outside pinned taxonomy)
LINT-FLAG: status:frobnicate  (status:*-shaped label outside pinned taxonomy)
```

It **never** edits an issue or a label — the board sha is unchanged. The contract
suite `reference/tests/finale-hygiene.test.sh` (leaf #1329, P4 group, self-activating
on `grep taxonomy` in the doctor) asserts exactly this.

The doctor sha256 is regenerated in `reference/runtime-manifest.tsv` in this PR.

## 2. Team-catalog sync in deploy

Role files now deploy **WITH the code** instead of by operator hand. This complements
the runtime `_cb_role_guard` (#1331), which refuses to route/spawn into a role whose
`.md` file is absent from the live catalog. The guard checks these roots:

- `team/roles` — `$CB_MANIFEST/roles`, `$CB_HOME/team/roles`
- `gov` — `$CB_HOME/gov/.claude/agents`, `$CB_HOME/gov/roles`
- repo `.claude/agents` — `$HERE_LAUNCHER/../.claude/agents`, `$CB_GATE_REPO_DIR/.claude/agents`

Two deploy paths gained a `sync_team_catalog` step (opt-out `CB_SYNC_TEAM=0`):

- **`deploy-runtime.sh`** — ssh-`mkdir` `team/roles` + `gov/.claude/agents` on the box,
  then `scp` every `reference/.claude/agents/*.md` and `team-example/roles/*.md` into
  both roots. Runs before the API restart so the catalog is present when the loop
  comes back up. Best-effort + non-fatal (never aborts a deploy).
- **`deploy-live-swap.sh`** — the same catalog `cp` runs inside `swap_in`, so the NEW
  launcher started at step 4 (RESTART) never trips `_cb_role_guard` on a role that IS
  defined in the repo.

This directly closes the #1281 gap: a routed role can no longer be silently missing
from the box after a deploy.

## 3. Live rollout

Deploy the merged launcher (#1330, #1331) and doctor (this leaf) changes to the box via
the #1306 `deploy-live-swap.sh` path — the safe between-ticks swap, NOT a blind
`deploy-runtime.sh` overwrite of the running loop:

```
# rehearse the full backup → quiesce → swap → restart → verify → sha-lock → rollback path
bash reference/runtime/deploy-live-swap.sh simulate

# on the box (real systemd + real loop)
bash reference/runtime/deploy-live-swap.sh deploy
```

- **QUIESCE at a tick boundary** — `run/kill_switch` makes the loop exit `42` at the
  *top* of its next tick, before any spawn; the unit is then stopped so
  `Restart=always` cannot relaunch OLD code.
- **VERIFY a healthy tick** — `crewboss-doctor.sh` drift check + observe one completed
  tick, then a sha-lock re-confirm (deployed sha256 == `runtime-manifest.tsv`).
- **byte-exact ROLLBACK on unhealthy** — any unhealthy signal restores the pre-deploy
  files from `$CB_HOME/backups/deploy-1306-<ts>/` and restarts.

Post-rollout, run the label-taxonomy lint against the live board to surface any
off-taxonomy labels for operator cleanup (report-only — no mutation):

```
CB_REPO=ruslan-shaydullin/crewboss bash /cbnet/crewboss-doctor.sh --lint-labels
```

## Out of scope

RL-limits (#1274), verify-merged semantics; the #291 recycle-or-resolve decision is a
human call outside this leaf.
