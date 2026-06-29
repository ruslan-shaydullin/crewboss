#!/usr/bin/env python3
# VALID-PASS fixture (charter #993, gated lane): a well-formed api.py whose
# /api/state returns prompt, valid, non-empty JSON and the server exits cleanly.
# Used ONLY by the live-gated lane (real gh + board); never mocked.
import http.server
import json
import os


def build_state():
    return {"ok": True, "charters": [], "leaves": []}


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        if self.path == "/api/state":
            body = json.dumps(build_state()).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, *_a):
        return


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "0"))
    httpd = http.server.HTTPServer(("127.0.0.1", port), Handler)
    print("PORT=%d" % httpd.server_address[1], flush=True)
    httpd.serve_forever()
