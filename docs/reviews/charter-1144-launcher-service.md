# Review: Charter #1144 — Durable launcher supervision (dedicated systemd service)

**Reviewer leaf:** #1269
**Reviewed leaves:** #1267 (qa-engineer, deploy-contract test + manifest exclusion), #1268 (infra-engineer, unit files + deploy-units.sh + keepalive seam)
**Verdict:** ✅ APPROVED — both leaves; all three machine acceptance checks green

---

## Context

The 2026-06-30→07-01 incident: `crewboss-loop-keepalive.service` (Type=oneshot) spawned the
launcher via `nohup … &`. Without `KillMode=process`, systemd tore down the oneshot service
cgroup on ExecStart exit and killed the just-spawned launcher — an infinite restart-kill every
5 min, compounded by the spawned launcher inheriting `keepalive.lock`'s fd. The charter fix runs
the launcher as its own `Restart=always` service (own cgroup, no inherited lock fd), reduces the
keepalive tick to `systemctl start crewboss-launcher` via an env-override seam (nohup fallback
retained), version-controls the units, and adds a deploy-contract test.

---

## Machine acceptance checks

| Check | Command | Result |
|-------|---------|--------|
| 1 | `bash reference/tests/1144-launcher-service.test.sh` | passed=19 failed=0 |
| 2 | `grep -q 'EXCLUDED 1144-launcher-service' reference/runtime/per-leaf-manifest` | FOUND |
| 3 | `! grep -E '<four unit basenames>' reference/runtime-manifest.tsv …` | absent (exit 0) |

---

## Leaf #1268 (infra-engineer) — unit files, deploy-units.sh, keepalive seam

### Unit files (`reference/runtime/`)

- **`crewboss-launcher.service`** — `Type=simple`, `Restart=always`, `RestartSec=5`. ✅
  `ExecStart` sources `run-env.sh` before `exec bash … crewboss-launcher-gh.sh run`, rebuilding
  the full env contract (`CB_HOME`, `~/.crewboss.env` tokens) — closes the root-A lock-path
  divergence. Modeled on `crewboss-api.service`. `WantedBy=multi-user.target`. ✅
- **`crewboss-loop-keepalive.service`** — correctly retains `Type=oneshot` (single-tick, driven
  by the timer); ExecStart runs `crewboss-loop-keepalive.sh --once`. ✅
- **`crewboss-loop-keepalive.timer`** — `OnBootSec=1min`, `OnUnitActiveSec=5min`,
  `Unit=crewboss-loop-keepalive.service`, `WantedBy=timers.target`. ✅
- **`crewboss-loop-keepalive-killmode.conf`** — `[Service] KillMode=process` drop-in; header
  documents install path `…/crewboss-loop-keepalive.service.d/10-killmode.conf`; correctly framed
  as belt-and-braces for the legacy fallback path. ✅

### `deploy-units.sh`

- Targets `/etc/systemd/system/`; the killmode drop-in routes to
  `…/crewboss-loop-keepalive.service.d/10-killmode.conf`. ✅
- Staged scp → `sudo cp` (units not writable by the scp ssh user); `sudo mkdir -p` for the
  drop-in dir. ✅
- `daemon-reload` + `enable crewboss-launcher crewboss-loop-keepalive.timer`. ✅
- FIELD-TEST comment present (header) and echoed at end: "confirm launcher PID persists across a
  manual keepalive tick" — correctly flags this as the cgroup-teardown root-cause fix that cannot
  be reproduced in CI. ✅

### Keepalive behavior change (`crewboss-loop-keepalive.sh` `start_loop()`)

- Env-override seam used, **not** a hardcoded path:
  `LAUNCHER_UNIT="${CREWBOSS_LAUNCHER_UNIT:-/etc/systemd/system/crewboss-launcher.service}"`. ✅
- Unit present → `systemctl start crewboss-launcher`; unit absent → nohup fallback retained. ✅
- DRY_RUN branch mirrors the same routing. ✅

---

## Leaf #1267 (qa-engineer) — deploy-contract test + manifest exclusion

### `reference/tests/1144-launcher-service.test.sh`

- **UNIT-1..4** assert unit-file field completeness + deploy-units.sh coverage. ✅
- **CONTRACT-1** greps the keepalive seam + `systemctl start crewboss-launcher`. ✅
- **CONTRACT-2a** (CI-testable) points `CREWBOSS_LAUNCHER_UNIT` at a touched file in the test
  tmpdir (**not** `/etc/systemd/system/`) so no sudo is needed; stubs `systemctl` + `nohup` on
  PATH and sources `start_loop()` in a **child** process. It asserts call routing only — the
  comment explicitly states "Proves call routing, not cgroup isolation," so it does not overclaim
  cgroup safety. ✅
- **CONTRACT-2b / FIELD-TEST** note is present and clearly labeled in a boxed header block
  (lines 22–26): the cgroup-teardown proof requires real systemd and is out of CI scope. ✅
- **MANIFEST-EXCLUSION** guard iterates the four unit basenames and fails if any appears in
  `runtime-manifest.tsv`. ✅

### `reference/runtime/per-leaf-manifest`

- `EXCLUDED 1144-launcher-service` present, with justification: CONTRACT-2a sources
  keepalive.sh and invokes `start_loop()` in a child process — subprocess-spawn pattern, same
  class as `1073-keepalive-singletick`; fail-closed default. ✅

---

## Manifest placement (OPTION (b), `crewboss-api.service` precedent)

Confirmed none of the four unit basenames appear in `reference/runtime-manifest.tsv` — units are
deployed to `/etc/systemd/system/` by `deploy-units.sh`, NOT copied to `~/cbnet/` by the manifest
scp loop. Acceptance check 3 passes. ✅

---

## Minor (non-blocking) observation

The `per-leaf-manifest` header count comment (`Counts: ALLOW=25, EXCLUDED=77, union=102`) is
stale — it is not updated for `1144-launcher-service` nor for the pre-existing `role-model-policy`
/ `spawn-model` tests from charter #1234 (#1249). The ALLOW/EXCLUDED **entries** themselves are
correct and the machine checks are green; only the human-readable count comment lags. Out of
scope for charter #1144 (the drift predates these leaves); flagged for a bookkeeping pass.

---

## Summary

Both leaves meet the charter acceptance. The infra leaf (#1268) delivers correct, well-documented
unit files with the right field set and a safe env-seam behavior change; `deploy-units.sh` installs
to the correct targets with daemon-reload/enable and the required FIELD-TEST flag. The qa leaf
(#1267) delivers a hermetic deploy-contract test that proves call routing without overclaiming
cgroup safety, plus the correct EXCLUDED manifest classification and manifest-exclusion regression
guard. **All three machine checks green. Both PRs approved.**
