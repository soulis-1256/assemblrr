#!/bin/bash
set -euo pipefail

# Service wiring — invoked by setup and upgrade.
# Exit 0 if all required steps succeed; exit 1 if any required step fails.

# --- Config discovery ---

# Locate lib/ directory (handles both repo layout and installed layout)
_cfg_self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$_cfg_self/../lib/core.sh" ]; then
    _lib_dir="$_cfg_self/../lib"       # repo: bin/ and lib/ are siblings
elif [ -f "$_cfg_self/lib/core.sh" ]; then
    _lib_dir="$_cfg_self/lib"          # installed: lib/ is subdirectory of install dir
elif [ -f "${ASSEMBLRR_DIR:-$HOME/assemblrr}/lib/core.sh" ]; then
    _lib_dir="${ASSEMBLRR_DIR:-$HOME/assemblrr}/lib"
else
    echo -e "\033[0;31mError: lib/core.sh not found. Re-run setup.\033[0m" >&2
    exit 1
fi

# Source core library (logging, colors, safe_source, find_install_directory)
source "$_lib_dir/core.sh"
# Source branding
source "$_lib_dir/branding.sh"

INSTALL_DIR=$(find_install_directory)
if [ -z "$INSTALL_DIR" ]; then
    log_error "Could not find installation. Run setup first."
fi

# Source runtime config and branding
safe_source "$INSTALL_DIR/.assemblrr-config"
load_branding "$INSTALL_DIR"

# Source .env for VPN_ENABLED and other settings
set -a; safe_source "$INSTALL_DIR/.env"; set +a
API_HOST="${API_HOST:-127.0.0.1}"

# --- Constants ---

# Docker network URLs (for inter-service communication)
RADARR_DOCKER_URL="http://radarr:7878"
SONARR_DOCKER_URL="http://sonarr:8989"
PROWLARR_DOCKER_URL="http://prowlarr:9696"

# Download client host depends on VPN mode
if [ "${VPN_ENABLED:-n}" = "y" ]; then
    QBITTORRENT_HOST="gluetun"
else
    QBITTORRENT_HOST="qbittorrent"
fi

# Auth credentials
AUTH_USERNAME=$(cat "$INSTALL_DIR/secrets/auth_username.txt" 2>/dev/null || echo "$USER")
AUTH_PASSWORD=$(cat "$INSTALL_DIR/secrets/auth_password.txt" 2>/dev/null || echo "")

# --- Logging ---

# Always create a configure log file (same output for both express and manual)
CONFIGURE_LOG="/tmp/${APP_NAME}-configure-$(date '+%Y%m%d-%H%M%S').log"

# Extended logging for configure (step markers on top of lib/core.sh base, tee to log file)
_cfg_log_info() { echo "  $1" | tee -a "$CONFIGURE_LOG"; }

# Step markers for the summary line (exit code uses _wire_critical_fail)
_configure_total=0
_configure_ok=0
_configure_fail=0
log_step() { echo -e " ${GREEN}✓${NC} $1" | tee -a "$CONFIGURE_LOG"; _configure_ok=$((_configure_ok + 1)); _configure_total=$((_configure_total + 1)); }
log_step_fail() { echo -e " ${RED}✗${NC} $1" | tee -a "$CONFIGURE_LOG"; _configure_fail=$((_configure_fail + 1)); _configure_total=$((_configure_total + 1)); }

_wire_critical_fail=0
_wire_optional_fail=0

# Required step: on failure count and continue
run_critical() {
    set +e
    "$@"
    local rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        _wire_critical_fail=$((_wire_critical_fail + 1))
    fi
    return 0
}

# Nice-to-have step: never fails the overall run
run_optional() {
    set +e
    "$@"
    local rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        _wire_optional_fail=$((_wire_optional_fail + 1))
    fi
    return 0
}

# Prompt for custom indexers (fzf TUI)
source "$_lib_dir/fzf-tui.sh"

# --- API helpers ---
source "$_lib_dir/api.sh"

# --- Service configuration modules ---
source "$_lib_dir/arr.sh"
source "$_lib_dir/jellyfin.sh"
source "$_lib_dir/seerr.sh"
source "$_lib_dir/bazarr.sh"

# --- Main ---

echo
_cfg_log_info "Wiring ${APP_DISPLAY_NAME} services..."

# API keys from config.xml (services write these on first start)
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

# Drop key if API never becomes ready so later steps skip that service
if [ -n "$RADARR_API_KEY" ]; then
    if ! wait_for_api "Radarr" "7878" "$RADARR_API_KEY"; then
        _wire_critical_fail=$((_wire_critical_fail + 1))
        RADARR_API_KEY=""
    fi
fi

if [ -n "$SONARR_API_KEY" ]; then
    if ! wait_for_api "Sonarr" "8989" "$SONARR_API_KEY"; then
        _wire_critical_fail=$((_wire_critical_fail + 1))
        SONARR_API_KEY=""
    fi
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

if [ -n "$RADARR_API_KEY" ]; then
    run_critical configure_radarr "$RADARR_API_KEY"
    run_optional add_arr_purge_hook "Radarr" "7878" "$RADARR_API_KEY"
fi

if [ -n "$SONARR_API_KEY" ]; then
    run_critical configure_sonarr "$SONARR_API_KEY"
    run_optional add_arr_purge_hook "Sonarr" "8989" "$SONARR_API_KEY"
fi

if [ -n "$PROWLARR_API_KEY" ]; then
    run_critical configure_prowlarr "$PROWLARR_API_KEY" "$RADARR_API_KEY" "$SONARR_API_KEY"
fi

if [ "${MEDIA_SERVICE:-}" = "jellyfin" ]; then
    run_critical configure_jellyfin
    run_optional configure_jellyfin_notifications
fi

# Bazarr after *arr (+ Jellyfin key when available): auto-subs for Sonarr/Radarr library
if [ -n "$RADARR_API_KEY" ] || [ -n "$SONARR_API_KEY" ]; then
    run_optional configure_subtitle_providers
    run_critical configure_bazarr
fi

# Recyclarr before Seerr (profiles must exist for Seerr defaults)
run_critical configure_recyclarr

if [ -n "$RADARR_API_KEY" ]; then
    run_critical relax_quality_sizes "Radarr" "7878" "$RADARR_API_KEY"
    run_critical set_default_quality_profile "Radarr" "7878" "$RADARR_API_KEY" "lookup_radarr_profile"
fi
if [ -n "$SONARR_API_KEY" ]; then
    run_critical relax_quality_sizes "Sonarr" "8989" "$SONARR_API_KEY"
    run_critical set_default_quality_profile "Sonarr" "8989" "$SONARR_API_KEY" "lookup_sonarr_profile"
fi

# Existing files under media roots → *arr library (so Bazarr/Seerr see them)
if [ -n "$RADARR_API_KEY" ]; then
    run_optional import_radarr_existing_media "$RADARR_API_KEY"
fi
if [ -n "$SONARR_API_KEY" ]; then
    run_optional import_sonarr_existing_media "$SONARR_API_KEY"
fi
# After imports, pull *arr library into Bazarr
run_optional trigger_bazarr_library_sync

run_critical configure_seerr

echo
if [ "$_wire_critical_fail" -gt 0 ]; then
    echo -e "  ${RED}Wiring failed: ${_wire_critical_fail} required step(s)${NC}" | tee -a "$CONFIGURE_LOG"
    if [ "$_configure_ok" -gt 0 ] || [ "$_configure_fail" -gt 0 ]; then
        echo -e "  ${YELLOW}${_configure_ok} ok, ${_configure_fail} failed (see markers above)${NC}" | tee -a "$CONFIGURE_LOG"
    fi
    echo -e "  ${YELLOW}Log: $CONFIGURE_LOG${NC}" | tee -a "$CONFIGURE_LOG"
    echo
    _cfg_log_info "Fix issues, then re-run: ${APP_CLI_NAME:-assemblrr} config apply"
    echo
    exit 1
fi

if [ "$_configure_fail" -gt 0 ] || [ "$_wire_optional_fail" -gt 0 ]; then
    echo -e "  ${GREEN}Required wiring succeeded${NC}" | tee -a "$CONFIGURE_LOG"
    echo -e "  ${YELLOW}Some optional steps had issues — log: $CONFIGURE_LOG${NC}" | tee -a "$CONFIGURE_LOG"
    echo
else
    echo -e "  ${GREEN}All ${_configure_ok} steps succeeded${NC}" | tee -a "$CONFIGURE_LOG"
    echo
fi

_cfg_log_info "Next steps:"
if [ "${MEDIA_SERVICE:-}" = "jellyfin" ]; then
    _cfg_log_info "  1. Open Jellyfin at http://${API_HOST}:8096"
    _cfg_log_info "  2. Open Seerr at http://${API_HOST}:5055 and request a movie"
    _cfg_log_info "  3. It will download via qBittorrent; Bazarr grabs subtitles; Jellyfin shows both"
    _cfg_log_info "  4. Bazarr UI: http://${API_HOST}:6767"
else
    _cfg_log_info "  1. Open Seerr at http://${API_HOST}:5055"
    _cfg_log_info "  2. Request a movie — it will download automatically via qBittorrent"
    _cfg_log_info "  3. Bazarr downloads subtitles alongside media (http://${API_HOST}:6767)"
    _cfg_log_info "  4. Your media service will pick up video + sidecar subs from your media folder"
fi
echo
if [ -n "$AUTH_USERNAME" ]; then
    _cfg_log_info "Login credentials: $AUTH_USERNAME / (the password you set during setup)"
fi

exit 0
