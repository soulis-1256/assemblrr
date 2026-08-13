#!/bin/bash
# assemblrr service catalog — UI URLs and display labels for status
# Requires: MEDIA_SERVICE, VPN_ENABLED optional (from install config)

if [ -n "${_ASSEMBLRR_SERVICES_SOURCED:-}" ]; then
    return 0
fi
readonly _ASSEMBLRR_SERVICES_SOURCED=1

# Emit catalog lines (stable order):
#   compose_service|Display Name|port|path|kind
# kind: ui = browser URL, internal = no public UI
list_service_catalog() {
    local media="${MEDIA_SERVICE:-jellyfin}"
    local media_port=8096
    local media_path="/"
    local media_label="Jellyfin"

    case "$media" in
        jellyfin)
            media_label="Jellyfin"
            media_port=8096
            media_path="/"
            ;;
        emby)
            media_label="Emby"
            media_port=8096
            media_path="/"
            ;;
        plex)
            media_label="Plex"
            media_port=32400
            media_path="/web"
            ;;
        *)
            media_label="$media"
            media_port=8096
            media_path="/"
            ;;
    esac

    printf '%s\n' \
        "${media}|${media_label}|${media_port}|${media_path}|ui" \
        "seerr-gateway|Seerr|5055|/|ui" \
        "bazarr|Bazarr|6767|/|ui" \
        "sonarr|Sonarr|8989|/|ui" \
        "radarr|Radarr|7878|/|ui" \
        "prowlarr|Prowlarr|9696|/|ui" \
        "qbittorrent|qBittorrent|8081|/|ui" \
        "recyclarr|Recyclarr|||internal"

    printf '%s\n' \
        "seerr|Seerr (internal)|||internal" \
        "media-purge-watch|Media purge watch|||internal"

    if [ "${VPN_ENABLED:-n}" = "y" ]; then
        printf '%s\n' \
            "gluetun|Gluetun (VPN)|||internal" \
            "deunhealth|Deunhealth|||internal" \
            "vpn-watchdog|VPN watchdog|||internal"
    fi
}

# Build URL for a catalog row (localhost — stable across DHCP changes)
service_ui_url() {
    local port="$1"
    local path="${2:-/}"
    local host="${3:-localhost}"

    [ -z "$port" ] && { echo ""; return 0; }
    if [ "$path" != "/" ] && [[ "$path" != /* ]]; then
        path="/$path"
    fi
    if [ "$path" = "/" ]; then
        echo "http://${host}:${port}/"
    else
        echo "http://${host}:${port}${path}"
    fi
}

# True when a compose ps row is ready for the operator.
# healthy → ready; starting/unhealthy → not; no healthcheck + running → ready.
service_row_ready() {
    local state="${1:-}"
    local health="${2:-}"
    state=$(printf '%s' "$state" | tr '[:upper:]' '[:lower:]')
    health=$(printf '%s' "$health" | tr '[:upper:]' '[:lower:]')
    case "$health" in
        healthy) return 0 ;;
        unhealthy|starting) return 1 ;;
    esac
    [ "$state" = "running" ]
}

# Human-readable service URLs only (setup summary / scripting)
running_services_location() {
    local host_ip="localhost"
    local line svc label port path kind

    echo "Service URLs (live: ${APP_CLI_NAME:-assemblrr} status):"
    while IFS='|' read -r svc label port path kind; do
        [ "$kind" = "ui" ] || continue
        printf '  %-12s %s\n' "$label" "$(service_ui_url "$port" "$path" "$host_ip")"
    done < <(list_service_catalog)
}
