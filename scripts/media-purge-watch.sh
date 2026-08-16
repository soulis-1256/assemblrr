#!/bin/bash
# inotify on /data/media → media-purge when a library *video* is deleted.
# Ignores *arr write-tests, sidecars, and upgrade races (new file not yet written).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PURGE="${SCRIPT_DIR}/media-purge.sh"
MEDIA_ROOT="${MEDIA_ROOT:-/data}"
WATCH_ROOT="${WATCH_ROOT:-${MEDIA_ROOT}/media}"
# First look: skip if a replacement video is already there (normal import).
DEBOUNCE_SEC="${DEBOUNCE_SEC:-8}"
# Second look: Radarr/Sonarr upgrades delete the old file before writing the new one.
UPGRADE_GRACE_SEC="${UPGRADE_GRACE_SEC:-20}"

export API_HOST="${API_HOST:-127.0.0.1}"
export RADARR_URL="${RADARR_URL:-http://radarr:7878}"
export SONARR_URL="${SONARR_URL:-http://sonarr:8989}"
export JELLYFIN_URL="${JELLYFIN_URL:-http://jellyfin:8096}"
export JELLYFIN_API_KEY_FILE="${JELLYFIN_API_KEY_FILE:-/run/secrets/jellyfin_api_key.txt}"
export CONFIG_DIR="${CONFIG_DIR:-/config}"
export AUTH_USERNAME_FILE="${AUTH_USERNAME_FILE:-/run/secrets/auth_username.txt}"
export AUTH_PASSWORD_FILE="${AUTH_PASSWORD_FILE:-/run/secrets/auth_password.txt}"

log() { echo "media-purge-watch: $*" >&2; }

# Setup write-tests, editor junk, and incomplete tmp names must never purge.
purge_watch_is_ignored() {
    local p="${1:-}"
    local base="${p##*/}"
    case "$base" in
        ""|.|..|.DS_Store|Thumbs.db) return 0 ;;
        *write_test*|*_write_test.txt|radarr_write_test.txt|sonarr_write_test.txt) return 0 ;;
        .nfs*|.tmp*|*.tmp|*.partial|*.!qB|*.part) return 0 ;;
    esac
    case "$p" in
        */.nfs*|*/.tmp*|*/tmp/*|*/.git/*) return 0 ;;
    esac
    return 1
}

purge_watch_is_video() {
    local p="${1:-}"
    local ext="${p##*.}"
    ext=$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')
    case "$ext" in
        mkv|mp4|avi|m4v|ts|m2ts|webm|mov|wmv|mpg|mpeg) return 0 ;;
        *) return 1 ;;
    esac
}

# Folder we would ask *arr to delete (title directory under movies/ or tv/).
purge_watch_library_folder() {
    local p="$1"
    case "$p" in
        */media/movies/*) echo "$p" | sed -E 's|(.*/media/movies/[^/]+).*|\1|' ;;
        */media/tv/*) echo "$p" | sed -E 's|(.*/media/tv/[^/]+).*|\1|' ;;
        *) echo "" ;;
    esac
}

# Season number from a library path (.../Season 2/ep.mkv or .../Specials/...). Empty if none.
purge_watch_season_number() {
    local p="${1:-}"
    local n
    n=$(printf '%s' "$p" | sed -nE 's|.*/[Ss]eason[[:space:]]*0*([0-9]+)/.*|\1|p')
    if [ -z "$n" ]; then
        n=$(printf '%s' "$p" | sed -nE 's|.*/[Ss]eason[[:space:]]*0*([0-9]+)$|\1|p')
    fi
    if [ -z "$n" ]; then
        case "$p" in
            */[Ss]pecials|*/[Ss]pecials/*) echo 0; return 0 ;;
        esac
        return 0
    fi
    echo $((10#$n))
}

purge_watch_season_folder() {
    local series_folder="$1"
    local season="$2"
    local cand
    [ -n "$series_folder" ] || return 1
    if [ "$season" = "0" ]; then
        for cand in "${series_folder}/Specials" "${series_folder}/specials"; do
            [ -d "$cand" ] && echo "$cand" && return 0
        done
        return 1
    fi
    for cand in \
        "${series_folder}/Season ${season}" \
        "${series_folder}/Season $(printf '%02d' "$season")" \
        "${series_folder}/season ${season}" \
        "${series_folder}/season $(printf '%02d' "$season")"
    do
        [ -d "$cand" ] && echo "$cand" && return 0
    done
    return 1
}

purge_watch_folder_has_video() {
    local folder="$1"
    [ -d "$folder" ] || return 1
    find "$folder" -type f \( \
        -iname '*.mkv' -o -iname '*.mp4' -o -iname '*.avi' -o \
        -iname '*.m4v' -o -iname '*.ts' -o -iname '*.m2ts' -o \
        -iname '*.webm' -o -iname '*.mov' \
    \) 2>/dev/null | grep -q .
}

# --- sourced by unit tests: stop here ---
if [ "${PURGE_WATCH_SOURCE_ONLY:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

[ -x "$PURGE" ] || chmod +x "$PURGE" 2>/dev/null || true

if [ "${MEDIA_PURGE_WATCH:-1}" = "0" ] || [ "${MEDIA_PURGE_WATCH:-1}" = "false" ] || [ "${MEDIA_PURGE_WATCH:-1}" = "off" ]; then
    log "disabled (MEDIA_PURGE_WATCH=${MEDIA_PURGE_WATCH}); idling"
    exec sleep infinity
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

LAST_PURGE_PATH=""
LAST_PURGE_TS=0

handle_event() {
    local path="$1"
    local folder
    folder=$(purge_watch_library_folder "$path")
    [ -n "$folder" ] || return 0

    local now
    now=$(date +%s)

    local season
    season=$(purge_watch_season_number "$path")
    # Dedup per season so S01 then S02 in the same window both run.
    local dedup_key="$folder"
    [ -n "$season" ] && dedup_key="${folder}/s${season}"
    if [ "$dedup_key" = "$LAST_PURGE_PATH" ] && [ $((now - LAST_PURGE_TS)) -lt 15 ]; then
        return 0
    fi

    sleep "$DEBOUNCE_SEC"

    local arr_path
    case "$folder" in
        /data/*) arr_path="$folder" ;;
        *) arr_path=$(echo "$folder" | sed -E 's|.*/media/|/data/media/|') ;;
    esac

    if [ -n "$season" ]; then
        # Other seasons may only be monitored or still downloading — never
        # treat an empty series folder as "the show is done".
        local sfolder
        sfolder=$(purge_watch_season_folder "$folder" "$season" || true)
        if [ -n "$sfolder" ] && purge_watch_folder_has_video "$sfolder"; then
            return 0
        fi
        sleep "$UPGRADE_GRACE_SEC"
        sfolder=$(purge_watch_season_folder "$folder" "$season" || true)
        if [ -n "$sfolder" ] && purge_watch_folder_has_video "$sfolder"; then
            return 0
        fi
        LAST_PURGE_PATH="$dedup_key"
        LAST_PURGE_TS=$(date +%s)
        log "purge $arr_path season ${season}"
        "$PURGE" --path "$arr_path" --seasons "$season" || log "purge failed for $arr_path season ${season}"
        return 0
    fi

    if purge_watch_folder_has_video "$folder"; then
        return 0
    fi
    sleep "$UPGRADE_GRACE_SEC"
    if purge_watch_folder_has_video "$folder"; then
        return 0
    fi

    LAST_PURGE_PATH="$dedup_key"
    LAST_PURGE_TS=$(date +%s)
    log "purge $arr_path"
    "$PURGE" --path "$arr_path" || log "purge failed for $arr_path"
}

mkdir -p "$WATCH_ROOT/movies" "$WATCH_ROOT/tv" 2>/dev/null || true

if ! command -v inotifywait >/dev/null 2>&1; then
    log "ERROR: inotifywait missing (sidecar image not built?)"
    exit 1
fi

# Serial: one event at a time. Backgrounding every inotify line can fork-bomb
# a library delete and race an in-progress *arr upgrade.
inotifywait -m -r \
    -e delete,delete_self,moved_from \
    --format '%e|%w|%f' \
    "$WATCH_ROOT" 2>/dev/null | while IFS='|' read -r events watch_dir filename; do
    full="${watch_dir}${filename}"
    if purge_watch_is_ignored "$full"; then
        continue
    fi
    if purge_watch_is_video "$full"; then
        handle_event "$full"
        continue
    fi
    # Title folder removed (not a sidecar nfo/jpg delete).
    case ",${events}," in
        *,DELETE_SELF,*)
            handle_event "$full"
            ;;
    esac
done
