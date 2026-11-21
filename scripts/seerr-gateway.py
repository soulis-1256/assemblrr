#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""
seerr-gateway — reverse proxy for Seerr with delete-request full purge.

Stock Seerr DELETE /api/v1/request/:id only removes the request row. assemblrr
intercepts that call (when enabled) after verifying caller authorization via
GET /api/v1/auth/me:

  * Movies (and TV requests that cover every remaining season): drain the
    *arr download queue (removeFromClient) for this title first, then DELETE
    /api/v1/media/:id/file -> Radarr/Sonarr deleteFiles + purge hooks.
  * TV requests for a subset of seasons: drain only those seasons' queue
    items, then delete those seasons' episode files via Sonarr and unmonitor
    them. Other seasons stay. The title-level Seerr file-delete is skipped
    so Sonarr does not wipe the series folder.

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
import urllib.error
import urllib.request
from dataclasses import dataclass
from http.client import HTTPConnection, HTTPSConnection
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Dict, List, Optional, Tuple
from urllib.parse import urlparse

REQUEST_DELETE_RE = re.compile(r"^/api/v1/request/(\d+)/?$")

# Seerr permission bitmask constants (upstream Seerr Permission enum)
PERM_ADMIN = 2
PERM_MANAGE_REQUESTS = 4
PERM_PURGE_CAPABLE = PERM_ADMIN | PERM_MANAGE_REQUESTS

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


@dataclass
class GatewayConfig:
    listen_host: str = "0.0.0.0"
    listen_port: int = 5055
    upstream: str = "http://seerr:5055"
    purge_on_delete_request: bool = True
    connect_timeout: float = 10.0
    read_timeout: float = 120.0
    max_body_bytes: int = 16 * 1024 * 1024
    log_level: str = "INFO"
    sonarr_url: str = "http://sonarr:8989"
    sonarr_api_key: str = ""
    sonarr_config: str = "/config/sonarr/config.xml"
    radarr_url: str = "http://radarr:7878"
    radarr_api_key: str = ""
    radarr_config: str = "/config/radarr/config.xml"

    @classmethod
    def from_env(cls) -> "GatewayConfig":
        purge_raw = os.environ.get("SEERR_DELETE_REQUEST_PURGE", "1").strip().lower()
        return cls(
            listen_host=os.environ.get("SEERR_GATEWAY_LISTEN", "0.0.0.0"),
            listen_port=int(os.environ.get("SEERR_GATEWAY_PORT", "5055")),
            upstream=os.environ.get("SEERR_UPSTREAM", "http://seerr:5055").rstrip("/"),
            purge_on_delete_request=purge_raw not in ("0", "false", "no", "off"),
            connect_timeout=float(os.environ.get("SEERR_GATEWAY_CONNECT_TIMEOUT", "10")),
            read_timeout=float(os.environ.get("SEERR_GATEWAY_READ_TIMEOUT", "120")),
            max_body_bytes=int(os.environ.get("SEERR_GATEWAY_MAX_BODY_BYTES", str(16 * 1024 * 1024))),
            log_level=os.environ.get("SEERR_GATEWAY_LOG_LEVEL", "INFO").upper(),
            sonarr_url=os.environ.get("SONARR_URL", "http://sonarr:8989").rstrip("/"),
            sonarr_api_key=os.environ.get("SONARR_API_KEY", "").strip(),
            sonarr_config=os.environ.get("SONARR_CONFIG", "/config/sonarr/config.xml"),
            radarr_url=os.environ.get("RADARR_URL", "http://radarr:7878").rstrip("/"),
            radarr_api_key=os.environ.get("RADARR_API_KEY", "").strip(),
            radarr_config=os.environ.get("RADARR_CONFIG", "/config/radarr/config.xml"),
        )


def configure_logging(level: str = "INFO") -> None:
    logging.basicConfig(
        level=getattr(logging, level.upper(), logging.INFO),
        format="seerr-gateway: %(levelname)s: %(message)s",
        stream=sys.stderr,
    )


def _header(headers: List[Tuple[str, str]], name: str) -> str:
    want = name.lower()
    for key, value in headers:
        if key.lower() == want:
            return value
    return ""


def rewrite_location(
    cfg: GatewayConfig,
    value: str,
    client_host: str,
    client_proto: str = "http",
) -> str:
    if not client_host or not value:
        return value
    _, host, port, _ = upstream_parts(cfg)
    netlocs = [f"{host}:{port}" if port not in (80, 443) else host, "seerr:5055", "seerr"]
    proto = client_proto if client_proto in ("http", "https") else "http"
    out = value
    for netloc in netlocs:
        out = out.replace(f"http://{netloc}", f"{proto}://{client_host}")
        out = out.replace(f"https://{netloc}", f"{proto}://{client_host}")
    return out


def filter_request_headers(
    headers: List[Tuple[str, str]],
    client_addr: str,
    incoming_is_https: bool = False,
) -> List[Tuple[str, str]]:
    out: List[Tuple[str, str]] = []
    incoming_host = ""
    cookie_parts: List[str] = []
    for key, value in headers:
        lk = key.lower()
        if lk in HOP_BY_HOP or lk == "content-length":
            continue
        if lk == "host":
            incoming_host = value
            continue
        if lk == "cookie":
            cookie_parts.append(value)
            continue
        out.append((key, value))
    if cookie_parts:
        out.append(("Cookie", "; ".join(cookie_parts)))
    if incoming_host and not _header(out, "X-Forwarded-Host"):
        out.append(("X-Forwarded-Host", incoming_host))
    if not _header(out, "X-Forwarded-For"):
        out.append(("X-Forwarded-For", client_addr))
    if not _header(out, "X-Forwarded-Proto"):
        out.append(("X-Forwarded-Proto", "https" if incoming_is_https else "http"))
    return out


def filter_response_headers(
    cfg: GatewayConfig,
    headers: List[Tuple[str, str]],
    client_host: str = "",
    client_proto: str = "http",
) -> List[Tuple[str, str]]:
    result: List[Tuple[str, str]] = []
    for key, value in headers:
        if key.lower() in HOP_BY_HOP:
            continue
        if key.lower() == "location":
            value = rewrite_location(cfg, value, client_host, client_proto)
        result.append((key, value))
    return result


def upstream_parts(cfg: GatewayConfig) -> Tuple[str, str, int, bool]:
    up = cfg.upstream.rstrip("/")
    parsed = urlparse(up if "://" in up else f"http://{up}")
    scheme = parsed.scheme or "http"
    host = parsed.hostname or "seerr"
    port = parsed.port or (443 if scheme == "https" else 80)
    return scheme, host, port, scheme == "https"


def open_upstream(
    cfg: GatewayConfig,
    method: str,
    path: str,
    headers: List[Tuple[str, str]],
    body: Optional[bytes],
):
    _, host, port, is_https = upstream_parts(cfg)
    conn_cls = HTTPSConnection if is_https else HTTPConnection
    conn = conn_cls(host, port, timeout=cfg.connect_timeout)

    client_host = _header(headers, "X-Forwarded-Host")
    upstream_host = client_host or (f"{host}:{port}" if port not in (80, 443) else host)

    conn.putrequest(method, path, skip_host=True, skip_accept_encoding=True)
    conn.putheader("Host", upstream_host)
    for key, value in headers:
        conn.putheader(key, value)
    if body is not None:
        conn.putheader("Content-Length", str(len(body)))
    conn.endheaders(message_body=body)
    if conn.sock is not None:
        conn.sock.settimeout(cfg.read_timeout)
    return conn, conn.getresponse()


class PayloadTooLargeError(Exception):
    pass


def read_body(handler: BaseHTTPRequestHandler, max_bytes: int) -> bytes:
    te = (handler.headers.get("Transfer-Encoding") or "").lower()
    if "chunked" in te:
        buf = bytearray()
        while True:
            line = handler.rfile.readline(65536)
            if not line:
                break
            size_hex = line.split(b";", 1)[0].strip()
            try:
                chunk_len = int(size_hex, 16)
            except ValueError:
                break
            if chunk_len == 0:
                while True:
                    trailer = handler.rfile.readline(65536)
                    if not trailer or trailer in (b"\r\n", b"\n"):
                        break
                break
            if len(buf) + chunk_len > max_bytes:
                raise PayloadTooLargeError("chunked request body exceeds limit")
            buf.extend(handler.rfile.read(chunk_len))
            handler.rfile.readline(4)
        return bytes(buf)

    length = handler.headers.get("Content-Length")
    if not length:
        return b""
    try:
        n = int(length)
    except ValueError:
        return b""
    if n <= 0:
        return b""
    if n > max_bytes:
        raise PayloadTooLargeError(f"Content-Length {n} exceeds {max_bytes}")
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
    cfg: GatewayConfig,
    method: str,
    path: str,
    headers: List[Tuple[str, str]],
    body: Optional[bytes],
) -> Tuple[int, List[Tuple[str, str]], bytes]:
    conn = None
    try:
        conn, resp = open_upstream(cfg, method, path, headers, body)
        resp_body = resp.read()
        status = resp.status
        resp_headers = filter_response_headers(
            cfg,
            resp.getheaders(),
            _header(headers, "X-Forwarded-Host"),
            _header(headers, "X-Forwarded-Proto") or "http",
        )
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
        parsed = json.loads(data.decode("utf-8"))
        return parsed if isinstance(parsed, dict) else {}
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
    seen = set()
    uniq: List[int] = []
    for n in out:
        if n not in seen:
            seen.add(n)
            uniq.append(n)
    return uniq


def discover_arr_api_key(explicit: str, config_path: str) -> str:
    if explicit:
        return explicit
    if not config_path or not os.path.isfile(config_path):
        return ""
    try:
        with open(config_path, encoding="utf-8") as fh:
            text = fh.read()
    except OSError:
        return ""
    m = re.search(r"<ApiKey>([^<]+)</ApiKey>", text)
    return m.group(1).strip() if m else ""


def _arr_request(
    base_url: str,
    method: str,
    path: str,
    api_key: str,
    body: Optional[dict] = None,
    timeout: float = 20,
    label: str = "arr",
) -> Tuple[int, object]:
    url = f"{base_url.rstrip('/')}{path}"
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
        try:
            raw = e.read()
        finally:
            e.close()
        parsed = None
        if raw:
            try:
                parsed = json.loads(raw.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                parsed = raw
        return e.code, parsed
    except (urllib.error.URLError, TimeoutError, socket.timeout, OSError) as e:
        raise RuntimeError(f"{label} {method} {path}: {e}") from e


def request_media(payload: dict) -> dict:
    media = payload.get("media") or payload.get("mediaInfo") or {}
    return media if isinstance(media, dict) else {}


def arr_external_id(payload: dict, is4k: bool) -> Optional[int]:
    media = request_media(payload)
    raw = media.get("externalServiceId4k") if is4k else media.get("externalServiceId")
    if raw is None:
        return None
    try:
        return int(raw)
    except (TypeError, ValueError):
        return None


def radarr_lookup_movie_id(cfg: GatewayConfig, payload: dict, api_key: str) -> Optional[int]:
    ext = arr_external_id(payload, bool(payload.get("is4k", False)))
    if ext is not None:
        return ext
    tmdb = request_media(payload).get("tmdbId")
    if tmdb is None:
        return None
    try:
        tmdb_i = int(tmdb)
    except (TypeError, ValueError):
        return None
    status, movies = _arr_request(cfg.radarr_url, "GET", "/api/v3/movie", api_key, label="radarr")
    if status != 200 or not isinstance(movies, list):
        return None
    for row in movies:
        if isinstance(row, dict) and row.get("tmdbId") == tmdb_i:
            try:
                return int(row["id"])
            except (TypeError, ValueError, KeyError):
                return None
    return None


def sonarr_lookup_series_id(cfg: GatewayConfig, payload: dict, api_key: str) -> Optional[int]:
    ext = arr_external_id(payload, bool(payload.get("is4k", False)))
    if ext is not None:
        return ext
    tvdb = request_media(payload).get("tvdbId")
    if tvdb is None:
        return None
    try:
        tvdb_i = int(tvdb)
    except (TypeError, ValueError):
        return None
    status, series = _arr_request(cfg.sonarr_url, "GET", "/api/v3/series", api_key, label="sonarr")
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


def queue_records(cfg: GatewayConfig, kind: str, arr_id: int, api_key: str) -> List[dict]:
    if kind == "movie":
        status, data = _arr_request(
            cfg.radarr_url, "GET", f"/api/v3/queue?pageSize=250&movieId={arr_id}", api_key, label="radarr"
        )
    else:
        status, data = _arr_request(
            cfg.sonarr_url, "GET", f"/api/v3/queue?pageSize=250&seriesId={arr_id}", api_key, label="sonarr"
        )
    if status != 200:
        raise RuntimeError(f"{kind} queue GET HTTP {status}")
    if isinstance(data, list):
        rows = data
    elif isinstance(data, dict):
        rows = data.get("records") or []
    else:
        rows = []
    return [r for r in rows if isinstance(r, dict)]


def queue_record_season(row: dict) -> Optional[int]:
    if row.get("seasonNumber") is not None:
        try:
            return int(row["seasonNumber"])
        except (TypeError, ValueError):
            pass
    ep = row.get("episode")
    if isinstance(ep, dict) and ep.get("seasonNumber") is not None:
        try:
            return int(ep["seasonNumber"])
        except (TypeError, ValueError):
            return None
    return None


def drain_arr_queue(
    cfg: GatewayConfig,
    kind: str,
    arr_id: int,
    api_key: str,
    seasons: Optional[List[int]] = None,
) -> Tuple[int, int]:
    """Remove *arr queue items and matching download-client items."""
    rows = queue_records(cfg, kind, arr_id, api_key)
    wanted = set(seasons) if seasons else None
    deleted = 0
    considered = 0
    base_url = cfg.radarr_url if kind == "movie" else cfg.sonarr_url
    label = "radarr" if kind == "movie" else "sonarr"

    for row in rows:
        if kind == "movie":
            mid = row.get("movieId")
            if mid is not None:
                try:
                    if int(mid) != int(arr_id):
                        continue
                except (TypeError, ValueError):
                    continue
        elif kind == "series":
            sid = row.get("seriesId")
            if sid is not None:
                try:
                    if int(sid) != int(arr_id):
                        continue
                except (TypeError, ValueError):
                    continue
            if wanted is not None:
                sn = queue_record_season(row)
                if sn is None or sn not in wanted:
                    continue
        qid = row.get("id")
        if qid is None:
            continue
        considered += 1
        status, _ = _arr_request(
            base_url,
            "DELETE",
            f"/api/v3/queue/{qid}?removeFromClient=true&blocklist=false&skipRedownload=true",
            api_key,
            label=label,
        )
        if status in (200, 204):
            deleted += 1
        else:
            log.warning("%s queue delete id=%s HTTP %s", kind, qid, status)
    return considered, deleted


def _drain_queue_note(
    cfg: GatewayConfig,
    kind: str,
    arr_id: int,
    api_key: str,
    seasons: Optional[List[int]],
    request_id: str,
) -> str:
    try:
        considered, deleted = drain_arr_queue(cfg, kind, arr_id, api_key, seasons)
    except Exception as exc:
        log.warning("request %s: %s queue drain failed: %s", request_id, kind, exc)
        return f"queue_{kind}_failed"
    log.info(
        "request %s: %s queue drain id=%s considered=%s deleted=%s",
        request_id,
        kind,
        arr_id,
        considered,
        deleted,
    )
    return f"queue_{kind}:{considered}:{deleted}"


def _drain_movie_queue_note(cfg: GatewayConfig, payload: dict, request_id: str) -> str:
    api_key = discover_arr_api_key(cfg.radarr_api_key, cfg.radarr_config)
    if not api_key:
        log.info("request %s: no Radarr API key; skip queue drain", request_id)
        return "queue_movie_skipped"
    try:
        movie_id = radarr_lookup_movie_id(cfg, payload, api_key)
    except Exception as exc:
        log.warning("request %s: radarr movie lookup failed: %s", request_id, exc)
        return "queue_movie_failed"
    if movie_id is None:
        log.info("request %s: movie not in Radarr; skip queue drain", request_id)
        return "queue_movie_missing"
    return _drain_queue_note(cfg, "movie", movie_id, api_key, None, request_id)


def sonarr_remaining_seasons(cfg: GatewayConfig, series_id: int, api_key: str) -> List[int]:
    """Seasons that still have files or are monitored (includes specials / 0)."""
    status, series = _arr_request(cfg.sonarr_url, "GET", f"/api/v3/series/{series_id}", api_key, label="sonarr")
    if status == 404:
        return []
    if status != 200 or not isinstance(series, dict):
        raise RuntimeError(f"sonarr GET series/{series_id} HTTP {status}")
    status_f, files = _arr_request(
        cfg.sonarr_url, "GET", f"/api/v3/episodefile?seriesId={series_id}", api_key, label="sonarr"
    )
    if status_f != 200 or not isinstance(files, list):
        raise RuntimeError(f"sonarr GET episodefile HTTP {status_f}")
    remain: set = set()
    for f in files:
        if not isinstance(f, dict) or f.get("seasonNumber") is None:
            continue
        try:
            remain.add(int(f["seasonNumber"]))
        except (TypeError, ValueError):
            continue
    for s in series.get("seasons") or []:
        if not isinstance(s, dict):
            continue
        try:
            n = int(s.get("seasonNumber"))
        except (TypeError, ValueError):
            continue
        if s.get("monitored"):
            remain.add(n)
    return sorted(remain)


def sonarr_delete_seasons(
    cfg: GatewayConfig, series_id: int, seasons: List[int], api_key: str
) -> int:
    """Delete episode files and unmonitor the given seasons. Returns file-delete count."""
    if not seasons:
        return 0
    wanted = set(seasons)
    status, files = _arr_request(
        cfg.sonarr_url, "GET", f"/api/v3/episodefile?seriesId={series_id}", api_key, label="sonarr"
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
        dstatus, _ = _arr_request(cfg.sonarr_url, "DELETE", f"/api/v3/episodefile/{fid}", api_key, label="sonarr")
        if dstatus in (200, 204):
            deleted += 1
        elif dstatus == 404:
            continue
        else:
            raise RuntimeError(f"sonarr DELETE episodefile/{fid} HTTP {dstatus}")

    status, series = _arr_request(cfg.sonarr_url, "GET", f"/api/v3/series/{series_id}", api_key, label="sonarr")
    if status == 200 and isinstance(series, dict):
        changed = False
        for s in series.get("seasons") or []:
            if isinstance(s, dict) and s.get("seasonNumber") in wanted and s.get("monitored"):
                s["monitored"] = False
                changed = True
        if changed:
            pstatus, _ = _arr_request(
                cfg.sonarr_url, "PUT", f"/api/v3/series/{series_id}", api_key, series, label="sonarr"
            )
            if pstatus not in (200, 202):
                raise RuntimeError(f"sonarr PUT series/{series_id} unmonitor HTTP {pstatus}")
    elif status not in (200, 404):
        raise RuntimeError(f"sonarr GET series/{series_id} HTTP {status}")

    status, episodes = _arr_request(
        cfg.sonarr_url, "GET", f"/api/v3/episode?seriesId={series_id}", api_key, label="sonarr"
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
            pstatus, _ = _arr_request(
                cfg.sonarr_url,
                "PUT",
                "/api/v3/episode/monitor",
                api_key,
                {"episodeIds": ids, "monitored": False},
                label="sonarr",
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
    cfg: GatewayConfig,
    media_id: int,
    is4k: bool,
    headers: List[Tuple[str, str]],
) -> Tuple[str, int]:
    is4k_q = "true" if is4k else "false"
    file_path = f"/api/v1/media/{media_id}/file?is4k={is4k_q}"
    file_status, _, file_body = proxy_once(cfg, "DELETE", file_path, headers, None)
    if 200 <= file_status < 300 or file_status == 404:
        note = f"media_file_deleted:{media_id}:{file_status}"
        log.info("DELETE media/%s/file is4k=%s -> HTTP %s", media_id, is4k_q, file_status)
        return note, file_status
    log.warning("media file delete failed HTTP %s: %s", file_status, file_body[:200])
    return f"media_file_failed:{media_id}:{file_status}", file_status


def _purge_fail(status: int, detail: str, note: str) -> Tuple[int, List[Tuple[str, str]], bytes, str]:
    return (
        status,
        [
            ("Content-Type", "application/json"),
            ("X-Assemblrr-Request-Delete-Purge", "1"),
            ("X-Assemblrr-Purge-Detail", note[:200]),
        ],
        json.dumps({"error": "seerr-gateway request delete failed", "detail": detail}).encode("utf-8"),
        note,
    )


def _caller_identity(
    cfg: GatewayConfig, headers: List[Tuple[str, str]]
) -> Tuple[int, Optional[dict], bytes]:
    """Resolve authenticated caller from Seerr /api/v1/auth/me using caller headers."""
    status, _, body = proxy_once(cfg, "GET", "/api/v1/auth/me", headers, None)
    if status != 200:
        return status, None, body
    return status, parse_request_payload(body), body


def _is_own_pending_request(user: dict, payload: dict) -> bool:
    try:
        uid = int(user.get("id"))
        req_by = payload.get("requestedBy") or {}
        owner_id = int(req_by.get("id")) if isinstance(req_by, dict) else -1
        req_status = int(payload.get("status") or 0)
    except (TypeError, ValueError):
        return False
    # In Seerr, status == 1 is PENDING_APPROVAL.
    return uid == owner_id and req_status == 1


def purge_then_delete_request(
    cfg: GatewayConfig,
    request_id: str,
    path: str,
    headers: List[Tuple[str, str]],
) -> Tuple[int, List[Tuple[str, str]], bytes, str]:
    """
    Authorized cascade before deleting a Seerr request:
      1) GET /api/v1/auth/me -> fail closed if unauthenticated or upstream fails.
      2) GET /api/v1/request/:id -> fail closed on non-200/404.
      3) Verify ADMIN or MANAGE_REQUESTS permission before touching *arr/media files.
         Non-admin cancelling their own pending request passes straight through to
         DELETE without touching *arr; non-admin attempts on others or approved items
         return 403 immediately.
      4) Drain *arr queue + delete media file / TV season episode files.
      5) Forward DELETE /api/v1/request/:id.
    """
    me_status, me, me_body = _caller_identity(cfg, headers)
    if me_status in (401, 403):
        return me_status, [("Content-Type", "application/json")], me_body, "auth_failed"
    if me_status != 200 or not me:
        return _purge_fail(502, f"auth/me HTTP {me_status}", "auth_check_failed")

    get_status, _, get_body = proxy_once(cfg, "GET", f"/api/v1/request/{request_id}", headers, None)
    if get_status in (401, 403):
        return get_status, [("Content-Type", "application/json")], get_body, "auth_failed"
    if get_status == 404:
        del_status, del_headers, del_body = proxy_once(cfg, "DELETE", path, headers, None)
        extra = list(del_headers) + [
            ("X-Assemblrr-Request-Delete-Purge", "1"),
            ("X-Assemblrr-Purge-Detail", "request_not_found"),
        ]
        return del_status, extra, del_body, "request_not_found"
    if get_status != 200:
        return _purge_fail(502, f"GET request/{request_id} HTTP {get_status}", "request_lookup_failed")

    payload = parse_request_payload(get_body)
    try:
        perms = int(me.get("permissions") or 0)
    except (TypeError, ValueError):
        perms = 0

    if (perms & PERM_PURGE_CAPABLE) == 0:
        if _is_own_pending_request(me, payload):
            del_status, del_headers, del_body = proxy_once(cfg, "DELETE", path, headers, None)
            extra = list(del_headers) + [
                ("X-Assemblrr-Request-Delete-Purge", "0"),
                ("X-Assemblrr-Purge-Detail", "passthrough_own_pending"),
            ]
            return del_status, extra, del_body, "passthrough_own_pending"
        log.warning(
            "Forbidden DELETE request/%s by non-manager user id=%s perms=%s",
            request_id,
            me.get("id"),
            perms,
        )
        return (
            403,
            [
                ("Content-Type", "application/json"),
                ("X-Assemblrr-Request-Delete-Purge", "0"),
                ("X-Assemblrr-Purge-Detail", "forbidden_non_admin"),
            ],
            json.dumps({"error": "Forbidden", "message": "Requires ADMIN or MANAGE_REQUESTS permission"}).encode("utf-8"),
            "forbidden_non_admin",
        )

    media_id, is4k = media_ids_from_request(payload)
    purge_note = "no_media"
    if media_id is not None:
        if request_is_tv(payload):
            requested = seasons_from_request(payload)
            if not requested:
                log.warning("request %s: TV request has no season list; refusing title delete", request_id)
                return _purge_fail(502, "tv request has no seasons", "tv_seasons_unknown")
            api_key = discover_arr_api_key(cfg.sonarr_api_key, cfg.sonarr_config)
            if not api_key:
                log.warning("request %s: no Sonarr API key; refusing title delete", request_id)
                return _purge_fail(502, "sonarr api key missing", "sonarr_key_missing")
            try:
                series_id = sonarr_lookup_series_id(cfg, payload, api_key)
                if series_id is None:
                    log.info("request %s: series not in Sonarr; request-delete only", request_id)
                    purge_note = "sonarr_series_missing"
                else:
                    remaining = sonarr_remaining_seasons(cfg, series_id, api_key)
                    if remaining and not seasons_cover_remaining(requested, remaining):
                        qnote = _drain_queue_note(cfg, "series", series_id, api_key, requested, request_id)
                        deleted = sonarr_delete_seasons(cfg, series_id, requested, api_key)
                        purge_note = (
                            f"{qnote};seasons_deleted:{media_id}:{series_id}:"
                            f"{','.join(str(s) for s in requested)}:{deleted}"
                        )
                    else:
                        log.info("request %s: seasons %s cover remaining %s; title delete", request_id, requested, remaining)
                        qnote = _drain_queue_note(cfg, "series", series_id, api_key, None, request_id)
                        pnote, _ = _delete_media_file(cfg, media_id, is4k, headers)
                        purge_note = f"{qnote};{pnote}"
            except Exception as exc:
                log.error("request %s: season purge failed: %s", request_id, exc)
                return _purge_fail(502, str(exc), "season_purge_failed")
        else:
            qnote = _drain_movie_queue_note(cfg, payload, request_id)
            pnote, _ = _delete_media_file(cfg, media_id, is4k, headers)
            purge_note = f"{qnote};{pnote}" if qnote else pnote
    else:
        log.info("request %s: no linked media id; deleting request only", request_id)

    del_status, del_headers, del_body = proxy_once(cfg, "DELETE", path, headers, None)
    extra = list(del_headers)
    extra.append(("X-Assemblrr-Request-Delete-Purge", "1"))
    extra.append(("X-Assemblrr-Purge-Detail", purge_note[:200]))
    return del_status, extra, del_body, purge_note


class GatewayHTTPServer(ThreadingHTTPServer):
    def __init__(self, server_address: Tuple[str, int], handler_cls, config: GatewayConfig):
        self.gateway_config = config
        super().__init__(server_address, handler_cls)


class GatewayHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "assemblrr-seerr-gateway/1.1"

    def _cfg(self) -> GatewayConfig:
        return getattr(self.server, "gateway_config", None) or GatewayConfig.from_env()

    def log_message(self, fmt: str, *args) -> None:
        log.info("%s - %s", self.address_string(), fmt % args)

    def log_error(self, fmt: str, *args) -> None:
        log.error("%s - %s", self.address_string(), fmt % args)

    def _client_ip(self) -> str:
        return self.client_address[0] if self.client_address else "unknown"

    def _forwarded_headers(self) -> List[Tuple[str, str]]:
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
        cfg = self._cfg()
        path = self.path
        path_only = path.split("?", 1)[0]

        if path_only in ("/_assemblrr/health", "/_assemblrr/ready"):
            self._handle_health(cfg, ready=(path_only.endswith("/ready")))
            return

        if (
            cfg.purge_on_delete_request
            and self.command == "DELETE"
            and REQUEST_DELETE_RE.match(path_only)
        ):
            m = REQUEST_DELETE_RE.match(path_only)
            assert m is not None
            request_id = m.group(1)
            try:
                status, headers, body, note = purge_then_delete_request(
                    cfg, request_id, path_only, self._forwarded_headers()
                )
                log.info("DELETE request/%s cascade done status=%s detail=%s", request_id, status, note)
                self._write_response(status, headers, body)
            except Exception as exc:
                log.exception("cascade failed for request %s: %s", request_id, exc)
                json_response(self, 502, {"error": "seerr-gateway cascade failed", "detail": str(exc)})
            return

        try:
            body = (
                read_body(self, cfg.max_body_bytes)
                if self.command in ("POST", "PUT", "PATCH", "DELETE")
                else None
            )
        except PayloadTooLargeError as exc:
            json_response(self, 413, {"error": "payload too large", "detail": str(exc)})
            return

        if self.command == "DELETE" and not cfg.purge_on_delete_request and REQUEST_DELETE_RE.match(path_only):
            log.info("DELETE request passthrough (SEERR_DELETE_REQUEST_PURGE disabled)")
        try:
            self._stream_proxy(cfg, self.command, path, self._forwarded_headers(), body)
        except Exception as exc:
            log.exception("proxy error %s %s: %s", self.command, path_only, exc)
            json_response(self, 502, {"error": "seerr-gateway proxy failed", "detail": str(exc)})

    def _handle_health(self, cfg: GatewayConfig, ready: bool) -> None:
        upstream_ok = None
        upstream_status = None
        if ready:
            try:
                status, _, _ = proxy_once(cfg, "GET", "/api/v1/settings/public", [], None)
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
                        "upstream": cfg.upstream,
                        "upstream_ok": False,
                        "upstream_status": upstream_status,
                        "purge_on_delete_request": cfg.purge_on_delete_request,
                    },
                )
                return

        json_response(
            self,
            200,
            {
                "ok": True,
                "upstream": cfg.upstream,
                "upstream_ok": upstream_ok,
                "upstream_status": upstream_status,
                "purge_on_delete_request": cfg.purge_on_delete_request,
            },
        )

    def _write_response(self, status: int, headers: List[Tuple[str, str]], body: bytes) -> None:
        self.send_response(status)
        for key, value in headers:
            if key.lower() == "content-length":
                continue
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _stream_proxy(
        self,
        cfg: GatewayConfig,
        method: str,
        path: str,
        headers: List[Tuple[str, str]],
        body: Optional[bytes],
    ) -> None:
        conn = None
        try:
            conn, resp = open_upstream(cfg, method, path, headers, body)
            self.send_response(resp.status)
            for key, value in filter_response_headers(
                cfg,
                resp.getheaders(),
                _header(headers, "X-Forwarded-Host"),
                _header(headers, "X-Forwarded-Proto") or "http",
            ):
                if key.lower() == "content-length":
                    continue
                self.send_header(key, value)
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


def run_server(cfg: Optional[GatewayConfig] = None) -> None:
    config = cfg or GatewayConfig.from_env()
    configure_logging(config.log_level)
    server = GatewayHTTPServer((config.listen_host, config.listen_port), GatewayHandler, config)
    server.daemon_threads = True
    log.info(
        "listening on %s:%s -> %s (purge_on_delete_request=%s)",
        config.listen_host,
        config.listen_port,
        config.upstream,
        config.purge_on_delete_request,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("shutting down")
    finally:
        server.server_close()


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] in ("-h", "--help"):
        print(__doc__)
        print("Usage: seerr-gateway.py")
        print("Env: SEERR_UPSTREAM SEERR_DELETE_REQUEST_PURGE SEERR_GATEWAY_PORT ...")
        return 0
    run_server()
    return 0


if __name__ == "__main__":
    sys.exit(main())
