# Dashboard and API

The dashboard is a React + TypeScript app backed by a Python HTTP API. The API
reads GitHub board data and runtime files, and exposes operator actions. The
Python server uses only the standard library.

## Local development

Use Node.js 22 with npm, Python 3, and OpenSSL (to generate a local token). From
the repository root:

```sh
npm ci --prefix ui/app
npm run dev --prefix ui/app -- --host 127.0.0.1
```

Open `http://127.0.0.1:5500`. In a second terminal, from the repository root, start
an API with an empty board and an example team:

```sh
export CB_HOME="$PWD/.cbhome"
export CB_REPO=""
export CB_API_HOST=127.0.0.1
export CB_API_PORT=8787
export CB_API_TOKEN="$(openssl rand -hex 32)"
mkdir -p "$CB_HOME/run" "$CB_HOME/team"
cp -R team-example/. "$CB_HOME/team/"
printf 'Local API token: %s\n' "$CB_API_TOKEN"
python3 ui/server/crewboss-api.py
```

In the dashboard's Settings, set API URL to `http://127.0.0.1:8787` and paste the
local token printed by the second terminal. The board is empty because `CB_REPO`
is unset. This setup lets you develop the UI and API without agent credentials;
launching agents needs a provisioned runtime. Stop the API and Vite with Ctrl-C.
The local `.cbhome/` directory is ignored by Git.

To connect a real board, authenticate `gh` with the intended repository access,
set `CB_REPO=owner/repository`, and restart the API. Dashboard actions can then
modify that repository. Use a disposable repository when testing mutations.

## Build and test

```sh
make test-ui
make build-ui
```

The build checks TypeScript and creates `ui/app/dist/`. To serve that build from
the API, set `CB_WEB_DIR` to its absolute path when starting Python. The API can
then serve the dashboard and `/api/` on the same port.

Vitest tests live under `app/src/`. Browser and visual scripts under
`app/scripts/` are separate from the default test suite and may require
Playwright browsers, a running server, or scenario-specific fixtures. The PNGs
under `app/scripts/baselines/` are committed visual fixtures.

## API configuration

| Variable | Purpose |
| --- | --- |
| `CB_HOME` | Runtime files and `run/` directory; defaults to `~/cbnet` |
| `CB_REPO` | GitHub `owner/repository`; empty gives an empty board |
| `CB_API_TOKEN` | Operator token; **an empty value disables authentication** |
| `CB_API_HOST` | Bind address; defaults to `127.0.0.1` in the Python server |
| `CB_API_PORT` | HTTP port; defaults to `8787` |
| `CB_WEB_DIR` | Absolute path to built dashboard assets |
| `CB_WEBHOOK_SECRET` | Independent secret for signed GitHub webhook deliveries |

`GET /api/health` and static dashboard assets do not require a token. Other API
routes accept a bearer token; the EventSource connection sends its token in the
query string. The UI stores connection settings and the token in browser local
storage. The server has permissive CORS and does not provide TLS.

Keep development bound to loopback. For a remote runtime, tunnel the API over
SSH using your own host and key configuration:

```sh
ssh -N -L 8787:127.0.0.1:8787 user@your-server
```

For service installation and remote webhook delivery, see the
[operator guide](../reference/runtime/README.md) and
[security policy](../SECURITY.md).

## Source map

- `app/`: current React dashboard.
- `server/crewboss-api.py`: API implementation.
- `server/crewboss_api.py`: import shim used by tests and smoke tooling.
- `web/index.html`: historical single-file dashboard, retained for reference.
