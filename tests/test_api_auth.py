"""Exercise the real HTTP boundary with local state and command fixtures."""
import hashlib
import hmac
import http.client
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
API = ROOT / "ui/server/crewboss-api.py"
spec = importlib.util.spec_from_file_location("crewboss_auth_test_api", API)
api = importlib.util.module_from_spec(spec)
spec.loader.exec_module(api)


class ApiAuthTests(unittest.TestCase):
    def setUp(self):
        self.environment = patch.dict(os.environ, {
            "CB_ALLOWED_ORIGINS": "http://127.0.0.1:5500,https://dashboard.example",
            "CB_WEBHOOK_SECRET": "fixture-webhook-secret",
        })
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.token = "fixture-private-bearer"
        self.token_patch = patch.object(api, "TOKEN", self.token)
        self.token_patch.start()
        self.addCleanup(self.token_patch.stop)
        self.state_patch = patch.object(api, "build_state", return_value={"board": []})
        self.state_patch.start()
        self.addCleanup(self.state_patch.stop)
        self.command_patch = patch.object(api, "do_command", return_value={"ok": True})
        self.command = self.command_patch.start()
        self.addCleanup(self.command_patch.stop)
        self.server = api.ThreadingHTTPServer(("127.0.0.1", 0), api.H)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.stop_server)

    def stop_server(self):
        api._webhook_kick.set()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=3)

    def request(self, path="/api/state", method="GET", headers=None, body=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=3)
        try:
            connection.request(method, path, body=body, headers=headers or {})
            response = connection.getresponse()
            payload = response.read()
            return response.status, dict(response.getheaders()), payload
        finally:
            connection.close()

    def auth(self, **headers):
        return {"Authorization": "Bearer " + self.token, **headers}

    def test_protected_routes_reject_missing_wrong_and_query_tokens(self):
        for path in ("/api/state", "/api/events", "/api/team"):
            for headers in ({}, {"Authorization": "Bearer wrong"}):
                with self.subTest(path=path, headers=headers):
                    self.assertEqual(self.request(path, headers=headers)[0], 401)
        for query in ("token=", "%74oken="):
            self.assertEqual(self.request("/api/state?" + query + self.token)[0], 401)
            self.assertEqual(self.request("/api/events?" + query + self.token)[0], 401)
        self.assertEqual(self.request("/api/command?token=" + self.token, method="POST",
                                      body='{"action":"run"}')[0], 401)
        self.command.assert_not_called()

    def test_blank_handler_configuration_fails_closed(self):
        for token in ("", " \t"):
            with patch.object(api, "TOKEN", token):
                self.assertEqual(self.request(headers={"Authorization": "Bearer " + token})[0], 401)

    def test_valid_bearer_preserves_read_and_command(self):
        status, headers, body = self.request(headers=self.auth())
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), {"board": []})
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertNotIn("Access-Control-Allow-Origin", headers)
        self.assertEqual(self.request("/api/command", "POST", self.auth(), '{"action":"pause"}')[0], 200)
        self.command.assert_called_once_with({"action": "pause"})

    def test_untrusted_origin_cannot_read_or_mutate_even_with_valid_bearer(self):
        for origin in ("https://untrusted.example", "null", "http://127.0.0.1:5500.evil.example"):
            headers = self.auth(Origin=origin)
            self.assertEqual(self.request(headers=headers)[0], 403)
            status, response_headers, _ = self.request("/api/command", "POST", headers, '{"action":"run"}')
            self.assertEqual(status, 403)
            self.assertNotIn("Access-Control-Allow-Origin", response_headers)
        self.command.assert_not_called()

    def test_allowed_origin_and_preflight_use_exact_allowlist(self):
        for origin in ("http://127.0.0.1:5500", "https://dashboard.example"):
            status, headers, _ = self.request(headers=self.auth(Origin=origin))
            self.assertEqual(status, 200)
            self.assertEqual(headers["Access-Control-Allow-Origin"], origin)
            status, headers, _ = self.request("/api/events", "OPTIONS", {
                "Origin": origin, "Access-Control-Request-Method": "GET",
                "Access-Control-Request-Headers": "Authorization, Content-Type",
            })
            self.assertEqual(status, 204)
            self.assertEqual(headers["Access-Control-Allow-Origin"], origin)
        self.assertEqual(self.request("/api/state", "OPTIONS", {
            "Origin": "https://untrusted.example", "Access-Control-Request-Method": "GET",
        })[0], 403)
        self.assertEqual(self.request("/api/state", "OPTIONS", {
            "Origin": "http://127.0.0.1:5500", "Access-Control-Request-Method": "DELETE",
        })[0], 403)

    def test_duplicate_credentials_and_origins_are_rejected(self):
        for duplicate in ("Authorization", "Origin"):
            connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=3)
            try:
                connection.putrequest("GET", "/api/state")
                connection.putheader("Authorization", "Bearer " + self.token)
                connection.putheader("Origin", "http://127.0.0.1:5500")
                connection.putheader(duplicate, "Bearer " + self.token if duplicate == "Authorization"
                                     else "https://untrusted.example")
                connection.endheaders()
                response = connection.getresponse()
                self.assertEqual(response.status, 401 if duplicate == "Authorization" else 403)
                response.read()
            finally:
                connection.close()

    def test_sse_uses_bearer_header_and_preserves_state_frames(self):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=3)
        try:
            connection.request("GET", "/api/events", headers=self.auth(Origin="http://127.0.0.1:5500"))
            response = connection.getresponse()
            self.assertEqual(response.status, 200)
            self.assertEqual(response.getheader("Content-Type"), "text/event-stream")
            self.assertEqual(response.readline(), b"event: state\n")
            self.assertEqual(json.loads(response.readline().decode()[6:]), {"board": []})
        finally:
            connection.close()

    def test_webhook_uses_its_own_signature_without_bearer(self):
        body = b'{"action":"opened"}'
        signature = hmac.new(b"fixture-webhook-secret", body, hashlib.sha256).hexdigest()
        headers = {"X-Hub-Signature-256": "sha256=" + signature, "X-GitHub-Event": "issues"}
        self.assertEqual(self.request("/api/gh-webhook", "POST", headers, body)[0], 200)
        headers["X-Hub-Signature-256"] = "sha256=wrong"
        self.assertEqual(self.request("/api/gh-webhook", "POST", headers, body)[0], 401)

    def test_static_assets_cannot_escape_root_through_traversal_or_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "www"
            root.mkdir()
            (root / "index.html").write_text("dashboard fixture")
            private = Path(directory) / "www-private"
            private.mkdir()
            (private / "secret.txt").write_text("private fixture")
            (root / "outside").symlink_to(private, target_is_directory=True)
            with patch.dict(os.environ, {"CB_WEB_DIR": str(root)}):
                self.assertEqual(self.request("/")[2], b"dashboard fixture")
                self.assertEqual(self.request("/board/42")[2], b"dashboard fixture")
                for path in ("/../www-private/secret.txt", "/%2e%2e/www-private/secret.txt",
                             "/outside/secret.txt", "/%00"):
                    status, _, body = self.request(path)
                    self.assertEqual(status, 403, path)
                    self.assertNotIn(b"private fixture", body)


class ApiEntrypointTests(unittest.TestCase):
    def test_actual_entrypoint_cannot_bind_without_nonblank_token(self):
        with tempfile.TemporaryDirectory() as home:
            for token in (None, "", " \t"):
                env = {"PATH": os.environ["PATH"], "HOME": home}
                if token is not None:
                    env["CB_API_TOKEN"] = token
                result = subprocess.run([sys.executable, str(API), "--port", "0"],
                                        env=env, capture_output=True, text=True, timeout=3)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("CB_API_TOKEN", result.stderr)
                self.assertNotIn("crewboss-api on", result.stdout)

    def test_wildcard_origin_configuration_is_rejected(self):
        result = subprocess.run([sys.executable, str(API), "--port", "0"],
                                env={**os.environ, "CB_API_TOKEN": "fixture", "CB_ALLOWED_ORIGINS": "*"},
                                capture_output=True, text=True, timeout=3)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CB_ALLOWED_ORIGINS", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
