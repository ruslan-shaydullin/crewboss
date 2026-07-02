# crewboss UI — web dashboard (roadmap phase 0 + skeleton) — 2026-06-10

Replaces the curses TUI. Per [ui-roadmap.ru.md](../ui-roadmap.ru.md): a web client over the
**Engine↔View** contract — the engine (bash on the box) writes files/board; the UI reads via
a thin API and writes only through the same mechanisms the launcher uses.

## Layout
- **`app/`** — the **React + Vite + TS** dashboard (the way forward; roadmap Ф1/Ф2 base).
  Design tokens + components, top bar (brand/conn/budget/Run-Pause-Kill), Board (charters +
  tasks cards, state-colored), per-card Approve/Hold, **confirm dialogs** on spendy actions,
  toasts, SSE+poll, Settings tab. Builds clean (`npm run build`, 28 modules). This is where
  the visual phases (design system, animations, gamification) grow.
- **`web/index.html`** — the buildless single-file v0 (kept; proves the contract, no toolchain).
- **`server/crewboss-api.py`** — demon-API (python3 stdlib, no deps). HTTP + SSE + bearer auth.
  - `GET /api/health` (no auth) · `GET /api/state` · `GET /api/events` (SSE) ·
    `POST /api/command {action,number}` (run/pause/resume/kill/unkill/approve/hold/unhold).
  - Auth: `Authorization: Bearer <CB_API_TOKEN>` OR `?token=` (the browser EventSource can't
    set headers). CORS open (UI is a separate origin).
  - Validated: `run-api-test.sh` 9/9 (header path), `run-api-test2.sh` 3/3 (browser ?token path).
- **`web/index.html`** — single-file client (no build): live board (charters + tasks,
  state-colored cards), pool budget bar, pause/kill flag chips, connection dot; buttons
  Run/Pause/Kill + per-card Approve/Hold; **confirm dialogs on the spendy/irreversible**
  (Run, Kill, Approve — roadmap phase 4 predictability baked in from the start); toasts;
  SSE realtime + slow authed poll fallback; token/API-URL in localStorage (⚙).

## Run the React app (recommended)
```
# 1. on the box: API running (see below).  2. laptop: tunnel the port:
ssh -N -L 8787:127.0.0.1:8787 -i ~/.ssh/NewOne.pem ec2-user@<ip> &
# 3. laptop: dev server
cd ui/app && npm install && npm run dev    # -> http://localhost:5500
```
Open `http://localhost:5500` → ⚙ Settings → API URL `http://127.0.0.1:8787`, token = `CB_API_TOKEN`.

## Run the single-file v0
On the box (start the API):
```
CB_REPO=ruslan-shaydullin/crewboss-proto CB_HOME=~/cbnet CB_API_TOKEN=<pick-a-secret> \
  nohup python3 ~/cbnet/crewboss-api.py >~/cbnet/run/api.out 2>&1 &
```
From your laptop (tunnel the API port, then serve the page):
```
ssh -N -L 8787:127.0.0.1:8787 -i ~/.ssh/NewOne.pem ec2-user@3.217.199.168 &
cd ui/web && python3 -m http.server 5500
```
Open `http://localhost:5500`, click ⚙ → API URL `http://127.0.0.1:8787`, token = your secret.

## Status vs roadmap
- **Phase 0 (API + realtime + auth):** done + tested.
- **Skeleton of Ф1/Ф2/Ф3/Ф4/Ф8:** live board, core actions, confirm-predictability, toasts,
  connection state — in the single file.
- **Not yet:** real design system / animations / gamification (Ф2 deep, Ф5, Ф6) — these need
  a visual iteration loop (can't be verified headlessly) and likely a React app at that scale.
  This single-file client is the runnable foundation to iterate on, and proves the contract.
