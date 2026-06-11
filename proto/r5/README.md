# Round 5a — spawn primitive + load-bearing safety rails — validated 2026-06-10

Rounds 3a–4b proved the jail mechanics by hand (scattered scripts, manual `sed`
redaction). Round 5a consolidates them into the reusable **spawn primitive**
(`crewboss-spawn.sh`, design §4.4) with the rails that are *load-bearing for autonomy*
baked in and validated live.

## Result — `run-r5-test.sh`: 16/16
- **redact_secrets** (`redact.pl`, unit): masks the real OAuth token, `ghp_*`, `sk-ant-*`,
  and `https://x-access-token:…@` push creds. So a stray `set -x`/verbose/echo can't leak
  a token into `run.log`.
- **budget hard-stop** (no spend): with pool spend ≥ `monthly_credit_usd * cost_pct%`,
  spawn **refuses to launch** — exits 3, writes `status.json` phase=`budget-stop`, records
  **no** run. This is the structural stop that keeps an autonomous fleet from burning the
  dollar pool (§5/§7).
- **real smoke** (one paid run, $0.026): agent JSON flows stdout → redact → `run.log`
  (pipeline wired); reply `OK` through the jail; **no OAuth token in `run.log`**; budget
  accounting increments `run/budget.json` by `total_cost_usd` under `flock`; `status.json`
  phase=`done`, `cost_usd` set; both `run.log` and `status.json` are `0600`.

## The spawn primitive (`crewboss-spawn.sh <task> <role> <prompt-file> <work-dir> [pr_repo]`)
1. budget pre-check vs `run/config.json` cap → refuse (exit 3) if over.
2. **prompt-to-file** (copied verbatim; no title/body interpolation → no injection, §4.4).
3. bring up the egress proxy; run the agent in the **fully-hardened jail** (FS+net+
   seccomp KILL, the 3a/3b/3c profile) reading the prompt from `/work/.task.prompt`.
4. stdout/stderr → `redact.pl` → `run.log` (0600).
5. parse `total_cost_usd` → `run/budget.json` under `flock` (pool accounting).
6. write `status.json` (0600): task, role, pid, starttime, phase, exit_code, cost_usd, pr.
   Exit 0 done · 2 agent failed · 3 budget hard-stop.

## Grables (fixed)
- **`set -e` + `pipefail` + `PR=$(grep … | tail)`**: a smoke that opens no PR makes grep
  exit 1, pipefail propagates it, set -e kills the spawn *after* the agent ran but *before*
  budget accounting → status stuck at `starting`, budget not updated. Fix: `… || true` on
  every no-match-tolerant extraction. (Exactly the kind of thing the rails must survive.)
- **claude refuses to echo credential-shaped strings**: a redaction test that asks the
  agent to print a fake `ghp_…` fails because the model declines ("formatted as a GitHub
  PAT"). Test the redactor as a unit on real secret shapes instead; prove the pipeline
  wiring via the JSON landing in `run.log`.

---

# Round 5b — launcher loop (predicate / claim / route / retry / reconcile / lock) — validated 2026-06-10

`crewboss-launcher.sh` is the deterministic "brain" the board-orchestration design flags as
the new un-governed critical piece. Validated with a **stub spawn** (no jail, no spend),
`run-r5b-test.sh` **16/16**. Board = `run/board/*.json` (local stand-in for the GitHub
issue+label board); `$CB_SPAWN` is overridable so the loop is testable without cost.

- **predicate** `launchable(leaf)` = state open · not held · charter approved · all deps
  done. (T1 deps gate, T2 hold veto, T3 charter-approved gate.)
- **claim** sets state=in-progress + pid/starttime atomically; done/blocked tasks are not
  re-spawned (T4 idempotency).
- **route** by spawn exit: 0→done · nonzero→tries++ (requeue, or →blocked at
  `CB_RETRY_CAP`) · 3 (budget)→revert claim to open and **stop the cycle** (T5 retry-cap,
  T6 budget stop).
- **reconcile** requeues in-progress tasks whose pid is dead — reboot/SIGKILL orphans (T7).
- **single-instance** `flock run/launcher.lock` — a second launcher refuses (T8).

Grable (fixed): `local id role` without `id="$1"` → under `set -u` `claim_and_spawn` died
on "id: unbound variable" *before* spawning, silently turning several spawn assertions into
false positives. Lesson: a green suite where the spawn never ran looks identical to success
— assert the spawn was actually *called* (the harness greps `stub-calls.log`).

---

# Round 5c — capstone: launcher loop drives a real PR end-to-end — validated 2026-06-10

`crewboss-prep-spawn.sh` is the adapter that satisfies the loop's `$SPAWN <id> <role>`
contract: per task it reads `pr_repo`+`prompt` from the board, does the §4.5 repo prep
(mirror → local clone → push-fix remote → branch), writes the prompt to a file, and execs
`crewboss-spawn.sh` with full args. With `CB_SPAWN=crewboss-prep-spawn.sh` the **whole
stack runs autonomously from one board task**.

- `run-r5c-real.sh` (one paid run, $0.123): issue #7 → board task → **launcher `once`** →
  claim → adapter prep → **hardened jail** (FS+net+seccomp) → agent edits+commits+pushes+
  opens PR → route → **task state=done**.
- Verified: real **[PR #8](https://github.com/stratch1989/crewboss-proto/pull/8)** OPEN,
  **only `README.md`** changed (the `.task.prompt` the spawn drops in the work dir is kept
  out of the commit via `.git/info/exclude`); `status.json` phase=done, cost=$0.123,
  pr set, exit 0; `budget.json` spent incremented with the run recorded; **0 OAuth-token
  hits in `run.log`**.
- This is the first time the **loop** (not a human) drives the **real jail** to a **real
  PR**, with budget + redaction + status all active. End-to-end stack proven.

## Still open
- real board adapter (gh issues+labels ⇄ the JSON state machine — `run-r5c` still seeds the
  board JSON by hand from the issue); per-task socket/log; DENY-log → status telemetry;
  backgrounded parallel spawns (loop is synchronous per task — fine for the state machine;
  §4.6 backgrounds spawns + polls).
- `--agent executor` role-gating + merge-gate (governance, validated on the roles branch)
  wired onto the jailed spawn; real Quarter (node→20/Expo → re-capture policy; PAT; charters).
