# Security Review: Issue #668 — GitHub Webhook Endpoint (charter #527)

**Reviewed PRs:** #671 (`feat(#667): add CB_WEBHOOK_SECRET and CB_API_HOST env vars`) · #672 (`feat(#666): add webhook endpoint, ETag polling, and CB_API_HOST bind fix`)  
**Head commit reviewed:** `732fdc67e2a92f7e2e598dbec5c250037be3ee5c` (merge of #672 into charter/527)  
**Reviewer:** leaf/668-1782327543 (security-reviewer, charter #527)  
**Review date:** 2026-06-24  
**Charter:** #527

---

## Verdict: ✅ APPROVED

All eight security checklist items pass. One finding (replay attack surface) is documented
as a recommendation for a future charter — it does not block this PR.

---

## Item 1 — Import correctness · PASS ✅

**File:** `ui/server/crewboss-api.py`, line 16

```python
import hmac, hashlib
```

Both `hmac` and `hashlib` are imported at module load. A `NameError` on every webhook
request is not possible.

---

## Item 2 — HMAC comparison algorithm · PASS ✅

**File:** `ui/server/crewboss-api.py`, line 916

```python
if not expected or not hmac.compare_digest(computed, expected):
```

`hmac.compare_digest` is used — not `==`. This is the constant-time comparator required
to prevent timing-oracle attacks that could brute-force the secret one byte at a time.
The `==` operator would also short-circuit, giving the attacker a measurable signal.

---

## Item 3 — `sha256=` prefix stripping · PASS ✅

**File:** `ui/server/crewboss-api.py`, lines 912–916

```python
# CRITICAL: GitHub sends "sha256=<hexdigest>", not bare hex.
# Strip prefix before comparing; bare-hex or absent prefix → 401.
expected = sig_header[len("sha256="):] if sig_header.startswith("sha256=") else ""
computed = hmac.new(secret.encode(), body_bytes, hashlib.sha256).hexdigest()
if not expected or not hmac.compare_digest(computed, expected):
    return self._send(401, {"ok": False, "msg": "unauthorized"})
```

Two sub-checks:

- **GitHub's `sha256=<hex>` format:** `sig_header.startswith("sha256=")` is True →
  `expected = sig_header[7:]` (bare hex) → compared against `computed` (bare hex).
  A matching signature returns 200. ✅

- **Bare hex (no `sha256=` prefix):** `sig_header.startswith("sha256=")` is False →
  `expected = ""` → `not expected` is True (guard at start of `if`) → 401.
  Even if the bare hex equals the correct digest it is rejected. ✅

The test suite (`reference/tests/webhook-security.test.sh`) validates both cases
explicitly as Test 1 (valid prefixed HMAC → 200) and Test 4 (correct digest, no prefix → 401).

---

## Item 4 — Secret hygiene · PASS ✅

**File:** `ui/server/crewboss-api.py`

| Check | Result |
|---|---|
| `secret` variable never logged | ✅ `log_message` is fully silenced (line 808: `def log_message(self, *a): pass`). No `print()` or `sys.stderr.write()` call in `_handle_webhook` exposes the secret. |
| Missing `CB_WEBHOOK_SECRET` returns generic 500 | ✅ Line 908: `return self._send(500, {"ok": False, "msg": "server error"})`. The string `"CB_WEBHOOK_SECRET"` does not appear in the response body. |
| Secret not echoed in `/api/health` | ✅ Returns `{"ok": True, "repo": REPO}` — no secret, no internal env vars. |
| Secret not echoed in `/api/state` | ✅ `build_state()` touches only board/budget/flags/loop data — no env-var values. |
| Secret not echoed in 401 response | ✅ Returns `{"ok": False, "msg": "unauthorized"}` — no hint of secret value or variable name. |
| `body_bytes` not logged | ✅ Comment on line 918 and the code agree: payload bytes are consumed and discarded after HMAC computation. |

---

## Item 5 — Pre-auth bypass scope · PASS ✅

**File:** `ui/server/crewboss-api.py`, lines 883–888

```python
def do_POST(self):
    path = self.path.split("?",1)[0]          # 1. extract path first
    if path == "/api/gh-webhook":              # 2. webhook bypass (before Bearer check)
        return self._handle_webhook()
    if not self._auth_ok():                    # 3. auth gate for all other routes
        return self._send(401,{"ok":False,"msg":"unauthorized"})
```

The bypass uses `==` (exact equality), not `startswith` or a prefix match.

- `/api/gh-webhook/extra` → does **not** match → auth gate applied → 401 (if unauthenticated).
- `/api/gh-webhooks` → does **not** match → auth gate applied.
- `/api/gh-webhook` → matches → `_handle_webhook()` called (HMAC gate enforced inside).

No other route accidentally escapes the Bearer-auth gate.

---

## Item 6 — Replay attack surface · ⚠ FINDING (non-blocking)

The current implementation has **no replay-attack mitigation**:

- The `X-GitHub-Delivery` header (a UUID per delivery) is not captured or deduplicated.
- No timestamp window check against `X-GitHub-Event` or a custom header is performed.

**Impact:** An attacker who captures a valid HTTP request (with a correct
`X-Hub-Signature-256` header) could replay it indefinitely. Each replay would call
`_webhook_kick.set()`, causing the SSE loop to fire a state-refresh. This is a
denial-of-service vector (rate-limit exhaustion via forced GitHub API polling) rather
than an integrity or privilege escalation risk, because the webhook handler takes no
write actions — it only sets the kick Event.

**Recommendation (record only; implementation not required in charter #527):**

In a follow-on charter, implement one or both of:

1. **`X-GitHub-Delivery` deduplication:** Store the last N UUIDs (e.g. in a bounded
   `collections.deque`) and reject duplicates with 200 (idempotent acknowledge, not 4xx,
   to avoid GitHub retry storms).
2. **Timestamp window:** Reject deliveries whose `X-GitHub-Event` timestamp (derivable
   from the payload `"created_at"` field or a custom header) is more than 5 minutes old.

Option 1 is sufficient protection against the identified DoS vector.

---

## Item 7 — ETag state safety · PASS ✅

**File:** `ui/server/crewboss-api.py`, lines 29 and 188–202

```python
_etag_store = {}  # keyed by resource path
```

The `_etag_store` module-level variable is read/written only inside `build_state()`,
which is called from `GET /api/state` and `GET /api/events`. Both of those routes sit
behind the Bearer-auth gate (`_auth_ok()` check at line 847). The ETag value is consumed
internally as an `If-None-Match` header on outbound `gh api` calls and never written into
any response body or log.

`_handle_webhook()` does not reference `_etag_store` at all — it only calls
`_webhook_kick.set()`. Unauthenticated callers cannot observe ETag state.

---

## Item 8 — Bind address intent documentation · PASS ✅

**File 1:** `reference/runtime/crewboss-api.service`, lines 31–33

```ini
# Required so GitHub can POST webhooks to this host.
# All routes require Bearer auth; /api/gh-webhook uses HMAC-SHA256 instead.
Environment=CB_API_HOST=0.0.0.0
```

The inline comment directly above the `0.0.0.0` binding names the intent and cites
both security gates.

**File 2:** `reference/runtime/README.md`, §"Security note"

> Binding on `0.0.0.0` exposes all API routes to the network. Two gates mitigate this:
>
> 1. **All non-webhook routes** require a valid `Authorization: Bearer <CB_API_TOKEN>` …
> 2. **`/api/gh-webhook`** does not require a Bearer token but requires a valid
>    HMAC-SHA256 signature computed from `CB_WEBHOOK_SECRET`. …
>
> These two gates are the stated mitigations for the `0.0.0.0` binding.

Both the systemd unit and the operator docs satisfy the requirement. The `0.0.0.0`
binding is documented as intentional and both mitigations are explicitly cited.

---

## Summary table

| # | Check | Verdict |
|---|---|---|
| 1 | `import hmac, hashlib` present | ✅ PASS |
| 2 | `hmac.compare_digest` used (not `==`) | ✅ PASS |
| 3 | `sha256=` prefix stripping + bare-hex → 401 | ✅ PASS |
| 4 | `CB_WEBHOOK_SECRET` never echoed in logs/responses | ✅ PASS |
| 5 | Bypass scope exactly `"/api/gh-webhook"` (no wildcard) | ✅ PASS |
| 6 | Replay attack surface | ⚠ FINDING — dedup recommendation recorded |
| 7 | ETag state not exposed to unauthenticated callers | ✅ PASS |
| 8 | `CB_API_HOST=0.0.0.0` documented with mitigation citations | ✅ PASS |

**Overall verdict: APPROVED.** The implementation is correct and safe to merge.
The replay-attack finding (item 6) is recorded as a follow-on recommendation and
does not block this charter.
