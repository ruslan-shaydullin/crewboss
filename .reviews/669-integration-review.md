# Integration Review: Issue #669 — Charter #527 Final Integration Review

**Reviewed leaves:** #665 (tests) · #666 (impl) · #667 (infra) · #668 (security)  
**Reviewed PRs:** #670 (`test(#665)`) · #671 (`feat(#667)`) · #672 (`feat(#666)`) · #673 (`review(#668)`)  
**Head commit reviewed:** `97d82b9` (merge of #673 into `charter/527`)  
**Reviewer:** leaf/669-1782327931 (integration-reviewer, charter #527)  
**Review date:** 2026-06-24  
**Charter:** #527

---

## Verdict: ✅ APPROVED — all 10 integration items pass

All acceptance checks green:
- `bash reference/tests/webhook-security.test.sh 2>&1 | grep -c FAIL | grep -qx '0'` → **PASS** (8/8 subtests)
- `python3 -c "import ast; ast.parse(open('ui/server/crewboss-api.py').read()); print('ok')"` → **ok**
- `grep -qn 'state=all' ui/server/crewboss-api.py` → **PASS**
- `grep -qn '"/repos/{REPO}' ui/server/crewboss-api.py` → **PASS**

---

## Item 1 — `do_POST` path-extraction order · PASS ✅

**File:** `ui/server/crewboss-api.py`, lines 883–888 (and `_box-snapshot/cbnet/crewboss-api.py` lines 600–605)

```python
def do_POST(self):
    path = self.path.split("?",1)[0]          # 1. extract path first
    if path == "/api/gh-webhook":              # 2. webhook bypass (before Bearer check)
        return self._handle_webhook()
    if not self._auth_ok():                    # 3. auth gate for all other routes
        return self._send(401,{"ok":False,"msg":"unauthorized"})
```

The previous bug (`_auth_ok()` called before `path` was defined) is absent. Correct 3-step order confirmed in both files.

---

## Item 2 — Missing imports resolved · PASS ✅

**File:** `ui/server/crewboss-api.py`, line 16 (and `_box-snapshot/cbnet/crewboss-api.py`, line 16)

```python
import hmac, hashlib
```

Both `hmac` and `hashlib` are present at the top of both files. The previous `NameError` on webhook requests is not possible.

---

## Item 3 — HMAC wiring · PASS ✅

**File:** `ui/server/crewboss-api.py`, lines 905–925 (and box-snapshot lines 614–634)

- Body read via `Content-Length` ✅
- `sha256=` prefix stripped before comparison (`sig_header[len("sha256="):]`) ✅
- Bare-hex or absent prefix yields empty `expected` string → rejected ✅
- `hmac.compare_digest(computed, expected)` — timing-safe comparison ✅
- No `print(body_bytes)` or `print(secret)` anywhere in handler ✅

---

## Item 4 — `_webhook_kick` threading · PASS ✅

**File:** `ui/server/crewboss-api.py`, lines 879–880 and lines 923–924

```python
_webhook_kick.wait(timeout=int(os.environ.get("CB_API_POLL","10")))
_webhook_kick.clear()
```

```python
if event_type in ("issues", "pull_request"):
    _webhook_kick.set()
```

SSE loop uses `wait(timeout=CB_API_POLL)` + `clear()`. Handler calls `set()` on `issues` and `pull_request` events. Bare `time.sleep` is absent.

Test 5 confirms wakeup latency is <<1 s (vs 10 s poll ceiling).

---

## Item 5 — ETag polling fix points · PASS ✅

**File:** `ui/server/crewboss-api.py`, lines 185–204 (and box-snapshot lines 78–97)

```python
cmd = ["gh", "api", f"/repos/{REPO}/issues", "--include", "-X", "GET",
       "-F", "state=all", "-F", "per_page=100"]
```

- URL: `f"/repos/{REPO}/issues"` — no non-existent `OWNER` variable ✅
- `-F state=all -F per_page=100` — preserves all-issues (including closed/`done`) behavior ✅
- `--include` flag used; stdout split on blank line (`\r\n\r\n` / `\n\n`) ✅
- `ETag:` header extracted (case-insensitive) and stored in `_etag_store["issues"]` ✅
- `If-None-Match` sent on subsequent calls ✅
- 304 response skips `json.loads` and returns `_cached_issues` ✅

---

## Item 6 — Bind address · PASS ✅

**File:** `ui/server/crewboss-api.py`, line 969 (and box-snapshot line 638)

```python
ThreadingHTTPServer((os.environ.get("CB_API_HOST","127.0.0.1"), PORT), H).serve_forever()
```

Default `127.0.0.1` preserved for local dev. `CB_API_HOST=0.0.0.0` set in systemd unit enables GitHub webhook delivery.

---

## Item 7 — Test coverage · PASS ✅

**File:** `reference/tests/webhook-security.test.sh`

All 8 subtests pass (0 FAILs):

| # | Description | Result |
|---|---|---|
| 1 | Valid HMAC with `sha256=` prefix → 200 | ok |
| 2 | Invalid HMAC signature → 401 | ok |
| 3 | Missing `X-Hub-Signature-256` header → 401 | ok |
| 4 | Bare hex (correct digest, no `sha256=`) → 401 | ok |
| 5 | SSE `_webhook_kick` fires within 1 s | ok |
| 6a | First ETag poll → 200 with ETag header | ok |
| 6b | Second poll with `If-None-Match` → 304 | ok |
| 7 | `CB_API_HOST=0.0.0.0` bind accepted | ok |

---

## Item 8 — Service config hygiene · PASS ✅

**File:** `reference/runtime/crewboss-api.service`, lines 30 and 33

```ini
Environment=CB_WEBHOOK_SECRET=<placeholder>
Environment=CB_API_HOST=0.0.0.0
```

Both variables present in `[Service]` block.

**File:** `reference/runtime/start-api.sh`, lines 4–5

```bash
export CB_WEBHOOK_SECRET="${CB_WEBHOOK_SECRET:-changeme}"
export CB_API_HOST="${CB_API_HOST:-127.0.0.1}"
```

Both exported in `start-api.sh`.

---

## Item 9 — Operator docs · PASS ✅

**File:** `reference/runtime/README.md`

Documents:
- Webhook registration steps (Payload URL, content-type `application/json`, events: Issues + Pull requests) ✅
- Secret generation (`openssl rand -hex 32`) and configuration steps ✅
- Port exposure and firewall guidance (GitHub IP ranges) ✅
- Security trade-off: `0.0.0.0` binding mitigated by Bearer auth on all non-webhook routes and HMAC-SHA256 on `/api/gh-webhook` ✅

---

## Item 10 — `_box-snapshot` mirror · PASS ✅

**File:** `_box-snapshot/cbnet/crewboss-api.py`

All charter #527 changes applied identically:
- `import hmac, hashlib` (line 16) ✅
- `_webhook_kick = threading.Event()` (line 27) ✅
- `_etag_store = {}` and `_cached_issues = None` (lines 28–29) ✅
- ETag polling with `--include`, `state=all`, `If-None-Match` (lines 78–97) ✅
- `_webhook_kick.wait(timeout=...)` + `_webhook_kick.clear()` (lines 596–597) ✅
- `do_POST` 3-step ordering (lines 600–605) ✅
- `_handle_webhook` with HMAC verification (lines 614–634) ✅
- `ThreadingHTTPServer((os.environ.get("CB_API_HOST","127.0.0.1"), PORT), H)` (line 638) ✅

Differences from `ui/server/crewboss-api.py` are pre-existing features from unrelated charters (queue, synthetic agents, merge action, static serving, etc.) — all outside charter #527 scope.

---

## Summary

Charter #527 integration is **complete and correct**. All four dependent leaves (#665, #666, #667, #668) have been reviewed, their PRs merged, and this final review confirms all 10 integration items pass without exception.
