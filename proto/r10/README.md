# Round 10 — control surface: flag-files + TUI panel — 2026-06-10

The launcher was a fire-and-watch script. Round 10 adds the human control surface from
design §9/§10 — without changing the Engine↔View split (rails write files; the panel reads
files; control = flag-files / labels / a backgrounded launcher).

## Flag-files (in `crewboss-launcher-gh.sh run`) — validated 8/8 (`run-flags-test.sh`)
- `run/kill_switch` present → loop stops at the next tick.
- `run/pause` present → loop keeps managing in-flight spawns but claims NO new work; remove
  to resume. (Stub test: kill stops + nothing claimed; pause holds + nothing claimed;
  removing flags resumes to review.)

## TUI panel (`crewboss-tui.py`) — python curses, read-only over the file/board contract
Run it in your SSH session:
```
CB_REPO=owner/repo CB_HOME=~/cbnet python3 crewboss-tui.py        # interactive
CB_REPO=owner/repo python3 crewboss-tui.py --dump                 # one-shot render (no curses)
```
- **Shows:** pool $ spent / cap, pause/kill flag state, and a live table of issues
  (#, kind, role, state-colored, cost, pr/title) — board state from `gh issue list` +
  per-task cost/pr from `run/work/<n>/status.json`. Auto-refreshes every `CB_TUI_REFRESH`s.
- **Keys:** `r` start launcher (bg) · `p` toggle pause · `k` toggle kill-switch ·
  `a` approve a charter (input #) · `q` quit. Each maps to an already-validated mechanism
  (flag-files r9/r10, `status:approved` label r6, `run` loop r9).
- **Validated:** syntax + `--dump` against the real board (renders charters/leaves, derived
  states, live costs). The interactive curses panel is run by a human (can't be driven
  headlessly here); its data layer is the same `board()`/`summary()` used by `--dump`.

## Still thin (honest)
- The 3 view modes (§10 compact/table/detailed) — only the table is built.
- `r` starts the launcher with the TUI's own env (CB_REPO/CB_SPAWN/token) — document the
  launch env; no per-launcher config file yet.
- No attach-to-boss pane yet (boss not wired into the prototype).
