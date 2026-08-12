#!/usr/bin/env python3
"""
seerr-gateway — reverse proxy for Seerr with delete-request full purge.

Stock Seerr DELETE /api/v1/request/:id only removes the request row. assemblrr
intercepts that call (when enabled), deletes linked media files via Seerr first
(DELETE /api/v1/media/:id/file → Radarr/Sonarr deleteFiles + purge hooks), then
forwards the original request delete.

Passthrough: all other methods/paths are proxied unchanged to SEERR_UPSTREAM.

Retirement (when Seerr natively purges media on request delete):
  - Set SEERR_DELETE_REQUEST_PURGE=0 for pass-through-only, or
  - Remove this service and publish seerr:5055 again.
  See docs/seerr-delete-request.md.
"""
from __future__ import annotations

import json
import logging
import os
import re
import socket
import sys
import threading
import time
import urllib.error
import urllib.request
from http.client import HTTPConnection, HTTPSConnection
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Dict, List, Optional, Tuple
from urllib.parse import urlparse

LISTEN_HOST = os.environ.get("SEERR_GATEWAY_LISTEN", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("SEERR_GATEWAY_PORT", "5055"))
UPSTREAM = os.environ.get("SEERR_UPSTREAM", "http://seerr:5055").rstrip("/")
# When "0"/"false"/"off": pure reverse proxy (no purge intercept).
PURGE_ON_DELETE_REQUEST = os.environ.get("SEERR_DELETE_REQUEST_PURGE", "1").strip().lower() not in (
    "0",
    "false",
    "no",
    "off",
)
CONNECT_TIMEOUT = float(os.environ.get("SEERR_GATEWAY_CONNECT_TIMEOUT", "10"))
READ_TIMEOUT = float(os.environ.get("SEERR_GATEWAY_READ_TIMEOUT", "120"))
LOG_LEVEL = os.environ.get("SEERR_GATEWAY_LOG_LEVEL", "INFO").upper()

REQUEST_DELETE_RE = re.compile(r"^/api/v1/request/(\d+)/?$")

HOP_BY_HOP = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
    "proxy-connection",
}

log = logging.getLogger("seerr-gateway")


def configure_logging() -> None:
    logging.basicConfig(
        level=getattr(logging, LOG_LEVEL, logging.INFO),
        format="seerr-gateway: %(levelname)s: %(message)s",
        stream=sys.stderr,
    )


def filter_request_headers(headers: List[Tuple[str, str]], client_addr: str) -> Dict[str, str]:
    out: Dict[str, str] = {}
    for key, value in headers:
        lk = key.lower()
        if lk in HOP_BY_HOP or lk == "host":
            continue
        out[key] = value
    # Prefer client-visible host for apps that build absolute URLs from X-Forwarded-*.
    if "X-Forwarded-For" not in out and "x-forwarded-for" not in {k.lower() for k in out}:
        out["X-Forwarded-For"] = client_addr
    if "X-Forwarded-Proto" not in out and "x-forwarded-proto" not in {k.lower() for k in out}:
        out["X-Forwarded-Proto"] = "http"
    return out


def filter_response_headers(headers: List[Tuple[str, str]]) -> List[Tuple[str, str]]:
    result: List[Tuple[str, str]] = []
    for key, value in headers:
        if key.lower() in HOP_BY_HOP:
            continue
        result.append((key, value))
    return result


def upstream_parts() -> Tuple[str, str, int, bool]:
    parsed = urlparse(UPSTREAM if "://" in UPSTREAM else f"http://{UPSTREAM}")
    scheme = parsed.scheme or "http"
    host = parsed.hostname or "seerr"
    port = parsed.port or (443 if scheme == "https" else 80)
    return scheme, host, port, scheme == "https"


def open_upstream(method: str, path: str, headers: Dict[str, str], body: Optional[bytes]):
    scheme, host, port, is_https = upstream_parts()
    conn_cls = HTTPSConnection if is_https else HTTPConnection
    conn = conn_cls(host, port, timeout=CONNECT_TIMEOUT)
    # Host must match upstream service name so Seerr/Node accepts the request.
    hdrs = dict(headers)
    hdrs["Host"] = f"{host}:{port}" if port not in (80, 443) else host
    if body is not None and "Content-Length" not in {k.title() for k in hdrs} and "content-length" not in {
        k.lower() for k in hdrs
    }:
        hdrs["Content-Length"] = str(len(body))
    conn.request(method, path, body=body, headers=hdrs)
    # Apply read timeout on the socket after connect.
    if conn.sock is not None:
        conn.sock.settimeout(READ_TIMEOUT)
    return conn, conn.getresponse()


def read_body(handler: BaseHTTPRequestHandler) -> bytes:
    length = handler.headers.get("Content-Length")
    if not length:
        return b""
    try:
        n = int(length)
    except ValueError:
        return b""
    if n <= 0:
        return b""
    return handler.rfile.read(n)


def json_response(handler: BaseHTTPRequestHandler, status: int, payload: dict) -> None:
    body = json.dumps(payload).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.send_header("Cache-Control", "no-store")
    handler.end_headers()
    if handler.command != "HEAD":
        handler.wfile.write(body)


def proxy_once(
    method: str,
    path: str,
    headers: Dict[str, str],
    body: Optional[bytes],
) -> Tuple[int, List[Tuple[str, str]], bytes]:
    conn = None
    try:
        conn, resp = open_upstream(method, path, headers, body)
        resp_body = resp.read()
        status = resp.status
        resp_headers = filter_response_headers(resp.getheaders())
        return status, resp_headers, resp_body
    finally:
        if conn is not None:
            try:
                conn.close()
            except Exception:
                pass


def parse_request_payload(data: bytes) -> dict:
    if not data:
        return {}
    try:
        return json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return {}


def media_ids_from_request(payload: dict) -> Tuple[Optional[int], bool]:
    """Return (mediaId, is4k) from a Seerr MediaRequest payload."""
    is4k = bool(payload.get("is4k", False))
    media = payload.get("media") or payload.get("mediaInfo") or {}
    if not isinstance(media, dict):
        return None, is4k
    mid = media.get("id")
    if mid is None:
        return None, is4k
    try:
        return int(mid), is4k
    except (TypeError, ValueError):
        return None, is4k


def purge_then_delete_request(
    request_id: str,
    path: str,
    headers: Dict[str, str],
) -> Tuple[int, List[Tuple[str, str]], bytes, str]:
    """
    Cascade:
      GET request → DELETE media/:id/file (if linked) → DELETE request
    Always attempts request delete so Seerr state stays consistent.
    Returns (status, headers, body, purge_note).
    """
    get_status, _, get_body = proxy_once("GET", f"/api/v1/request/{request_id}", headers, None)
    media_id = None
    is4k = False
    if get_status == 200:
        payload = parse_request_payload(get_body)
        media_id, is4k = media_ids_from_request(payload)
    elif get_status in (401, 403):
        # Auth failed — surface upstream response; do not delete.
        return get_status, [("Content-Type", "application/json")], get_body, "auth_failed"
    else:
        log.warning("GET /api/v1/request/%s → HTTP %s (continuing with request delete)", request_id, get_status)

    purge_note = "no_media"
    if media_id is not None:
        is4k_q = "true" if is4k else "false"
        file_path = f"/api/v1/media/{media_id}/file?is4k={is4k_q}"
        file_status, _, file_body = proxy_once("DELETE", file_path, headers, None)
        if 200 <= file_status < 300 or file_status == 404:
            purge_note = f"media_file_deleted:{media_id}:{file_status}"
            log.info(
                "request %s: DELETE media/%s/file is4k=%s → HTTP %s",
                request_id,
                media_id,
                is4k_q,
                file_status,
            )
        else:
            purge_note = f"media_file_failed:{media_id}:{file_status}"
            log.warning(
                "request %s: media file delete failed HTTP %s: %s",
                request_id,
                file_status,
                file_body[:200],
            )
    else:
        log.info("request %s: no linked media id; deleting request only", request_id)

    del_status, del_headers, del_body = proxy_once("DELETE", path, headers, None)
    extra = list(del_headers)
    extra.append(("X-Assemblrr-Request-Delete-Purge", "1"))
    extra.append(("X-Assemblrr-Purge-Detail", purge_note[:200]))
    return del_status, extra, del_body, purge_note


class GatewayHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "assemblrr-seerr-gateway/1.0"

    def log_message(self, fmt: str, *args) -> None:
        log.info("%s - %s", self.address_string(), fmt % args)

    def log_error(self, fmt: str, *args) -> None:
        log.error("%s - %s", self.address_string(), fmt % args)

    def _client_ip(self) -> str:
        return self.client_address[0] if self.client_address else "unknown"

    def _forwarded_headers(self) -> Dict[str, str]:
        return filter_request_headers(list(self.headers.items()), self._client_ip())

    def do_GET(self) -> None:  # noqa: N802
        self._dispatch()

    def do_HEAD(self) -> None:  # noqa: N802
        self._dispatch()

    def do_POST(self) -> None:  # noqa: N802
        self._dispatch()

    def do_PUT(self) -> None:  # noqa: N802
        self._dispatch()

    def do_PATCH(self) -> None:  # noqa: N802
        self._dispatch()

    def do_DELETE(self) -> None:  # noqa: N802
        self._dispatch()

    def do_OPTIONS(self) -> None:  # noqa: N802
        self._dispatch()

    def _dispatch(self) -> None:
        path = self.path  # includes query string
        path_only = path.split("?", 1)[0]

        if path_only in ("/_assemblrr/health", "/_assemblrr/ready"):
            self._handle_health(ready=(path_only.endswith("/ready")))
            return

        if (
            PURGE_ON_DELETE_REQUEST
            and self.command == "DELETE"
            and REQUEST_DELETE_RE.match(path_only)
        ):
            m = REQUEST_DELETE_RE.match(path_only)
            assert m is not None
            request_id = m.group(1)
            try:
                status, headers, body, note = purge_then_delete_request(
                    request_id, path_only, self._forwarded_headers()
                )
                log.info(
                    "DELETE request/%s cascade done status=%s detail=%s",
                    request_id,
                    status,
                    note,
                )
                self._write_response(status, headers, body)
            except Exception as exc:
                log.exception("cascade failed for request %s: %s", request_id, exc)
                json_response(
                    self,
                    502,
                    {"error": "seerr-gateway cascade failed", "detail": str(exc)},
                )
            return

        # Pure reverse proxy (including DELETE request when purge disabled).
        body = read_body(self) if self.command in ("POST", "PUT", "PATCH", "DELETE") else None
        if self.command == "DELETE" and not PURGE_ON_DELETE_REQUEST and REQUEST_DELETE_RE.match(path_only):
            log.info("DELETE request passthrough (SEERR_DELETE_REQUEST_PURGE disabled)")
        try:
            self._stream_proxy(self.command, path, self._forwarded_headers(), body)
        except Exception as exc:
            log.exception("proxy error %s %s: %s", self.command, path_only, exc)
            json_response(self, 502, {"error": "seerr-gateway proxy failed", "detail": str(exc)})

    def _handle_health(self, ready: bool) -> None:
        upstream_ok = None
        upstream_status = None
        if ready:
            try:
                status, _, _ = proxy_once("GET", "/api/v1/settings/public", {}, None)
                upstream_ok = 200 <= status < 300
                upstream_status = status
            except Exception as exc:
                upstream_ok = False
                upstream_status = str(exc)
            if not upstream_ok:
                json_response(
                    self,
                    503,
                    {
                        "ok": False,
                        "upstream": UPSTREAM,
                        "upstream_ok": False,
                        "upstream_status": upstream_status,
                        "purge_on_delete_request": PURGE_ON_DELETE_REQUEST,
                    },
                )
                return

        json_response(
            self,
            200,
            {
                "ok": True,
                "upstream": UPSTREAM,
                "upstream_ok": upstream_ok,
                "upstream_status": upstream_status,
                "purge_on_delete_request": PURGE_ON_DELETE_REQUEST,
            },
        )

    def _write_response(self, status: int, headers: List[Tuple[str, str]], body: bytes) -> None:
        self.send_response(status)
        # Avoid duplicate Content-Length from upstream when we re-send body.
        sent_len = False
        for key, value in headers:
            if key.lower() == "content-length":
                continue
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(body)))
        sent_len = True
        assert sent_len
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _stream_proxy(
        self,
        method: str,
        path: str,
        headers: Dict[str, str],
        body: Optional[bytes],
    ) -> None:
        conn = None
        try:
            conn, resp = open_upstream(method, path, headers, body)
            self.send_response(resp.status)
            for key, value in filter_response_headers(resp.getheaders()):
                if key.lower() == "content-length":
                    continue
                self.send_header(key, value)
            # Stream body; set Content-Length if known from upstream.
            cl = resp.getheader("Content-Length")
            data = resp.read()
            self.send_header("Content-Length", cl if cl is not None else str(len(data)))
            self.end_headers()
            if self.command != "HEAD" and data:
                self.wfile.write(data)
        finally:
            if conn is not None:
                try:
                    conn.close()
                except Exception:
                    pass


def run_server() -> None:
    configure_logging()
    server = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), GatewayHandler)
    server.daemon_threads = True
    log.info(
        "listening on %s:%s → %s (purge_on_delete_request=%s)",
        LISTEN_HOST,
        LISTEN_PORT,
        UPSTREAM,
        PURGE_ON_DELETE_REQUEST,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("shutting down")
    finally:
        server.server_close()


# ---------------------------------------------------------------------------
# Built-in self-test (no Docker): mock Seerr + gateway cascade assertions
# ---------------------------------------------------------------------------


class _MockSeerr(BaseHTTPRequestHandler):
    """Minimal Seerr stand-in for unit tests."""

    protocol_version = "HTTP/1.1"
    # Shared call log: list of "METHOD path"
    calls: List[str] = []
    request_payload: dict = {}
    file_delete_status: int = 204
    request_delete_status: int = 204
    require_api_key: Optional[str] = "test-key"

    def log_message(self, fmt: str, *args) -> None:  # quiet
        return

    def _auth_ok(self) -> bool:
        if not self.require_api_key:
            return True
        key = self.headers.get("X-Api-Key") or ""
        return key == self.require_api_key

    def _send(self, status: int, body: bytes = b"", content_type: str = "application/json") -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD" and body:
            self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0]
        _MockSeerr.calls.append(f"GET {path}")
        if path == "/api/v1/settings/public":
            self._send(200, b'{"initialized":true}')
            return
        if not self._auth_ok():
            self._send(401, b'{"error":"Unauthorized"}')
            return
        m = re.match(r"^/api/v1/request/(\d+)/?$", path)
        if m:
            self._send(200, json.dumps(_MockSeerr.request_payload).encode())
            return
        self._send(404, b'{"error":"not found"}')

    def do_DELETE(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0]
        _MockSeerr.calls.append(f"DELETE {self.path}")
        if not self._auth_ok():
            self._send(401, b'{"error":"Unauthorized"}')
            return
        if re.match(r"^/api/v1/media/\d+/file", path):
            self._send(_MockSeerr.file_delete_status, b"")
            return
        if re.match(r"^/api/v1/request/\d+", path):
            self._send(_MockSeerr.request_delete_status, b"")
            return
        self._send(404, b'{"error":"not found"}')


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def self_test() -> int:
    """Run cascade + passthrough checks against a mock upstream. Exit 0/1."""
    configure_logging()
    failures = 0

    def check(cond: bool, msg: str) -> None:
        nonlocal failures
        if cond:
            print(f"  PASS: {msg}")
        else:
            print(f"  FAIL: {msg}")
            failures += 1

    mock_port = _free_port()
    gw_port = _free_port()

    _MockSeerr.calls = []
    _MockSeerr.request_payload = {
        "id": 42,
        "is4k": False,
        "media": {"id": 7, "tmdbId": 10378, "mediaType": "movie"},
    }
    _MockSeerr.file_delete_status = 204
    _MockSeerr.request_delete_status = 204
    _MockSeerr.require_api_key = "test-key"

    mock_httpd = ThreadingHTTPServer(("127.0.0.1", mock_port), _MockSeerr)
    mock_httpd.daemon_threads = True
    threading.Thread(target=mock_httpd.serve_forever, daemon=True).start()

    os.environ["SEERR_UPSTREAM"] = f"http://127.0.0.1:{mock_port}"
    os.environ["SEERR_DELETE_REQUEST_PURGE"] = "1"
    # Re-bind module globals used by handlers
    global UPSTREAM, PURGE_ON_DELETE_REQUEST, LISTEN_HOST, LISTEN_PORT
    UPSTREAM = os.environ["SEERR_UPSTREAM"].rstrip("/")
    PURGE_ON_DELETE_REQUEST = True
    LISTEN_HOST = "127.0.0.1"
    LISTEN_PORT = gw_port

    gw = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), GatewayHandler)
    gw.daemon_threads = True
    threading.Thread(target=gw.serve_forever, daemon=True).start()
    time.sleep(0.15)

    def http_call(method: str, url: str, headers: Optional[dict] = None) -> Tuple[int, dict, bytes]:
        req = urllib.request.Request(url, method=method, headers=headers or {})
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                return resp.status, dict(resp.headers), resp.read()
        except urllib.error.HTTPError as e:
            return e.code, dict(e.headers), e.read()

    print("=== seerr-gateway self-test ===")

    # Health
    st, _, body = http_call("GET", f"http://127.0.0.1:{gw_port}/_assemblrr/health")
    check(st == 200, "health returns 200")
    check(b"purge_on_delete_request" in body, "health reports purge flag")

    st, _, _ = http_call("GET", f"http://127.0.0.1:{gw_port}/_assemblrr/ready")
    check(st == 200, "ready when upstream up")

    # Cascade
    _MockSeerr.calls = []
    st, hdrs, _ = http_call(
        "DELETE",
        f"http://127.0.0.1:{gw_port}/api/v1/request/42",
        {"X-Api-Key": "test-key"},
    )
    check(st == 204, f"cascade DELETE request → 204 (got {st})")
    check(hdrs.get("X-Assemblrr-Request-Delete-Purge") == "1", "purge header set")
    calls = list(_MockSeerr.calls)
    check(any(c.startswith("GET /api/v1/request/42") for c in calls), "GET request first")
    check(
        any("DELETE /api/v1/media/7/file" in c for c in calls),
        "DELETE media file before request delete",
    )
    check(any(c.startswith("DELETE /api/v1/request/42") for c in calls), "DELETE request last")
    # Order: GET, media file, request delete
    try:
        i_get = next(i for i, c in enumerate(calls) if c.startswith("GET /api/v1/request/42"))
        i_file = next(i for i, c in enumerate(calls) if "DELETE /api/v1/media/7/file" in c)
        i_del = next(i for i, c in enumerate(calls) if c.startswith("DELETE /api/v1/request/42"))
        check(i_get < i_file < i_del, f"call order GET < file < request ({calls})")
    except StopIteration:
        check(False, f"missing expected calls: {calls}")

    # Auth failure: do not delete
    _MockSeerr.calls = []
    st, _, _ = http_call(
        "DELETE",
        f"http://127.0.0.1:{gw_port}/api/v1/request/42",
        {"X-Api-Key": "wrong"},
    )
    check(st == 401, f"bad API key → 401 (got {st})")
    check(
        not any(c.startswith("DELETE") for c in _MockSeerr.calls),
        "no deletes on auth failure",
    )

    # Passthrough GET public
    _MockSeerr.calls = []
    st, _, _ = http_call("GET", f"http://127.0.0.1:{gw_port}/api/v1/settings/public")
    check(st == 200, "passthrough public settings")

    # Purge disabled → only request DELETE
    PURGE_ON_DELETE_REQUEST = False
    _MockSeerr.calls = []
    st, hdrs, _ = http_call(
        "DELETE",
        f"http://127.0.0.1:{gw_port}/api/v1/request/99",
        {"X-Api-Key": "test-key"},
    )
    check(st == 204, "purge-disabled still deletes request")
    check(
        not any("media" in c for c in _MockSeerr.calls),
        "purge-disabled skips media file delete",
    )
    check(
        any(c.startswith("DELETE /api/v1/request/99") for c in _MockSeerr.calls),
        "purge-disabled forwards request delete",
    )
    PURGE_ON_DELETE_REQUEST = True

    # No media id → still delete request
    _MockSeerr.request_payload = {"id": 5, "is4k": False, "media": {}}
    _MockSeerr.calls = []
    st, hdrs, _ = http_call(
        "DELETE",
        f"http://127.0.0.1:{gw_port}/api/v1/request/5",
        {"X-Api-Key": "test-key"},
    )
    check(st == 204, "no media id still deletes request")
    check(
        not any("media" in c and "file" in c for c in _MockSeerr.calls),
        "no media file delete when unlinked",
    )
    check(
        "no_media" in (hdrs.get("X-Assemblrr-Purge-Detail") or ""),
        "purge detail notes no_media",
    )

    gw.shutdown()
    mock_httpd.shutdown()

    print("")
    if failures:
        print(f"self-test: FAILED ({failures})")
        return 1
    print("self-test: OK")
    return 0


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] in ("--self-test", "self-test"):
        return self_test()
    if len(sys.argv) > 1 and sys.argv[1] in ("-h", "--help"):
        print(__doc__)
        print("Usage: seerr-gateway.py [--self-test]")
        print("Env: SEERR_UPSTREAM SEERR_DELETE_REQUEST_PURGE SEERR_GATEWAY_PORT ...")
        return 0
    run_server()
    return 0


if __name__ == "__main__":
    sys.exit(main())
