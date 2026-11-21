#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""
Minimal offline mock NNTP server for testing SABnzbd / Usenet integrations
without external Usenet subscriptions or network access.

Serves a synthetic yEnc-encoded payload for `<sample-part1@assemblrr.test>`.
"""
from __future__ import annotations

import argparse
import binascii
import socketserver
import sys
import threading
from typing import Optional, Tuple

PAYLOAD_NAME = "assemblrr-sample.txt"
PAYLOAD_BYTES = b"assemblrr mock usenet payload ok\n"
MESSAGE_ID = "<sample-part1@assemblrr.test>"
GROUP_NAME = "alt.binaries.test"


def yenc_encode(data: bytes, filename: str = PAYLOAD_NAME) -> bytes:
    """Encode bytes into a single-part yEnc article body."""
    crc = binascii.crc32(data) & 0xFFFFFFFF
    encoded = bytearray()
    col = 0
    for b in data:
        yb = (b + 42) & 0xFF
        if yb in (0, 10, 13, 61):
            encoded.append(61)
            encoded.append((yb + 64) & 0xFF)
            col += 2
        else:
            encoded.append(yb)
            col += 1
        if col >= 128:
            encoded.extend(b"\r\n")
            col = 0
    if col > 0:
        encoded.extend(b"\r\n")

    header = (
        f"=ybegin part=1 line=128 size={len(data)} name={filename}\r\n"
        f"=ypart begin=1 end={len(data)}\r\n"
    ).encode("ascii")
    footer = (
        f"=yend size={len(data)} part=1 pcrc32={crc:08x} crc32={crc:08x}\r\n"
    ).encode("ascii")
    return header + bytes(encoded) + footer


ARTICLE_BODY = yenc_encode(PAYLOAD_BYTES, PAYLOAD_NAME)
ARTICLE_HEADERS = (
    f"From: test@assemblrr.local\r\n"
    f"Newsgroups: {GROUP_NAME}\r\n"
    f'Subject: [1/1] - "{PAYLOAD_NAME}" yEnc (1/1)\r\n'
    f"Message-ID: {MESSAGE_ID}\r\n"
).encode("ascii")


def _dot_stuff(body: bytes) -> bytes:
    lines = body.split(b"\r\n")
    out = []
    for line in lines:
        if line.startswith(b"."):
            out.append(b"." + line)
        else:
            out.append(line)
    return b"\r\n".join(out)


class _NNTPHandler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        server = self.server  # type: ignore[attr-defined]
        authed = not bool(server.username)
        pending_user: Optional[str] = None
        self.wfile.write(b"200 assemblrr-mock-nntp Service Ready\r\n")
        self.wfile.flush()

        while True:
            raw = self.rfile.readline(4096)
            if not raw:
                break
            line = raw.decode("utf-8", errors="replace").strip()
            if not line:
                continue
            parts = line.split()
            cmd = parts[0].upper()
            arg = " ".join(parts[1:]) if len(parts) > 1 else ""

            if cmd == "QUIT":
                self.wfile.write(b"205 closing connection\r\n")
                self.wfile.flush()
                break
            if cmd == "CAPABILITIES":
                self.wfile.write(
                    b"101 Capability list:\r\nVERSION 2\r\nREADER\r\nAUTHINFO USER\r\n.\r\n"
                )
            elif cmd == "MODE" and arg.upper() == "READER":
                self.wfile.write(b"200 Reading active\r\n")
            elif cmd == "DATE":
                self.wfile.write(b"111 20261121120000\r\n")
            elif cmd == "AUTHINFO":
                sub = parts[1].upper() if len(parts) > 1 else ""
                val = " ".join(parts[2:]) if len(parts) > 2 else ""
                if sub == "USER":
                    pending_user = val
                    if server.username and not server.password:
                        if val == server.username:
                            authed = True
                            self.wfile.write(b"281 Authentication accepted\r\n")
                        else:
                            self.wfile.write(b"481 Authentication rejected\r\n")
                    else:
                        self.wfile.write(b"381 Password required\r\n")
                elif sub == "PASS":
                    if (not server.username) or (
                        pending_user == server.username and val == server.password
                    ):
                        authed = True
                        self.wfile.write(b"281 Authentication accepted\r\n")
                    else:
                        self.wfile.write(b"481 Authentication rejected\r\n")
                else:
                    self.wfile.write(b"501 Syntax error\r\n")
            elif not authed:
                self.wfile.write(b"480 Authentication required\r\n")
            elif cmd == "GROUP":
                self.wfile.write(f"211 1 1 1 {arg or GROUP_NAME}\r\n".encode("ascii"))
            elif cmd in ("STAT", "HEAD", "BODY", "ARTICLE"):
                target = arg or "1"
                found = target in ("1", MESSAGE_ID, MESSAGE_ID.strip("<>"))
                if not found:
                    self.wfile.write(b"430 No such article found\r\n")
                elif cmd == "STAT":
                    self.wfile.write(f"223 1 {MESSAGE_ID} article exists\r\n".encode("ascii"))
                elif cmd == "HEAD":
                    self.wfile.write(f"221 1 {MESSAGE_ID} headers\r\n".encode("ascii"))
                    self.wfile.write(ARTICLE_HEADERS + b".\r\n")
                elif cmd == "BODY":
                    self.wfile.write(f"222 1 {MESSAGE_ID} body\r\n".encode("ascii"))
                    self.wfile.write(_dot_stuff(ARTICLE_BODY) + b".\r\n")
                else:
                    self.wfile.write(f"220 1 {MESSAGE_ID} article\r\n".encode("ascii"))
                    self.wfile.write(ARTICLE_HEADERS + b"\r\n" + _dot_stuff(ARTICLE_BODY) + b".\r\n")
            else:
                self.wfile.write(b"500 Unknown command\r\n")
            self.wfile.flush()


class MockNNTPServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, server_address: Tuple[str, int], username: str = "", password: str = ""):
        self.username = username
        self.password = password
        super().__init__(server_address, _NNTPHandler)


def start_background(
    host: str = "127.0.0.1", port: int = 0, username: str = "", password: str = ""
) -> MockNNTPServer:
    srv = MockNNTPServer((host, port), username=username, password=password)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


def main() -> int:
    ap = argparse.ArgumentParser(description="Offline mock NNTP server")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=1119)
    ap.add_argument("--user", default="")
    ap.add_argument("--password", default="")
    ap.add_argument("--port-file", default="")
    args = ap.parse_args()

    srv = MockNNTPServer((args.host, args.port), username=args.user, password=args.password)
    actual_port = srv.server_address[1]
    if args.port_file:
        with open(args.port_file, "w", encoding="utf-8") as fh:
            fh.write(f"{actual_port}\n")
    print(f"LISTENING {actual_port}", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        srv.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
