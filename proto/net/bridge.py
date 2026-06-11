#!/usr/bin/env python3
"""crewboss Round 3b: TCP->unix bridge (runs INSIDE the jail netns).

Listens on 127.0.0.1:<port> (jail loopback) and forwards each connection
to the bind-mounted unix socket of the host-side filtering proxy.
"""
import asyncio
import sys

SOCK = sys.argv[1]
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 3128


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
        r2, w2 = await asyncio.open_unix_connection(SOCK)
    except Exception:
        writer.close()
        return
    await asyncio.gather(pipe(reader, w2), pipe(r2, writer))


async def main():
    server = await asyncio.start_server(handle, "127.0.0.1", PORT)
    async with server:
        await server.serve_forever()


asyncio.run(main())
