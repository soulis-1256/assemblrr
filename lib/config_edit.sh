#!/bin/bash
# Modular config edit — shared prompt/picker engines, post-install copy.
# Sourced by the CLI. Does not run on source.
# Provides: config_edit_run, config_edit_usage, config_edit_section_ids, config_set_kv

if [ -n "${_ASSEMBLRR_CONFIG_EDIT_SOURCED:-}" ]; then
    return 0
fi
readonly _ASSEMBLRR_CONFIG_EDIT_SOURCED=1

_config_edit_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[ -f "$_config_edit_dir/ui.sh" ] && source "$_config_edit_dir/ui.sh"

# id|description
_config_edit_catalog() {
    cat <<'EOF'
indexers|Prowlarr indexers
providers|Bazarr subtitle providers
language|Preferred subtitle language
profile|Default movie quality (Radarr + Seerr)
opensubtitles|OpenSubtitles.com credentials
auth|Shared login for every service UI
timezone|Container timezone
vpn|VPN on/off, provider, and credentials (restarts stack)
media|Jellyfin (supported) / Emby / Plex unsupported (restarts stack)
all|Re-run the full setup wizard
EOF
}

config_edit_section_ids() {
    _config_edit_catalog | cut -d'|' -f1
}

config_edit_usage() {
    local cli="${APP_CLI_NAME:-assemblrr}"
    echo "Usage: ${cli} config edit"
    echo
    echo "Opens a picker. Choose what to change there."
    echo
    echo "In the picker:"
    local id desc
    while IFS='|' read -r id desc; do
        [ -z "$id" ] && continue
        printf "  %-14s %s\n" "$id" "$desc"
    done < <(_config_edit_catalog)
}

# Resolve picker output to a catalog id. Empty → "".
config_edit_resolve() {
    local want="${1:-}"
    want=$(echo "$want" | tr '[:upper:]' '[:lower:]')
    [ -z "$want" ] && return 1
    local id
    while IFS='|' read -r id _; do
        [ -z "$id" ] && continue
        if [ "$want" = "$id" ]; then
            echo "$id"
            return 0
        fi
    done < <(_config_edit_catalog)
    return 1
}

# Update or append KEY=value in a dotenv / runtime-config file.
# $4 = quoted (1, default) writes KEY="value"; 0 writes KEY=value
config_set_kv() {
    local file="$1"
    local key="$2"
    local value="$3"
    local quoted="${4:-1}"
    local tmp line_out

    [ -n "$file" ] && [ -n "$key" ] || return 1
    mkdir -p "$(dirname "$file")"
    tmp=$(mktemp)
    if [ -f "$file" ]; then
        grep -v "^${key}=" "$file" > "$tmp" || true
    fi
    if [ "$quoted" = "1" ]; then
        printf '%s="%s"\n' "$key" "$value" >> "$tmp"
    else
        printf '%s=%s\n' "$key" "$value" >> "$tmp"
    fi
    mv "$tmp" "$file"
}

# --- load install + *arr libs (idempotent) ---

_config_edit_loaded=0

_config_edit_load() {
    if [ "${_config_edit_loaded}" = "1" ]; then
        return 0
    fi

    if [ -z "${INSTALL_DIR:-}" ] || [ ! -d "$INSTALL_DIR" ]; then
        log_error "Could not find installation. Run setup first."
    fi

    safe_source "$INSTALL_DIR/.assemblrr-config"
    if [ -f "$INSTALL_DIR/.env" ]; then
        set -a
        safe_source "$INSTALL_DIR/.env"
        set +a
    fi
    load_branding "$INSTALL_DIR" 2>/dev/null || true

    API_HOST="${API_HOST:-127.0.0.1}"
    RADARR_DOCKER_URL="${RADARR_DOCKER_URL:-http://radarr:7878}"
    SONARR_DOCKER_URL="${SONARR_DOCKER_URL:-http://sonarr:8989}"
    PROWLARR_DOCKER_URL="${PROWLARR_DOCKER_URL:-http://prowlarr:9696}"
    if [ "${VPN_ENABLED:-n}" = "y" ]; then
        QBITTORRENT_HOST="${QBITTORRENT_HOST:-gluetun}"
    else
        QBITTORRENT_HOST="${QBITTORRENT_HOST:-qbittorrent}"
    fi
    AUTH_USERNAME=$(cat "$INSTALL_DIR/secrets/auth_username.txt" 2>/dev/null || echo "${AUTH_USERNAME:-$USER}")
    AUTH_PASSWORD=$(cat "$INSTALL_DIR/secrets/auth_password.txt" 2>/dev/null || echo "${AUTH_PASSWORD:-}")

    # Section editors always use the interactive prompts, never express defaults.
    ui_set_mode edit
    SETUP_MODE="manual"
    if [ -z "${SUPPORTED_MEDIA_SERVICES+x}" ]; then
        SUPPORTED_MEDIA_SERVICES=("jellyfin" "emby" "plex")
    fi

    CONFIGURE_LOG="${CONFIGURE_LOG:-/tmp/${APP_NAME:-assemblrr}-config-edit-$(date '+%Y%m%d-%H%M%S').log}"
    if ! type _cfg_log_info >/dev/null 2>&1; then
        _cfg_log_info() { echo "  $1" | tee -a "$CONFIGURE_LOG"; }
    fi
    if ! type log_step >/dev/null 2>&1; then
        _configure_total=0
        _configure_ok=0
        _configure_fail=0
        log_step() { echo -e " ${GREEN}✓${NC} $1" | tee -a "$CONFIGURE_LOG"; _configure_ok=$((_configure_ok + 1)); _configure_total=$((_configure_total + 1)); }
        log_step_fail() { echo -e " ${RED}✗${NC} $1" | tee -a "$CONFIGURE_LOG"; _configure_fail=$((_configure_fail + 1)); _configure_total=$((_configure_total + 1)); }
    fi

    local lib="${INSTALL_DIR}/lib"
    # shellcheck source=/dev/null
    [ -f "$lib/ui.sh" ] && source "$lib/ui.sh"
    # shellcheck source=/dev/null
    [ -f "$lib/fzf-tui.sh" ] && source "$lib/fzf-tui.sh"
    # shellcheck source=/dev/null
    [ -f "$lib/api.sh" ] && source "$lib/api.sh"
    # shellcheck source=/dev/null
    [ -f "$lib/arr.sh" ] && source "$lib/arr.sh"
    # shellcheck source=/dev/null
    [ -f "$lib/jellyfin.sh" ] && source "$lib/jellyfin.sh"
    # shellcheck source=/dev/null
    [ -f "$lib/seerr.sh" ] && source "$lib/seerr.sh"
    # shellcheck source=/dev/null
    [ -f "$lib/bazarr.sh" ] && source "$lib/bazarr.sh"
    # shellcheck source=/dev/null
    [ -f "$lib/prompts.sh" ] && source "$lib/prompts.sh"

    _config_edit_load_keys
    _config_edit_loaded=1
}

_config_edit_load_keys() {
    RADARR_API_KEY="${RADARR_API_KEY:-}"
    SONARR_API_KEY="${SONARR_API_KEY:-}"
    PROWLARR_API_KEY="${PROWLARR_API_KEY:-}"
    if [ -z "$RADARR_API_KEY" ] && type read_api_key >/dev/null 2>&1; then
        RADARR_API_KEY=$(read_api_key "radarr" 2>/dev/null || echo "")
    fi
    if [ -z "$SONARR_API_KEY" ] && type read_api_key >/dev/null 2>&1; then
        SONARR_API_KEY=$(read_api_key "sonarr" 2>/dev/null || echo "")
    fi
    if [ -z "$PROWLARR_API_KEY" ] && type read_api_key >/dev/null 2>&1; then
        PROWLARR_API_KEY=$(read_api_key "prowlarr" 2>/dev/null || echo "")
    fi
}

_config_edit_runtime_file() {
    echo "$INSTALL_DIR/.${APP_NAME:-assemblrr}-config"
}

_config_edit_restart_stack() {
    log_info "Restarting stack to apply compose/env changes..."
    build_compose_args "$INSTALL_DIR" "${VPN_ENABLED:-n}"
    if ! run_docker compose "${COMPOSE_ARGS[@]}" --profile "${MEDIA_SERVICE:-jellyfin}" up -d --remove-orphans; then
        log_error "docker compose up failed"
    fi
    log_success "Stack restarted"
}

_config_edit_pick() {
    local data selected
    data=$(_config_edit_catalog | awk -F'|' '{printf "%s\t%s\n", $1, $2}')
    if type _fzf_can_render >/dev/null 2>&1 && _fzf_can_render && _fzf_has_tty; then
        selected=$(echo "$data" | fzf \
            --prompt="Edit which setting> " \
            --delimiter='\t' \
            --with-nth=1,2 \
            --header='↑↓=navigate  Enter=confirm  Esc=cancel' \
            --height=60% \
            --layout=reverse \
            --border \
            2>/dev/null | cut -f1 || true)
        echo "$selected"
        return 0
    fi
    echo
    log_info "What do you want to change?"
    local i=1 id desc
    while IFS='|' read -r id desc; do
        printf "  %2d) %-14s %s\n" "$i" "$id" "$desc"
        i=$((i + 1))
    done < <(_config_edit_catalog)
    local choice
    read -p "Choose a section [1]: " choice || true
    choice=${choice:-1}
    if [[ "$choice" =~ ^[0-9]+$ ]]; then
        sed -n "${choice}p" < <(config_edit_section_ids)
        return 0
    fi
    echo "$choice"
}

# --- section appliers ---

_config_edit_indexers() {
    _config_edit_load
    if [ -z "${PROWLARR_API_KEY:-}" ]; then
        log_error "Prowlarr API key not available. Is Prowlarr running?"
    fi
    if ! wait_for_api "Prowlarr" "9696" "$PROWLARR_API_KEY" "/api/v1/system/status"; then
        log_error "Prowlarr is not responding on port 9696"
    fi
    SELECTED_INDEXERS=()
    configure_indexers "$PROWLARR_API_KEY"
    if ui_picker_cancelled; then
        return 0
    fi
    if [ "${#SELECTED_INDEXERS[@]}" -eq 0 ]; then
        local wipe="n"
        if [ -t 0 ] && [ "${ASSEMBLRR_NONINTERACTIVE:-0}" != "1" ]; then
            echo
            log_warning "No indexers selected."
            read -p "Remove ALL Prowlarr indexers? (y/N) [Default = n]: " wipe
            wipe=${wipe:-n}
        fi
        if [ "${wipe,,}" != "y" ]; then
            log_info "Leaving Prowlarr indexers unchanged."
            return 0
        fi
    fi
    sync_selected_indexers "$PROWLARR_API_KEY"
    wait_for_arr_indexer_sync "$RADARR_API_KEY" || true
    arr_set_indexer_min_seeders "Radarr" "7878" "$RADARR_API_KEY" || true
    arr_set_indexer_min_seeders "Sonarr" "8989" "$SONARR_API_KEY" || true
}

_config_edit_providers() {
    _config_edit_load
    SELECTED_SUBTITLE_PROVIDERS=()
    configure_subtitle_providers
    if ui_picker_cancelled; then
        return 0
    fi
    if [ "${#SELECTED_SUBTITLE_PROVIDERS[@]}" -eq 0 ]; then
        local wipe="n"
        if [ -t 0 ] && [ "${ASSEMBLRR_NONINTERACTIVE:-0}" != "1" ]; then
            echo
            log_warning "No subtitle providers selected."
            read -p "Disable ALL Bazarr providers? (y/N) [Default = n]: " wipe
            wipe=${wipe:-n}
        fi
        if [ "${wipe,,}" != "y" ]; then
            log_info "Leaving Bazarr providers unchanged."
            return 0
        fi
    fi
    configure_bazarr
}

_config_edit_language() {
    _config_edit_load
    configure_subtitle_language
    config_set_kv "$(_config_edit_runtime_file)" "SUBTITLE_LANGUAGE" "${subtitle_language:-}"
    SUBTITLE_LANGUAGE="${subtitle_language:-}"
    configure_bazarr || true
    if [ "${MEDIA_SERVICE:-}" = "jellyfin" ]; then
        configure_jellyfin || true
    fi
}

_config_edit_profile() {
    _config_edit_load
    configure_seerr_profile
    config_set_kv "$(_config_edit_runtime_file)" "SEERR_DEFAULT_PROFILE" "${seerr_default_profile:-1}"
    config_set_kv "$(_config_edit_runtime_file)" "SEERR_IS_4K" "${seerr_is_4k:-false}"
    SEERR_DEFAULT_PROFILE="${seerr_default_profile:-1}"
    SEERR_IS_4K="${seerr_is_4k:-false}"
    if [ -n "${RADARR_API_KEY:-}" ]; then
        set_default_quality_profile "Radarr" "7878" "$RADARR_API_KEY" "lookup_radarr_profile" || true
    fi
    if [ -n "${SONARR_API_KEY:-}" ]; then
        set_default_quality_profile "Sonarr" "8989" "$SONARR_API_KEY" "lookup_sonarr_profile" || true
    fi
    configure_seerr || true
}

_config_edit_opensubtitles() {
    _config_edit_load
    configure_opensubtitles
    local secrets_dir="$INSTALL_DIR/secrets"
    mkdir -p "$secrets_dir"
    if [ "${opensubtitles_enabled:-n}" = "y" ] && [ -n "${opensubtitles_username:-}" ]; then
        echo -n "${opensubtitles_username}" > "$secrets_dir/opensubtitles_username.txt"
        echo -n "${opensubtitles_password:-}" > "$secrets_dir/opensubtitles_password.txt"
        chmod 600 "$secrets_dir/opensubtitles_username.txt" "$secrets_dir/opensubtitles_password.txt"
        log_success "OpenSubtitles.com credentials written to $secrets_dir"
    else
        rm -f "$secrets_dir/opensubtitles_username.txt" "$secrets_dir/opensubtitles_password.txt" 2>/dev/null || true
        log_info "OpenSubtitles.com credentials cleared"
    fi
    configure_bazarr || true
}

_config_edit_auth() {
    _config_edit_load
    local old_user old_pass
    old_user=$(cat "$INSTALL_DIR/secrets/auth_username.txt" 2>/dev/null || echo "${AUTH_USERNAME:-}")
    old_pass=$(cat "$INSTALL_DIR/secrets/auth_password.txt" 2>/dev/null || echo "${AUTH_PASSWORD:-}")

    configure_auth
    local secrets_dir="$INSTALL_DIR/secrets"
    AUTH_USERNAME="${auth_username:-admin}"
    AUTH_PASSWORD="${auth_password:-}"

    local fail=0
    qbit_change_credentials "$old_user" "$old_pass" "$AUTH_USERNAME" "$AUTH_PASSWORD" || fail=1
    if [ -n "${RADARR_API_KEY:-}" ]; then
        set_arr_auth "Radarr" "7878" "$RADARR_API_KEY" "v3" || fail=1
    else
        log_step_fail "Radarr: no API key — skipped"
        fail=1
    fi
    if [ -n "${SONARR_API_KEY:-}" ]; then
        set_arr_auth "Sonarr" "8989" "$SONARR_API_KEY" "v3" || fail=1
    else
        log_step_fail "Sonarr: no API key — skipped"
        fail=1
    fi
    if [ -n "${PROWLARR_API_KEY:-}" ]; then
        set_arr_auth "Prowlarr" "9696" "$PROWLARR_API_KEY" "v1" || fail=1
    else
        log_step_fail "Prowlarr: no API key — skipped"
        fail=1
    fi

    case "${MEDIA_SERVICE:-jellyfin}" in
        jellyfin)
            jellyfin_change_credentials "$old_user" "$old_pass" "$AUTH_USERNAME" "$AUTH_PASSWORD" || fail=1
            ;;
        emby)
            jellyfin_change_credentials "$old_user" "$old_pass" "$AUTH_USERNAME" "$AUTH_PASSWORD" 8096 "Emby" || fail=1
            ;;
        plex)
            log_warning "Plex account password is not this login — change it in Plex."
            ;;
    esac

    bazarr_set_auth || fail=1

    if [ "${MEDIA_SERVICE:-jellyfin}" = "jellyfin" ] || [ "${MEDIA_SERVICE:-}" = "emby" ]; then
        if type seerr_verify_login >/dev/null 2>&1; then
            seerr_verify_login || true
        fi
    fi

    if [ "$fail" -ne 0 ]; then
        log_warning "Some UIs did not take the new password. Secrets were left unchanged. Run ${APP_CLI_NAME:-assemblrr} config edit and pick login again (same password)."
        return 1
    fi

    mkdir -p "$secrets_dir"
    echo -n "$AUTH_USERNAME" > "$secrets_dir/auth_username.txt"
    echo -n "$AUTH_PASSWORD" > "$secrets_dir/auth_password.txt"
    chmod 600 "$secrets_dir/auth_username.txt" "$secrets_dir/auth_password.txt"
    log_success "Auth credentials written to $secrets_dir"
}

_config_edit_timezone() {
    _config_edit_load
    configure_timezone
    config_set_kv "$(_config_edit_runtime_file)" "TZ" "${tz:-UTC}"
    config_set_kv "$INSTALL_DIR/.env" "TZ" "${tz:-UTC}" 0
    TZ="${tz:-UTC}"
    _config_edit_restart_stack
}

_config_edit_vpn() {
    _config_edit_load
    configure_vpn
    local enabled="n"
    [ "${setup_vpn,,}" = "y" ] && enabled="y"
    VPN_ENABLED="$enabled"
    VPN_TYPE="${vpn_type:-openvpn}"
    VPN_SERVICE="${vpn_service:-}"
    config_set_kv "$(_config_edit_runtime_file)" "VPN_ENABLED" "$VPN_ENABLED"
    config_set_kv "$(_config_edit_runtime_file)" "VPN_TYPE" "$VPN_TYPE"
    config_set_kv "$INSTALL_DIR/.env" "VPN_ENABLED" "$VPN_ENABLED" 0
    config_set_kv "$INSTALL_DIR/.env" "VPN_TYPE" "$VPN_TYPE" 0
    config_set_kv "$INSTALL_DIR/.env" "VPN_SERVICE" "$VPN_SERVICE" 0
    config_set_kv "$INSTALL_DIR/.env" "WIREGUARD_ADDRESSES" "${wireguard_addresses:-}" 0
    if [ "${enable_port_forwarding:-n}" = "y" ]; then
        config_set_kv "$INSTALL_DIR/.env" "PORT_FORWARD_ONLY" "on" 0
        config_set_kv "$INSTALL_DIR/.env" "VPN_PORT_FORWARDING" "on" 0
    else
        config_set_kv "$INSTALL_DIR/.env" "PORT_FORWARD_ONLY" "off" 0
        config_set_kv "$INSTALL_DIR/.env" "VPN_PORT_FORWARDING" "off" 0
    fi

    local secrets_dir="$INSTALL_DIR/secrets"
    mkdir -p "$secrets_dir"
    if [ "$enabled" = "y" ]; then
        if [ "${vpn_type:-}" = "openvpn" ]; then
            echo -n "${vpn_user:-}" > "$secrets_dir/openvpn_user.txt"
            echo -n "${vpn_password:-}" > "$secrets_dir/openvpn_password.txt"
            : > "$secrets_dir/wireguard_private_key.txt"
        else
            echo -n "${wireguard_private_key:-}" > "$secrets_dir/wireguard_private_key.txt"
            : > "$secrets_dir/openvpn_user.txt"
            : > "$secrets_dir/openvpn_password.txt"
        fi
        chmod 600 \
            "$secrets_dir/openvpn_user.txt" \
            "$secrets_dir/openvpn_password.txt" \
            "$secrets_dir/wireguard_private_key.txt" \
            2>/dev/null || true
        log_success "VPN secrets written to $secrets_dir"
    fi
    if [ "${VPN_ENABLED:-n}" = "y" ]; then
        QBITTORRENT_HOST="gluetun"
    else
        QBITTORRENT_HOST="qbittorrent"
    fi
    _config_edit_restart_stack
    qbit_set_credentials || true
    if [ -n "${RADARR_API_KEY:-}" ]; then
        wait_for_api "Radarr" "7878" "$RADARR_API_KEY" || true
        arr_update_qb_host "Radarr" "7878" "$RADARR_API_KEY" || true
    fi
    if [ -n "${SONARR_API_KEY:-}" ]; then
        wait_for_api "Sonarr" "8989" "$SONARR_API_KEY" || true
        arr_update_qb_host "Sonarr" "8989" "$SONARR_API_KEY" || true
    fi
}

_config_edit_media() {
    _config_edit_load
    local previous="${MEDIA_SERVICE:-jellyfin}"
    configure_media_service
    MEDIA_SERVICE="$media_service"
    config_set_kv "$(_config_edit_runtime_file)" "MEDIA_SERVICE" "$MEDIA_SERVICE"
    config_set_kv "$INSTALL_DIR/.env" "MEDIA_SERVICE" "$MEDIA_SERVICE" 0
    _config_edit_restart_stack
    if [ "$MEDIA_SERVICE" = "jellyfin" ]; then
        configure_jellyfin || true
        configure_jellyfin_notifications || true
    elif [ "$previous" != "$MEDIA_SERVICE" ]; then
        log_info "Switched media server to ${MEDIA_SERVICE}. Finish any first-run UI setup, then run: ${APP_CLI_NAME:-assemblrr} config apply"
    fi
}

_config_edit_all() {
    ui_set_mode setup
    echo "Re-running ${APP_DISPLAY_NAME:-assemblrr} setup wizard..."
    echo "Current configuration will be used as defaults."
    echo
    local setup_script
    if [ -f "$INSTALL_DIR/setup.sh" ]; then
        setup_script="$INSTALL_DIR/setup.sh"
    else
        log_error "setup.sh not found in $INSTALL_DIR"
    fi
    bash "$setup_script"
}

_config_edit_load_picker() {
    local lib="${INSTALL_DIR:-}/lib"
    if [ -f "$lib/fzf-tui.sh" ]; then
        # shellcheck source=/dev/null
        source "$lib/fzf-tui.sh"
    elif [ -n "${_lib_dir:-}" ] && [ -f "$_lib_dir/fzf-tui.sh" ]; then
        # shellcheck source=/dev/null
        source "$_lib_dir/fzf-tui.sh"
    fi
}

config_edit_run() {
    local raw="${1:-}"
    local section=""
    ui_set_mode edit

    case "$raw" in
        --help|-h|help)
            config_edit_usage
            return 0
            ;;
        "")
            ;;
        *)
            log_error "Just run '${APP_CLI_NAME:-assemblrr} config edit' and pick from the menu"
            ;;
    esac

    _config_edit_load_picker
    raw=$(_config_edit_pick)
    raw=$(echo "${raw:-}" | head -1 | tr -d '[:space:]')
    if [ -z "$raw" ]; then
        echo "Cancelled."
        return 0
    fi

    if ! section=$(config_edit_resolve "$raw"); then
        log_error "Unknown config section: $raw"
    fi

    case "$section" in
        indexers) _config_edit_indexers ;;
        providers) _config_edit_providers ;;
        language) _config_edit_language ;;
        profile) _config_edit_profile ;;
        opensubtitles) _config_edit_opensubtitles ;;
        auth) _config_edit_auth ;;
        timezone) _config_edit_timezone ;;
        vpn) _config_edit_vpn ;;
        media) _config_edit_media ;;
        all) _config_edit_all ;;
        *) log_error "Unknown config section: $section" ;;
    esac
}
