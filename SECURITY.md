# Security policy

## Reporting a vulnerability

Do not post credentials, exploit details, or private repository data in a public
issue. On the repository's [security advisories page](https://github.com/ruslan-shaydullin/crewboss/security/advisories),
use **Report a vulnerability** if private reporting is enabled. If that option
is unavailable, open an issue requesting a private contact from a maintainer,
without including the vulnerability details.

A private report should include the affected commit, component, setup and
exposure, reproduction steps, expected behavior, and likely impact. Replace
tokens and private data with placeholders. Please allow maintainers time to
investigate and coordinate disclosure.

crewboss is experimental and has no maintained release series or guaranteed
response time. Reports against the current default branch are useful; include
the commit when reporting an older deployment.

## System and trust boundaries

The Bash runtime launches coding agents and operates GitHub issues and pull
requests. The Python API exposes board state, configuration, and commands to
the dashboard. These components can access repository contents, credentials,
local runtime files, and agent processes.

Treat issue text, pull request content, checked-out code, agent output, webhook
payloads, and HTTP requests as inputs that may cross a trust boundary. API
access grants operator capabilities; this is not a multi-tenant service.

Report unintended credential disclosure, unauthorized API or GitHub actions,
access outside intended file/process boundaries, and failures of the configured
approval or completion controls. Describe the required access and actual
deployment conditions so impact can be assessed. Prototype code should be
assessed for whether it is reached by the current runtime or instructions; some
files under `proto/` are still canonical runtime dependencies.

## Deployment limitations

- A role's tool list and command hook are reliability controls. Shell access can
  bypass command-level checks; these hooks are not a security sandbox for
  hostile code or prompt injection. Use appropriately scoped credentials,
  isolated execution environments, and server-side repository protections.
- The API disables token authentication when `CB_API_TOKEN` is empty. Set a
  strong token and bind local development to `127.0.0.1`. The health endpoint
  and static dashboard assets are public even when token auth is configured.
- The browser stores its API token in local storage and sends it in the URL for
  EventSource requests. Do not share browser profiles or log token-bearing
  URLs. Remote access requires a trusted tunnel or HTTPS configuration; the
  Python server does not provide TLS itself.
- Webhooks use `CB_WEBHOOK_SECRET` independently of the API token. Use a unique
  generated secret. Historical scripts contain demo credentials, paths, and
  host-specific settings; inspect and adapt them before use.

These limitations describe the current implementation, not blanket exclusions
for security reports or a claim that a deployment has been audited.
