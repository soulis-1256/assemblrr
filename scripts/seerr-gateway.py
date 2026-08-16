#!/usr/bin/env python3
"""
seerr-gateway — reverse proxy for Seerr with delete-request full purge.

Stock Seerr DELETE /api/v1/request/:id only removes the request row. assemblrr
intercepts that call (when enabled):

  * Movies (and TV requests that cover every remaining season): DELETE
    /api/v1/media/:id/file → Radarr/Sonarr deleteFiles + purge hooks.
  * TV requests for a subset of seasons: delete only those seasons' episode
    files via Sonarr and unmonitor them. Other seasons stay. The title-level
    Seerr file-delete is skipped so Sonarr does not wipe the series folder.

Then the original request delete is forwarded.

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
SONARR_URL = os.environ.get("SONARR_URL", "http://sonarr:8989").rstrip("/")
SONARR_API_KEY = os.environ.get("SONARR_API_KEY", "").strip()
SONARR_CONFIG = os.environ.get("SONARR_CONFIG", "/config/sonarr/config.xml")

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


def _header(headers: Dict[str, str], name: str) -> str:
    want = name.lower()
    for key, value in headers.items():
        if key.lower() == want:
            return value
    return ""


def rewrite_location(value: str, client_host: str) -> str:
    if not client_host or not value:
        return value
    _, host, port, _ = upstream_parts()
    netlocs = [f"{host}:{port}" if port not in (80, 443) else host, "seerr:5055", "seerr"]
    out = value
    for netloc in netlocs:
        out = out.replace(f"http://{netloc}", f"http://{client_host}")
        out = out.replace(f"https://{netloc}", f"http://{client_host}")
    return out


def filter_request_headers(headers: List[Tuple[str, str]], client_addr: str) -> Dict[str, str]:
    out: Dict[str, str] = {}
    incoming_host = ""
    for key, value in headers:
        lk = key.lower()
        if lk in HOP_BY_HOP:
            continue
        if lk == "host":
            incoming_host = value
            continue
        out[key] = value
    # Browser Host so Seerr CSRF / redirects match what the user typed.
    if incoming_host and not _header(out, "X-Forwarded-Host"):
        out["X-Forwarded-Host"] = incoming_host
    if not _header(out, "X-Forwarded-For"):
        out["X-Forwarded-For"] = client_addr
    if not _header(out, "X-Forwarded-Proto"):
        out["X-Forwarded-Proto"] = "http"
    return out


def filter_response_headers(
    headers: List[Tuple[str, str]],
    client_host: str = "",
) -> List[Tuple[str, str]]:
    result: List[Tuple[str, str]] = []
    for key, value in headers:
        if key.lower() in HOP_BY_HOP:
            continue
        if key.lower() == "location":
            value = rewrite_location(value, client_host)
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
    hdrs = dict(headers)
    # Pass the browser Host through (Seerr's own reverse-proxy docs). Fall back
    # to the upstream name only when the client did not send one.
    client_host = _header(hdrs, "X-Forwarded-Host")
    if client_host:
        hdrs["Host"] = client_host
    else:
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
        resp_headers = filter_response_headers(resp.getheaders(), _header(headers, "X-Forwarded-Host"))
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


def request_is_tv(payload: dict) -> bool:
    rtype = (payload.get("type") or payload.get("mediaType") or "").lower()
    if rtype == "tv":
        return True
    media = payload.get("media") or payload.get("mediaInfo") or {}
    if isinstance(media, dict):
        return (media.get("mediaType") or "").lower() == "tv"
    return False


def seasons_from_request(payload: dict) -> List[int]:
    """Season numbers listed on this Seerr request (including specials if present)."""
    out: List[int] = []
    for row in payload.get("seasons") or []:
        if not isinstance(row, dict):
            continue
        try:
            n = int(row.get("seasonNumber"))
        except (TypeError, ValueError):
            continue
        out.append(n)
    # Unique, stable order
    seen = set()
    uniq: List[int] = []
    for n in out:
        if n not in seen:
            seen.add(n)
            uniq.append(n)
    return uniq


def discover_sonarr_api_key() -> str:
    if SONARR_API_KEY:
        return SONARR_API_KEY
    path = SONARR_CONFIG
    if not path or not os.path.isfile(path):
        return ""
    try:
        text = open(path, encoding="utf-8").read()
    except OSError:
        return ""
    m = re.search(r"<ApiKey>([^<]+)</ApiKey>", text)
    return m.group(1).strip() if m else ""


def _sonarr_request(
    method: str,
    path: str,
    api_key: str,
    body: Optional[dict] = None,
    timeout: float = 20,
) -> Tuple[int, object]:
    url = f"{SONARR_URL}{path}"
    data = None if body is None else json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("X-Api-Key", api_key)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
            parsed: object = None
            if raw:
                try:
                    parsed = json.loads(raw.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError):
                    parsed = raw
            return resp.status, parsed
    except urllib.error.HTTPError as e:
        raw = e.read()
        parsed = None
        if raw:
            try:
                parsed = json.loads(raw.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                parsed = raw
        return e.code, parsed
    except (urllib.error.URLError, TimeoutError, socket.timeout, OSError) as e:
        raise RuntimeError(f"sonarr {method} {path}: {e}") from e


def sonarr_lookup_series_id(payload: dict, api_key: str) -> Optional[int]:
    media = payload.get("media") or payload.get("mediaInfo") or {}
    if not isinstance(media, dict):
        media = {}
    ext = media.get("externalServiceId")
    if ext is not None:
        try:
            return int(ext)
        except (TypeError, ValueError):
            pass
    tvdb = media.get("tvdbId")
    if tvdb is None:
        return None
    try:
        tvdb_i = int(tvdb)
    except (TypeError, ValueError):
        return None
    status, series = _sonarr_request("GET", "/api/v3/series", api_key)
    if status != 200 or not isinstance(series, list):
        return None
    for row in series:
        if isinstance(row, dict) and row.get("tvdbId") == tvdb_i:
            sid = row.get("id")
            try:
                return int(sid)
            except (TypeError, ValueError):
                return None
    return None


def sonarr_remaining_seasons(series_id: int, api_key: str) -> List[int]:
    """Seasons that still have files or are monitored (skip specials)."""
    status, series = _sonarr_request("GET", f"/api/v3/series/{series_id}", api_key)
    if status == 404:
        return []
    if status != 200 or not isinstance(series, dict):
        raise RuntimeError(f"sonarr GET series/{series_id} HTTP {status}")
    status_f, files = _sonarr_request(
        "GET", f"/api/v3/episodefile?seriesId={series_id}", api_key
    )
    if status_f != 200 or not isinstance(files, list):
        raise RuntimeError(f"sonarr GET episodefile HTTP {status_f}")
    remain: set = set()
    for f in files:
        if isinstance(f, dict) and f.get("seasonNumber") not in (None, 0):
            remain.add(int(f["seasonNumber"]))
    for s in series.get("seasons") or []:
        if not isinstance(s, dict):
            continue
        try:
            n = int(s.get("seasonNumber"))
        except (TypeError, ValueError):
            continue
        if n == 0:
            continue
        if s.get("monitored"):
            remain.add(n)
    return sorted(remain)


def sonarr_delete_seasons(series_id: int, seasons: List[int], api_key: str) -> int:
    """Delete episode files and unmonitor the given seasons. Returns file-delete count."""
    if not seasons:
        return 0
    wanted = set(seasons)
    status, files = _sonarr_request(
        "GET", f"/api/v3/episodefile?seriesId={series_id}", api_key
    )
    if status != 200 or not isinstance(files, list):
        raise RuntimeError(f"sonarr GET episodefile HTTP {status}")
    deleted = 0
    for f in files:
        if not isinstance(f, dict):
            continue
        try:
            sn = int(f.get("seasonNumber"))
            fid = int(f.get("id"))
        except (TypeError, ValueError):
            continue
        if sn not in wanted:
            continue
        dstatus, _ = _sonarr_request("DELETE", f"/api/v3/episodefile/{fid}", api_key)
        if dstatus in (200, 204):
            deleted += 1
        elif dstatus == 404:
            continue
        else:
            raise RuntimeError(f"sonarr DELETE episodefile/{fid} HTTP {dstatus}")

    status, series = _sonarr_request("GET", f"/api/v3/series/{series_id}", api_key)
    if status == 200 and isinstance(series, dict):
        changed = False
        for s in series.get("seasons") or []:
            if isinstance(s, dict) and s.get("seasonNumber") in wanted and s.get("monitored"):
                s["monitored"] = False
                changed = True
        if changed:
            pstatus, _ = _sonarr_request("PUT", f"/api/v3/series/{series_id}", api_key, series)
            if pstatus not in (200, 202):
                raise RuntimeError(f"sonarr PUT series/{series_id} unmonitor HTTP {pstatus}")
    elif status not in (200, 404):
        raise RuntimeError(f"sonarr GET series/{series_id} HTTP {status}")

    status, episodes = _sonarr_request(
        "GET", f"/api/v3/episode?seriesId={series_id}", api_key
    )
    if status == 200 and isinstance(episodes, list):
        ids = []
        for ep in episodes:
            if not isinstance(ep, dict):
                continue
            try:
                if int(ep.get("seasonNumber")) in wanted:
                    ids.append(int(ep["id"]))
            except (TypeError, ValueError, KeyError):
                continue
        if ids:
            pstatus, _ = _sonarr_request(
                "PUT",
                "/api/v3/episode/monitor",
                api_key,
                {"episodeIds": ids, "monitored": False},
            )
            if pstatus not in (200, 202):
                raise RuntimeError(f"sonarr PUT episode/monitor HTTP {pstatus}")
    elif status not in (200, 404):
        raise RuntimeError(f"sonarr GET episode HTTP {status}")
    return deleted


def seasons_cover_remaining(requested: List[int], remaining: List[int]) -> bool:
    if not remaining:
        return True
    want = set(requested)
    return all(n in want for n in remaining)


def _delete_media_file(
    media_id: int,
    is4k: bool,
    headers: Dict[str, str],
) -> Tuple[str, int]:
    is4k_q = "true" if is4k else "false"
    file_path = f"/api/v1/media/{media_id}/file?is4k={is4k_q}"
    file_status, _, file_body = proxy_once("DELETE", file_path, headers, None)
    if 200 <= file_status < 300 or file_status == 404:
        note = f"media_file_deleted:{media_id}:{file_status}"
        log.info(
            "DELETE media/%s/file is4k=%s → HTTP %s",
            media_id,
            is4k_q,
            file_status,
        )
        return note, file_status
    log.warning(
        "media file delete failed HTTP %s: %s",
        file_status,
        file_body[:200],
    )
    return f"media_file_failed:{media_id}:{file_status}", file_status


def _season_purge_fail(detail: str, note: str) -> Tuple[int, List[Tuple[str, str]], bytes, str]:
    return (
        502,
        [
            ("Content-Type", "application/json"),
            ("X-Assemblrr-Request-Delete-Purge", "1"),
            ("X-Assemblrr-Purge-Detail", note[:200]),
        ],
        json.dumps({"error": "seerr-gateway season purge failed", "detail": detail}).encode(),
        note,
    )


def purge_then_delete_request(
    request_id: str,
    path: str,
    headers: Dict[str, str],
) -> Tuple[int, List[Tuple[str, str]], bytes, str]:
    """
    Cascade:
      GET request
        movie / TV covering every remaining season → DELETE media/:id/file
        TV subset of seasons → Sonarr season file delete only
      DELETE request
    Auth failure on GET, or any TV-scope / Sonarr uncertainty, returns without
    deleting the request (no title-level wipe).
    Returns (status, headers, body, purge_note).
    """
    get_status, _, get_body = proxy_once("GET", f"/api/v1/request/{request_id}", headers, None)
    media_id = None
    is4k = False
    payload: dict = {}
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
        if request_is_tv(payload):
            requested = seasons_from_request(payload)
            if not requested:
                log.warning("request %s: TV request has no season list; refusing title delete", request_id)
                return _season_purge_fail("tv request has no seasons", "tv_seasons_unknown")
            api_key = discover_sonarr_api_key()
            if not api_key:
                log.warning("request %s: no Sonarr API key; refusing title delete", request_id)
                return _season_purge_fail("sonarr api key missing", "sonarr_key_missing")
            try:
                series_id = sonarr_lookup_series_id(payload, api_key)
                if series_id is None:
                    # Not in Sonarr — drop the request only (under-delete).
                    log.info("request %s: series not in Sonarr; request-delete only", request_id)
                    purge_note = "sonarr_series_missing"
                else:
                    remaining = sonarr_remaining_seasons(series_id, api_key)
                    if remaining and not seasons_cover_remaining(requested, remaining):
                        deleted = sonarr_delete_seasons(series_id, requested, api_key)
                        purge_note = (
                            f"seasons_deleted:{media_id}:{series_id}:"
                            f"{','.join(str(s) for s in requested)}:{deleted}"
                        )
                        log.info(
                            "request %s: season-scoped purge seasons=%s remaining_after_intent=%s files=%s",
                            request_id,
                            requested,
                            [n for n in remaining if n not in set(requested)],
                            deleted,
                        )
                    else:
                        log.info(
                            "request %s: seasons %s cover remaining %s; title delete",
                            request_id,
                            requested,
                            remaining,
                        )
                        purge_note, _ = _delete_media_file(media_id, is4k, headers)
            except Exception as exc:
                log.error("request %s: season purge failed: %s", request_id, exc)
                return _season_purge_fail(str(exc), "season_purge_failed")
        else:
            purge_note, _ = _delete_media_file(media_id, is4k, headers)
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
            for key, value in filter_response_headers(
                resp.getheaders(), _header(headers, "X-Forwarded-Host")
            ):
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
    last_request_headers: Dict[str, str] = {}

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


class _MockSonarr(BaseHTTPRequestHandler):
    """Sonarr stand-in: series 10 has S01+S02 files unless deleted."""

    protocol_version = "HTTP/1.1"
    calls: List[str] = []
    files: List[dict] = []
    series: dict = {}
    episodefile_status: int = 200
    delete_episodefile_status: int = 200

    def log_message(self, fmt: str, *args) -> None:
        return

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
            self._send(200, json.dumps(_MockSonarr.series).encode())
            return
        if path == "/api/v3/series":
            self._send(200, json.dumps([_MockSonarr.series]).encode())
            return
        if path == "/api/v3/episodefile":
            if _MockSonarr.episodefile_status != 200:
                self._send(_MockSonarr.episodefile_status, b'{"error":"episodefile failed"}')
                return
            self._send(200, json.dumps(_MockSonarr.files).encode())
            return
        if path == "/api/v3/episode":
            eps = [
                {"id": 100 + f["id"], "seasonNumber": f["seasonNumber"], "seriesId": 10}
                for f in _MockSonarr.files
            ]
            self._send(200, json.dumps(eps).encode())
            return
        self._send(404, b"{}")

    def do_DELETE(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0]
        _MockSonarr.calls.append(f"DELETE {path}")
        m = re.match(r"^/api/v3/episodefile/(\d+)$", path)
        if m:
            if _MockSonarr.delete_episodefile_status != 200:
                self._send(_MockSonarr.delete_episodefile_status, b'{"error":"delete failed"}')
                return
            fid = int(m.group(1))
            _MockSonarr.files = [f for f in _MockSonarr.files if f.get("id") != fid]
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


def _reset_mock_sonarr() -> None:
    _MockSonarr.calls = []
    _MockSonarr.episodefile_status = 200
    _MockSonarr.delete_episodefile_status = 200
    _MockSonarr.files = [
        {"id": 1, "seasonNumber": 1, "seriesId": 10},
        {"id": 2, "seasonNumber": 2, "seriesId": 10},
    ]
    _MockSonarr.series = {
        "id": 10,
        "title": "Loki",
        "tvdbId": 362472,
        "seasons": [
            {"seasonNumber": 1, "monitored": True},
            {"seasonNumber": 2, "monitored": True},
        ],
    }


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
    sonarr_port = _free_port()
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

    _reset_mock_sonarr()
    sonarr_httpd = ThreadingHTTPServer(("127.0.0.1", sonarr_port), _MockSonarr)
    sonarr_httpd.daemon_threads = True
    threading.Thread(target=sonarr_httpd.serve_forever, daemon=True).start()

    os.environ["SEERR_UPSTREAM"] = f"http://127.0.0.1:{mock_port}"
    os.environ["SEERR_DELETE_REQUEST_PURGE"] = "1"
    # Re-bind module globals used by handlers
    global UPSTREAM, PURGE_ON_DELETE_REQUEST, LISTEN_HOST, LISTEN_PORT, SONARR_URL, SONARR_API_KEY, SONARR_CONFIG
    UPSTREAM = os.environ["SEERR_UPSTREAM"].rstrip("/")
    PURGE_ON_DELETE_REQUEST = True
    LISTEN_HOST = "127.0.0.1"
    LISTEN_PORT = gw_port
    SONARR_URL = f"http://127.0.0.1:{sonarr_port}"
    SONARR_API_KEY = "sonarr-test-key"

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

    # Browser Host is forwarded; Location pointing at seerr:5055 is rewritten.
    _MockSeerr.last_request_headers = {}
    conn = HTTPConnection("127.0.0.1", gw_port, timeout=5)
    conn.request("GET", "/api/v1/settings/public", headers={"Host": "localhost:5055"})
    resp = conn.getresponse()
    resp.read()
    conn.close()
    got_host = _MockSeerr.last_request_headers.get("Host") or _MockSeerr.last_request_headers.get("host")
    got_xfh = (
        _MockSeerr.last_request_headers.get("X-Forwarded-Host")
        or _MockSeerr.last_request_headers.get("x-forwarded-host")
    )
    check(got_host == "localhost:5055", f"upstream Host is the browser host (got {got_host})")
    check(got_xfh == "localhost:5055", f"X-Forwarded-Host is the browser host (got {got_xfh})")

    conn = HTTPConnection("127.0.0.1", gw_port, timeout=5)
    conn.request("GET", "/redir", headers={"Host": "localhost:5055"})
    resp = conn.getresponse()
    loc = resp.getheader("Location") or ""
    resp.read()
    conn.close()
    check(resp.status == 302, f"redir passthrough → 302 (got {resp.status})")
    check(loc == "http://localhost:5055/login", f"Location rewritten off seerr:5055 (got {loc})")

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

    # TV S01-only request: do not wipe S02 (no Seerr title-level file delete).
    _reset_mock_sonarr()
    _MockSeerr.request_payload = {
        "id": 8,
        "type": "tv",
        "is4k": False,
        "seasons": [{"seasonNumber": 1, "status": 2}],
        "media": {
            "id": 6,
            "tmdbId": 84958,
            "tvdbId": 362472,
            "mediaType": "tv",
            "externalServiceId": 10,
        },
    }
    _MockSeerr.calls = []
    st, hdrs, _ = http_call(
        "DELETE",
        f"http://127.0.0.1:{gw_port}/api/v1/request/8",
        {"X-Api-Key": "test-key"},
    )
    check(st == 204, f"TV S01 request delete → 204 (got {st})")
    check(
        not any("DELETE /api/v1/media/6/file" in c for c in _MockSeerr.calls),
        "TV S01 request does not title-delete media files",
    )
    check(
        any(c.startswith("DELETE /api/v1/request/8") for c in _MockSeerr.calls),
        "TV S01 still deletes the request row",
    )
    check(
        any(c == "DELETE /api/v3/episodefile/1" for c in _MockSonarr.calls),
        "TV S01 deletes Sonarr S01 episode file",
    )
    check(
        not any(c == "DELETE /api/v3/episodefile/2" for c in _MockSonarr.calls),
        "TV S01 does not delete Sonarr S02 episode file",
    )
    check(
        "seasons_deleted" in (hdrs.get("X-Assemblrr-Purge-Detail") or ""),
        f"purge detail is season-scoped ({hdrs.get('X-Assemblrr-Purge-Detail')})",
    )
    check(
        all(f.get("seasonNumber") != 1 for f in _MockSonarr.files),
        "S01 file removed from mock Sonarr",
    )
    check(
        any(f.get("seasonNumber") == 2 for f in _MockSonarr.files),
        "S02 file still in mock Sonarr",
    )

    # TV request covering every remaining season → title-level delete.
    _reset_mock_sonarr()
    _MockSeerr.request_payload = {
        "id": 9,
        "type": "tv",
        "is4k": False,
        "seasons": [{"seasonNumber": 1}, {"seasonNumber": 2}],
        "media": {
            "id": 6,
            "mediaType": "tv",
            "externalServiceId": 10,
            "tvdbId": 362472,
        },
    }
    _MockSeerr.calls = []
    _MockSonarr.calls = []
    st, hdrs, _ = http_call(
        "DELETE",
        f"http://127.0.0.1:{gw_port}/api/v1/request/9",
        {"X-Api-Key": "test-key"},
    )
    check(st == 204, f"TV all-seasons request → 204 (got {st})")
    check(
        any("DELETE /api/v1/media/6/file" in c for c in _MockSeerr.calls),
        "TV all-seasons uses title-level media file delete",
    )
    check(
        not any(c.startswith("DELETE /api/v3/episodefile/") for c in _MockSonarr.calls),
        "TV all-seasons does not piecemeal-delete episode files",
    )

    tv_s01 = {
        "id": 8,
        "type": "tv",
        "is4k": False,
        "seasons": [{"seasonNumber": 1, "status": 2}],
        "media": {
            "id": 6,
            "tmdbId": 84958,
            "tvdbId": 362472,
            "mediaType": "tv",
            "externalServiceId": 10,
        },
    }

    # Missing Sonarr key → 502, no title wipe, request kept.
    saved_key = SONARR_API_KEY
    saved_cfg = SONARR_CONFIG
    SONARR_API_KEY = ""
    SONARR_CONFIG = "/tmp/assemblrr-no-such-sonarr-config.xml"
    _reset_mock_sonarr()
    _MockSeerr.request_payload = dict(tv_s01)
    _MockSeerr.calls = []
    st, hdrs, _ = http_call(
        "DELETE",
        f"http://127.0.0.1:{gw_port}/api/v1/request/8",
        {"X-Api-Key": "test-key"},
    )
    check(st == 502, f"missing Sonarr key → 502 (got {st})")
    check(
        not any("DELETE /api/v1/media/6/file" in c for c in _MockSeerr.calls),
        "missing key does not title-delete",
    )
    check(
        not any(c.startswith("DELETE /api/v1/request/") for c in _MockSeerr.calls),
        "missing key keeps the request",
    )
    check(
        "sonarr_key_missing" in (hdrs.get("X-Assemblrr-Purge-Detail") or ""),
        "missing key purge detail",
    )
    SONARR_API_KEY = saved_key
    SONARR_CONFIG = saved_cfg

    # TV request with empty seasons → 502 (unknown scope).
    _reset_mock_sonarr()
    _MockSeerr.request_payload = {
        "id": 11,
        "type": "tv",
        "is4k": False,
        "seasons": [],
        "media": {"id": 6, "mediaType": "tv", "externalServiceId": 10, "tvdbId": 362472},
    }
    _MockSeerr.calls = []
    st, hdrs, _ = http_call(
        "DELETE",
        f"http://127.0.0.1:{gw_port}/api/v1/request/11",
        {"X-Api-Key": "test-key"},
    )
    check(st == 502, f"empty TV seasons → 502 (got {st})")
    check(
        not any("DELETE /api/v1/media/" in c for c in _MockSeerr.calls),
        "empty seasons does not title-delete",
    )
    check(
        not any(c.startswith("DELETE /api/v1/request/") for c in _MockSeerr.calls),
        "empty seasons keeps the request",
    )

    # Failed episodefile GET → 502, no title wipe.
    _reset_mock_sonarr()
    _MockSonarr.episodefile_status = 500
    _MockSeerr.request_payload = dict(tv_s01)
    _MockSeerr.calls = []
    st, _, _ = http_call(
        "DELETE",
        f"http://127.0.0.1:{gw_port}/api/v1/request/8",
        {"X-Api-Key": "test-key"},
    )
    check(st == 502, f"episodefile 500 → 502 (got {st})")
    check(
        not any("DELETE /api/v1/media/6/file" in c for c in _MockSeerr.calls),
        "episodefile 500 does not title-delete",
    )
    check(
        not any(c.startswith("DELETE /api/v1/request/") for c in _MockSeerr.calls),
        "episodefile 500 keeps the request",
    )
    _MockSonarr.episodefile_status = 200

    gw.shutdown()
    mock_httpd.shutdown()
    sonarr_httpd.shutdown()

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
