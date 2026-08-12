#!/bin/bash
# inotify on /data/media → media-purge when library files are deleted.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PURGE="${SCRIPT_DIR}/media-purge.sh"
MEDIA_ROOT="${MEDIA_ROOT:-/data}"
WATCH_ROOT="${WATCH_ROOT:-${MEDIA_ROOT}/media}"
DEBOUNCE_SEC="${DEBOUNCE_SEC:-2}"

export API_HOST="${API_HOST:-127.0.0.1}"
export RADARR_URL="${RADARR_URL:-http://radarr:7878}"
export SONARR_URL="${SONARR_URL:-http://sonarr:8989}"
export CONFIG_DIR="${CONFIG_DIR:-/config}"
export AUTH_USERNAME_FILE="${AUTH_USERNAME_FILE:-/run/secrets/auth_username.txt}"
export AUTH_PASSWORD_FILE="${AUTH_PASSWORD_FILE:-/run/secrets/auth_password.txt}"

log() { echo "media-purge-watch: $*" >&2; }

[ -x "$PURGE" ] || chmod +x "$PURGE" 2>/dev/null || true

if ! command -v inotifywait >/dev/null 2>&1; then
    apk add --no-cache inotify-tools curl jq bash >/dev/null
fi

if [ -z "${QBITTORRENT_URL:-}" ]; then
    if curl -s --connect-timeout 2 -o /dev/null -w "%{http_code}" "http://gluetun:8081/" 2>/dev/null | grep -qE '^[2345]'; then
        export QBITTORRENT_URL="http://gluetun:8081"
    elif curl -s --connect-timeout 2 -o /dev/null -w "%{http_code}" "http://qbittorrent:8081/" 2>/dev/null | grep -qE '^[2345]'; then
        export QBITTORRENT_URL="http://qbittorrent:8081"
    else
        export QBITTORRENT_URL="http://gluetun:8081"
    fi
fi

log "watching ${WATCH_ROOT} (qB=${QBITTORRENT_URL})"

library_folder_for() {
    local p="$1"
    case "$p" in
        */media/movies/*) echo "$p" | sed -E 's|(.*/media/movies/[^/]+).*|\1|' ;;
        */media/tv/*) echo "$p" | sed -E 's|(.*/media/tv/[^/]+).*|\1|' ;;
        *) echo "" ;;
    esac
}

LAST_PURGE_PATH=""
LAST_PURGE_TS=0

handle_event() {
    local path="$1"
    local folder
    folder=$(library_folder_for "$path")
    [ -n "$folder" ] || return 0

    local now
    now=$(date +%s)
    if [ "$folder" = "$LAST_PURGE_PATH" ] && [ $((now - LAST_PURGE_TS)) -lt 15 ]; then
        return 0
    fi

    sleep "$DEBOUNCE_SEC"
    if [ -e "$folder" ]; then
        if find "$folder" -type f \( -name '*.mkv' -o -name '*.mp4' -o -name '*.avi' -o -name '*.m4v' -o -name '*.ts' \) 2>/dev/null | grep -q .; then
            return 0
        fi
    fi

    LAST_PURGE_PATH="$folder"
    LAST_PURGE_TS=$now
    local arr_path
    case "$folder" in
        /data/*) arr_path="$folder" ;;
        *) arr_path=$(echo "$folder" | sed -E 's|.*/media/|/data/media/|') ;;
    esac
    log "purge $arr_path"
    "$PURGE" --path "$arr_path" || log "purge failed for $arr_path"
}

mkdir -p "$WATCH_ROOT/movies" "$WATCH_ROOT/tv" 2>/dev/null || true

inotifywait -m -r \
    -e delete,delete_self,moved_from \
    --format '%e|%w|%f' \
    "$WATCH_ROOT" 2>/dev/null | while IFS='|' read -r events watch_dir filename; do
    full="${watch_dir}${filename}"
    case "$full" in
        *'/.nfs'*|*/.tmp*|*/tmp/*) continue ;;
    esac
    handle_event "$full" &
done
