#!/bin/bash
# Radarr/Sonarr Custom Script → media-purge (qB cleanup on delete).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PURGE="${SCRIPT_DIR}/media-purge.sh"
[ -x "$PURGE" ] || chmod +x "$PURGE" 2>/dev/null || true

export API_HOST="${API_HOST:-127.0.0.1}"
export QBITTORRENT_URL="${QBITTORRENT_URL:-}"
export AUTH_USERNAME_FILE="${AUTH_USERNAME_FILE:-/run/secrets/auth_username.txt}"
export AUTH_PASSWORD_FILE="${AUTH_PASSWORD_FILE:-/run/secrets/auth_password.txt}"

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
