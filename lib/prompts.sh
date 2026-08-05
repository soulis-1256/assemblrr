#!/bin/bash
# assemblrr setup prompts — sourced by setup.sh
# Provides: interactive prompt functions for service configuration
# Requires: lib/core.sh (logging, read_masked, expand_path, directory helpers),
#           SETUP_MODE, SUPPORTED_MEDIA_SERVICES, APP_DEFAULT_INSTALL_DIR,
#           APP_DEFAULT_MEDIA_DIR, MEDIA_SUBDIRS (all set by setup.sh)

set -euo pipefail

configure_media_service() {
    # Express mode: use Jellyfin by default
    if [ "${SETUP_MODE:-}" = "express" ]; then
        media_service="jellyfin"
        media_service_port=8096
        log_success "Media service: Jellyfin (port $media_service_port)"
        export media_service media_service_port
        return 0
    fi

    echo
    echo
    log_info "Time to choose your media service."
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

    echo
    echo
    log_info "What default quality profile would you like to set for Seerr (Movies)?"
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

    echo
    echo
    log_info "Select your preferred subtitle language for Jellyfin."

    # Use fzf single-select with fallback to "en"
    subtitle_language=$(fzf_single_select "$iso639_url" "$awk_filter" "")

    if [ -n "$subtitle_language" ]; then
        log_success "Subtitle language: $subtitle_language"
    else
        log_success "Subtitle language: none (no preference)"
    fi
    export subtitle_language
}

configure_vpn() {
    echo
    echo
    log_info "Time to set up the VPN."
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

    # Port forwarding
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
    echo
    echo
    log_info "Set credentials for your service web UIs."
    log_info "These will be used to log into Radarr, Prowlarr, and other services."
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

running_services_location() {
    local host_ip
    # Get the IP of the default route interface (avoids Docker bridges, VPN tunnels)
    host_ip=$(ip -4 route show default 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 || true)
    if [ -z "$host_ip" ]; then
        host_ip=$(hostname -I 2>/dev/null | awk '{ print $1 }' || true)
    fi
    host_ip=${host_ip:-"localhost"}

    local -A services=(
        ["qBittorrent"]="8081"
        ["Radarr"]="7878"
        ["Sonarr"]="8989"
        ["Prowlarr"]="9696"
        ["Seerr"]="5055"
        ["$media_service"]="$media_service_port"
        ["Portainer"]="9000"
    )

    echo -e "Service URLs:"
    for service in "${!services[@]}"; do
        if [ "$service" = "plex" ]; then
            echo "$service: http://$host_ip:${services[$service]}/web"
        else
            echo "$service: http://$host_ip:${services[$service]}/"
        fi
    done
}

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
    # Express mode: use default paths
    if [ "${SETUP_MODE:-}" = "express" ]; then
        install_directory="$APP_DEFAULT_INSTALL_DIR"
        media_directory="$APP_DEFAULT_MEDIA_DIR"
        log_success "Install directory: $install_directory"
        log_success "Media directory: $media_directory"
    else
        read -p "Installation directory? [$APP_DEFAULT_INSTALL_DIR]: " install_directory
        install_directory=${install_directory:-$APP_DEFAULT_INSTALL_DIR}
        # FIX: Expand tilde in user input
        install_directory=$(expand_path "$install_directory")
        create_and_verify_directory "$install_directory" "installation"

        read -p "Media directory? [$APP_DEFAULT_MEDIA_DIR]: " media_directory
        media_directory=${media_directory:-$APP_DEFAULT_MEDIA_DIR}
        # FIX: Expand tilde in user input
        media_directory=$(expand_path "$media_directory")

        while true; do
            read -p "Are you sure your media directory is \"$media_directory\"? (Y/n) [Default = y]: " media_directory_correct
            media_directory_correct=${media_directory_correct:-"y"}

            if [ "${media_directory_correct,,}" != "y" ]; then
                read -p "Media directory? [$APP_DEFAULT_MEDIA_DIR]: " media_directory
                media_directory=${media_directory:-$APP_DEFAULT_MEDIA_DIR}
                media_directory=$(expand_path "$media_directory")
            else
                break
            fi
        done
    fi

    setup_directory_structure "$media_directory"
    verify_user_permissions "$username" "$media_directory"

    # Pre-create Seerr config dir with correct ownership (Seerr runs as node/UID 1000)
    # Docker would create this as root on first mount, causing EACCES
    mkdir -p "$install_directory/config/seerr"
    if [ "$(id -u)" -ne 1000 ]; then
        sudo chown -R 1000:1000 "$install_directory/config/seerr" 2>/dev/null || true
    fi

    # Pre-create Recyclarr config dir to avoid root-owned volume files
    mkdir -p "$install_directory/config/recyclarr"
    if [ "$(id -u)" -ne "$puid" ] || [ "$(id -g)" -ne "$pgid" ]; then
        sudo chown -R "$puid:$pgid" "$install_directory/config/recyclarr" 2>/dev/null || true
    fi

    export install_directory media_directory
}
