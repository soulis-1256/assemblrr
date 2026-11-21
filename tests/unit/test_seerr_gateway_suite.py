#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Offline unit tests for scripts/seerr-gateway.py (no Docker stack required)."""
from __future__ import annotations

import importlib.util
import json
import os
import re
import socket
import threading
import time
import unittest
import urllib.error
import urllib.request
from http.client import HTTPConnection
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Dict, List, Optional, Tuple

REPO_ROOT = Path(__file__).resolve().parents[2]
_GW_PATH = REPO_ROOT / "scripts" / "seerr-gateway.py"
_SPEC = importlib.util.spec_from_file_location("seerr_gateway", _GW_PATH)
assert _SPEC and _SPEC.loader
gw_mod = importlib.util.module_from_spec(_SPEC)
import sys
sys.modules["seerr_gateway"] = gw_mod
_SPEC.loader.exec_module(gw_mod)


class _MockSeerr(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    calls: List[str] = []
    request_payload: dict = {}
    request_status: int = 200
    file_delete_status: int = 204
    request_delete_status: int = 204
    users_by_key: Dict[str, dict] = {
        "test-key": {"id": 1, "permissions": 2},       # ADMIN
        "manager-key": {"id": 2, "permissions": 4},    # MANAGE_REQUESTS
        "user-key": {"id": 99, "permissions": 32},     # Regular REQUEST user
    }
    last_request_headers: Dict[str, str] = {}

    def log_message(self, fmt: str, *args) -> None:
        return

    def _caller(self) -> Optional[dict]:
        key = self.headers.get("X-Api-Key") or ""
        return self.users_by_key.get(key)

    def _send(self, status: int, body: bytes = b"", content_type: str = "application/json") -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD" and body:
            self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0]
        _MockSeerr.last_request_headers = {k: v for k, v in self.headers.items()}
        _MockSeerr.calls.append(f"GET {path}")
        if path == "/redir":
            self.send_response(302)
            self.send_header("Location", "http://seerr:5055/login")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if path == "/api/v1/settings/public":
            self._send(200, b'{"initialized":true}')
            return
        user = self._caller()
        if user is None:
            self._send(401, b'{"error":"Unauthorized"}')
            return
        if path == "/api/v1/auth/me":
            self._send(200, json.dumps(user).encode("utf-8"))
            return
        if re.match(r"^/api/v1/request/(\d+)/?$", path):
            if _MockSeerr.request_status != 200:
                self._send(_MockSeerr.request_status, b'{"error":"upstream error"}')
                return
            self._send(200, json.dumps(_MockSeerr.request_payload).encode("utf-8"))
            return
        self._send(404, b'{"error":"not found"}')

    def do_DELETE(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0]
        _MockSeerr.calls.append(f"DELETE {self.path}")
        if self._caller() is None:
            self._send(401, b'{"error":"Unauthorized"}')
            return
        if re.match(r"^/api/v1/media/\d+/file", path):
            self._send(_MockSeerr.file_delete_status, b"")
            return
        if re.match(r"^/api/v1/request/\d+", path):
            self._send(_MockSeerr.request_delete_status, b"")
            return
        self._send(404, b'{"error":"not found"}')

    def do_POST(self) -> None:  # noqa: N802
        length = int(self.headers.get("Content-Length") or "0")
        body = self.rfile.read(length) if length else b""
        self._send(200, body)


class _MockSonarr(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    calls: List[str] = []
    files: List[dict] = []
    series: dict = {}
    queue: List[dict] = []
    episodefile_status: int = 200

    def log_message(self, fmt: str, *args) -> None:
        return

    @classmethod
    def reset(cls) -> None:
        cls.calls = []
        cls.episodefile_status = 200
        cls.files = [
            {"id": 1, "seasonNumber": 1, "seriesId": 10},
            {"id": 2, "seasonNumber": 2, "seriesId": 10},
        ]
        cls.series = {
            "id": 10,
            "title": "Sample Show",
            "tvdbId": 362472,
            "seasons": [
                {"seasonNumber": 1, "monitored": True},
                {"seasonNumber": 2, "monitored": True},
            ],
        }
        cls.queue = [
            {"id": 201, "seriesId": 10, "downloadId": "aaa", "episode": {"seasonNumber": 1}},
            {"id": 202, "seriesId": 10, "downloadId": "bbb", "episode": {"seasonNumber": 2}},
            {"id": 203, "seriesId": 11, "downloadId": "ccc", "episode": {"seasonNumber": 1}},
        ]

    def _send(self, status: int, body: bytes = b"") -> None:
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD" and body:
            self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0]
        _MockSonarr.calls.append(f"GET {self.path}")
        if path == "/api/v3/series/10":
            self._send(200, json.dumps(_MockSonarr.series).encode("utf-8"))
            return
        if path == "/api/v3/series":
            self._send(200, json.dumps([_MockSonarr.series]).encode("utf-8"))
            return
        if path == "/api/v3/episodefile":
            if _MockSonarr.episodefile_status != 200:
                self._send(_MockSonarr.episodefile_status, b'{"error":"episodefile failed"}')
                return
            self._send(200, json.dumps(_MockSonarr.files).encode("utf-8"))
            return
        if path == "/api/v3/episode":
            eps = [{"id": 100 + f["id"], "seasonNumber": f["seasonNumber"], "seriesId": 10} for f in _MockSonarr.files]
            self._send(200, json.dumps(eps).encode("utf-8"))
            return
        if path == "/api/v3/queue":
            self._send(200, json.dumps({"records": list(_MockSonarr.queue)}).encode("utf-8"))
            return
        self._send(404, b"{}")

    def do_DELETE(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0]
        _MockSonarr.calls.append(f"DELETE {path}")
        m = re.match(r"^/api/v3/episodefile/(\d+)$", path)
        if m:
            fid = int(m.group(1))
            _MockSonarr.files = [f for f in _MockSonarr.files if f.get("id") != fid]
            self._send(200, b"")
            return
        m = re.match(r"^/api/v3/queue/(\d+)$", path)
        if m:
            qid = int(m.group(1))
            _MockSonarr.queue = [q for q in _MockSonarr.queue if q.get("id") != qid]
            self._send(200, b"")
            return
        self._send(404, b"{}")

    def do_PUT(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0]
        _MockSonarr.calls.append(f"PUT {path}")
        length = int(self.headers.get("Content-Length") or "0")
        if length:
            self.rfile.read(length)
        self._send(202, b"{}")


class _MockRadarr(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    calls: List[str] = []
    movies: List[dict] = []
    queue: List[dict] = []

    def log_message(self, fmt: str, *args) -> None:
        return

    @classmethod
    def reset(cls) -> None:
        cls.calls = []
        cls.movies = [
            {"id": 1, "tmdbId": 10378, "title": "Big Buck Bunny"},
            {"id": 2, "tmdbId": 999999, "title": "Sample Movie Two"},
        ]
        cls.queue = [
            {"id": 99, "movieId": 1, "downloadId": "abc123"},
            {"id": 100, "movieId": 2, "downloadId": "def456"},
        ]

    def _send(self, status: int, body: bytes = b"") -> None:
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD" and body:
            self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0]
        _MockRadarr.calls.append(f"GET {self.path}")
        if path == "/api/v3/movie":
            self._send(200, json.dumps(list(_MockRadarr.movies)).encode("utf-8"))
            return
        if path == "/api/v3/queue":
            self._send(200, json.dumps({"records": list(_MockRadarr.queue)}).encode("utf-8"))
            return
        self._send(404, b"{}")

    def do_DELETE(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0]
        _MockRadarr.calls.append(f"DELETE {path}")
        m = re.match(r"^/api/v3/queue/(\d+)$", path)
        if m:
            qid = int(m.group(1))
            _MockRadarr.queue = [q for q in _MockRadarr.queue if q.get("id") != qid]
            self._send(200, b"")
            return
        self._send(404, b"{}")


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class SeerrGatewayTests(unittest.TestCase):
    mock_httpd: ThreadingHTTPServer
    sonarr_httpd: ThreadingHTTPServer
    radarr_httpd: ThreadingHTTPServer
    gw_httpd: gw_mod.GatewayHTTPServer
    cfg: gw_mod.GatewayConfig
    gw_port: int

    @classmethod
    def setUpClass(cls) -> None:
        mock_port = _free_port()
        sonarr_port = _free_port()
        radarr_port = _free_port()
        cls.gw_port = _free_port()

        cls.mock_httpd = ThreadingHTTPServer(("127.0.0.1", mock_port), _MockSeerr)
        cls.sonarr_httpd = ThreadingHTTPServer(("127.0.0.1", sonarr_port), _MockSonarr)
        cls.radarr_httpd = ThreadingHTTPServer(("127.0.0.1", radarr_port), _MockRadarr)
        cls.cfg = gw_mod.GatewayConfig(
            listen_host="127.0.0.1",
            listen_port=cls.gw_port,
            upstream=f"http://127.0.0.1:{mock_port}",
            purge_on_delete_request=True,
            max_body_bytes=1024,
            sonarr_url=f"http://127.0.0.1:{sonarr_port}",
            sonarr_api_key="sonarr-test-key",
            sonarr_config="/tmp/assemblrr-no-such-sonarr-config.xml",
            radarr_url=f"http://127.0.0.1:{radarr_port}",
            radarr_api_key="radarr-test-key",
            radarr_config="/tmp/assemblrr-no-such-radarr-config.xml",
        )
        cls.gw_httpd = gw_mod.GatewayHTTPServer(("127.0.0.1", cls.gw_port), gw_mod.GatewayHandler, cls.cfg)

        for srv in (cls.mock_httpd, cls.sonarr_httpd, cls.radarr_httpd, cls.gw_httpd):
            srv.daemon_threads = True
            threading.Thread(target=srv.serve_forever, daemon=True).start()
        time.sleep(0.1)

    @classmethod
    def tearDownClass(cls) -> None:
        for srv in (cls.gw_httpd, cls.mock_httpd, cls.sonarr_httpd, cls.radarr_httpd):
            srv.shutdown()
            srv.server_close()

    def setUp(self) -> None:
        _MockSeerr.calls = []
        _MockSeerr.request_status = 200
        _MockSeerr.file_delete_status = 204
        _MockSeerr.request_delete_status = 204
        _MockSeerr.last_request_headers = {}
        _MockSeerr.request_payload = {
            "id": 42,
            "status": 2,
            "requestedBy": {"id": 1},
            "is4k": False,
            "media": {"id": 7, "tmdbId": 10378, "mediaType": "movie", "externalServiceId": 1},
        }
        _MockSonarr.reset()
        _MockRadarr.reset()
        self.cfg.purge_on_delete_request = True
        self.cfg.sonarr_api_key = "sonarr-test-key"

    def _http(
        self, method: str, path: str, headers: Optional[dict] = None, data: Optional[bytes] = None
    ) -> Tuple[int, dict, bytes]:
        url = f"http://127.0.0.1:{self.gw_port}{path}"
        req = urllib.request.Request(url, data=data, method=method, headers=headers or {})
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                return resp.status, dict(resp.headers), resp.read()
        except urllib.error.HTTPError as e:
            try:
                return e.code, dict(e.headers), e.read()
            finally:
                e.close()

    def test_health_and_ready(self) -> None:
        st, _, body = self._http("GET", "/_assemblrr/health")
        self.assertEqual(st, 200)
        self.assertIn(b"purge_on_delete_request", body)
        st, _, _ = self._http("GET", "/_assemblrr/ready")
        self.assertEqual(st, 200)

    def test_movie_cascade_order_and_queue_drain(self) -> None:
        st, hdrs, _ = self._http("DELETE", "/api/v1/request/42", {"X-Api-Key": "test-key"})
        self.assertEqual(st, 204)
        self.assertEqual(hdrs.get("X-Assemblrr-Request-Delete-Purge"), "1")
        self.assertIn("queue_movie:1:1", hdrs.get("X-Assemblrr-Purge-Detail") or "")
        calls = list(_MockSeerr.calls)
        i_me = next(i for i, c in enumerate(calls) if c == "GET /api/v1/auth/me")
        i_get = next(i for i, c in enumerate(calls) if c.startswith("GET /api/v1/request/42"))
        i_file = next(i for i, c in enumerate(calls) if "DELETE /api/v1/media/7/file" in c)
        i_del = next(i for i, c in enumerate(calls) if c.startswith("DELETE /api/v1/request/42"))
        self.assertLess(i_me, i_get)
        self.assertLess(i_get, i_file)
        self.assertLess(i_file, i_del)
        self.assertTrue(any(c.startswith("DELETE /api/v3/queue/99") for c in _MockRadarr.calls))
        self.assertFalse(any(c.startswith("DELETE /api/v3/queue/100") for c in _MockRadarr.calls))

    def test_auth_failure_and_non_admin_confused_deputy_blocked(self) -> None:
        # 1) Invalid key -> 401, zero deletes
        st, _, _ = self._http("DELETE", "/api/v1/request/42", {"X-Api-Key": "wrong"})
        self.assertEqual(st, 401)
        self.assertFalse(any(c.startswith("DELETE") for c in _MockSeerr.calls))
        self.assertEqual(_MockRadarr.calls, [])

        # 2) Regular non-admin user trying to delete someone else's approved request -> 403, ZERO *arr calls!
        _MockSeerr.calls = []
        st, hdrs, _ = self._http("DELETE", "/api/v1/request/42", {"X-Api-Key": "user-key"})
        self.assertEqual(st, 403)
        self.assertEqual(hdrs.get("X-Assemblrr-Purge-Detail"), "forbidden_non_admin")
        self.assertEqual(_MockRadarr.calls, [])
        self.assertEqual(_MockSonarr.calls, [])
        self.assertFalse(any(c.startswith("DELETE") for c in _MockSeerr.calls))

        # 3) Regular non-admin user cancelling OWN pending request -> passes DELETE through, ZERO *arr calls!
        _MockSeerr.calls = []
        _MockSeerr.request_payload = {
            "id": 42,
            "status": 1,  # pending
            "requestedBy": {"id": 99},
            "is4k": False,
            "media": {"id": 7, "tmdbId": 10378, "mediaType": "movie", "externalServiceId": 1},
        }
        st, hdrs, _ = self._http("DELETE", "/api/v1/request/42", {"X-Api-Key": "user-key"})
        self.assertEqual(st, 204)
        self.assertEqual(hdrs.get("X-Assemblrr-Purge-Detail"), "passthrough_own_pending")
        self.assertEqual(_MockRadarr.calls, [])
        self.assertFalse(any("media/7/file" in c for c in _MockSeerr.calls))
        self.assertTrue(any(c == "DELETE /api/v1/request/42" for c in _MockSeerr.calls))

    def test_upstream_500_fails_closed(self) -> None:
        _MockSeerr.request_status = 500
        st, _, _ = self._http("DELETE", "/api/v1/request/42", {"X-Api-Key": "test-key"})
        self.assertEqual(st, 502)
        self.assertFalse(any(c.startswith("DELETE") for c in _MockSeerr.calls))
        self.assertEqual(_MockRadarr.calls, [])

    def test_forwarding_headers_and_https_location_rewrite(self) -> None:
        st, _, _ = self._http("GET", "/api/v1/settings/public")
        self.assertEqual(st, 200)

        conn = HTTPConnection("127.0.0.1", self.gw_port, timeout=5)
        conn.request("GET", "/redir", headers={"Host": "localhost:5055", "X-Forwarded-Proto": "https"})
        resp = conn.getresponse()
        loc = resp.getheader("Location") or ""
        resp.read()
        conn.close()
        self.assertEqual(resp.status, 302)
        self.assertEqual(loc, "https://localhost:5055/login")

        conn = HTTPConnection("127.0.0.1", self.gw_port, timeout=5)
        conn.request("GET", "/api/v1/settings/public", headers={"Host": "localhost:5055"})
        conn.getresponse().read()
        conn.close()
        got_host = _MockSeerr.last_request_headers.get("Host") or _MockSeerr.last_request_headers.get("host")
        got_proto = _MockSeerr.last_request_headers.get("X-Forwarded-Proto") or _MockSeerr.last_request_headers.get("x-forwarded-proto")
        self.assertEqual(got_host, "localhost:5055")
        self.assertEqual(got_proto, "http")

    def test_purge_disabled_and_no_media(self) -> None:
        self.cfg.purge_on_delete_request = False
        st, _, _ = self._http("DELETE", "/api/v1/request/99", {"X-Api-Key": "test-key"})
        self.assertEqual(st, 204)
        self.assertFalse(any("media" in c for c in _MockSeerr.calls))

        self.cfg.purge_on_delete_request = True
        _MockSeerr.calls = []
        _MockSeerr.request_payload = {"id": 5, "is4k": False, "media": {}}
        st, hdrs, _ = self._http("DELETE", "/api/v1/request/5", {"X-Api-Key": "test-key"})
        self.assertEqual(st, 204)
        self.assertIn("no_media", hdrs.get("X-Assemblrr-Purge-Detail") or "")

    def test_tv_partial_seasons_vs_all_seasons_and_specials(self) -> None:
        # S01 only when S02 exists
        _MockSeerr.request_payload = {
            "id": 8,
            "type": "tv",
            "is4k": False,
            "seasons": [{"seasonNumber": 1, "status": 2}],
            "media": {"id": 6, "tmdbId": 84958, "tvdbId": 362472, "mediaType": "tv", "externalServiceId": 10},
        }
        st, hdrs, _ = self._http("DELETE", "/api/v1/request/8", {"X-Api-Key": "manager-key"})
        self.assertEqual(st, 204)
        self.assertFalse(any("DELETE /api/v1/media/6/file" in c for c in _MockSeerr.calls))
        self.assertTrue(any(c == "DELETE /api/v3/episodefile/1" for c in _MockSonarr.calls))
        self.assertFalse(any(c == "DELETE /api/v3/episodefile/2" for c in _MockSonarr.calls))
        self.assertTrue(any(c == "DELETE /api/v3/queue/201" for c in _MockSonarr.calls))
        self.assertFalse(any(c == "DELETE /api/v3/queue/202" for c in _MockSonarr.calls))
        self.assertIn("seasons_deleted", hdrs.get("X-Assemblrr-Purge-Detail") or "")

        # S01 with specials surviving
        _MockSonarr.reset()
        _MockSonarr.files = [{"id": 1, "seasonNumber": 1, "seriesId": 10}, {"id": 3, "seasonNumber": 0, "seriesId": 10}]
        _MockSonarr.series = {
            "id": 10, "title": "Sample Show", "tvdbId": 362472,
            "seasons": [{"seasonNumber": 0, "monitored": True}, {"seasonNumber": 1, "monitored": True}],
        }
        _MockSeerr.calls = []
        st, _, _ = self._http("DELETE", "/api/v1/request/8", {"X-Api-Key": "test-key"})
        self.assertEqual(st, 204)
        self.assertTrue(any(f.get("seasonNumber") == 0 for f in _MockSonarr.files))
        self.assertFalse(any("DELETE /api/v1/media/6/file" in c for c in _MockSeerr.calls))

        # All seasons covered -> title delete
        _MockSonarr.reset()
        _MockSeerr.calls = []
        _MockSeerr.request_payload = {
            "id": 9, "type": "tv", "is4k": False,
            "seasons": [{"seasonNumber": 1}, {"seasonNumber": 2}],
            "media": {"id": 6, "mediaType": "tv", "externalServiceId": 10, "tvdbId": 362472},
        }
        st, _, _ = self._http("DELETE", "/api/v1/request/9", {"X-Api-Key": "test-key"})
        self.assertEqual(st, 204)
        self.assertTrue(any("DELETE /api/v1/media/6/file" in c for c in _MockSeerr.calls))
        self.assertFalse(any(c.startswith("DELETE /api/v3/episodefile/") for c in _MockSonarr.calls))

    def test_tv_safety_gates_and_body_limit(self) -> None:
        # Missing Sonarr key -> 502
        self.cfg.sonarr_api_key = ""
        _MockSeerr.request_payload = {
            "id": 8, "type": "tv", "is4k": False,
            "seasons": [{"seasonNumber": 1}],
            "media": {"id": 6, "mediaType": "tv", "externalServiceId": 10},
        }
        st, hdrs, _ = self._http("DELETE", "/api/v1/request/8", {"X-Api-Key": "test-key"})
        self.assertEqual(st, 502)
        self.assertIn("sonarr_key_missing", hdrs.get("X-Assemblrr-Purge-Detail") or "")
        self.cfg.sonarr_api_key = "sonarr-test-key"

        # Empty TV seasons -> 502
        _MockSeerr.request_payload = {
            "id": 11, "type": "tv", "is4k": False, "seasons": [],
            "media": {"id": 6, "mediaType": "tv", "externalServiceId": 10},
        }
        st, _, _ = self._http("DELETE", "/api/v1/request/11", {"X-Api-Key": "test-key"})
        self.assertEqual(st, 502)

        # Episodefile 500 -> 502
        _MockSonarr.episodefile_status = 500
        _MockSeerr.request_payload = {
            "id": 8, "type": "tv", "is4k": False,
            "seasons": [{"seasonNumber": 1}],
            "media": {"id": 6, "mediaType": "tv", "externalServiceId": 10},
        }
        st, _, _ = self._http("DELETE", "/api/v1/request/8", {"X-Api-Key": "test-key"})
        self.assertEqual(st, 502)

        # is4k uses externalServiceId4k
        self.assertEqual(
            gw_mod.sonarr_lookup_series_id(
                self.cfg,
                {"is4k": True, "media": {"externalServiceId": 10, "externalServiceId4k": 42}},
                "sonarr-test-key",
            ),
            42,
        )

        # Oversized body -> 413
        st, _, _ = self._http("POST", "/echo", data=b"x" * 2048)
        self.assertEqual(st, 413)


if __name__ == "__main__":
    unittest.main(verbosity=2)
