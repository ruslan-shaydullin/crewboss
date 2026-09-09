# Dashboard and API

The dashboard is a React + TypeScript app backed by a Python HTTP API. The API
reads GitHub board data and runtime files and exposes operator actions. The
Python server and its helper modules use only the standard library.

## Try the dashboard

For sample data without credentials or an API, run these commands from the
repository root with Node.js 22+ and npm:

```sh
make setup
make demo
```

Open the URL printed by Vite. **Local demo** identifies the fixture-backed
session; commands and edits affect only browser memory. **Reset demo** restores
the sample board and team. See the [demo guide](../docs/demo.md) for screenshots
and browser checks.

## Develop against a local API

Use Python 3.12+ and OpenSSL to generate a token. From the repository root, start
the live dashboard:

```sh
make setup
npm run dev --prefix ui/app -- --host 127.0.0.1
```

In a second terminal, from the repository root:

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

Open `http://127.0.0.1:5500`. In Connection settings, enter API URL
`http://127.0.0.1:8787` and the local token printed in the second terminal. The
token stays in page memory and must be reentered after a reload; the API URL is
saved separately. Blank connection settings issue no API requests.

The direct Python development entrypoint accepts an empty `CB_REPO` to show an
empty board. It still requires a nonblank token. This setup needs no nsjail,
agent provider, or GitHub credentials. Agent Run actions require the complete
Linux runtime and preflight. The ignored `.cbhome/` directory isolates local
runtime state. Stop the API and Vite with Ctrl+C.

For a real board, install GitHub CLI, supply `GH_TOKEN` or authenticate `gh` for
the account running this development API, set `CB_REPO=owner/repository`, and
restart Python. Dashboard edits then modify that repository; use a disposable
repository for mutation tests. An installed agent runtime requires explicit
`GH_TOKEN` in the shared operator configuration. See the
[installation guide](../docs/install.md) for that setup.

## Build and test

```sh
make test-ui
make build-ui
python3 tests/test_api_auth.py
python3 tests/test_api_launch.py
```

The build checks TypeScript and writes `ui/app/dist/`, including the linked
stylesheet. To serve this source build through the API, export
`CB_WEB_DIR="$PWD/ui/app/dist"` before starting Python. Both the dashboard and
`/api/` then use port `8787`. Release archives install these assets at
`$CB_HOME/ui`, the API's default static root.

Vitest tests cover UI contracts, authenticated stream reconnect/cleanup, and the
demo's local command behavior. The Python tests use local HTTP and process
fixtures and no real provider or GitHub account. For browser smoke checks:

```sh
cd ui/app
npx playwright install chromium
node scripts/demo-smoke.mjs
node scripts/production-smoke.mjs
```

The demo check starts its own server and refreshes the documentation screenshots.
The production check builds into a temporary directory and verifies a styled
live dashboard with blank settings and no unauthenticated API requests. Both
stop their own servers. Older browser/visual scripts in `app/scripts/` may need
scenario-specific servers or fixtures; they are separate from `make check`.

## API configuration and authentication

| Variable | Purpose |
| --- | --- |
| `CB_HOME` | Runtime and `run/` directory; defaults to `~/cbnet` |
| `CB_REPO` | GitHub `owner/repository`; direct Python development may leave it empty |
| `CB_API_TOKEN` | Required nonblank private operator token |
| `CB_API_HOST`, `CB_API_PORT` | Default `127.0.0.1` and `8787` |
| `CB_WEB_DIR` | Absolute dashboard asset path; defaults to `$CB_HOME/ui` |
| `CB_ALLOWED_ORIGINS` | Comma-separated exact HTTP(S) origins; loopback defaults |
| `CB_WEBHOOK_SECRET` | Independent secret for signed GitHub webhook deliveries |

Direct Python startup reads its environment. Installed `start-api.sh`, CLI
launchers, and API Run actions share the trusted `CB_ENV_FILE` configuration;
see the [runtime notes](../reference/runtime/README.md). Run rejects a missing or
failed runtime preflight and preserves configured homes, credentials, and binary
paths. Changing the active repository or runtime path requires an API restart.

Static files and `GET /api/health` are public. Operator routes use a bearer token
in the Authorization header; SSE uses fetch streaming with that same header,
never a token URL. The UI removes legacy stored tokens and does not persist new
ones. CORS defaults to loopback hostnames at port `5500` and the configured API
port; remote dashboard origins must be listed explicitly. The API has no TLS
termination. For a remote runtime, use your own SSH tunnel or HTTPS proxy:

```sh
ssh -N -L 8787:127.0.0.1:8787 user@your-server
```

## Source map

- `app/src/App.tsx`: dashboard composition and board state.
- `app/src/TaskDrawer.tsx`, `NewIssueModal.tsx`, `QueuePanel.tsx`, `Dialogs.tsx`:
  task, creation, queue, and connection flows.
- `app/src/api.ts`, `transport.ts`, `sse.ts`: API access and authenticated streams.
- `app/src/demo.ts`: isolated fixture state and local request handling.
- `server/crewboss-api.py`: board and operator API behavior.
- `server/crewboss_http.py`: authentication, CORS, and HTTP response helpers.
- `server/crewboss_launch.py`: shared configuration loading and launch preflight.
- `server/crewboss_api.py`: import shim for tests and smoke tooling.

The retired single-file dashboard remains available through Git history. Read
[SECURITY.md](../SECURITY.md) before exposing a live runtime beyond loopback.
