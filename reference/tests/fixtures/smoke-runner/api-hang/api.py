#!/usr/bin/env python3
# HERMETIC RED fixture (charter #993 / catches #973): an api.py whose state
# builder never returns -> any real /api/state smoke probe HANGS.  smoke-runner.sh
# MUST kill this by its per-detector timeout and report exit 1 (FAIL), proving the
# gate does NOT itself hang.  This is a deliberately broken artifact, never run in
# production; it exists only to be caught by the smoke gate.
import http.server
import json
import os


def build_state():
    # BUG class "built but does not run live": no-exit loop (cf. api.py `while True:`
    # in charter #969). /api/state never produces a response.
    while True:
        pass
    return {}  # unreachable


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        if self.path == "/api/state":
            body = json.dumps(build_state()).encode()  # hangs here forever
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, *_a):  # silence
        return


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "0"))
    httpd = http.server.HTTPServer(("127.0.0.1", port), Handler)
    # Advertise the bound port so a probing harness can find us.
    print("PORT=%d" % httpd.server_address[1], flush=True)
    httpd.serve_forever()
