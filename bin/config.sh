#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Service wiring — invoked by setup and upgrade.
# Exit 0 if all required steps succeed; exit 1 if any required step fails.
set -euo pipefail

_cfg_self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$_cfg_self/../lib/core.sh" ]; then
    _lib_dir="$_cfg_self/../lib"
elif [ -f "$_cfg_self/lib/core.sh" ]; then
    _lib_dir="$_cfg_self/lib"
elif [ -f "${ASSEMBLRR_DIR:-$HOME/assemblrr}/lib/core.sh" ]; then
    _lib_dir="${ASSEMBLRR_DIR:-$HOME/assemblrr}/lib"
else
    echo -e "\033[0;31mError: lib/core.sh not found. Re-run setup.\033[0m" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$_lib_dir/core.sh"
# shellcheck source=/dev/null
source "$_lib_dir/branding.sh"
# shellcheck source=/dev/null
source "$_lib_dir/fzf-tui.sh"
# shellcheck source=/dev/null
source "$_lib_dir/api.sh"
# shellcheck source=/dev/null
source "$_lib_dir/arr.sh"
# shellcheck source=/dev/null
source "$_lib_dir/recyclarr.sh"
# shellcheck source=/dev/null
source "$_lib_dir/jellyfin.sh"
# shellcheck source=/dev/null
source "$_lib_dir/seerr.sh"
# shellcheck source=/dev/null
source "$_lib_dir/bazarr.sh"
# shellcheck source=/dev/null
source "$_lib_dir/usenet.sh"

_cfg_log_info() {
    echo "  $1"
    printf '  %s\n' "$1" >> "${CONFIGURE_LOG:-/dev/null}"
}

_configure_total=0
_configure_ok=0
_configure_fail=0
log_step() {
    printf ' %b✓%b %s\n' "${GREEN:-}" "${NC:-}" "$1"
    printf ' ✓ %s\n' "$1" >> "${CONFIGURE_LOG:-/dev/null}"
    _configure_ok=$((_configure_ok + 1))
    _configure_total=$((_configure_total + 1))
}
log_step_fail() {
    printf ' %b✗%b %s\n' "${RED:-}" "${NC:-}" "$1" >&2
    printf ' ✗ %s\n' "$1" >> "${CONFIGURE_LOG:-/dev/null}"
    _configure_fail=$((_configure_fail + 1))
    _configure_total=$((_configure_total + 1))
}

_wire_critical_fail=0
_wire_optional_fail=0

run_critical() {
    if ! "$@"; then
        _wire_critical_fail=$((_wire_critical_fail + 1))
    fi
    return 0
}

run_optional() {
    if ! "$@"; then
        _wire_optional_fail=$((_wire_optional_fail + 1))
    fi
    return 0
}

main() {
    INSTALL_DIR=$(find_install_directory || true)
    if [ -z "${INSTALL_DIR:-}" ]; then
        log_error "Could not find installation. Run setup first."
    fi

    safe_source "$INSTALL_DIR/.assemblrr-config"
    load_branding "$INSTALL_DIR"
    set -a
    [ -f "$INSTALL_DIR/.env" ] && safe_source "$INSTALL_DIR/.env"
    set +a

    API_HOST="${API_HOST:-127.0.0.1}"
    RADARR_DOCKER_URL="${RADARR_DOCKER_URL:-http://radarr:7878}"
    SONARR_DOCKER_URL="${SONARR_DOCKER_URL:-http://sonarr:8989}"
    PROWLARR_DOCKER_URL="${PROWLARR_DOCKER_URL:-http://prowlarr:9696}"
    if [ "${VPN_ENABLED:-n}" = "y" ] || [ "${VPN_ENABLED:-n}" = "Y" ]; then
        QBITTORRENT_HOST="gluetun"
    else
        QBITTORRENT_HOST="qbittorrent"
    fi

    AUTH_USERNAME=$(cat "$INSTALL_DIR/secrets/auth_username.txt" 2>/dev/null || echo "$USER")
    AUTH_PASSWORD=$(cat "$INSTALL_DIR/secrets/auth_password.txt" 2>/dev/null || echo "")
    CONFIGURE_LOG="${CONFIGURE_LOG:-/tmp/${APP_NAME:-assemblrr}-configure-$(date '+%Y%m%d-%H%M%S').log}"

    echo
    _cfg_log_info "Wiring ${APP_DISPLAY_NAME} services..."

    RADARR_API_KEY=""
    SONARR_API_KEY=""
    PROWLARR_API_KEY=""

    if ! RADARR_API_KEY=$(read_api_key "radarr"); then
        RADARR_API_KEY=""
        _wire_critical_fail=$((_wire_critical_fail + 1))
    fi
    if ! SONARR_API_KEY=$(read_api_key "sonarr"); then
        SONARR_API_KEY=""
        _wire_critical_fail=$((_wire_critical_fail + 1))
    fi
    if ! PROWLARR_API_KEY=$(read_api_key "prowlarr"); then
        PROWLARR_API_KEY=""
        _wire_critical_fail=$((_wire_critical_fail + 1))
    fi

    if [ -n "$RADARR_API_KEY" ] && ! wait_for_api "Radarr" "7878" "$RADARR_API_KEY"; then
        _wire_critical_fail=$((_wire_critical_fail + 1))
        RADARR_API_KEY=""
    fi
    if [ -n "$SONARR_API_KEY" ] && ! wait_for_api "Sonarr" "8989" "$SONARR_API_KEY"; then
        _wire_critical_fail=$((_wire_critical_fail + 1))
        SONARR_API_KEY=""
    fi
    if [ -n "$PROWLARR_API_KEY" ]; then
        if wait_for_api "Prowlarr" "9696" "$PROWLARR_API_KEY" "/api/v1/system/status"; then
            run_optional configure_indexers "$PROWLARR_API_KEY"
        else
            _wire_critical_fail=$((_wire_critical_fail + 1))
            PROWLARR_API_KEY=""
        fi
    fi

    if [ -n "$RADARR_API_KEY" ] || [ -n "$SONARR_API_KEY" ]; then
        run_critical qbit_set_credentials
    fi

    if [ "${USENET_ENABLED:-n}" = "y" ] || [ "${USENET_ENABLED:-n}" = "Y" ]; then
        run_critical configure_sabnzbd
    fi

    if [ -n "$RADARR_API_KEY" ]; then
        run_critical configure_radarr "$RADARR_API_KEY"
        run_optional add_arr_purge_hook "Radarr" "7878" "$RADARR_API_KEY"
    fi

    if [ -n "$SONARR_API_KEY" ]; then
        run_critical configure_sonarr "$SONARR_API_KEY"
        run_optional add_arr_purge_hook "Sonarr" "8989" "$SONARR_API_KEY"
    fi

    if [ "${USENET_ENABLED:-n}" = "y" ] || [ "${USENET_ENABLED:-n}" = "Y" ]; then
        if [ -n "$RADARR_API_KEY" ] || [ -n "$SONARR_API_KEY" ]; then
            run_critical arr_configure_sabnzbd
        fi
    fi

    if [ -n "$PROWLARR_API_KEY" ]; then
        run_critical configure_prowlarr "$PROWLARR_API_KEY" "$RADARR_API_KEY" "$SONARR_API_KEY"
        if [ "${BYPARR_ENABLED:-n}" = "y" ] || [ "${BYPARR_ENABLED:-n}" = "Y" ]; then
            run_optional prowlarr_sync_byparr_proxy "$PROWLARR_API_KEY"
        fi
    fi

    run_critical configure_jellyfin
    run_optional configure_jellyfin_notifications

    if [ -n "$RADARR_API_KEY" ] || [ -n "$SONARR_API_KEY" ]; then
        run_optional configure_subtitle_providers
        run_critical configure_bazarr
    fi

    if [ -n "$RADARR_API_KEY" ] || [ -n "$SONARR_API_KEY" ]; then
        run_critical configure_recyclarr
        if [ -n "$RADARR_API_KEY" ]; then
            run_critical relax_quality_sizes "Radarr" "7878" "$RADARR_API_KEY"
            run_critical set_default_quality_profile "Radarr" "7878" "$RADARR_API_KEY" "lookup_radarr_profile"
        fi
        if [ -n "$SONARR_API_KEY" ]; then
            run_critical relax_quality_sizes "Sonarr" "8989" "$SONARR_API_KEY"
            run_critical set_default_quality_profile "Sonarr" "8989" "$SONARR_API_KEY" "lookup_sonarr_profile"
        fi
        if [ -n "$RADARR_API_KEY" ]; then
            run_optional import_radarr_existing_media "$RADARR_API_KEY"
        fi
        if [ -n "$SONARR_API_KEY" ]; then
            run_optional import_sonarr_existing_media "$SONARR_API_KEY"
        fi
        run_optional trigger_bazarr_library_sync
        run_critical configure_seerr
    else
        _cfg_log_info "Skipping Recyclarr & Seerr wiring (neither Radarr nor Sonarr API key available)"
    fi

    echo
    if [ "$_wire_critical_fail" -gt 0 ]; then
        printf '  %bWiring failed: %s required step(s)%b\n' "${RED:-}" "${_wire_critical_fail}" "${NC:-}"
        printf '  Wiring failed: %s required step(s)\n' "${_wire_critical_fail}" >> "$CONFIGURE_LOG"
        if [ "$_configure_ok" -gt 0 ] || [ "$_configure_fail" -gt 0 ]; then
            printf '  %b%s ok, %s failed (see markers above)%b\n' "${YELLOW:-}" "${_configure_ok}" "${_configure_fail}" "${NC:-}"
            printf '  %s ok, %s failed (see markers above)\n' "${_configure_ok}" "${_configure_fail}" >> "$CONFIGURE_LOG"
        fi
        printf '  %bLog: %s%b\n\n' "${YELLOW:-}" "$CONFIGURE_LOG" "${NC:-}"
        _cfg_log_info "Fix issues, then re-run: ${APP_CLI_NAME:-assemblrr} config apply"
        echo
        exit 1
    fi

    if [ "$_configure_fail" -gt 0 ] || [ "$_wire_optional_fail" -gt 0 ]; then
        printf '  %bRequired wiring succeeded%b\n' "${GREEN:-}" "${NC:-}"
        printf '  %bSome optional steps had issues — log: %s%b\n' "${YELLOW:-}" "$CONFIGURE_LOG" "${NC:-}"
        printf '  Required wiring succeeded (optional issues: %s)\n' "$_wire_optional_fail" >> "$CONFIGURE_LOG"
    else
        printf '  %b✓ All %s wiring steps succeeded%b\n' "${GREEN:-}" "${_configure_ok}" "${NC:-}"
        printf '  All %s wiring steps succeeded\n' "${_configure_ok}" >> "$CONFIGURE_LOG"
    fi

    if [ "${ASSEMBLRR_FROM_SETUP:-0}" = "1" ]; then
        exit 0
    fi

    echo
    local ui_host="$API_HOST"
    [ "$ui_host" = "127.0.0.1" ] && ui_host="localhost"
    _cfg_log_info "Next steps:"
    _cfg_log_info "  1. Open Jellyfin at http://${ui_host}:8096"
    _cfg_log_info "  2. Open Seerr at http://${ui_host}:5055 and request a movie or show"
    _cfg_log_info "  3. qBittorrent UI: http://${ui_host}:8081  |  Bazarr UI: http://${ui_host}:6767"
    if [ "${USENET_ENABLED:-n}" = "y" ] || [ "${USENET_ENABLED:-n}" = "Y" ]; then
        _cfg_log_info "  4. SABnzbd UI:     http://${ui_host}:8085"
    fi
    echo
    if [ -n "$AUTH_USERNAME" ]; then
        _cfg_log_info "Login credentials: $AUTH_USERNAME / (the password you set during setup)"
    fi

    exit 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
