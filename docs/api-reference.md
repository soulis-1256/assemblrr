# assemblrr API & Developer Troubleshooting Guide

This guide documents the API authentication methods, service endpoints, and `curl` troubleshooting recipes used by assemblrr's automation and developers.

---

## Service Authentication Quick Reference

assemblrr services generate API keys during initial boot. Extract them using the paths below:

| Service | Port | Config / Secret Location | Auth Header / Query Parameter |
| :--- | :--- | :--- | :--- |
| **Radarr** | `7878` | `config/radarr/config.xml` | `X-Api-Key: $KEY` |
| **Sonarr** | `8989` | `config/sonarr/config.xml` | `X-Api-Key: $KEY` |
| **Prowlarr** | `9696` | `config/prowlarr/config.xml` | `X-Api-Key: $KEY` |
| **Bazarr** | `6767` | `secrets/bazarr_api_key.txt` | `X-API-KEY: $KEY` |
| **Seerr** | `5055` | `config/seerr/settings.json` | `X-Api-Key: $KEY` |
| **Jellyfin** | `8096` | `secrets/jellyfin_api_key.txt` | `Authorization: MediaBrowser Client="cli", Device="cli", DeviceId="cli", Version="1.0", Token="$KEY"` |
| **qBittorrent** | `8081` | `secrets/auth_*.txt` | Cookie-based auth (`SID` / `QBT_SID_*`) via `/api/v2/auth/login` |
| **SABnzbd** *(opt.)* | `8085` | `config/sabnzbd/sabnzbd.ini` | `?apikey=$KEY` (`mode=...&output=json`) |
| **Byparr** *(opt.)* | `8191` (internal) | — | Unauthenticated HTTP challenge proxy inside `assemblrr_network` |

> [!NOTE]
> Jellyfin 12.4 removed legacy `X-Emby-Token` defaults in favor of standard `Authorization: MediaBrowser ... Token="..."` headers. assemblrr uses `Authorization: MediaBrowser` across all scripts and setup modules.

### Quick Key Extraction (Bash Snippet)
```bash
RADARR_KEY=$(sed -n 's/.*<ApiKey>\(.*\)<\/ApiKey>.*/\1/p' config/radarr/config.xml | head -1)
SONARR_KEY=$(sed -n 's/.*<ApiKey>\(.*\)<\/ApiKey>.*/\1/p' config/sonarr/config.xml | head -1)
PROWLARR_KEY=$(sed -n 's/.*<ApiKey>\(.*\)<\/ApiKey>.*/\1/p' config/prowlarr/config.xml | head -1)
SABNZBD_KEY=$(sed -n 's/^[[:space:]]*api_key[[:space:]]*=[[:space:]]*//p' config/sabnzbd/sabnzbd.ini | head -1)
BAZARR_KEY=$(cat secrets/bazarr_api_key.txt 2>/dev/null)
JELLYFIN_KEY=$(cat secrets/jellyfin_api_key.txt 2>/dev/null)
```

---

## Radarr & Sonarr (*arr API v3) Recipes

### 1. Quality Profiles
* **List all profiles:**
  ```bash
  curl -s -H "X-Api-Key: $RADARR_KEY" "http://127.0.0.1:7878/api/v3/qualityprofile" | jq '.[] | {id: .id, name: .name}'
  ```
* **Inspect a specific profile:**
  ```bash
  curl -s -H "X-Api-Key: $RADARR_KEY" "http://127.0.0.1:7878/api/v3/qualityprofile/1" | jq .
  ```

### 2. Media Management & Hardlinks
* **Inspect Media Management config:**
  ```bash
  curl -s -H "X-Api-Key: $RADARR_KEY" "http://127.0.0.1:7878/api/v3/config/mediamanagement" | jq '{copyUsingHardlinks, recycleBin, recycleBinCleanupDays}'
  ```

### 3. Queue & Active Downloads
* **Inspect download queue:**
  ```bash
  curl -s -H "X-Api-Key: $RADARR_KEY" "http://127.0.0.1:7878/api/v3/queue" | jq '.records[] | {id: .id, title: .title, status: .status, downloadId: .downloadId}'
  ```
* **Drain a specific queue item from *arr and download client:**
  ```bash
  curl -s -X DELETE -H "X-Api-Key: $RADARR_KEY" "http://127.0.0.1:7878/api/v3/queue/123?removeFromClient=true&blocklist=false"
  ```

---

## Seerr & Seerr Gateway Recipes

`seerr-gateway` sits on port `5055` and verifies caller permissions via `GET /api/v1/auth/me` before intercepting `DELETE /api/v1/request/:id`.

* **Check gateway health & upstream readiness:**
  ```bash
  curl -s http://127.0.0.1:5055/_assemblrr/ready | jq .
  ```
* **List pending/approved requests:**
  ```bash
  curl -s "http://127.0.0.1:5055/api/v1/request?take=20" -H "X-Api-Key: $SEERR_KEY" | jq '.results[] | {id: .id, type: .type, media: .media.tmdbId, status: .status}'
  ```

---

## Optional Overlays: SABnzbd & Byparr

* **Check SABnzbd version and queue (when `USENET_ENABLED=y`):**
  ```bash
  curl -s "http://127.0.0.1:8085/api?mode=queue&output=json&apikey=$SABNZBD_KEY" | jq .
  ```
* **Check Byparr health (inside container network when `BYPARR_ENABLED=y`):**
  ```bash
  docker exec byparr python3 -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8191/health').read().decode())"
  ```
* **Inspect Prowlarr indexer proxies (`byparr` tag):**
  ```bash
  curl -s -H "X-Api-Key: $PROWLARR_KEY" "http://127.0.0.1:9696/api/v1/indexerProxy" | jq .
  ```

---

## Recyclarr Maintenance Recipes

* **Trigger Recyclarr sync manually:**
  ```bash
  docker exec recyclarr recyclarr sync
  ```
* **List TRaSH guide IDs available for Radarr/Sonarr:**
  ```bash
  docker exec recyclarr recyclarr list quality-profiles radarr
  docker exec recyclarr recyclarr list quality-profiles sonarr
  ```

---

## Official API Documentation Links

| Service | Official Documentation |
| :--- | :--- |
| **Radarr** | https://radarr.video/docs/api/ |
| **Sonarr** | https://sonarr.tv/docs/api/ |
| **Prowlarr** | https://prowlarr.com/docs/api/ |
| **Bazarr** | https://wiki.bazarr.media/ |
| **Seerr** | https://api-docs.overseerr.dev/ |
| **Jellyfin** | https://api.jellyfin.org/ |
| **qBittorrent** | https://github.com/qbittorrent/qBittorrent/wiki/WebUI-API-(qBittorrent-4.1) |
| **SABnzbd** | https://sabnzbd.org/wiki/configuration/4.3/api |
