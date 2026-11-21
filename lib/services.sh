#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# assemblrr service catalog — UI URLs and display labels for status
# Requires: MEDIA_SERVICE, VPN_ENABLED, USENET_ENABLED, BYPARR_ENABLED optional

if [ -n "${_ASSEMBLRR_SERVICES_SOURCED:-}" ]; then
    return 0
fi
readonly _ASSEMBLRR_SERVICES_SOURCED=1

# Emit catalog lines (stable order):
#   compose_service|Display Name|port|path|kind
# kind: ui = browser URL, internal = no public UI
list_service_catalog() {
    printf '%s\n' \
        "jellyfin|Jellyfin|8096|/|ui" \
        "seerr-gateway|Seerr|5055|/|ui" \
        "bazarr|Bazarr|6767|/|ui" \
        "sonarr|Sonarr|8989|/|ui" \
        "radarr|Radarr|7878|/|ui" \
        "prowlarr|Prowlarr|9696|/|ui" \
        "qbittorrent|qBittorrent|8081|/|ui"

    if [ "${USENET_ENABLED:-n}" = "y" ] || [ "${USENET_ENABLED:-n}" = "Y" ]; then
        printf '%s\n' "sabnzbd|SABnzbd|8085|/|ui"
    fi

    printf '%s\n' \
        "recyclarr|Recyclarr|||internal" \
        "seerr|Seerr (internal)|||internal"

    if [ "${BYPARR_ENABLED:-n}" = "y" ] || [ "${BYPARR_ENABLED:-n}" = "Y" ]; then
        printf '%s\n' "byparr|Byparr (solver)|||internal"
    fi

    printf '%s\n' "media-purge-watch|Media purge watch|||internal"

    if [ "${VPN_ENABLED:-n}" = "y" ] || [ "${VPN_ENABLED:-n}" = "Y" ]; then
        printf '%s\n' \
            "gluetun|Gluetun (VPN)|||internal" \
            "deunhealth|Deunhealth|||internal" \
            "vpn-watchdog|VPN watchdog|||internal"
    fi
}

# Build URL for a catalog row (uses localhost unless API_HOST points to a LAN/remote host)
service_ui_url() {
    local port="$1"
    local path="${2:-/}"
    local host="${3:-${API_HOST:-localhost}}"

    case "$host" in
        ""|127.0.0.1|0.0.0.0) host="localhost" ;;
    esac

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
# healthy -> ready; starting/unhealthy -> not; no healthcheck + running -> ready.
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
    local host_ip="${1:-${API_HOST:-localhost}}"
    local line svc label port path kind

    echo "Service URLs (live: ${APP_CLI_NAME:-assemblrr} status):"
    while IFS='|' read -r svc label port path kind; do
        [ "$kind" = "ui" ] || continue
        printf '  %-14s %s\n' "$label" "$(service_ui_url "$port" "$path" "$host_ip")"
    done < <(list_service_catalog)
}
