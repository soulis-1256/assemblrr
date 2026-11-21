#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Modular config edit — shared prompt/picker engines, post-install copy.
# Provides: config_edit_run, config_edit_usage, config_edit_section_ids, config_set_kv
# Does not set -euo pipefail when sourced.

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
language|Subtitle languages (preferred + extras)
profile|Default quality (Radarr, Sonarr, Seerr)
opensubtitles|OpenSubtitles.com username and password
auth|Shared login for every service UI
timezone|Container timezone
vpn|VPN on/off, provider, and credentials (restarts stack)
qbit-ui|qBittorrent WebUI: VueTorrent, qui, or stock (restarts stack)
gpu|Jellyfin hardware GPU transcoding: Intel/AMD or NVIDIA (restarts stack)
byparr|Byparr HTTP solver proxy for Prowlarr (restarts stack)
usenet|SABnzbd Usenet downloader and NNTP provider (restarts stack)
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

config_edit_resolve() {
    local want="${1:-}"
    want=$(echo "$want" | tr '[:upper:]' '[:lower:]')
    [ -z "$want" ] && return 1
    case "$want" in
        vuetorrent|vue|qui) want="qbit-ui" ;;
    esac
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

# Atomically update or append KEY=value in a dotenv / runtime-config file, preserving mode.
# $4 = quoted (1, default) writes KEY="escaped_value"; 0 writes KEY=value
config_set_kv() {
    local file="$1"
    local key="$2"
    local value="$3"
    local quoted="${4:-1}"
    local tmp mode="" escaped

    [ -n "$file" ] && [ -n "$key" ] || return 1
    mkdir -p "$(dirname "$file")"
    if [ -f "$file" ]; then
        mode=$(stat -c '%a' "$file" 2>/dev/null || stat -f '%Lp' "$file" 2>/dev/null || echo "")
    fi
    tmp=$(mktemp)
    if [ -f "$file" ]; then
        grep -v "^${key}=" "$file" > "$tmp" || true
    fi
    if [ "$quoted" = "1" ]; then
        escaped="${value//\\/\\\\}"
        escaped="${escaped//\"/\\\"}"
        printf '%s="%s"\n' "$key" "$escaped" >> "$tmp"
    else
        printf '%s=%s\n' "$key" "$value" >> "$tmp"
    fi
    mv "$tmp" "$file"
    if [ -n "$mode" ]; then
        chmod "$mode" "$file" 2>/dev/null || true
    fi
}

config_unset_kv() {
    local file="$1"
    local key="$2"
    local tmp mode=""

    [ -n "$file" ] && [ -n "$key" ] || return 1
    [ -f "$file" ] || return 0
    mode=$(stat -c '%a' "$file" 2>/dev/null || stat -f '%Lp' "$file" 2>/dev/null || echo "")
    tmp=$(mktemp)
    grep -v "^${key}=" "$file" > "$tmp" || true
    mv "$tmp" "$file"
    if [ -n "$mode" ]; then
        chmod "$mode" "$file" 2>/dev/null || true
    fi
}

# --- load install + *arr libs (idempotent) ---

_config_edit_loaded=0

_config_edit_load() {
    if [ "${_config_edit_loaded}" = "1" ]; then
        return 0
    fi

    if [ -z "${INSTALL_DIR:-}" ] || [ ! -d "$INSTALL_DIR" ]; then
        log_error "Could not find installation. Run setup first."
        return 1
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

    ui_set_mode edit
    SETUP_MODE="manual"
    SUPPORTED_MEDIA_SERVICES=("jellyfin")

    CONFIGURE_LOG="${CONFIGURE_LOG:-/tmp/${APP_NAME:-assemblrr}-config-edit-$(date '+%Y%m%d-%H%M%S').log}"
    if ! type _cfg_log_info >/dev/null 2>&1; then
        # shellcheck disable=SC2329
        _cfg_log_info() { echo "  $1" | tee -a "$CONFIGURE_LOG"; }
    fi
    if ! type log_step >/dev/null 2>&1; then
        _configure_total=0
        _configure_ok=0
        _configure_fail=0
        # shellcheck disable=SC2329
        log_step() { printf ' %b✓%b %s\n' "${GREEN:-}" "${NC:-}" "$1"; printf ' ✓ %s\n' "$1" >> "$CONFIGURE_LOG"; _configure_ok=$((_configure_ok + 1)); _configure_total=$((_configure_total + 1)); }
        # shellcheck disable=SC2329
        log_step_warn() { printf ' %b⚠%b %s\n' "${YELLOW:-}" "${NC:-}" "$1"; printf ' ⚠ %s\n' "$1" >> "$CONFIGURE_LOG"; _configure_ok=$((_configure_ok + 1)); _configure_total=$((_configure_total + 1)); }
        # shellcheck disable=SC2329
        log_step_fail() { printf ' %b✗%b %s\n' "${RED:-}" "${NC:-}" "$1"; printf ' ✗ %s\n' "$1" >> "$CONFIGURE_LOG"; _configure_fail=$((_configure_fail + 1)); _configure_total=$((_configure_total + 1)); }
    fi

    local lib="${INSTALL_DIR}/lib"
    local m
    for m in ui.sh fzf-tui.sh api.sh quality.sh arr.sh recyclarr.sh jellyfin.sh seerr.sh bazarr.sh usenet.sh prompts.sh; do
        # shellcheck source=/dev/null
        [ -f "$lib/$m" ] && source "$lib/$m"
    done

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
    if ! compose_up_stack "default"; then
        log_error "docker compose up failed"
        return 1
    fi
    log_success "Stack restarted"
}

_config_edit_kv() {
    local key="$1" f_main="$2" envf="$3"
    local v=""
    [ -n "$f_main" ] && [ -f "$f_main" ] && v=$(_pointer_get "$f_main" "$key")
    [ -z "$v" ] && [ -n "$envf" ] && [ -f "$envf" ] && v=$(_pointer_get "$envf" "$key")
    printf '%s' "$v"
}

_config_edit_current_status() {
    local id="$1"
    local inst="${INSTALL_DIR:-}"
    [ -n "$inst" ] && [ -d "$inst" ] || return 0
    local cfg="" envf="$inst/.env"
    [ -f "$inst/.assemblrr-config" ] && cfg="$inst/.assemblrr-config"
    [ -z "$cfg" ] && [ -f "$inst/.${APP_NAME:-assemblrr}-config" ] && cfg="$inst/.${APP_NAME:-assemblrr}-config"
    local f_main="${cfg:-$envf}"

    local val="" val2=""
    case "$id" in
        qbit-ui)
            val=$(_config_edit_kv "QBIT_UI" "$f_main" "$envf")
            if [ -z "$val" ]; then
                val2=$(_config_edit_kv "VUETORRENT_ENABLED" "$f_main" "$envf")
                case "${val2,,}" in
                    y|yes) val="vuetorrent" ;;
                    *) val="stock" ;;
                esac
            fi
            case "${val,,}" in
                vuetorrent|vue) echo "on|vuetorrent" ;;
                qui) echo "on|qui" ;;
                *) echo "off|stock" ;;
            esac
            ;;
        gpu)
            val=$(_config_edit_kv "GPU_TRANSCODING" "$f_main" "$envf")
            val="${val:-none}"
            case "${val,,}" in
                ""|none) echo "off|none" ;;
                *) echo "on|${val}" ;;
            esac
            ;;
        byparr)
            val=$(_config_edit_kv "BYPARR_ENABLED" "$f_main" "$envf")
            case "${val,,}" in
                y|yes) echo "on|on" ;;
                *) echo "off|off" ;;
            esac
            ;;
        usenet)
            val=$(_config_edit_kv "USENET_ENABLED" "$f_main" "$envf")
            case "${val,,}" in
                y|yes)
                    val2=$(_config_edit_kv "USENET_HOST" "$f_main" "$envf")
                    if [ -n "$val2" ]; then
                        echo "on|on · ${val2}"
                    else
                        echo "on|on"
                    fi
                    ;;
                *) echo "off|off" ;;
            esac
            ;;
        vpn)
            val=$(_config_edit_kv "VPN_ENABLED" "$f_main" "$envf")
            case "${val,,}" in
                y|yes)
                    val2=$(_config_edit_kv "VPN_SERVICE" "$f_main" "$envf")
                    if [ -n "$val2" ]; then
                        echo "on|on · ${val2}"
                    else
                        echo "on|on"
                    fi
                    ;;
                *) echo "off|off" ;;
            esac
            ;;
        profile)
            val=$(_config_edit_kv "QUALITY_TIER" "$f_main" "$envf")
            val2=$(_config_edit_kv "QUALITY_SOURCE" "$f_main" "$envf")
            case "${val,,}" in
                uhd) [ "${val2,,}" = "web" ] && echo "on|4K WEB" || echo "on|4K Bluray+WEB" ;;
                hd)  [ "${val2,,}" = "web" ] && echo "on|1080p WEB" || echo "on|1080p Bluray+WEB" ;;
                any) echo "dim|Any" ;;
                *)   echo "dim|default" ;;
            esac
            ;;
        language)
            val=$(_config_edit_kv "SUBTITLE_LANGUAGES" "$f_main" "$envf")
            [ -z "$val" ] && val=$(_config_edit_kv "SUBTITLE_LANGUAGE" "$f_main" "$envf")
            if [ -n "$val" ]; then
                echo "on|${val}"
            else
                echo "dim|default (en)"
            fi
            ;;
        timezone)
            val=$(_config_edit_kv "TZ" "$f_main" "$envf")
            echo "on|${val:-UTC}"
            ;;
        opensubtitles)
            if [ -s "$inst/secrets/opensubtitles_username.txt" ]; then
                val=$(cat "$inst/secrets/opensubtitles_username.txt" 2>/dev/null || true)
                echo "on|set (${val})"
            else
                echo "off|not set"
            fi
            ;;
        auth)
            if [ -s "$inst/secrets/auth_username.txt" ]; then
                val=$(cat "$inst/secrets/auth_username.txt" 2>/dev/null || true)
                echo "on|${val}"
            else
                echo "dim|unset"
            fi
            ;;
        indexers)  echo "dim|in Prowlarr" ;;
        providers) echo "dim|in Bazarr" ;;
        all)       echo "dim|full wizard" ;;
    esac
}

_config_edit_pick() {
    local interactive=0
    if type _fzf_is_interactive >/dev/null 2>&1 && _fzf_is_interactive; then
        interactive=1
    fi

    if [ "$interactive" -eq 1 ]; then
        local data="" id desc st kind label col_id col_st line
        while IFS='|' read -r id desc; do
            [ -z "$id" ] && continue
            st=$(_config_edit_current_status "$id" || true)
            kind="${st%%|*}"
            label="${st#*|}"
            [ "$st" = "$kind" ] && label=""
            col_id=$(_tui_pad_ansi "$id" 14)
            if [ -n "$label" ]; then
                case "$kind" in
                    on)  col_st=$(_tui_pad_ansi "[$label]" 20 "32") ;;
                    *)   col_st=$(_tui_pad_ansi "[$label]" 20 "2") ;;
                esac
            else
                col_st=$(_tui_pad_ansi "" 20)
            fi
            line=$(printf '%s\t%s  %s  %s' "$id" "$col_id" "$col_st" "$desc")
            data+="${line}"$'\n'
        done < <(_config_edit_catalog)

        local selected fzf_rc=0
        selected=$(printf '%s' "$data" | fzf \
            --ansi \
            --prompt="Edit which setting> " \
            --delimiter=$'\t' \
            --with-nth=2 \
            --header='↑↓=navigate  Enter=confirm  Esc=exit' \
            --height=60% \
            --layout=reverse \
            --border \
            2>/dev/null) || fzf_rc=$?
        flush_tty_input
        [ "$fzf_rc" -ne 0 ] && return 0
        printf '%s\n' "$selected" | cut -f1
        return 0
    fi
    # Non-fzf fallback prints all UI/prompts to stderr so stdout returns ONLY the chosen section id
    echo >&2
    log_info "What do you want to change?" >&2
    local i=1 id desc st label tag=""
    while IFS='|' read -r id desc; do
        st=$(_config_edit_current_status "$id" || true)
        label="${st#*|}"
        [ -n "$st" ] && [ "$st" != "$label" ] && tag=" [$label]" || tag=""
        printf "  %2d) %-14s %-18s %s\n" "$i" "$id" "$tag" "$desc" >&2
        i=$((i + 1))
    done < <(_config_edit_catalog)
    local choice=""
    if ! read_prompt "Choose a section [1]: " choice; then
        echo ""
        return 0
    fi
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
        return 1
    fi
    if ! wait_for_api "Prowlarr" "9696" "$PROWLARR_API_KEY" "/api/v1/system/status"; then
        log_error "Prowlarr is not responding on port 9696"
        return 1
    fi
    SELECTED_INDEXERS=()
    configure_indexers "$PROWLARR_API_KEY"
    if ui_picker_cancelled; then
        return "${PROMPT_CANCEL_RC:-2}"
    fi
    if [ "${#SELECTED_INDEXERS[@]}" -eq 0 ]; then
        local wipe="n"
        if [ -t 0 ] && [ "${ASSEMBLRR_NONINTERACTIVE:-0}" != "1" ]; then
            echo
            log_warning "No indexers selected."
            read_prompt "Remove ALL Prowlarr indexers? (y/N) [Default = n]: " wipe || return "${PROMPT_CANCEL_RC:-2}"
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
    [ -n "${RADARR_API_KEY:-}" ] && api_post "7878" "/api/v3/command" "$RADARR_API_KEY" '{"name":"MissingMoviesSearch"}' >/dev/null 2>&1 || true
    [ -n "${SONARR_API_KEY:-}" ] && api_post "8989" "/api/v3/command" "$SONARR_API_KEY" '{"name":"MissingEpisodeSearch"}' >/dev/null 2>&1 || true
}

_config_edit_providers() {
    _config_edit_load
    SELECTED_SUBTITLE_PROVIDERS=()
    configure_subtitle_providers
    if ui_picker_cancelled; then
        return "${PROMPT_CANCEL_RC:-2}"
    fi
    if [ "${#SELECTED_SUBTITLE_PROVIDERS[@]}" -eq 0 ]; then
        local wipe="n"
        if [ -t 0 ] && [ "${ASSEMBLRR_NONINTERACTIVE:-0}" != "1" ]; then
            echo
            log_warning "No subtitle providers selected."
            read_prompt "Disable ALL Bazarr providers? (y/N) [Default = n]: " wipe || return "${PROMPT_CANCEL_RC:-2}"
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
    local rc=0
    configure_subtitle_language || rc=$?
    if [ "$rc" -eq "${PROMPT_CANCEL_RC:-2}" ] || ui_picker_cancelled; then
        return "${PROMPT_CANCEL_RC:-2}"
    fi
    if [ "${subtitle_language:-}" = "${SUBTITLE_LANGUAGE:-}" ] && \
       [ "${subtitle_languages:-}" = "${SUBTITLE_LANGUAGES:-}" ]; then
        log_info "Subtitle languages unchanged."
        return 0
    fi
    config_set_kv "$(_config_edit_runtime_file)" "SUBTITLE_LANGUAGE" "${subtitle_language:-}"
    config_set_kv "$(_config_edit_runtime_file)" "SUBTITLE_LANGUAGES" "${subtitle_languages:-}"
    SUBTITLE_LANGUAGE="${subtitle_language:-}"
    SUBTITLE_LANGUAGES="${subtitle_languages:-}"
    configure_bazarr || true
    configure_jellyfin || true
}

_config_edit_profile() {
    _config_edit_load
    local prev_tier="${QUALITY_TIER:-}" prev_source="${QUALITY_SOURCE:-}"
    configure_quality_profile || return $?
    quality_sync_exports
    if [ "$QUALITY_TIER" = "$prev_tier" ] && [ "$QUALITY_SOURCE" = "$prev_source" ]; then
        log_info "Quality profile unchanged."
        return 0
    fi
    config_set_kv "$(_config_edit_runtime_file)" "QUALITY_TIER" "$QUALITY_TIER"
    config_set_kv "$(_config_edit_runtime_file)" "QUALITY_SOURCE" "$QUALITY_SOURCE"
    config_set_kv "$(_config_edit_runtime_file)" "SEERR_IS_4K" "$SEERR_IS_4K"
    config_unset_kv "$(_config_edit_runtime_file)" "SEERR_DEFAULT_PROFILE"
    configure_recyclarr || true
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
    local rc=0
    configure_opensubtitles || rc=$?
    if [ "$rc" -eq "${PROMPT_CANCEL_RC:-2}" ]; then
        log_info "Cancelled."
        return "${PROMPT_CANCEL_RC:-2}"
    fi
    local secrets_dir="$INSTALL_DIR/secrets"
    mkdir -p "$secrets_dir"
    if [ "${opensubtitles_enabled:-n}" = "y" ] && [ -n "${opensubtitles_username:-}" ]; then
        (umask 077
            echo -n "${opensubtitles_username}" > "$secrets_dir/opensubtitles_username.txt"
            echo -n "${opensubtitles_password:-}" > "$secrets_dir/opensubtitles_password.txt"
        )
        chmod 600 "$secrets_dir/opensubtitles_username.txt" "$secrets_dir/opensubtitles_password.txt"
        log_success "OpenSubtitles.com credentials written to $secrets_dir"
        configure_bazarr || true
        return 0
    fi
    log_info "Cancelled."
    return "${PROMPT_CANCEL_RC:-2}"
}

_config_edit_auth() {
    _config_edit_load
    local old_user old_pass
    old_user=$(cat "$INSTALL_DIR/secrets/auth_username.txt" 2>/dev/null || echo "${AUTH_USERNAME:-}")
    old_pass=$(cat "$INSTALL_DIR/secrets/auth_password.txt" 2>/dev/null || echo "${AUTH_PASSWORD:-}")

    configure_auth || return $?
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

    jellyfin_change_credentials "$old_user" "$old_pass" "$AUTH_USERNAME" "$AUTH_PASSWORD" || fail=1
    bazarr_set_auth || fail=1

    if sabnzbd_enabled 2>/dev/null; then
        sabnzbd_change_credentials "$AUTH_USERNAME" "$AUTH_PASSWORD" || fail=1
    fi
    if type qbit_qui_enabled >/dev/null 2>&1 && qbit_qui_enabled; then
        qui_change_credentials "$old_user" "$old_pass" "$AUTH_USERNAME" "$AUTH_PASSWORD" || fail=1
    fi

    if type seerr_verify_login >/dev/null 2>&1; then
        seerr_verify_login || true
    fi

    if [ "$fail" -ne 0 ]; then
        log_warning "Some UIs did not take the new password. Secrets were left unchanged. Run ${APP_CLI_NAME:-assemblrr} config edit and pick auth again."
        return 1
    fi

    mkdir -p "$secrets_dir"
    (umask 077
        echo -n "$AUTH_USERNAME" > "$secrets_dir/auth_username.txt"
        echo -n "$AUTH_PASSWORD" > "$secrets_dir/auth_password.txt"
    )
    chmod 600 "$secrets_dir/auth_username.txt" "$secrets_dir/auth_password.txt"
    log_success "Auth credentials written to $secrets_dir"
}

_config_edit_timezone() {
    _config_edit_load
    local prev_tz="${TZ:-UTC}"
    configure_timezone || return $?
    if [ "${tz:-UTC}" = "$prev_tz" ]; then
        log_info "Timezone unchanged (${prev_tz}) — no restart needed."
        return 0
    fi
    config_set_kv "$(_config_edit_runtime_file)" "TZ" "${tz:-UTC}"
    config_set_kv "$INSTALL_DIR/.env" "TZ" "${tz:-UTC}" 0
    TZ="${tz:-UTC}"
    _config_edit_restart_stack
}

_config_edit_vpn() {
    _config_edit_load
    local prev_vpn="${VPN_ENABLED:-n}"
    configure_vpn || return $?
    local enabled="n"
    setup_vpn="${setup_vpn:-n}"
    [ "${setup_vpn,,}" = "y" ] && enabled="y"
    if [ "$enabled" = "n" ] && [ "${prev_vpn,,}" != "y" ]; then
        log_info "VPN already disabled — no restart needed."
        return 0
    fi
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
        (umask 077
            if [ "${vpn_type:-}" = "openvpn" ]; then
                echo -n "${vpn_user:-}" > "$secrets_dir/openvpn_user.txt"
                echo -n "${vpn_password:-}" > "$secrets_dir/openvpn_password.txt"
                : > "$secrets_dir/wireguard_private_key.txt"
            else
                echo -n "${wireguard_private_key:-}" > "$secrets_dir/wireguard_private_key.txt"
                : > "$secrets_dir/openvpn_user.txt"
                : > "$secrets_dir/openvpn_password.txt"
            fi
        )
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
    if [ -n "${PROWLARR_API_KEY:-}" ]; then
        wait_for_api "Prowlarr" "9696" "$PROWLARR_API_KEY" "/api/v1/system/status" || true
        prowlarr_sync_gluetun_proxy "$PROWLARR_API_KEY" || true
    fi
    if type qbit_qui_enabled >/dev/null 2>&1 && qbit_qui_enabled; then
        configure_qui || true
    fi
}

_config_edit_qbit_ui() {
    _config_edit_load
    local prev_ui
    prev_ui=$(qbit_ui_mode)
    configure_qbit_ui || return $?
    if ui_picker_cancelled; then
        return "${PROMPT_CANCEL_RC:-2}"
    fi
    QBIT_UI="${qbit_ui:-vuetorrent}"
    if [ "$QBIT_UI" = "$prev_ui" ]; then
        log_info "qBittorrent UI unchanged (${prev_ui}) — no restart needed."
        return 0
    fi
    [ "$QBIT_UI" = "vuetorrent" ] && VUETORRENT_ENABLED="y" || VUETORRENT_ENABLED="n"
    config_set_kv "$(_config_edit_runtime_file)" "QBIT_UI" "$QBIT_UI"
    config_set_kv "$(_config_edit_runtime_file)" "VUETORRENT_ENABLED" "$VUETORRENT_ENABLED"
    config_set_kv "$INSTALL_DIR/.env" "QBIT_UI" "$QBIT_UI" 0
    config_set_kv "$INSTALL_DIR/.env" "VUETORRENT_ENABLED" "$VUETORRENT_ENABLED" 0
    if [ "$QBIT_UI" = "qui" ]; then
        mkdir -p "$INSTALL_DIR/config/qui"
        ensure_owned "$INSTALL_DIR/config/qui" "${PUID:-$(id -u)}" "${PGID:-$(id -g)}" 2>/dev/null || true
    fi
    install_directory="$INSTALL_DIR" write_qbittorrent_config
    _config_edit_restart_stack
    qbit_set_credentials || true
    if qbit_qui_enabled; then
        configure_qui || true
        log_success "qui WebUI ready at http://localhost:7476/ (:8081 redirects automatically)"
    fi
}

_config_edit_vuetorrent() {
    _config_edit_qbit_ui "$@"
}

_config_edit_gpu() {
    _config_edit_load
    local prev_gpu="${GPU_TRANSCODING:-none}"
    configure_gpu_transcoding || return $?
    GPU_TRANSCODING="${gpu_transcoding:-none}"
    if [ "$GPU_TRANSCODING" = "$prev_gpu" ]; then
        log_info "GPU transcoding unchanged (${prev_gpu}) — no restart needed."
        return 0
    fi
    config_set_kv "$(_config_edit_runtime_file)" "GPU_TRANSCODING" "$GPU_TRANSCODING"
    config_set_kv "$INSTALL_DIR/.env" "GPU_TRANSCODING" "$GPU_TRANSCODING" 0
    _config_edit_restart_stack
    if type configure_jellyfin_transcoding >/dev/null 2>&1; then
        type _jf_is_up >/dev/null 2>&1 && wait_until "Waiting for Jellyfin" 60 2 _jf_is_up || true
        configure_jellyfin_transcoding "" 8096 || true
    fi
}

_config_edit_byparr() {
    _config_edit_load
    local prev_byparr="${BYPARR_ENABLED:-n}"
    configure_byparr || return $?
    BYPARR_ENABLED="${byparr_enabled:-n}"
    if [ "${BYPARR_ENABLED,,}" = "${prev_byparr,,}" ]; then
        log_info "Byparr unchanged (${prev_byparr,,}) — no restart needed."
        return 0
    fi
    config_set_kv "$(_config_edit_runtime_file)" "BYPARR_ENABLED" "$BYPARR_ENABLED"
    config_set_kv "$INSTALL_DIR/.env" "BYPARR_ENABLED" "$BYPARR_ENABLED" 0
    _config_edit_restart_stack
    if [ -n "${PROWLARR_API_KEY:-}" ]; then
        wait_for_api "Prowlarr" "9696" "$PROWLARR_API_KEY" "/api/v1/system/status" || true
        prowlarr_sync_byparr_proxy "$PROWLARR_API_KEY" || true
        if [ "${BYPARR_ENABLED,,}" = "y" ]; then
            [ -n "${RADARR_API_KEY:-}" ] && wait_for_arr_indexer_sync "$RADARR_API_KEY" || true
            [ -n "${RADARR_API_KEY:-}" ] && arr_set_indexer_min_seeders "Radarr" "7878" "$RADARR_API_KEY" || true
            [ -n "${SONARR_API_KEY:-}" ] && arr_set_indexer_min_seeders "Sonarr" "8989" "$SONARR_API_KEY" || true
            [ -n "${RADARR_API_KEY:-}" ] && api_post "7878" "/api/v3/command" "$RADARR_API_KEY" '{"name":"MissingMoviesSearch"}' >/dev/null 2>&1 || true
            [ -n "${SONARR_API_KEY:-}" ] && api_post "8989" "/api/v3/command" "$SONARR_API_KEY" '{"name":"MissingEpisodeSearch"}' >/dev/null 2>&1 || true
        fi
    fi
}

_config_edit_usenet() {
    _config_edit_load
    local prev_usenet="${USENET_ENABLED:-n}"
    configure_usenet || return $?
    USENET_ENABLED="${usenet_enabled:-n}"
    if [ "$USENET_ENABLED" = "n" ] && [ "${prev_usenet,,}" != "y" ]; then
        log_info "SABnzbd / Usenet already disabled — no restart needed."
        return 0
    fi
    if [ "${usenet_keep_nntp:-0}" = "1" ] && [ "${prev_usenet,,}" = "y" ]; then
        log_info "SABnzbd / Usenet unchanged — no restart needed."
        return 0
    fi
    config_set_kv "$(_config_edit_runtime_file)" "USENET_ENABLED" "$USENET_ENABLED"
    config_set_kv "$INSTALL_DIR/.env" "USENET_ENABLED" "$USENET_ENABLED" 0
    config_set_kv "$(_config_edit_runtime_file)" "USENET_HOST" "${usenet_host:-}"
    config_set_kv "$(_config_edit_runtime_file)" "USENET_PORT" "${usenet_port:-563}"
    config_set_kv "$(_config_edit_runtime_file)" "USENET_SSL" "${usenet_ssl:-y}"
    config_set_kv "$(_config_edit_runtime_file)" "USENET_USERNAME" "${usenet_username:-}"
    config_set_kv "$(_config_edit_runtime_file)" "USENET_CONNECTIONS" "${usenet_connections:-8}"
    USENET_HOST="${usenet_host:-}"
    USENET_PORT="${usenet_port:-563}"
    USENET_SSL="${usenet_ssl:-y}"
    USENET_USERNAME="${usenet_username:-}"
    USENET_CONNECTIONS="${usenet_connections:-8}"
    if [ -n "${usenet_password:-}" ]; then
        mkdir -p "$INSTALL_DIR/secrets"
        (umask 077; echo -n "$usenet_password" > "$INSTALL_DIR/secrets/usenet_password.txt")
        chmod 600 "$INSTALL_DIR/secrets/usenet_password.txt"
    fi
    mkdir -p "$INSTALL_DIR/config/sabnzbd"
    setup_directory_structure "$MEDIA_DIRECTORY" 2>/dev/null || true
    _config_edit_restart_stack
    if [ "$USENET_ENABLED" = "y" ]; then
        configure_sabnzbd || true
        arr_configure_sabnzbd || true
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
        return 1
    fi
    ASSEMBLRR_RECONFIGURE=1 bash "$setup_script" --reconfigure
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
            return 1
            ;;
    esac

    _config_edit_load_picker
    local prev_allow_esc="${PROMPT_ALLOW_ESC:-0}"
    local rc=0
    PROMPT_ALLOW_ESC=1
    while true; do
        raw=$(_config_edit_pick)
        raw=$(echo "${raw:-}" | head -1 | tr -d '[:space:]')
        if [ -z "$raw" ]; then
            echo "Cancelled."
            rc=0
            break
        fi

        if ! section=$(config_edit_resolve "$raw"); then
            log_error "Unknown config section: $raw"
            rc=1
            break
        fi

        flush_tty_input

        rc=0
        case "$section" in
            indexers) _config_edit_indexers || rc=$? ;;
            providers) _config_edit_providers || rc=$? ;;
            language) _config_edit_language || rc=$? ;;
            profile) _config_edit_profile || rc=$? ;;
            opensubtitles) _config_edit_opensubtitles || rc=$? ;;
            auth) _config_edit_auth || rc=$? ;;
            timezone) _config_edit_timezone || rc=$? ;;
            vpn) _config_edit_vpn || rc=$? ;;
            qbit-ui|vuetorrent) _config_edit_qbit_ui || rc=$? ;;
            gpu) _config_edit_gpu || rc=$? ;;
            byparr) _config_edit_byparr || rc=$? ;;
            usenet) _config_edit_usenet || rc=$? ;;
            all) _config_edit_all || rc=$? ;;
            *) log_error "Unknown config section: $section"; rc=1; break ;;
        esac

        if [ "$rc" -eq "${PROMPT_CANCEL_RC:-2}" ]; then
            continue
        fi
        break
    done
    PROMPT_ALLOW_ESC="$prev_allow_esc"
    return "$rc"
}
