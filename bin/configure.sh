#!/bin/bash
set -euo pipefail

# assemblrr Service Auto-Configuration
# Configures Radarr, Prowlarr, and related services after initial deployment
# Called by setup.sh after containers start, or via: assemblrr configure
# Uses jq for JSON parsing

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

# Track step counts for end-of-run summary
_configure_total=0
_configure_ok=0
_configure_fail=0
log_step() { echo -e " ${GREEN}✓${NC} $1" | tee -a "$CONFIGURE_LOG"; _configure_ok=$((_configure_ok + 1)); _configure_total=$((_configure_total + 1)); }
log_step_fail() { echo -e " ${RED}✗${NC} $1" | tee -a "$CONFIGURE_LOG"; _configure_fail=$((_configure_fail + 1)); _configure_total=$((_configure_total + 1)); }

# Prompt for custom indexers (fzf TUI)
source "$_lib_dir/fzf-tui.sh"

# --- API helpers ---
source "$_lib_dir/api.sh"

# --- Service configuration modules ---
source "$_lib_dir/arr.sh"
source "$_lib_dir/jellyfin.sh"
source "$_lib_dir/seerr.sh"

# --- Main ---

echo
_cfg_log_info "Auto-configuring ${APP_DISPLAY_NAME} services..."
echo

# Read API keys from config.xml (created by services on first start)
RADARR_API_KEY=$(read_api_key "radarr") || RADARR_API_KEY=""
SONARR_API_KEY=$(read_api_key "sonarr") || SONARR_API_KEY=""
PROWLARR_API_KEY=$(read_api_key "prowlarr") || PROWLARR_API_KEY=""

if [ -z "$RADARR_API_KEY" ]; then
    log_step_fail "Cannot read Radarr API key — skipping Radarr configuration"
fi

if [ -z "$SONARR_API_KEY" ]; then
    log_step_fail "Cannot read Sonarr API key — skipping Sonarr configuration"
fi

if [ -z "$PROWLARR_API_KEY" ]; then
    log_step_fail "Cannot read Prowlarr API key — skipping Prowlarr configuration"
fi

# Wait for APIs to be fully ready
if [ -n "$RADARR_API_KEY" ]; then
    wait_for_api "Radarr" "7878" "$RADARR_API_KEY" || true
fi

if [ -n "$SONARR_API_KEY" ]; then
    wait_for_api "Sonarr" "8989" "$SONARR_API_KEY" || true
fi

if [ -n "$PROWLARR_API_KEY" ]; then
    wait_for_api "Prowlarr" "9696" "$PROWLARR_API_KEY" "/api/v1/system/status" || true
    configure_indexers "$PROWLARR_API_KEY"
fi

# Set qBittorrent credentials once (before configuring any *arr service)
if [ -n "$RADARR_API_KEY" ] || [ -n "$SONARR_API_KEY" ]; then
    qbit_set_credentials || true
fi

# Configure services
if [ -n "$RADARR_API_KEY" ]; then
    configure_radarr "$RADARR_API_KEY" || true
fi

if [ -n "$SONARR_API_KEY" ]; then
    configure_sonarr "$SONARR_API_KEY" || true
fi

if [ -n "$PROWLARR_API_KEY" ]; then
    configure_prowlarr "$PROWLARR_API_KEY" "$RADARR_API_KEY" "$SONARR_API_KEY" || true
fi

if [ "${MEDIA_SERVICE:-}" = "jellyfin" ]; then
    configure_jellyfin || true
    configure_jellyfin_notifications || true
fi

# Configure Recyclarr (must run before Seerr so quality profiles exist in Radarr/Sonarr)
configure_recyclarr || true

# Enforce minSize=0 and record preferred quality profiles after Recyclarr sync.
if [ -n "$RADARR_API_KEY" ]; then
    relax_quality_sizes "Radarr" "7878" "$RADARR_API_KEY" || true
    set_default_quality_profile "Radarr" "7878" "$RADARR_API_KEY" "lookup_radarr_profile" || true
fi
if [ -n "$SONARR_API_KEY" ]; then
    relax_quality_sizes "Sonarr" "8989" "$SONARR_API_KEY" || true
    set_default_quality_profile "Sonarr" "8989" "$SONARR_API_KEY" "lookup_sonarr_profile" || true
fi

# Configure Seerr (must run after media server is configured AND Recyclarr has synced profiles)
configure_seerr || true

# Show compact summary
if [ "${_configure_fail:-0}" -gt 0 ]; then
    echo
    echo -e "  ${YELLOW}${_configure_ok} succeeded, ${_configure_fail} failed${NC}"
    echo -e "  ${YELLOW}Details: $CONFIGURE_LOG${NC}"
    echo
else
    echo
    echo -e "  ${GREEN}All ${_configure_ok} steps succeeded${NC}"
    echo
fi

_cfg_log_info "Next steps:"
if [ "${MEDIA_SERVICE:-}" = "jellyfin" ]; then
    _cfg_log_info "  1. Open Jellyfin at http://${API_HOST}:8096"
    _cfg_log_info "  2. Open Seerr at http://${API_HOST}:5055 and request a movie"
    _cfg_log_info "  3. It will download automatically via qBittorrent and appear in Jellyfin"
else
    _cfg_log_info "  1. Open Seerr at http://${API_HOST}:5055"
    _cfg_log_info "  2. Request a movie — it will download automatically via qBittorrent"
    _cfg_log_info "  3. Your media service will pick it up from your media folder"
fi
echo
if [ -n "$AUTH_USERNAME" ]; then
    _cfg_log_info "Login credentials: $AUTH_USERNAME / (the password you set during setup)"
fi
