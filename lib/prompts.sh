#!/bin/bash
# assemblrr setup prompts — sourced by setup.sh
# Provides: interactive prompt functions for service configuration
# Requires: lib/core.sh (logging, read_masked, expand_path, directory helpers),
#           SETUP_MODE, SUPPORTED_MEDIA_SERVICES, APP_DEFAULT_INSTALL_DIR,
#           APP_DEFAULT_MEDIA_DIR, MEDIA_SUBDIRS (all set by setup.sh)

set -euo pipefail

_prompts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[ -f "$_prompts_dir/ui.sh" ] && source "$_prompts_dir/ui.sh"

configure_media_service() {
    # Express mode: use Jellyfin by default
    if [ "${SETUP_MODE:-}" = "express" ]; then
        media_service="jellyfin"
        media_service_port=8096
        log_success "Media service: Jellyfin (port $media_service_port)"
        export media_service media_service_port
        return 0
    fi

    ui_intro \
        "Time to choose your media service." \
        "Change the media server. This restarts the stack."
    echo "  1) Jellyfin (recommended, easier)"
    echo "  2) Emby"
    echo "  3) Plex (advanced, uses host networking)"

    while true; do
        read -p "Choose your media service [1]: " media_service_choice
        media_service_choice=${media_service_choice:-1}

        case "$media_service_choice" in
            1) media_service="jellyfin"; break ;;
            2) media_service="emby"; break ;;
            3) media_service="plex"; break ;;
            *) media_service=$(echo "$media_service_choice" | awk '{print tolower($0)}') ;;
        esac

        if [[ ! " ${SUPPORTED_MEDIA_SERVICES[@]} " =~ " ${media_service} " ]]; then
            log_warning "\"$media_service\" is not supported. Please choose 1, 2, or 3."
        else
            break
        fi
    done

    # Set media service port
    if [ "$media_service" == "plex" ]; then
        media_service_port=32400
    else
        media_service_port=8096
    fi

    echo
    log_success "${APP_DISPLAY_NAME} will install \"$media_service\" on port \"$media_service_port\""

    export media_service media_service_port
}

configure_seerr_profile() {
    # Express mode: default to Ultra-HD (4K)
    if [ "${SETUP_MODE:-}" = "express" ]; then
        seerr_default_profile="5"
        seerr_is_4k="true"
        log_success "Quality profile: Ultra-HD (4K)"
        export seerr_default_profile seerr_is_4k
        return 0
    fi

    ui_intro \
        "What default quality profile would you like to set for Seerr (Movies)?" \
        "Change Seerr's default movie quality profile."
    echo "  1) Ultra-HD (4K - Optimized for HEVC/x265)"
    echo "  2) 1080p"
    echo "  3) Any (Radarr Default)"

    while true; do
        read -p "Choose your Seerr default profile [1]: " seerr_profile_choice
        seerr_profile_choice=${seerr_profile_choice:-1}

        case "$seerr_profile_choice" in
            1) seerr_default_profile="5"; seerr_is_4k="true"; break ;;
            2) seerr_default_profile="4"; seerr_is_4k="false"; break ;;
            3) seerr_default_profile="1"; seerr_is_4k="false"; break ;;
            *) log_warning "Invalid choice. Please choose 1, 2, or 3." ;;
        esac
    done

    export seerr_default_profile seerr_is_4k
}

configure_subtitle_language() {
    # Jellyfin ISO 639-1 code (2-letter) to ISO 639-2/B (3-letter) mapping
    # Source: https://github.com/jellyfin/jellyfin/blob/master/Emby.Server.Implementations/Localization/iso6392.txt
    # Format: code|bibliographic|terminology|name|english_name
    local iso639_url="https://raw.githubusercontent.com/jellyfin/jellyfin/master/Emby.Server.Implementations/Localization/iso6392.txt"
    local awk_filter='$4 != "" {print $1 "\t" $4}'

    ui_intro \
        "Select your preferred subtitle language (Jellyfin playback + Bazarr downloads)." \
        "Change the preferred subtitle language (Jellyfin + Bazarr)."

    # Use fzf single-select with fallback to "en"
    subtitle_language=$(fzf_single_select "$iso639_url" "$awk_filter" "")

    if [ -n "$subtitle_language" ]; then
        log_success "Subtitle language: $subtitle_language"
    else
        log_success "Subtitle language: none (Bazarr defaults to English)"
    fi
    export subtitle_language
}

# OpenSubtitles.com website login accepts email or username; the REST API (and
# Bazarr) require the profile username. Consumer Api-Key is Bazarr's public key
# from upstream so we validate the same path Bazarr will use at runtime.
# Override with OPENSUBTITLES_API_KEY if needed.
_verify_opensubtitles_login() {
    local user="$1"
    local pass="$2"
    local api_key="${OPENSUBTITLES_API_KEY:-s38zmzVlW7IlYruWi7mHwDYl2SfMQoC1}"
    local ua="${OPENSUBTITLES_USER_AGENT:-assemblrr/1.0}"
    local tmp http_code body
    local attempt

    tmp=$(mktemp)
    for attempt in 1 2 3; do
        http_code=$(curl -sS -o "$tmp" -w "%{http_code}" --connect-timeout 10 --max-time 30 \
            -X POST "https://api.opensubtitles.com/api/v1/login" \
            -H "Content-Type: application/json" \
            -H "Api-Key: ${api_key}" \
            -H "User-Agent: ${ua}" \
            -d "$(jq -nc --arg u "$user" --arg p "$pass" '{username:$u,password:$p}')" \
            2>/dev/null || echo "000")
        body=$(cat "$tmp" 2>/dev/null || true)

        case "$http_code" in
            200)
                if echo "$body" | jq -e '.token // empty' >/dev/null 2>&1; then
                    rm -f "$tmp"
                    return 0
                fi
                rm -f "$tmp"
                return 1
                ;;
            429)
                log_warning "OpenSubtitles rate limit — retrying (${attempt}/3)..."
                sleep $((attempt + 1))
                continue
                ;;
            000)
                log_warning "OpenSubtitles: network error (could not reach API)"
                rm -f "$tmp"
                return 2
                ;;
            *)
                # Prefer API message when present
                local msg
                msg=$(echo "$body" | jq -r '.message // empty' 2>/dev/null || true)
                if [ -n "$msg" ]; then
                    log_warning "OpenSubtitles: $msg"
                else
                    log_warning "OpenSubtitles: login failed (HTTP ${http_code})"
                fi
                rm -f "$tmp"
                return 1
                ;;
        esac
    done
    rm -f "$tmp"
    return 1
}

# Optional OpenSubtitles.com account for Bazarr (free registration).
# Same y/N + credentials flow for express and manual. Credentials are
# verified against the OpenSubtitles API before we accept them.
configure_opensubtitles() {
    opensubtitles_enabled="n"
    opensubtitles_username=""
    opensubtitles_password=""

    ui_intro \
        "Optional: OpenSubtitles.com credentials for Bazarr (https://www.opensubtitles.com/)." \
        "Update OpenSubtitles.com credentials for Bazarr. Answer n to clear them."
    log_info "The website login accepts email or username; Bazarr/API require your profile username."
    log_info "Find it under your OpenSubtitles profile (not the signup email)."
    ui_note \
        "Other subtitle providers can be configured later with: ${APP_CLI_NAME:-assemblrr} config edit providers" \
        ""
    read -p "Do you have OpenSubtitles.com credentials? (y/N) [Default = n]: " opensubtitles_enabled
    opensubtitles_enabled=${opensubtitles_enabled:-n}

    if [ "${opensubtitles_enabled,,}" != "y" ]; then
        opensubtitles_enabled="n"
        log_success "OpenSubtitles.com: not configured"
        export opensubtitles_enabled opensubtitles_username opensubtitles_password
        return 0
    fi

    local retry=""
    while true; do
        opensubtitles_username=""
        opensubtitles_password=""

        while [ -z "$opensubtitles_username" ]; do
            read -p "OpenSubtitles.com username (profile name, not email): " opensubtitles_username
            if [ -z "$opensubtitles_username" ]; then
                log_warning "Username cannot be empty."
                continue
            fi
            if [[ "$opensubtitles_username" == *@* ]]; then
                log_warning "That looks like an email. OpenSubtitles API rejects email logins."
                log_warning "Use your profile username (website login may accept email; Bazarr does not)."
                opensubtitles_username=""
            fi
        done
        while [ -z "$opensubtitles_password" ]; do
            read_masked "OpenSubtitles.com password: " opensubtitles_password
            if [ -z "$opensubtitles_password" ]; then
                log_warning "Password cannot be empty."
            fi
        done

        log_info "Verifying OpenSubtitles.com login..."
        if _verify_opensubtitles_login "$opensubtitles_username" "$opensubtitles_password"; then
            opensubtitles_enabled="y"
            log_success "OpenSubtitles.com: login OK — credentials will be stored under secrets/"
            export opensubtitles_enabled opensubtitles_username opensubtitles_password
            return 0
        fi

        read -p "Try again? (Y/n) [Default = y]: " retry
        retry=${retry:-y}
        if [ "${retry,,}" != "y" ]; then
            opensubtitles_enabled="n"
            opensubtitles_username=""
            opensubtitles_password=""
            log_warning "OpenSubtitles.com: skipped (credentials not verified)"
            export opensubtitles_enabled opensubtitles_username opensubtitles_password
            return 0
        fi
    done
}

configure_vpn() {
    ui_intro \
        "Time to set up the VPN." \
        "Change VPN settings. This restarts the stack and can interrupt downloads."
    log_info "Supported VPN providers: https://github.com/qdm12/gluetun-wiki"

    read -p "Configure VPN? (Y/n) [Default = y]: " setup_vpn
    setup_vpn=${setup_vpn:-"y"}

    if [ "${setup_vpn,,}" != "y" ]; then
        export setup_vpn="n"
        export vpn_service=""
        export vpn_type="openvpn"
        export enable_port_forwarding="n"
        return 0
    fi

    # Supported VPN providers (from Gluetun)
    local -a vpn_providers=(
        "protonvpn"
        "surfshark"
        "mullvad"
        "nordvpn"
        "expressvpn"
        "pia"
        "windscribe"
        "ivyvpn"
        "custom"
    )

    echo "  1) ProtonVPN"
    echo "  2) Surfshark"
    echo "  3) Mullvad"
    echo "  4) NordVPN"
    echo "  5) ExpressVPN"
    echo "  6) Private Internet Access"
    echo "  7) Windscribe"
    echo "  8) IvyVPN"
    echo "  9) Custom (manual configuration)"

    read -p "Choose your VPN provider [1]: " vpn_choice
    vpn_choice=${vpn_choice:-1}

    if [[ "$vpn_choice" =~ ^[0-9]+$ ]] && [ "$vpn_choice" -ge 1 ] && [ "$vpn_choice" -le ${#vpn_providers[@]} ]; then
        vpn_service="${vpn_providers[$((vpn_choice-1))]}"
    else
        vpn_service="$vpn_choice"
    fi

    echo
    echo "  1) WireGuard (recommended)"
    echo "  2) OpenVPN"
    read -p "Choose VPN type [1]: " vpn_type_choice
    vpn_type_choice=${vpn_type_choice:-1}

    while true; do
        case "$vpn_type_choice" in
            1) vpn_type="wireguard"; break ;;
            2) vpn_type="openvpn"; break ;;
            *) vpn_type="$vpn_type_choice" ;;
        esac

        if [[ "$vpn_type" != "openvpn" && "$vpn_type" != "wireguard" ]]; then
            log_warning "Unsupported VPN type. Please choose 1 or 2."
            read -p "Choose VPN type [1]: " vpn_type_choice
            vpn_type_choice=${vpn_type_choice:-1}
        else
            break
        fi
    done

    echo
    log_info "Provider docs: https://github.com/qdm12/gluetun-wiki/blob/main/setup/providers/${vpn_service// /-}.md"
    echo

    prompt_vpn_credentials

    # Port forwarding — we do not maintain a provider allowlist (lists go stale).
    log_info "Port forwarding only helps if your provider supports it (and Gluetun can use it)."
    log_info "If they do not, leave this off — turning it on can limit which servers Gluetun picks."
    read -p "Enable port forwarding? (y/N) [Default = n]: " enable_port_forwarding
    enable_port_forwarding=${enable_port_forwarding:-"n"}

    export setup_vpn vpn_service vpn_type enable_port_forwarding
    export vpn_user vpn_password wireguard_private_key wireguard_addresses
}

# Prompt only for credentials (uses existing vpn_type). Safe to call again on VPN test failure.
prompt_vpn_credentials() {
    if [ "${vpn_type:-}" = "wireguard" ]; then
        wireguard_private_key=""
        while [ -z "$wireguard_private_key" ]; do
            read_masked "WireGuard private key: " wireguard_private_key
            [ -z "$wireguard_private_key" ] && log_warning "Private key cannot be empty. Try again."
        done
        wireguard_addresses=""
        while [ -z "$wireguard_addresses" ]; do
            read_masked "WireGuard interface addresses (e.g., 10.64.0.1/32): " wireguard_addresses
            [ -z "$wireguard_addresses" ] && log_warning "Addresses cannot be empty. Try again."
        done
        vpn_user=""
        vpn_password=""
    else
        vpn_user=""
        while [ -z "$vpn_user" ]; do
            read -p "VPN username (without spaces): " vpn_user
            [ -z "$vpn_user" ] && log_warning "Username cannot be empty. Try again."
        done
        vpn_password=""
        while [ -z "$vpn_password" ]; do
            read_masked "VPN password: " vpn_password
            if [ -z "$vpn_password" ]; then
                log_warning "Password cannot be empty. Try again."
                continue
            fi
            local vpn_password_confirm=""
            read_masked "Confirm VPN password: " vpn_password_confirm
            if [ "$vpn_password" != "$vpn_password_confirm" ]; then
                log_warning "Passwords do not match. Try again."
                vpn_password=""
            fi
        done
        wireguard_private_key=""
        wireguard_addresses=""
    fi

    export vpn_user vpn_password wireguard_private_key wireguard_addresses
}

configure_auth() {
    ui_intro \
        "Set credentials for your service web UIs." \
        "Change the shared service login (Radarr, Sonarr, Prowlarr, qBittorrent)."
    ui_note \
        "These will be used to log into Radarr, Prowlarr, and other services." \
        "Seerr / Jellyfin / Bazarr may still use the previous password until you sign in there or re-run wiring."
    echo

    auth_username=""
    while [ -z "$auth_username" ]; do
        read -p "Username for service login? [$USER]: " auth_username
        auth_username=${auth_username:-$USER}
        [ -z "$auth_username" ] && log_warning "Username cannot be empty. Try again."
    done

    auth_password=""
    while [ -z "$auth_password" ]; do
        read_masked "Password for service login: " auth_password
        if [ -z "$auth_password" ]; then
            log_warning "Password cannot be empty. Try again."
            continue
        fi
        local auth_password_confirm=""
        read_masked "Confirm password: " auth_password_confirm
        if [ "$auth_password" != "$auth_password_confirm" ]; then
            log_warning "Passwords do not match. Try again."
            auth_password=""
        fi
    done

    export auth_username auth_password
}

configure_timezone() {
    local detected_tz
    detected_tz=$(cat /etc/timezone 2>/dev/null || timedatectl show -p Timezone -v 2>/dev/null | tail -1 || echo "UTC")
    detected_tz=${detected_tz:-"UTC"}

    # Express mode: auto-detect timezone
    if [ "${SETUP_MODE:-}" = "express" ]; then
        tz="$detected_tz"
        log_success "Timezone: $tz (auto-detected)"
        export tz
        return 0
    fi

    read -p "Timezone? [$detected_tz]: " tz
    tz=${tz:-$detected_tz}

    export tz
}

# running_services_location lives in lib/services.sh (sourced by setup via core path
# or explicitly). Keep a thin wrapper if services.sh not loaded yet.
if ! type running_services_location >/dev/null 2>&1; then
    running_services_location() {
        if [ -f "${_lib_dir:-}/services.sh" ]; then
            # shellcheck source=/dev/null
            source "${_lib_dir}/services.sh"
            running_services_location
            return
        fi
        echo "Service URLs: run ${APP_CLI_NAME:-assemblrr} status"
    }
fi

get_user_info() {
    # Express mode: use current user
    if [ "${SETUP_MODE:-}" = "express" ]; then
        username="$USER"
        puid=$(id -u "$username")
        pgid=$(id -g "$username")
        log_success "User: $username (PUID=$puid, PGID=$pgid)"
        export username puid pgid
        return 0
    fi

    while true; do
        read -p "User to own the media server files? [$USER]: " username
        username=${username:-$USER}

        if id -u "$username" &>/dev/null; then
            puid=$(id -u "$username")
            pgid=$(id -g "$username")
            break
        else
            log_warning "User \"$username\" doesn't exist! Try again."
        fi
    done

    export username puid pgid
}

get_installation_paths() {
    ui_intro \
        "Where should assemblrr store config and media? External drives (WSL E:, USB, …) show up in the list." \
        "Change install and media directories. This does not move existing files."

    pick_storage_paths
    install_directory=$(expand_path "$install_directory")
    media_directory=$(expand_path "$media_directory")

    # VPN gate bootstraps ~/assemblrr first. If the user then picked another
    # install path, drop that leftover tree so CLI discovery cannot shadow it.
    if [ -n "${_ASSEMBLRR_PROVISIONAL_INSTALL:-}" ] && \
       [ "$install_directory" != "$_ASSEMBLRR_PROVISIONAL_INSTALL" ] && \
       [ -d "$_ASSEMBLRR_PROVISIONAL_INSTALL" ]; then
        log_info "Install path changed — removing temporary files at $_ASSEMBLRR_PROVISIONAL_INSTALL"
        safe_rm_rf "$_ASSEMBLRR_PROVISIONAL_INSTALL"
    fi

    create_and_verify_directory "$install_directory" "installation"
    setup_directory_structure "$media_directory"
    verify_user_permissions "$username" "$media_directory"

    log_success "Install directory: $install_directory"
    log_success "Media directory: $media_directory"

    export install_directory media_directory
}
