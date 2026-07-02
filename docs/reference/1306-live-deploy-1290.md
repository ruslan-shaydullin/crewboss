# Leaf #1306 — Deploy charter #1290 live-loop fixes to the box (runbook + report)

**Charter:** #1290  **Depends-on (all merged):** #1303, #1304, #1305
**Role:** infra-engineer

## What this leaf ships

Charter #1290 changed the deployed live-loop runtime. Its executor leaves are merged
into `charter/1290`:

- **#1303** — classify env-fail as retryable *infra* red, never a confirmed *code* red.
- **#1304** — triage crash-death survives the RL-storm and retries instead of terminal park.
- **#1305** — rework-PR hygiene: route rework creation through `cb_pr_create`, close
  superseded siblings.

Those fixes live in five runtime files under `reference/runtime/`:

| file | sha-locked in manifest |
|------|------------------------|
| `crewboss-launcher-gh.sh` | yes |
| `crewboss-integrator.sh`  | yes |
| `cb-pr-create.sh`         | yes |
| `rework-prep.sh`          | yes |
| `smoke-runner.sh`         | no (not present in `reference/runtime-manifest.tsv`) |

During the 2026-07-02 incident these fixes had to be applied by hand (state reset, PR
closing, role deploy). This leaf makes the merged fixes **actually live, safely** —
without a blind `deploy-runtime.sh` overwrite of the running loop mid-session.

## Why not `deploy-runtime.sh`

`deploy-runtime.sh` blind-scps **every** canonical file and hard-restarts the API. For
the live launcher loop a mid-tick overwrite can corrupt an in-flight spawn / integrator
merge — the exact incident class we are fixing. Instead, `deploy-live-swap.sh` swaps only
the five #1290 files and only **between ticks**, with a byte-exact rollback.

## The safe deploy tool

`reference/runtime/deploy-live-swap.sh` (subcommands `deploy` / `simulate`):

1. **BACKUP** — snapshot the currently-deployed five files (+ their sha256, + the box
   manifest copy) into `$CB_HOME/backups/deploy-1306-<ts>/` so rollback is byte-exact.
2. **QUIESCE (between ticks)** — write `run/kill_switch`; the launcher loop checks it at
   the *top* of the next tick and exits `42` **before** spawning anything (see
   `crewboss-launcher-gh.sh` `cmd_run`). Wait for `run/launcher.pid` to clear, then
   `systemctl stop crewboss-launcher` so `Restart=always` cannot relaunch the OLD code.
3. **SWAP** — `cp` the merged files over the deployed ones (`chmod 0755`) and refresh the
   box `runtime-manifest.tsv` copy so the doctor drift check reflects the new sha-lock.
4. **RESTART** — clear `run/kill_switch`, `systemctl start crewboss-launcher` on NEW code.
5. **VERIFY** — `crewboss-doctor.sh` (drift: deployed sha256 == manifest) **and** observe
   one full healthy tick (tick counter advances).
6. **SHA-LOCK** — re-confirm each deployed file's sha256 == its
   `reference/runtime-manifest.tsv` entry.
7. **ROLLBACK** — on any unhealthy signal in 5/6, restore the backup, restart, re-run the
   doctor, exit non-zero. A report is printed and appended to `run/deploy-1306.log`
   **either way**.

### Operator runbook (on the box)

```bash
cd ~/crewboss                      # repo checkout on the box
git fetch origin && git checkout charter/1290   # (or main once #1290 lands)
CB_HOME=~/cbnet bash reference/runtime/deploy-live-swap.sh deploy
# On SUCCESS: charter #1290 fixes are live, doctor green, one healthy tick observed.
# On FAILURE: automatically rolled back to the pre-deploy state; see run/deploy-1306.log.
```

Config seams: `CB_HOME`, `CB_LAUNCHER_UNIT` (default `crewboss-launcher`), `CB_SYSTEMCTL`
(default `sudo systemctl`), `CB_DOCTOR`, `CB_QUIESCE_TIMEOUT`, `CB_TICK_TIMEOUT`,
`CB_TICK_PROBE`, `CB_DEPLOY_MANIFEST`.

## Rehearsal evidence

`deploy-live-swap.sh simulate` builds a throwaway `CB_HOME` with OLD stub files and a fake
`systemctl` driving a fake loop (honours `kill_switch`, increments `run/tick.count`), then
runs the entire path. (No box manifest is placed in the sim, so the doctor's box-wide drift
check — which needs all ~76 canonical files present — is skipped; the targeted sha-lock of
the five deployed files is still asserted against the real repo manifest by step 6.)

**Success path** — `SIM_EXIT=0`:

```
[deploy-1306] setting kill_switch — loop will exit cleanly at next tick top (exit 42)
[deploy-1306] loop reached tick boundary (after 1s) — stopping unit ...
[deploy-1306] swapped: crewboss-launcher-gh.sh ... rework-prep.sh
=== doctor ===        [doctor] 0 problem(s) detected            doctor: healthy
=== observe one full tick === observed a completed tick (4 -> 5) after 1s
=== sha-lock confirmation (deployed == manifest) ===
  ok   crewboss-launcher-gh.sh ccbe18aa...
  ok   crewboss-integrator.sh  eb462f89...
  n/a  smoke-runner.sh (not sha-locked in manifest) ...
  ok   cb-pr-create.sh         ea13d5b1...
  ok   rework-prep.sh          67406917...
RESULT: SUCCESS — charter #1290 fixes are live and verified
```

**Rollback path** — forced unhealthy tick (`CB_TICK_TIMEOUT` too short, tick never
advances). The five files are restored to their exact pre-deploy sha256:

```
doctor: healthy
TICK FAIL: no tick completed within 4s (stuck at 0)
!!! ROLLBACK: restoring from .../backups/deploy-1306-<ts>
  restored: crewboss-launcher-gh.sh ... rework-prep.sh
RESULT: FAILED (health=1 shalock=0) — rolled back to pre-deploy state
# post-rollback sha == pre-deploy OLD sha (byte-exact restore verified)
```

## Acceptance (machine)

- `bash crewboss-doctor.sh` — repo-root entrypoint that delegates to the canonical
  `reference/runtime/crewboss-doctor.sh` (single source of truth; the file sha-locked in
  the manifest and deployed to the box). Runs the same drift + process/tunnel checks.
- `bash reference/tests/runtime-manifest.test.sh` — repo↔manifest sha-lock is intact for
  all five files (Test 3 canonical sha-lock: green).
