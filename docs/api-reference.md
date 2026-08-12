# assemblrr API Reference

This document aggregates the official API documentation for all services used by assemblrr.

## Media Services

| Service | API Documentation | Notes |
|---------|-------------------|-------|
| **Jellyfin** | https://api.jellyfin.org/openapi/jellyfin-openapi-stable.json | Raw OpenAPI JSON; alternative Mintlify: https://mintlify.com/jellyfin/jellyfin |
| **Emby** | https://app.swaggerhub.com/apis-docs/MediaBrowser/Emby.Api | Outdated spec; Emby and Jellyfin share origins but their APIs diverged — not interchangeable |
| **Plex** | https://www.plexopedia.com/plex-media-server/api | Unofficial but comprehensive; official docs require login |

## *arr Stack (Servarr Family)

| Service | API Documentation | Notes |
|---------|-------------------|-------|
| **Prowlarr** | https://prowlarr.com/docs/api/ | OpenAPI/Swagger UI |
| **Sonarr** | https://sonarr.tv/docs/api/ | v3 API covers v3 and v4 |
| **Radarr** | https://radarr.video/docs/api/ | OpenAPI/Swagger UI |
| **Bazarr** | https://wiki.bazarr.media/ | Companion subtitle manager; API via `/api/` with `apikey` |

### Servarr Wiki
- **URL:** https://wiki.servarr.com/
- Contains setup guides, configuration tutorials, and troubleshooting for all *arr services.

## Request Management

| Service | API Documentation | Notes |
|---------|-------------------|-------|
| **Seerr** | https://api-docs.overseerr.dev/ | Swagger UI |

