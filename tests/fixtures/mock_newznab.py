#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""
Minimal offline mock Newznab HTTP server for testing SABnzbd/Prowlarr integration
without external Usenet indexers or paid accounts.
"""
from __future__ import annotations

import argparse
import html
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Tuple
from urllib.parse import parse_qs, urlparse

NZB_TEMPLATE = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE nzb PUBLIC "-//newzBin//DTD NZB 1.1//EN" "http://www.newzbin.com/DTD/nzb/nzb-1.1.dtd">
<nzb xmlns="http://www.newzbin.com/DTD/2003/nzb">
  <file poster="test@assemblrr.local" date="1760000000" subject="[1/1] - &quot;assemblrr-sample.txt&quot; yEnc (1/1)">
    <groups>
      <group>alt.binaries.test</group>
    </groups>
    <segments>
      <segment bytes="{nbytes}" number="1">sample-part1@assemblrr.test</segment>
    </segments>
  </file>
</nzb>
"""

CAPS_XML = """<?xml version="1.0" encoding="UTF-8"?>
<caps>
  <server version="1.0" title="assemblrr mock newznab"/>
  <limits max="100" default="100"/>
  <searching>
    <search available="yes" supportedParams="q"/>
    <tv-search available="yes" supportedParams="q,tvdbid,season,ep"/>
    <movie-search available="yes" supportedParams="q,imdbid,tmdbid"/>
  </searching>
  <categories>
    <category id="2000" name="Movies">
      <subcat id="2040" name="Movies/HD"/>
    </category>
    <category id="5000" name="TV">
      <subcat id="5040" name="TV/HD"/>
    </category>
  </categories>
</caps>
"""


class _NewznabHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args) -> None:
        return

    def _send(self, status: int, content_type: str, body: str) -> None:
        raw = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        qs = parse_qs(parsed.query)
        t = (qs.get("t") or [""])[0].lower()

        if parsed.path in ("/health", "/ping"):
            self._send(200, "application/json", '{"ok":true}')
            return
        if t == "caps":
            self._send(200, "application/xml; charset=utf-8", CAPS_XML)
            return
        if t in ("search", "movie", "tvsearch"):
            host = self.headers.get("Host") or f"127.0.0.1:{self.server.server_address[1]}"
            nzb_url = html.escape(f"http://{host}/api?t=get&id=sample-1")
            rss = (
                '<?xml version="1.0" encoding="UTF-8"?>'
                '<rss version="2.0" xmlns:newznab="http://www.newznab.com/DTD/2010/feeds/attributes/">'
                "<channel><title>assemblrr mock newznab</title>"
                "<item><title>Alpha.Film.2016.1080p.WEB</title>"
                '<guid isPermaLink="false">sample-1</guid>'
                f'<link>{nzb_url}</link>'
                f'<enclosure url="{nzb_url}" length="33" type="application/x-nzb"/>'
                '<category>2040</category>'
                '<newznab:attr name="category" value="2000"/>'
                "</item></channel></rss>"
            )
            self._send(200, "application/rss+xml; charset=utf-8", rss)
            return
        if t == "get":
            self._send(200, "application/x-nzb; charset=utf-8", NZB_TEMPLATE.format(nbytes=4096))
            return
        self._send(404, "application/xml; charset=utf-8", '<error code="404" description="not found"/>')


class MockNewznabServer(ThreadingHTTPServer):
    daemon_threads = True


def start_background(host: str = "127.0.0.1", port: int = 0) -> MockNewznabServer:
    srv = MockNewznabServer((host, port), _NewznabHandler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


def main() -> int:
    ap = argparse.ArgumentParser(description="Offline mock Newznab HTTP server")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8182)
    ap.add_argument("--port-file", default="")
    args = ap.parse_args()

    srv = MockNewznabServer((args.host, args.port), _NewznabHandler)
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
