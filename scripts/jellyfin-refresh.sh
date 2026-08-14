#!/bin/sh
# Triggered by Radarr/Sonarr after import (see lib/jellyfin.sh).
#
# POST /Library/Refresh discovers new files. A second POST cancels the
# in-progress scan. Jellyfin 10.11 can then save a new series under a TVDB
# PresentationUniqueKey while its episodes keep the series GUID as
# SeriesPresentationUniqueKey — the UI shows 0 episodes / 0 minutes even
# though the files are in the DB. Do not cancel a running scan; after the
# scan goes idle, recursively refresh any series that still look empty
# despite video files on disk.

JF_HOST="${JELLYFIN_HOST:-jellyfin}"
JF_PORT="${JELLYFIN_PORT:-8096}"
JF_REFRESH_HEAL_POLL_SEC="${JF_REFRESH_HEAL_POLL_SEC:-5}"
JF_REFRESH_HEAL_MAX_POLLS="${JF_REFRESH_HEAL_MAX_POLLS:-36}"
JF_HEAL_LOCK_DIR="${JF_HEAL_LOCK_DIR:-/tmp/assemblrr-jf-heal.lock}"

jf_refresh_is_test_event() {
    [ "${radarr_eventtype:-}" = "Test" ] || [ "${sonarr_eventtype:-}" = "Test" ]
}

# Arg: GET /ScheduledTasks JSON. Echo Idle when missing or unparseable.
jf_refresh_scan_state() {
    local state
    [ -n "${1:-}" ] || { echo Idle; return 0; }
    state=$(printf '%s' "$1" | jq -r \
        '([.[]? | select(.Key == "RefreshLibrary") | .State] | first) // "Idle"' \
        2>/dev/null || true)
    [ -n "$state" ] && [ "$state" != "null" ] || state=Idle
    echo "$state"
}

jf_refresh_scan_busy() {
    case "${1:-}" in
        Running|Cancelling) return 0 ;;
        *) return 1 ;;
    esac
}

# True when the Shows API reports no episodes but the library folder has video.
# That is the 10.11 identity-key miss (series page empty; item-by-id still works).
jf_refresh_dir_has_video() {
    local dir="${1:-}"
    [ -n "$dir" ] && [ -d "$dir" ] || return 1
    find "$dir" \( -iname '*.mkv' -o -iname '*.mp4' -o -iname '*.m4v' \
        -o -iname '*.avi' -o -iname '*.ts' -o -iname '*.m2ts' -o -iname '*.wmv' \) \
        -type f -print 2>/dev/null | head -1 | grep -q .
}

jf_refresh_empty_series_ids() {
    printf '%s' "${1:-}" | jq -r '.Items[]? | .Id // empty' 2>/dev/null
}

if [ "${JF_REFRESH_SOURCE_ONLY:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

if [ -f "/run/secrets/jellyfin_api_key.txt" ]; then
    JF_API_KEY=$(cat /run/secrets/jellyfin_api_key.txt)
else
    JF_API_KEY="${JELLYFIN_API_KEY:-}"
fi

jf_refresh_curl() {
    curl -sS --connect-timeout 5 --max-time 30 \
        -H "X-Emby-Token: ${JF_API_KEY}" \
        "$@" 2>/dev/null
}

jf_refresh_heal_after_scan() {
    local i=0
    local tasks state series_json sid path eps

    while [ "$i" -lt "$JF_REFRESH_HEAL_MAX_POLLS" ]; do
        tasks=$(jf_refresh_curl "http://${JF_HOST}:${JF_PORT}/ScheduledTasks" || echo "")
        state=$(jf_refresh_scan_state "$tasks")
        if ! jf_refresh_scan_busy "$state"; then
            break
        fi
        sleep "$JF_REFRESH_HEAL_POLL_SEC"
        i=$((i + 1))
    done

    series_json=$(jf_refresh_curl \
        "http://${JF_HOST}:${JF_PORT}/Items?IncludeItemTypes=Series&Recursive=true&Fields=Path" \
        || echo "")

    echo "$series_json" | jq -c '.Items[]? | {Id, Path}' 2>/dev/null | while read -r row; do
        sid=$(echo "$row" | jq -r '.Id // empty')
        path=$(echo "$row" | jq -r '.Path // empty')
        [ -n "$sid" ] || continue
        jf_refresh_dir_has_video "$path" || continue

        eps=$(jf_refresh_curl \
            "http://${JF_HOST}:${JF_PORT}/Shows/${sid}/Episodes" || echo "")
        if [ "$(echo "$eps" | jq -r '.TotalRecordCount // 0' 2>/dev/null || echo 0)" != "0" ]; then
            continue
        fi

        echo "Jellyfin refresh: healing empty series ${sid} (${path})"
        jf_refresh_curl -o /dev/null -X POST \
            "http://${JF_HOST}:${JF_PORT}/Items/${sid}/Refresh?Recursive=true&MetadataRefreshMode=FullRefresh&ImageRefreshMode=Default&ReplaceAllMetadata=false" \
            || true
    done
}

if [ "${1:-}" = "--heal-only" ]; then
    if [ -z "$JF_API_KEY" ]; then
        echo "Jellyfin refresh: JELLYFIN_API_KEY not set" >&2
        exit 1
    fi
    if mkdir "$JF_HEAL_LOCK_DIR" 2>/dev/null; then
        echo $$ >"$JF_HEAL_LOCK_DIR/pid"
        trap 'rm -rf "$JF_HEAL_LOCK_DIR"' EXIT
        jf_refresh_heal_after_scan
    else
        oldpid=$(cat "$JF_HEAL_LOCK_DIR/pid" 2>/dev/null || echo "")
        if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
            echo "Jellyfin refresh: heal already running (pid ${oldpid})"
            exit 0
        fi
        rm -rf "$JF_HEAL_LOCK_DIR"
        mkdir "$JF_HEAL_LOCK_DIR" 2>/dev/null || exit 0
        echo $$ >"$JF_HEAL_LOCK_DIR/pid"
        trap 'rm -rf "$JF_HEAL_LOCK_DIR"' EXIT
        jf_refresh_heal_after_scan
    fi
    exit 0
fi

if jf_refresh_is_test_event; then
    echo "Jellyfin refresh: test event received, skipping"
    exit 0
fi

if [ -z "$JF_API_KEY" ]; then
    echo "Jellyfin refresh: JELLYFIN_API_KEY not set" >&2
    exit 1
fi

TASKS_JSON=$(jf_refresh_curl "http://${JF_HOST}:${JF_PORT}/ScheduledTasks" || echo "")
SCAN_STATE=$(jf_refresh_scan_state "$TASKS_JSON")

if jf_refresh_scan_busy "$SCAN_STATE"; then
    echo "Jellyfin refresh: scan already ${SCAN_STATE}, not cancelling"
else
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 \
        -X POST \
        -H "X-Emby-Token: ${JF_API_KEY}" \
        "http://${JF_HOST}:${JF_PORT}/Library/Refresh" 2>/dev/null || echo "000")

    if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
        echo "Jellyfin refresh: triggered successfully (HTTP ${HTTP_CODE})"
    else
        echo "Jellyfin refresh: failed (HTTP ${HTTP_CODE})" >&2
        exit 1
    fi
fi

# Sonarr/Radarr wait on this process; heal in the background so we do not
# block their notification pipeline. nohup survives the parent exiting.
SCRIPT_PATH="$0"
case "$SCRIPT_PATH" in
    /*) ;;
    *) SCRIPT_PATH="$(pwd)/$SCRIPT_PATH" ;;
esac
nohup env \
    JELLYFIN_HOST="$JF_HOST" \
    JELLYFIN_PORT="$JF_PORT" \
    JELLYFIN_API_KEY="$JF_API_KEY" \
    JF_REFRESH_HEAL_POLL_SEC="$JF_REFRESH_HEAL_POLL_SEC" \
    JF_REFRESH_HEAL_MAX_POLLS="$JF_REFRESH_HEAL_MAX_POLLS" \
    JF_HEAL_LOCK_DIR="$JF_HEAL_LOCK_DIR" \
    "$SCRIPT_PATH" --heal-only >/tmp/assemblrr-jf-heal.log 2>&1 &
exit 0
