#!/usr/bin/env python3
"""Minimal Source-RCON client for the factorio-pi server.

Usage:
  tools/rcon.py '/pi {"op":"summary"}'
  tools/rcon.py --op summary            # shorthand for /pi {"op": ...}
Reads RCON_PASSWORD from server/.env, port from RCON_PORT (default 27015).
"""
import json
import os
import socket
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def load_password() -> str:
    if os.environ.get("RCON_PASSWORD"):
        return os.environ["RCON_PASSWORD"]
    for line in (ROOT / "server" / ".env").read_text().splitlines():
        if line.startswith("RCON_PASSWORD="):
            return line.split("=", 1)[1].strip()
    raise SystemExit("RCON_PASSWORD not found")


class Rcon:
    AUTH, EXEC = 3, 2

    def __init__(self, host="127.0.0.1", port=None, password=None):
        self.sock = socket.create_connection((host, int(port or os.environ.get("RCON_PORT", 27015))), timeout=10)
        self._id = 0
        self._send(self.AUTH, password or load_password())
        rid, _, _ = self._recv()
        if rid == -1:
            raise SystemExit("RCON auth failed")

    def _send(self, kind: int, body: str) -> int:
        self._id += 1
        data = struct.pack("<ii", self._id, kind) + body.encode() + b"\x00\x00"
        self.sock.sendall(struct.pack("<i", len(data)) + data)
        return self._id

    def _recv_exact(self, n: int) -> bytes:
        buf = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise ConnectionError("RCON connection closed")
            buf += chunk
        return buf

    def _recv(self):
        (size,) = struct.unpack("<i", self._recv_exact(4))
        payload = self._recv_exact(size)
        rid, kind = struct.unpack("<ii", payload[:8])
        return rid, kind, payload[8:-2].decode(errors="replace")

    def command(self, cmd: str) -> str:
        rid = self._send(self.EXEC, cmd)
        while True:
            got, _, body = self._recv()
            if got == rid:
                return body


def main():
    args = sys.argv[1:]
    if not args:
        raise SystemExit(__doc__)
    if args[0] == "--op":
        payload = {"op": args[1]}
        if len(args) > 2:
            payload.update(json.loads(args[2]))
        cmd = "/pi " + json.dumps(payload)
    else:
        cmd = " ".join(args)
    print(Rcon().command(cmd))


if __name__ == "__main__":
    main()
