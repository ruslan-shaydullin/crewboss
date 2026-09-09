# Install the alpha runtime

The agent runtime targets Linux x86_64 with Bash 5+, Python 3.12+, Git, GitHub
CLI, jq, Perl, `flock`, and nsjail. The Linux integration harness uses Ubuntu
24.04 and nsjail 3.6. Other distributions and nsjail versions need their own
validation; the shipped seccomp policy does not support ARM64. The browser demo
and standalone Python API can run without this agent environment.

This alpha has no automatic upgrade or credential provisioning. Use a dedicated
unprivileged account, a repository you control, and your own GitHub and Claude
credentials. Agent operations can create issues, branches, commits, and pull
requests, and can merge changes subject to the configured workflow and GitHub
permissions. Provider requests use your account's quota.

## Build or obtain the archive

From a source checkout, with Node.js 22+ and npm available:

```sh
make setup
make check
make release
```

`make release` builds the dashboard and writes
`dist/releases/crewboss-<VERSION>.tar.gz` and an external `SHA256SUMS` file. The
version comes from the repository's `VERSION` file. Use the archive and checksum
file from the same build or published release. On the Linux destination, verify
the archive before extracting it:

```sh
sha256sum -c SHA256SUMS
tar -xzf crewboss-0.1.0-alpha.1.tar.gz
cd crewboss-0.1.0-alpha.1
```

Substitute the downloaded version in those two paths. The archive contains an
additional checksum inventory for its contents. Checksums detect corruption or
changes; they are not a signature from a separately trusted publisher.

## Install into an empty directory

Have an administrator create the runtime account and its writable home if they
do not exist. The examples below run **as that account**, with a home such as
`/var/lib/crewboss`. Keep paths short, absolute, and free of spaces or shell
metacharacters so they also work with the unit renderer and sandbox mounts.

From the extracted archive:

```sh
export CB_HOME="$HOME/cbnet"
bash ./install-runtime.sh --prefix "$CB_HOME"
```

The installer requires an explicit absolute prefix. It verifies the bundle and
runtime manifests before copying, and refuses a nonempty destination. It does
not install dependencies, create accounts, retrieve credentials, change system
services, or contact the network. Run it without `sudo` so the runtime belongs to
the account that will use it.

The installed layout is:

```text
CB_HOME/
  crewboss-api.py, crewboss_http.py, crewboss_launch.py
  start-api.sh, run-env.sh, run-charter.sh, crewboss-doctor.sh, ...
  runtime-manifest.tsv
  gh -> gh-shim.sh
  run/          mutable process and task state
  team/         example organization, rubric, and role definitions
  gov/.claude/  governance settings, hooks, and role agents
  systemd/      service templates and render-units.py
  ui/           built dashboard
```

Review the installed example team and governance configuration for your project.
The release includes the governance hook and its `PreToolUse` wiring; copying
only the launcher scripts is insufficient for a working installation.
Review `model` values in `team/roles/*.md` before launching work and select Claude
model IDs available to your account. The sample roles do not establish provider
availability. The current spawn primitive forwards `claude-*` model overrides;
without such an override, the provider CLI chooses its default model.

## Configure the account

For a new installation, copy the supplied example and edit it privately:

```sh
install -m 600 crewboss.env.example "$HOME/.crewboss.env"
```

Do not overwrite an existing configuration with this command. Set these values
in that file:

| Setting | Required value or default |
| --- | --- |
| `CB_REPO` | Your GitHub `owner/repository`; there is no default repository |
| `CB_API_TOKEN` | A nonblank private operator token; generate one locally with `openssl rand -hex 32` |
| `CB_HOME` | The absolute directory passed to the installer |
| `GH_TOKEN` | Your explicit GitHub credential for the intended repository and workflow |
| `CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_API_KEY` | Your agent provider credential |
| `CB_API_HOST`, `CB_API_PORT` | Default `127.0.0.1` and `8787` |

Use literal `KEY=value` assignments in the file. Do not use `export`, `$HOME`,
`~`, or command substitutions: Bash and systemd load the same file, and systemd
does not perform shell expansion. Startup sources it as trusted shell input, so
keep it owned by the runtime account, mode `0600`, and outside version control.
Assignments in the file override inherited environment values.

Install and configure the provider CLI for this account separately. The defaults
are `$HOME/.local/bin/claude`, installation directory `$HOME/.local`, configuration
directory `$HOME/.claude`, and configuration file `$HOME/.claude.json`. For another
layout, set absolute `CB_AGENT_HOME`, `CB_CLAUDE_BIN`,
`CB_CLAUDE_INSTALL_DIR`, `CB_CLAUDE_CONFIG_DIR`, and `CB_CLAUDE_CONFIG_FILE` paths.
The installation directory must contain the resolved provider executable,
including its symlink target, unless the executable lives under `/usr` or `/bin`.
The provider configuration directory and file must exist and be writable by the
runtime account. A new configuration file may start as an empty JSON object;
preserve an existing provider configuration.

`CB_NSJAIL_BIN` defaults to `/usr/local/bin/nsjail`; `CB_GH_BIN` defaults to
`/usr/bin/gh`. Point them at your actual executables. The runtime never extracts a
stored `gh auth` token on your behalf. Review repository permissions and branch
protection before enabling agent work.

For a custom configuration location, export
`CB_ENV_FILE=/absolute/path/to/crewboss.env` before each entrypoint and use that
same path in the systemd renderer. The default is `$HOME/.crewboss.env`.

## Check the environment and start the API

As the runtime account:

```sh
export CB_ENV_FILE="$HOME/.crewboss.env"
bash "$CB_HOME/crewboss-doctor.sh" --preflight
bash "$CB_HOME/start-api.sh" --foreground
```

Preflight checks configuration, dependencies, provider mounts, credentials being
present, governance wiring, and a real nsjail `/bin/true` probe with the shipped
seccomp policy. It makes no GitHub or provider requests. A successful preflight
does not prove credentials or live repository permissions work. Fix any reported
failure before launching work; API Run actions and launcher entrypoints repeat
the check before starting agents.

Open `http://127.0.0.1:8787` and enter the API URL and operator token in Connection
settings. The dashboard keeps the token in memory until a page reload. The API
serves the installed dashboard from `$CB_HOME/ui`; set `CB_WEB_DIR` to an absolute
path to override it. Stop the foreground API with Ctrl+C. Starting the API alone
does not start the agent loop; the dashboard's Run action does.

For remote access, tunnel the loopback port using your own SSH account:

```sh
ssh -N -L 8787:127.0.0.1:8787 user@your-server
```

The API does not terminate TLS. If you configure an HTTPS reverse proxy, set
`CB_ALLOWED_ORIGINS` to the exact browser origins you intend to use, separated by
commas. Defaults allow loopback origins at dashboard port `5500` and the API
port; wildcards are rejected. SSE uses authenticated fetch streams, with the
bearer token in the `Authorization` header. Query-string tokens are rejected.
Health checks and static assets are public; operator API routes require the
token. Optional GitHub webhooks use a separate `CB_WEBHOOK_SECRET` and
HMAC-SHA256 signatures at `/api/gh-webhook`.

## Run under systemd

Render all units for the same account, home, runtime, and configuration paths.
This writes files for review and requires no administrative privileges:

```sh
python3 "$CB_HOME/systemd/render-units.py" \
  --output-dir "$HOME/crewboss-units" \
  --user crewboss \
  --home /var/lib/crewboss \
  --runtime-dir /var/lib/crewboss/cbnet \
  --env-file /var/lib/crewboss/.crewboss.env
```

Replace all example account paths together. The rendered units use the same
name for the service user and group; both must exist when the units are started.
The renderer does not create accounts. Review the generated files, then have an
administrator install the API unit and start it:

```sh
sudo install -m 644 "$HOME/crewboss-units/crewboss-api.service" /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now crewboss-api.service
sudo systemctl status crewboss-api.service
```

For a supervised agent loop, also install `crewboss-launcher.service`,
`crewboss-loop-keepalive.service`, and `crewboss-loop-keepalive.timer` from the same
rendered directory. Enabling `crewboss-launcher.service` begins agent work;
enabling `crewboss-loop-keepalive.timer` periodically requests that launcher
service to start. The launcher runs in its own cgroup under the configured
unprivileged account. The generated legacy `crewboss-loop-keepalive-killmode.conf`
is unnecessary for this service-based layout.

Use `journalctl -u crewboss-api.service` and
`journalctl -u crewboss-launcher.service` for service failures. Keep the API and
launcher on the same configuration; restart them after editing it. An API Run
request fails if a reloaded configuration changes its active repository or
runtime directory, rather than launching work in a different environment.

## Moving from prototype installations

Install into a fresh prefix and review configuration and team state before
switching services. The installer provides no in-place overwrite or migration.
Stop the old launcher before enabling another installation against the same
board. Keep backups of the old runtime state and private configuration outside
the new release directory.

Changes that affect existing setups:

- Every actual API entrypoint requires a nonblank token, including direct Python
  startup. Empty-token access and bearer tokens in SSE URLs have been removed.
- Browser tokens are no longer saved in local storage; reenter them after reload.
  Browser origins must match the explicit CORS policy.
- `CB_REPO` and agent `GH_TOKEN` must be supplied explicitly. There is no personal
  repository fallback or automatic extraction of a GitHub login token.
- API, CLI, and systemd entrypoints share `CB_HOME` and `CB_ENV_FILE`. Custom paths
  now work for agent Run actions too; render units again for those paths.
- Provider binaries and configuration mounts have explicit path settings, and
  launcher preflight rejects unsupported hosts or incomplete sandbox setups.
- Archives install maintained runtime files with their Python companions,
  governance files, team, and dashboard. Historical prototype provisioning
  bundles are not the alpha installation path.

## API-only source development

To inspect the dashboard/API without Linux or nsjail, use the source checkout's
`ui/README.md` guide. It starts `ui/server/crewboss-api.py` directly with a private
token, an isolated `CB_HOME`, and an empty `CB_REPO`. This intentionally creates
an empty board without agent credentials. The Python server uses the standard
library; the separate local demo also supplies sample board data without an API.
Agent Run actions still require a complete runtime and successful preflight.
