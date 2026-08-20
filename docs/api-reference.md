# assemblrr API & Developer Troubleshooting Guide

This guide documents the API authentication methods, service endpoints, and `curl` troubleshooting recipes used by assemblrr's automation and developers.

---

## Service Authentication Quick Reference

assemblrr services generate API keys during initial boot. Extract them using the paths below:

| Service | Port | Config / Secret Location | Auth Header / Query Parameter |
| :--- | :--- | :--- | :--- |
| **Radarr** | `7878` | `config/radarr/config.xml` | `?apikey=$KEY` or `X-Api-Key: $KEY` |
| **Sonarr** | `8989` | `config/sonarr/config.xml` | `?apikey=$KEY` or `X-Api-Key: $KEY` |
| **Prowlarr** | `9696` | `config/prowlarr/config.xml` | `?apikey=$KEY` or `X-Api-Key: $KEY` |
| **Bazarr** | `6767` | `secrets/bazarr_api_key.txt` | `?apikey=$KEY` or `X-API-KEY: $KEY` |
| **Seerr** | `5055` | `config/seerr/settings.json` | `X-Api-Key: $KEY` |
| **Jellyfin** | `8096` | `secrets/jellyfin_api_key.txt` | `X-Emby-Token: $KEY` or `Authorization: MediaBrowser Token="$KEY"` |
| **qBittorrent** | `8080` | `config/qbittorrent/` | Cookie-based auth via `/api/v2/auth/login` |

### Quick Key Extraction (Bash Snippet)
```bash
RADARR_KEY=$(sed -n 's/.*<ApiKey>\(.*\)<\/ApiKey>.*/\1/p' config/radarr/config.xml | head -1)
SONARR_KEY=$(sed -n 's/.*<ApiKey>\(.*\)<\/ApiKey>.*/\1/p' config/sonarr/config.xml | head -1)
PROWLARR_KEY=$(sed -n 's/.*<ApiKey>\(.*\)<\/ApiKey>.*/\1/p' config/prowlarr/config.xml | head -1)
BAZARR_KEY=$(cat secrets/bazarr_api_key.txt 2>/dev/null)
JELLYFIN_KEY=$(cat secrets/jellyfin_api_key.txt 2>/dev/null)
```

---

## Radarr & Sonarr (*arr API v3) Recipes

### 1. Quality Profiles
* **List all profiles:**
  ```bash
  curl -s "http://127.0.0.1:7878/api/v3/qualityprofile?apikey=$RADARR_KEY" | jq '.[] | {id: .id, name: .name}'
  ```
* **Inspect a specific profile:**
  ```bash
  curl -s "http://127.0.0.1:7878/api/v3/qualityprofile/1?apikey=$RADARR_KEY" | jq .
  ```
* **Delete an orphaned profile:**
  ```bash
  curl -s -X DELETE "http://127.0.0.1:7878/api/v3/qualityprofile/8?apikey=$RADARR_KEY"
  ```

### 2. Media Management & Hardlinks
* **Inspect Media Management config:**
  ```bash
  curl -s "http://127.0.0.1:7878/api/v3/config/mediamanagement?apikey=$RADARR_KEY" | jq '{copyUsingHardlinks, recycleBin, recycleBinCleanupDays}'
  ```
* **Disable recycle bin and verify hardlinks:**
  ```bash
  curl -s "http://127.0.0.1:7878/api/v3/config/mediamanagement?apikey=$RADARR_KEY" \
    | jq '.copyUsingHardlinks = true | .recycleBin = "" | .recycleBinCleanupDays = 0' \
    | curl -s -X PUT "http://127.0.0.1:7878/api/v3/config/mediamanagement?apikey=$RADARR_KEY" -H "Content-Type: application/json" -d @-
  ```

### 3. Root Folders
* **List root folders and default profile IDs:**
  ```bash
  curl -s "http://127.0.0.1:7878/api/v3/rootfolder?apikey=$RADARR_KEY" | jq .
  ```

### 4. Queue & Active Downloads
* **Inspect download queue:**
  ```bash
  curl -s "http://127.0.0.1:7878/api/v3/queue?apikey=$RADARR_KEY" | jq '.records[] | {id: .id, title: .title, status: .status, downloadId: .downloadId}'
  ```
* **Drain a specific queue item from *arr and download client:**
  ```bash
  curl -s -X DELETE "http://127.0.0.1:7878/api/v3/queue/123?apikey=$RADARR_KEY&removeFromClient=true&blocklist=false"
  ```

---

## Seerr & Seerr Gateway Recipes

`seerr-gateway` sits on port `5055` as a sidecar proxying Overseas/Jellyseerr.

* **List pending/approved requests:**
  ```bash
  curl -s "http://127.0.0.1:5055/api/v1/request?take=20" -H "X-Api-Key: $SEERR_KEY" | jq '.results[] | {id: .id, type: .type, media: .media.tmdbId, status: .status}'
  ```
* **Test request-delete cascade:**
  ```bash
  curl -i -X DELETE "http://127.0.0.1:5055/api/v1/request/42" -H "X-Api-Key: $SEERR_KEY"
  ```
  *(Responses will include `X-Assemblrr-Purge-Detail` headers indicating queue drains and media deletions.)*

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
  docker exec recyclarr recyclarr list custom-formats radarr
  ```

---

## Official API Documentation Links

| Service | Official Documentation | Notes |
| :--- | :--- | :--- |
| **Radarr** | https://radarr.video/docs/api/ | OpenAPI / Swagger UI |
| **Sonarr** | https://sonarr.tv/docs/api/ | v3 OpenAPI spec (covers Sonarr v3 and v4) |
| **Prowlarr** | https://prowlarr.com/docs/api/ | OpenAPI / Swagger UI |
| **Bazarr** | https://wiki.bazarr.media/ | Companion subtitle manager API |
| **Seerr** | https://api-docs.overseerr.dev/ | Jellyseerr / Overseerr Swagger UI |
| **Jellyfin** | https://api.jellyfin.org/ | OpenAPI stable spec |
| **qBittorrent** | https://github.com/qbittorrent/qBittorrent/wiki/WebUI-API-(qBittorrent-4.1) | Web API Reference |
| **Servarr Wiki** | https://wiki.servarr.com/ | Servarr community configuration & troubleshooting |


