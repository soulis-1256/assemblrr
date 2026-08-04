#!/bin/sh
# Triggered by Radarr/Sonarr on movie/episode import.
# Calls Jellyfin's full library refresh to discover new files.
# /Library/Media/Updated only refreshes EXISTING items — it cannot
# discover new ones.  /Library/Refresh performs a full scan.

JF_HOST="${JELLYFIN_HOST:-jellyfin}"
JF_PORT="${JELLYFIN_PORT:-8096}"

# Read API key from mounted secrets file (preferred) or env var (fallback)
if [ -f "/run/secrets/jellyfin_api_key.txt" ]; then
    JF_API_KEY=$(cat /run/secrets/jellyfin_api_key.txt)
else
    JF_API_KEY="${JELLYFIN_API_KEY:-}"
fi

# Ignore the Test event (Radarr sends this when clicking "Test")
if [ "${radarr_eventtype}" = "Test" ] || [ "${sonarr_eventtype}" = "Test" ]; then
    echo "Jellyfin refresh: test event received, skipping"
    exit 0
fi

if [ -z "$JF_API_KEY" ]; then
    echo "Jellyfin refresh: JELLYFIN_API_KEY not set" >&2
    exit 1
fi

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "X-Emby-Token: ${JF_API_KEY}" \
    "http://${JF_HOST}:${JF_PORT}/Library/Refresh" 2>/dev/null)

if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
    echo "Jellyfin refresh: triggered successfully (HTTP ${HTTP_CODE})"
else
    echo "Jellyfin refresh: failed (HTTP ${HTTP_CODE})" >&2
    exit 1
fi
