#!/usr/bin/env python3
"""Stand-in for a revision-1 PTY daemon (2.0.0-beta.1) for the R7-01a
self-test: it never answers HELLO, answers LIST with ALIVE live sessions,
and exits (removing its socket) on SHUTDOWN.
usage: legacy_ptyd.py SOCKET ALIVE
"""

import json
import os
import socket
import struct
import sys
import uuid

HEADER = struct.Struct(">B16sI")
LIST, SHUTDOWN, SESSIONS = 6, 8, 105


def serve(conn, sessions, server, path):
    """False once SHUTDOWN arrived."""
    buffer = b""
    conn.settimeout(3)
    try:
        while True:
            chunk = conn.recv(4096)
            if not chunk:
                return True
            buffer += chunk
            while len(buffer) >= HEADER.size:
                kind, _, length = HEADER.unpack_from(buffer)
                if len(buffer) < HEADER.size + length:
                    break
                buffer = buffer[HEADER.size + length:]
                if kind == LIST:
                    payload = json.dumps(sessions).encode()
                    conn.sendall(HEADER.pack(SESSIONS, bytes(16), len(payload)) + payload)
                elif kind == SHUTDOWN:
                    return False
    except (socket.timeout, OSError):
        return True
    finally:
        conn.close()


def main():
    path, alive = sys.argv[1], int(sys.argv[2])
    if os.path.exists(path):
        os.unlink(path)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(path)
    server.listen(8)
    sessions = [{"id": str(uuid.uuid4()).upper(), "pid": os.getpid(), "alive": True, "startedAt": 0.0}
                for _ in range(alive)]
    while True:
        conn, _ = server.accept()
        if not serve(conn, sessions, server, path):
            server.close()
            os.unlink(path)
            return 0


if __name__ == "__main__":
    sys.exit(main())
