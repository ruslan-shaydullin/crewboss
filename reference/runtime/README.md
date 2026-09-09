# Runtime operator notes

The board launcher and its sandboxed agents target Linux. This directory is part
of a runtime assembled from
[`runtime-manifest.tsv`](../runtime-manifest.tsv); installing the API alone does
not provision agents, nsjail, GitHub permissions, or the launcher. For local UI
work, start with the [dashboard guide](../../ui/README.md).

The checked-in systemd unit is a template for a new installation. Existing
operators must adapt its account and paths before replacing a deployed unit.
The current launcher requires its runtime at `$HOME/cbnet` and reads shared
configuration from `$HOME/.crewboss.env`. The API unit uses those same locations
so dashboard Run actions inherit the intended repository and credentials.
Older prototypes and incident records describe specific historical hosts.

## Configure API startup

[`start-api.sh`](start-api.sh) starts an already deployed API. It requires:

- `CB_REPO`: the GitHub `owner/repository` the operator intends to manage.
- `CB_API_TOKEN`: a nonempty, private bearer token.
- `CB_HOME`: the deployed runtime directory, defaulting to `$HOME/cbnet`.

Generate a token locally with `openssl rand -hex 32`. Copy
[`api.env.example`](api.env.example) to the service account's `$HOME/.crewboss.env`,
fill in the required values, and restrict it to that account (`chmod 600`). The
API and launcher must read the same file. Keep the real file outside Git. Use plain `KEY=value` assignments and absolute paths so
the file can also be loaded by systemd; systemd does not expand shell expressions
such as `$HOME`, `~`, or `$(...)`.

For a foreground operator session:

```sh
bash reference/runtime/start-api.sh --foreground
```

`CB_ENV_FILE` is sourced as a **trusted shell file** by the startup script. If it
is not specified, the script loads `~/.crewboss.env` when present. File values
override inherited environment values. Set `CB_ENV_FILE=/dev/null` to use only
the current environment. Without `--foreground`, the script starts a background
process and records its PID and log under `$CB_HOME/run/`; it refuses to replace
a running process from an existing PID file.

The script defaults to `CB_API_HOST=127.0.0.1` and `CB_API_PORT=8787`, and refuses
to start without a repository and token. Set `CB_API_SCRIPT` to an absolute path
to `ui/server/crewboss-api.py` when using a source checkout instead of a deployed
copy. A custom `CB_ENV_FILE` or `CB_HOME` supports API-only development; dashboard
Run actions still need the shared `$HOME/.crewboss.env` and `$HOME/cbnet` runtime.
Set `CB_WEB_DIR` to the absolute path of built dashboard assets if the API
should serve the UI. Authentication for `gh` must be configured separately for
the account running the service; API startup does not retrieve or print tokens.

## Run under systemd

[`crewboss-api.service`](crewboss-api.service) expects:

- A dedicated `crewboss` user and group, with home `/var/lib/crewboss`.
- An installed runtime at `/var/lib/crewboss/cbnet`, including `start-api.sh` and
  `crewboss-api.py`. The service account must be able to write its runtime state
  and read any configured credentials and UI assets.
- A private configuration file at `/var/lib/crewboss/.crewboss.env` based on the example.
  The file is mandatory and must contain the intended repository and API token.
- Python 3 and GitHub CLI available on the service's PATH, plus any additional
  runtime dependencies needed for enabled actions.

Create or adapt those resources before enabling the unit. With the prerequisites
in place, install the reviewed unit:

```sh
sudo install -m 644 reference/runtime/crewboss-api.service /etc/systemd/system/crewboss-api.service
sudo systemctl daemon-reload
sudo systemctl enable --now crewboss-api
sudo systemctl status crewboss-api
```

Use `journalctl -u crewboss-api` for startup failures. The unit loads the environment
file itself and invokes the same validated startup script in foreground mode.
Do not use `export` statements in the systemd environment file. For an existing
installation with a different account or directory, adapt `User`, `Group`,
`WorkingDirectory`, `HOME`, `CB_HOME`, `EnvironmentFile`, and `ExecStart` together.
Keep `CB_HOME` at `$HOME/cbnet` and the shared file at `$HOME/.crewboss.env` for
launcher compatibility. Keep deployment tooling's destination directory aligned
with the unit.

## Remote access and webhooks

For the dashboard, prefer an SSH tunnel to the loopback-bound API:

```sh
ssh -N -L 8787:127.0.0.1:8787 user@your-server
```

GitHub webhook delivery needs an HTTPS endpoint reachable from GitHub. Use a TLS
reverse proxy or an appropriate forwarding service; the Python API does not
terminate TLS. Route webhook traffic to `/api/gh-webhook` without exposing
operator routes unnecessarily.

Generate a separate secret with `openssl rand -hex 32`. Add it as
`CB_WEBHOOK_SECRET` in the API environment and in the GitHub repository's webhook
settings. Choose JSON content and the **Issues** and **Pull requests** events,
with a payload URL such as `https://your-server.example.com/api/gh-webhook`.
Restart the API after changing its environment. Deliveries are checked using
HMAC-SHA256 and the `X-Hub-Signature-256` header.

## Authentication limits

The Python API itself permits requests when `CB_API_TOKEN` is empty. The startup
script above rejects that configuration; invoking Python directly bypasses this
startup check. `/api/health` and static UI files are public even with a token.
Webhooks use their own signature check instead of bearer authentication.

The browser stores the API token in local storage and includes it in EventSource
URLs. Avoid logging token-bearing URLs. The API has permissive CORS, so network
exposure and token handling must be configured deliberately. Read
[SECURITY.md](../../SECURITY.md) for the broader boundaries and reporting process.
