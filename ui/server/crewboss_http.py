"""HTTP authentication and origin policy shared by the API request handlers."""
import hmac
import json
from urllib.parse import urlsplit


def require_api_token(token):
    if not token or not token.strip():
        raise ValueError("CB_API_TOKEN must contain a private bearer token")


def allowed_origins(value, port=8787):
    """Return exact origins; an explicitly empty setting disables browser access."""
    if value is None:
        return frozenset(
            f"http://{host}:{number}"
            for host in ("127.0.0.1", "localhost", "[::1]")
            for number in (5500, port)
        )
    origins = set()
    for item in value.split(","):
        origin = item.strip().rstrip("/")
        if not origin:
            continue
        parsed = urlsplit(origin)
        try:
            parsed.port
        except ValueError:
            raise ValueError("CB_ALLOWED_ORIGINS contains an invalid port") from None
        if (parsed.scheme not in ("http", "https") or not parsed.hostname
                or parsed.username is not None or parsed.password is not None
                or parsed.path or parsed.query or parsed.fragment or "*" in origin):
            raise ValueError("CB_ALLOWED_ORIGINS must contain exact http(s) origins")
        origins.add(origin)
    return frozenset(origins)


class SecureRequestMixin:
    """Handlers supply api_token and permitted_origins; credentials stay in headers."""

    def _origin_ok(self):
        values = self.headers.get_all("Origin", [])
        return not values or (len(values) == 1 and values[0] in self.permitted_origins)

    def _cors(self):
        self.send_header("Vary", "Origin")
        origin = self.headers.get("Origin")
        if origin and self._origin_ok():
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Access-Control-Allow-Headers", "authorization,content-type")
            self.send_header("Access-Control-Allow-Methods", "GET,POST,OPTIONS")

    def _send(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        if code == 401:
            self.send_header("WWW-Authenticate", "Bearer")
        self._cors()
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _auth_ok(self):
        token = self.api_token
        if not token or not token.strip():
            return False
        values = self.headers.get_all("Authorization", [])
        return len(values) == 1 and hmac.compare_digest(
            values[0].encode(), ("Bearer " + token).encode()
        )

    def do_OPTIONS(self):
        requested = self.headers.get("Access-Control-Request-Method", "")
        headers = {part.strip().lower() for part in
                   self.headers.get("Access-Control-Request-Headers", "").split(",") if part.strip()}
        if (not self.headers.get("Origin") or not self._origin_ok()
                or requested not in ("GET", "POST")
                or not headers.issubset({"authorization", "content-type"})):
            return self._send(403, {"ok": False, "msg": "origin or preflight not allowed"})
        self.send_response(204)
        self._cors()
        self.send_header("Content-Length", "0")
        self.end_headers()
