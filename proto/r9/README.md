# Round 9 — background-parallel spawns (§4.6) — validated 2026-06-10

The launcher loop was synchronous (claim → run spawn ~minutes → route → next). Round 9 adds
the `run` poll-loop: backgrounds each spawn up to a concurrency cap, routes each on finish
(by `status.json`, not a blocking exit code), reconciles orphans at startup, exits when idle.

## Prerequisite fix — per-task proxy socket (`crewboss-spawn.sh`)
The per-spawn `pkill -f "proxy.py $SOCK"` + restart of a SHARED socket made spawn B kill
spawn A's proxy under concurrency. Fixed: each spawn uses its own `$TDIR/proxy.sock`, starts
its own proxy, and kills only that proxy by PID (no shared `pkill`). Single-spawn behaviour
unchanged; concurrent spawns no longer collide.

## `run` mode (`crewboss-launcher-gh.sh run`)
Each tick: route finished spawns (dead pid → read `status.json` phase: done→review,
unknown/crash→retry/blocked at cap, budget→requeue+stop) → claim new launchable up to
`CB_MAX_PARALLEL` (background-spawn, record pid) → exit when nothing running and no fresh
launchable. `reconcile` runs **once at startup only** (see bug 2).

## Validation
- **`run-parallel-test.sh` 5/5** (real gh board, stub spawn, no claude spend): 3 leaves,
  cap 2 → trace `bg-spawn #40(1/2)`, `bg-spawn #39(2/2)`, `#40 done→review`,
  `bg-spawn #38(1/2)`, all→review, `idle`. **Observed max concurrency = 2** (parallelism
  happened AND the cap held), all 3 reached review, loop exited cleanly.
- **`run-parallel-real.sh` (paid $0.052):** TWO real jailed claude agents run **concurrently**,
  each through its OWN per-task proxy — `bg-spawn #43(1/2)`, `bg-spawn #42(2/2)`, both
  `done→review`, both cost $0.026, no `is_error` (a proxy collision would have failed one).
  wall 12s. Proves the per-task-socket fix under real concurrent load.

## Two bugs found and fixed (both real, both subtle)
1. **proxy collision** (above) — shared socket + per-spawn pkill → per-task socket.
2. **`reconcile` inside the tick requeued normally-finished spawns.** reconcile treats a
   dead pid as an orphan and requeues it — but in the live loop EVERY finished spawn has a
   dead pid, so reconcile requeued each finished task *before* route-finished could route it
   → infinite respawn of the first task. Fix: reconcile is **startup-only** (orphans from a
   previous run/reboot); inside the loop the launcher started its own spawns, so dead pid =
   finished → route by status.json. Plus a **local `term`/`pid` guard** in the claim loop so
   a task already handled this run is never re-claimed even if the (read-after-write-laggy)
   `gh issue list` still reports it launchable. (Lesson: gh label edits are not immediately
   reflected in `gh issue list`; the launcher must be authoritative over its own lifecycle.)

## Honest limits
- Real parallelism is capped by the **subscription dollar pool**, not process count
  (Pro≈1, Max5x≈2, Max20x≈3-4) — `CB_MAX_PARALLEL` above that just burns the pool faster;
  the budget guard is the real limiter.
- conservative-parallel: deps already serialize dependent leaves; same-file collisions
  between independent leaves fall back to git rebase-retry (not handled here — the merge
  layer's job).
- Budget pre-check races under concurrency (two spawns can both pass then both spend) —
  best-effort, as designed.
