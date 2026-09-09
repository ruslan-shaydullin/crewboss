# Runtime operator notes

Start with the [installation guide](../../docs/install.md) for the versioned
archive, account configuration, sandbox preflight, and systemd setup. The agent
runtime targets Linux x86_64 and Bash 5+; the [local demo](../../docs/demo.md) and
[standalone API](../../ui/README.md) do not need an agent environment.

This directory contains maintained runtime source. The release packager combines
canonical files from [`runtime-manifest.tsv`](../runtime-manifest.tsv) with the
Python API and its helper modules, example team, governance hooks, dashboard, and
systemd templates. Install the archive into an explicit empty `CB_HOME`; copying
this directory alone omits required files. Historical host snapshots and
prototype provisioners are not the alpha installation path.

## Shared configuration

Copy [`api.env.example`](api.env.example) to the runtime account's
`$HOME/.crewboss.env` for a new installation and fill in the values. Keep the
file private, mode `0600`, outside Git. API startup, CLI launcher entrypoints,
systemd units, and dashboard Run actions use the same configuration contract:

| Variable | Contract |
| --- | --- |
| `CB_ENV_FILE` | Trusted configuration file; defaults to `$HOME/.crewboss.env` |
| `CB_HOME` | Absolute installed runtime path; defaults to `$HOME/cbnet` |
| `CB_REPO` | Required GitHub `owner/repository`; no personal fallback |
| `CB_API_TOKEN` | Required nonblank bearer token for the HTTP API |
| `GH_TOKEN` | Explicit GitHub credential required before agent work |
| `CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_API_KEY` | Provider credential required before agent work |
| `CB_API_HOST`, `CB_API_PORT` | Default `127.0.0.1` and `8787` |
| `CB_WEB_DIR` | Dashboard assets; defaults to `$CB_HOME/ui` |
| `CB_ALLOWED_ORIGINS` | Comma-separated exact HTTP(S) browser origins; loopback defaults |

Use literal `KEY=value` assignments: no `export`, `$HOME`, `~`, or command
substitutions inside the file. It is trusted shell input when sourced by Bash,
and must also work as a systemd `EnvironmentFile`. File values override inherited
environment values. An explicitly selected missing file is an error;
`CB_ENV_FILE=/dev/null` selects an environment-only session.

Provider executable and configuration paths are configurable through the
`CB_AGENT_HOME`, `CB_CLAUDE_*`, `CB_NSJAIL_BIN`, and `CB_GH_BIN` settings in the
example. The installation guide describes required mounts and permissions.
Credentials are supplied by the operator; startup does not extract a stored
`gh auth` token. Custom `CB_HOME` and `CB_ENV_FILE` paths apply to both API and
launcher. Restart the API after changing its repository or runtime directory;
Run refuses a configuration that disagrees with the running API.

## Entrypoints and checks

Run these commands as the runtime account after installation:

```sh
export CB_HOME="$HOME/cbnet"
export CB_ENV_FILE="$HOME/.crewboss.env"
bash "$CB_HOME/crewboss-doctor.sh" --preflight
bash "$CB_HOME/start-api.sh" --foreground
```

Preflight checks the Linux architecture, dependencies, configuration, governance
hook, and a real nsjail `/bin/true` sandbox probe. It makes no GitHub or provider
requests. Agent launch entrypoints and API Run actions repeat it before starting
work. It does not establish that live credentials or repository permissions work.

`start-api.sh --foreground` runs under a terminal or process supervisor. Without
the flag, it starts a background API, checks `/api/health` using curl, and records
its PID and output under `$CB_HOME/run/`. It refuses to replace a running process
from the existing PID file. `CB_API_SCRIPT` can override the installed Python
entrypoint with an absolute source path; its sibling helper modules must remain
available. Starting the API does not start the launcher.

For systemd, use the installed `$CB_HOME/systemd/render-units.py` to generate
templates for your account and paths. Review and install the generated units as
described in the installation guide. API and launcher execute as the same
unprivileged account and load the same mandatory environment file. The optional
keepalive oneshot requests the dedicated launcher service to start; it does not
execute user-writable runtime scripts as root.

## HTTP access

Every real Python server entrypoint requires a nonblank token. Operator routes,
including the streaming state endpoint, require `Authorization: Bearer TOKEN`.
Tokens in query strings are rejected. The UI holds its token in memory and uses
authenticated fetch streams; reenter the token after a reload. Static dashboard
files and `/api/health` remain public.

The API normally sends a state frame or keepalive every 10 seconds. The dashboard
retries a stream after 60 seconds without data and falls back to authenticated
polling. Keep a custom `CB_API_POLL` interval below that inactivity timeout.

CORS allows exact origins. Defaults cover `localhost`, `127.0.0.1`, and `[::1]`
on port `5500` and the configured API port. Set `CB_ALLOWED_ORIGINS` explicitly
for a reverse proxy or another dashboard origin; wildcard origins are rejected.
An explicit empty list rejects browser requests carrying an Origin header.
Requests without an Origin header, such as CLI clients, still require their
normal authentication.

The server binds to loopback by default and does not provide TLS. For remote
dashboard access, use an SSH tunnel:

```sh
ssh -N -L 8787:127.0.0.1:8787 user@your-server
```

Optional GitHub webhooks need a reachable HTTPS endpoint at `/api/gh-webhook`,
JSON content, and Issues/Pull requests events. Set a separate
`CB_WEBHOOK_SECRET` in the API environment and GitHub webhook settings. The API
checks `X-Hub-Signature-256` using HMAC-SHA256; webhook signatures are independent
of operator bearer authentication. Restart after environment changes. See the
[security policy](../../SECURITY.md) for the wider trust boundaries.
