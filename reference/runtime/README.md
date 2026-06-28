# reference/runtime — Operator Setup Guide

## Operator setup — GitHub Webhooks

This section documents how to configure the crewboss API daemon to receive GitHub webhook events.

### Webhook registration

In your GitHub repository go to **Settings → Webhooks → Add webhook** and set:

- **Payload URL**: `http://<host>:<PORT>/api/gh-webhook`  
  (e.g. `http://your-server-ip:8787/api/gh-webhook`)
- **Content type**: `application/json`
- **Events**: select **Issues** and **Pull requests**
- **Secret**: paste the secret value generated in the next step

### Secret generation

Generate a strong random secret and configure it in both GitHub and the systemd unit:

```sh
openssl rand -hex 32
```

1. Copy the output.
2. Paste it into the **Secret** field of the GitHub webhook form.
3. Set the same value as `CB_WEBHOOK_SECRET` in the systemd unit
   (`reference/runtime/crewboss-api.service`), replacing the `<placeholder>`:

```ini
Environment=CB_WEBHOOK_SECRET=<paste-your-secret-here>
```

After editing the unit file, reload and restart:

```sh
sudo systemctl daemon-reload
sudo systemctl restart crewboss-api
```

### Port exposure

The API daemon must be reachable from GitHub's IP ranges on the configured port
(default `8787`).

- `CB_API_HOST=0.0.0.0` is set in the systemd unit so the server binds on all
  interfaces — this is what allows GitHub's servers to POST to the endpoint.
- **Firewall**: restrict inbound access on the webhook port to
  [GitHub's published IP ranges](https://api.github.com/meta) (`hooks` key)
  where possible (e.g. via `iptables`, `ufw`, or your cloud security group).

### Security note

Binding on `0.0.0.0` exposes all API routes to the network. Two gates mitigate this:

1. **All non-webhook routes** require a valid `Authorization: Bearer <CB_API_TOKEN>`
   header. Requests without a matching token are rejected with `401 Unauthorized`.
2. **`/api/gh-webhook`** does not require a Bearer token but requires a valid
   HMAC-SHA256 signature computed from `CB_WEBHOOK_SECRET`. GitHub signs every
   delivery; the daemon rejects any request whose `X-Hub-Signature-256` header does
   not match.

These two gates are the stated mitigations for the `0.0.0.0` binding. Do **not**
leave `CB_WEBHOOK_SECRET` at its default `changeme` value in production — always
set a real secret generated with `openssl rand -hex 32`.

### Local development

For local dev runs (`start-api.sh`), `CB_API_HOST` defaults to `127.0.0.1`
(no network exposure) and `CB_WEBHOOK_SECRET` defaults to `changeme`.
Override before running if you need to test webhook delivery locally
(e.g. via [smee.io](https://smee.io) or `gh webhook forward`):

```sh
export CB_WEBHOOK_SECRET=your-dev-secret
export CB_API_HOST=127.0.0.1
bash reference/runtime/start-api.sh
```
