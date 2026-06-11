#!/usr/bin/env python3
"""crewboss Round 3b: filtering CONNECT proxy on a unix socket (runs on HOST).

Jail reaches it via a bind-mounted unix socket + in-jail TCP bridge.
DNS is resolved here, on the host; the jail needs no resolver at all.
Only CONNECT to allowlisted hosts on port 443 is permitted.
"""
import asyncio
import os
import re
import sys
import time

SOCK = sys.argv[1] if len(sys.argv) > 1 else "/tmp/cbnet/proxy.sock"
LOG = os.environ.get("CB_PROXY_LOG", "/tmp/cbnet/proxy.log")

ALLOW_EXACT = {
    "github.com",
    "api.github.com",
    "codeload.github.com",
    "objects.githubusercontent.com",
    "api.anthropic.com",
    "console.anthropic.com",
    "registry.npmjs.org",
    "platform.claude.com",
}
ALLOW_SUFFIX = (".githubusercontent.com", ".npmjs.org")
ALLOW_PORTS = {443}


def allowed(host, port):
    h = host.lower().rstrip(".")
    if port not in ALLOW_PORTS:
        return False
    if h in ALLOW_EXACT:
        return True
    return any(h.endswith(s) and len(h) > len(s) for s in ALLOW_SUFFIX)


def log(msg):
    with open(LOG, "a") as f:
        f.write("%s %s\n" % (time.strftime("%H:%M:%S"), msg))


async def pipe(reader, writer):
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except Exception:
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


async def handle(reader, writer):
    try:
        line = await asyncio.wait_for(reader.readline(), 10)
        m = re.match(rb"CONNECT\s+\[?([^\s\]:]+)\]?:(\d+)\s+HTTP/1\.[01]", line or b"")
        while True:  # drain request headers
            h = await asyncio.wait_for(reader.readline(), 10)
            if not h or h in (b"\r\n", b"\n"):
                break
        if not m:
            log("DENY non-connect %r" % (line[:120] if line else b""))
            writer.write(b"HTTP/1.1 400 Bad Request\r\n\r\n")
            await writer.drain()
            writer.close()
            return
        host, port = m.group(1).decode(), int(m.group(2))
        if not allowed(host, port):
            log("DENY %s:%d" % (host, port))
            writer.write(b"HTTP/1.1 403 Forbidden\r\n\r\n")
            await writer.drain()
            writer.close()
            return
        try:
            r2, w2 = await asyncio.wait_for(asyncio.open_connection(host, port), 15)
        except Exception as e:
            log("UPSTREAM-FAIL %s:%d %s" % (host, port, e))
            writer.write(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
            await writer.drain()
            writer.close()
            return
        log("ALLOW %s:%d" % (host, port))
        writer.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        await writer.drain()
        await asyncio.gather(pipe(reader, w2), pipe(r2, writer))
    except Exception as e:
        log("ERR %s" % e)
        try:
            writer.close()
        except Exception:
            pass


async def main():
    try:
        os.unlink(SOCK)
    except FileNotFoundError:
        pass
    server = await asyncio.start_unix_server(handle, SOCK)
    os.chmod(SOCK, 0o666)
    log("proxy up on %s pid=%d" % (SOCK, os.getpid()))
    async with server:
        await server.serve_forever()


asyncio.run(main())
