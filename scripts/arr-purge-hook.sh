#!/bin/bash
# Radarr/Sonarr Custom Script → media-purge (qB cleanup on delete).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PURGE="${SCRIPT_DIR}/media-purge.sh"
[ -x "$PURGE" ] || chmod +x "$PURGE" 2>/dev/null || true

export API_HOST="${API_HOST:-127.0.0.1}"
export QBITTORRENT_URL="${QBITTORRENT_URL:-}"
export MEDIA_ROOT="${MEDIA_ROOT:-/data}"
export JELLYFIN_URL="${JELLYFIN_URL:-http://jellyfin:8096}"
export JELLYFIN_API_KEY_FILE="${JELLYFIN_API_KEY_FILE:-/run/secrets/jellyfin_api_key.txt}"
export AUTH_USERNAME_FILE="${AUTH_USERNAME_FILE:-/run/secrets/auth_username.txt}"
export AUTH_PASSWORD_FILE="${AUTH_PASSWORD_FILE:-/run/secrets/auth_password.txt}"

# Inside *arr the app config is /config/config.xml (not /config/sonarr/...).
if [ -f /config/config.xml ]; then
    _arr_key=$(sed -n 's/.*<ApiKey>\(.*\)<\/ApiKey>.*/\1/p' /config/config.xml 2>/dev/null | head -1)
    if [ -n "${sonarr_eventtype:-}" ]; then
        export SONARR_API_KEY="${SONARR_API_KEY:-${_arr_key:-}}"
        export SONARR_URL="${SONARR_URL:-http://127.0.0.1:8989}"
    fi
    if [ -n "${radarr_eventtype:-}" ]; then
        export RADARR_API_KEY="${RADARR_API_KEY:-${_arr_key:-}}"
        export RADARR_URL="${RADARR_URL:-http://127.0.0.1:7878}"
    fi
    unset _arr_key
fi

if [ -z "$QBITTORRENT_URL" ]; then
    if curl -s --connect-timeout 2 -o /dev/null -w "%{http_code}" "http://gluetun:8081/" 2>/dev/null | grep -qE '^[2345]'; then
        export QBITTORRENT_URL="http://gluetun:8081"
    elif curl -s --connect-timeout 2 -o /dev/null -w "%{http_code}" "http://qbittorrent:8081/" 2>/dev/null | grep -qE '^[2345]'; then
        export QBITTORRENT_URL="http://qbittorrent:8081"
    fi
fi

if [ -n "${radarr_eventtype:-}" ]; then
    exec "$PURGE" --radarr-event
fi
if [ -n "${sonarr_eventtype:-}" ]; then
    exec "$PURGE" --sonarr-event
fi

echo "arr-purge-hook: no event env" >&2
exit 0
