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

configure_quality_profile() {
    ui_intro \
        "What default quality should movies and TV use (Radarr, Sonarr, and Seerr)?" \
        "Change the default quality on Radarr, Sonarr, and Seerr."
    echo "  1) 4K (Ultra-HD — TV: assemblrr 4K WEB)"
    echo "  2) 1080p (TV: assemblrr 1080p WEB)"
    echo "  3) Any (stock *arr profile — no quality preference)"

    while true; do
        read -p "Choose your default quality profile [1]: " quality_choice
        quality_choice=${quality_choice:-1}

        case "$quality_choice" in
            1) QUALITY_TIER="uhd"; break ;;
            2) QUALITY_TIER="hd"; break ;;
            3) QUALITY_TIER="any"; break ;;
            *) log_warning "Invalid choice. Please choose 1, 2, or 3." ;;
        esac
    done

    QUALITY_SOURCE="bluray"
    if [ "$QUALITY_TIER" != "any" ]; then
        echo
        echo "  Movies: WEB only, or allow Blu-ray upgrades?"
        echo "  (TV stays WEB. TRaSH has no English Blu-ray TV default.)"
        echo "  1) WEB only (smaller files; no Blu-ray upgrades)"
        echo "  2) Bluray + WEB (upgrades WEB to a Blu-ray encode when one exists)"
        while true; do
            read -p "Choose movie source [2]: " source_choice
            source_choice=${source_choice:-2}
            case "$source_choice" in
                1) QUALITY_SOURCE="web"; break ;;
                2) QUALITY_SOURCE="bluray"; break ;;
                *) log_warning "Invalid choice. Please choose 1 or 2." ;;
            esac
        done
    fi

    seerr_is_4k="false"
    [ "$QUALITY_TIER" = "uhd" ] && seerr_is_4k="true"
    export QUALITY_TIER QUALITY_SOURCE seerr_is_4k
    case "$QUALITY_TIER" in
        uhd)
            if [ "$QUALITY_SOURCE" = "web" ]; then
                log_success "Quality: 4K WEB for movies and TV"
            else
                log_success "Quality: 4K (movies: 4K Bluray + WEB, TV: 4K WEB)"
            fi
            ;;
        hd)
            if [ "$QUALITY_SOURCE" = "web" ]; then
                log_success "Quality: 1080p WEB for movies and TV"
            else
                log_success "Quality: 1080p (movies: 1080p Bluray + WEB, TV: 1080p WEB)"
            fi
            ;;
        *)
            log_success "Quality: Any"
            ;;
    esac
}

# Older name — setup / config edit used this when the question was Seerr-only.
configure_seerr_profile() {
    configure_quality_profile
}

configure_subtitle_language() {
    # Jellyfin iso6392.txt: iso639-2/T|iso639-2/B|iso639-1|english_name|french_name
    local iso639_url="https://raw.githubusercontent.com/jellyfin/jellyfin/master/Emby.Server.Implementations/Localization/iso6392.txt"
    local awk_filter='$4 != "" {print $1 "\t" $4}'

    SELECTED_SUBTITLE_LANGUAGES=()
    FZF_SELECT_STATUS="cancelled"

    ui_intro \
        "Select subtitle languages to download. If you pick more than one, a second menu asks which Jellyfin should prefer." \
        "Change subtitle languages. If you pick more than one, a second menu asks which Jellyfin should prefer."

    if [ "${ASSEMBLRR_NONINTERACTIVE:-0}" = "1" ]; then
        log_info "Skipping subtitle language picker (non-interactive)."
        return 0
    fi

    local data
    data=$(curl -sf --connect-timeout 5 "$iso639_url" 2>/dev/null | awk -F'|' "$awk_filter" | sort -k2) || true
    if [ -z "$data" ]; then
        log_info "Could not load language list — leaving subtitle language unchanged."
        return 0
    fi

    local prompt header preselect_names=""
    preselect_names=$(_subtitle_stored_lang_codes)
    if ui_is_edit; then
        prompt="Subtitle languages> "
        header="Enter/TAB=toggle  Ctrl-O=save  Esc=cancel"
    else
        prompt="Subtitle languages> "
        header="Enter/TAB=toggle  Ctrl-O=confirm  Esc=skip"
    fi
    fzf_multi_select "$data" \
        "$prompt" \
        "$header" \
        SELECTED_SUBTITLE_LANGUAGES \
        "language" \
        "$preselect_names" || true
    ui_picker_done "languages"
    if ui_picker_cancelled; then
        return 0
    fi

    if [ "${#SELECTED_SUBTITLE_LANGUAGES[@]}" -eq 0 ]; then
        subtitle_language=""
        subtitle_languages=""
        log_success "Subtitle language: none (Bazarr defaults to English)"
        export subtitle_language subtitle_languages
        return 0
    fi

    local preferred="${SELECTED_SUBTITLE_LANGUAGES[0]}"
    if [ "${#SELECTED_SUBTITLE_LANGUAGES[@]}" -gt 1 ]; then
        local current_pref="${SUBTITLE_LANGUAGE:-}"
        current_pref="${current_pref%%,*}"
        current_pref=${current_pref// /}
        local in_set=0 code
        for code in "${SELECTED_SUBTITLE_LANGUAGES[@]}"; do
            [ "$code" = "$current_pref" ] && in_set=1 && break
        done
        [ "$in_set" -eq 0 ] && current_pref="$preferred"

        local selected_data="" row
        for code in "${SELECTED_SUBTITLE_LANGUAGES[@]}"; do
            row=$(printf '%s\n' "$data" | awk -F'\t' -v c="$code" '$1 == c { print; exit }')
            [ -n "$row" ] && selected_data+="$row"$'\n'
        done
        ui_intro \
            "Which of those should Jellyfin prefer for playback?" \
            "Which of those should Jellyfin prefer for playback?"
        preferred=$(fzf_single_select_data \
            "$selected_data" \
            "Preferred language> " \
            "↑↓=navigate  Enter=confirm  Esc=keep current preferred" \
            "$current_pref")
        [ -z "$preferred" ] && preferred="$current_pref"
        in_set=0
        for code in "${SELECTED_SUBTITLE_LANGUAGES[@]}"; do
            [ "$code" = "$preferred" ] && in_set=1 && break
        done
        [ "$in_set" -eq 0 ] && preferred="${SELECTED_SUBTITLE_LANGUAGES[0]}"
    fi

    subtitle_language="$preferred"
    subtitle_languages=$(_subtitle_join_preferred_first "$preferred" "${SELECTED_SUBTITLE_LANGUAGES[@]}")
    if [ "$subtitle_languages" = "$subtitle_language" ]; then
        log_success "Subtitle language: $subtitle_language (preferred)"
    else
        log_success "Subtitle languages: $subtitle_language (preferred), ${subtitle_languages#*,}"
    fi
    export subtitle_language subtitle_languages
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

# Collect verified OpenSubtitles.com username/password into the usual globals.
# $1 = cancel_on_empty_user (1 for config edit, 0 for setup).
# Returns 0 on verified login, 1 on cancel/skip.
_opensubtitles_ask_and_verify() {
    local cancel_on_empty="${1:-0}"
    local retry=""

    while true; do
        opensubtitles_username=""
        opensubtitles_password=""

        while [ -z "$opensubtitles_username" ]; do
            read_prompt "OpenSubtitles.com username (profile name, not email): " opensubtitles_username
            if [ -z "$opensubtitles_username" ]; then
                if [ "$cancel_on_empty" = "1" ]; then
                    return 1
                fi
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
            if [ -r /dev/tty ]; then
                read_masked "OpenSubtitles.com password: " opensubtitles_password </dev/tty
            else
                read_masked "OpenSubtitles.com password: " opensubtitles_password
            fi
            if [ -z "$opensubtitles_password" ]; then
                log_warning "Password cannot be empty."
            fi
        done

        log_info "Verifying OpenSubtitles.com login..."
        if _verify_opensubtitles_login "$opensubtitles_username" "$opensubtitles_password"; then
            log_success "OpenSubtitles.com: login OK — credentials will be stored under secrets/"
            return 0
        fi

        read_prompt "Try again? (Y/n) [Default = y]: " retry
        retry=${retry:-y}
        if [ "${retry,,}" != "y" ]; then
            return 1
        fi
    done
}

# Optional OpenSubtitles.com account for Bazarr (free registration).
# Setup: y/N first (optional). Config edit: user already picked this section,
# so go straight to username/password. Empty username cancels with no change.
configure_opensubtitles() {
    opensubtitles_enabled="n"
    opensubtitles_username=""
    opensubtitles_password=""

    if ui_is_edit; then
        echo
        if _opensubtitles_ask_and_verify 1; then
            opensubtitles_enabled="y"
        else
            opensubtitles_enabled="n"
            opensubtitles_username=""
            opensubtitles_password=""
        fi
        export opensubtitles_enabled opensubtitles_username opensubtitles_password
        return 0
    fi

    ui_intro \
        "Optional: OpenSubtitles.com credentials for Bazarr (https://www.opensubtitles.com/)." \
        "Update OpenSubtitles.com credentials for Bazarr."
    log_info "The website login accepts email or username; Bazarr/API require your profile username."
    log_info "Find it under your OpenSubtitles profile (not the signup email)."
    ui_note \
        "Other subtitle providers can be configured later with: ${APP_CLI_NAME:-assemblrr} config edit" \
        ""
    read_prompt "Do you have OpenSubtitles.com credentials? (y/N) [Default = n]: " opensubtitles_enabled
    opensubtitles_enabled=${opensubtitles_enabled:-n}

    if [ "${opensubtitles_enabled,,}" != "y" ]; then
        opensubtitles_enabled="n"
        log_success "OpenSubtitles.com: not configured"
        export opensubtitles_enabled opensubtitles_username opensubtitles_password
        return 0
    fi

    if _opensubtitles_ask_and_verify 0; then
        opensubtitles_enabled="y"
    else
        opensubtitles_enabled="n"
        opensubtitles_username=""
        opensubtitles_password=""
        log_warning "OpenSubtitles.com: skipped (credentials not verified)"
    fi
    export opensubtitles_enabled opensubtitles_username opensubtitles_password
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
        "Set one username and password for every service web UI." \
        "Change the shared login on every service UI."
    ui_note \
        "Same login on Radarr, Sonarr, Prowlarr, qBittorrent, Jellyfin, and Bazarr. Seerr signs in with the Jellyfin (or Emby) user." \
        "Updates Radarr, Sonarr, Prowlarr, qBittorrent, Jellyfin, and Bazarr. Seerr signs in with the Jellyfin (or Emby) user."
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

_probe_selected_storage() {
    local p root
    local -A seen=()
    for p in "$install_directory" "$media_directory"; do
        storage_needs_probe "$p" || continue
        root=$(storage_mount_root "$p")
        [ -n "$root" ] || continue
        [ -n "${seen[$root]:-}" ] && continue
        seen[$root]=1
        log_info "Checking ${root} is responding..."
        if ! probe_writable_path "$root"; then
            echo
            log_info "Pick another location (Home is safest), or fix the drive and choose it again."
            return 1
        fi
    done
    return 0
}

# Setup is first-time only. A complete tree means use the CLI, not bootstrap again.
refuse_setup_if_already_installed() {
    poke_wsl_automounts 2>/dev/null || true
    local existing=""
    existing=$(find_install_directory 2>/dev/null || true)
    if [ -z "$existing" ] || ! is_complete_assemblrr_install "$existing"; then
        return 0
    fi

    INSTALL_DIR="$existing"
    load_install_pointer 2>/dev/null || true
    if [ -f "$existing/.assemblrr-config" ]; then
        safe_source "$existing/.assemblrr-config"
    elif [ -f "$existing/.${APP_NAME:-assemblrr}-config" ]; then
        safe_source "$existing/.${APP_NAME:-assemblrr}-config"
    fi
    MEDIA_DIRECTORY="${MEDIA_DIRECTORY:-}"

    local cli="${APP_CLI_NAME:-assemblrr}"
    echo
    log_warning "${APP_DISPLAY_NAME} is already installed."
    print_detected_locations
    echo
    log_info "Setup is first-time only. Use the CLI:"
    log_info "  $cli upgrade        # update the stack"
    log_info "  $cli config edit    # change settings"
    log_info "  $cli uninstall      # remove it, then run setup again"
    echo
    exit 1
}

# Incomplete trees from an aborted setup. Offer to delete them before we start.
offer_leftover_cleanup() {
    poke_wsl_automounts 2>/dev/null || true
    local leftover kind path ans
    leftover=$(list_assemblrr_leftovers || true)
    [ -n "$leftover" ] || return 0

    local has_install=false
    local has_media=false
    if echo "$leftover" | grep -q $'^install\t'; then
        has_install=true
    fi
    if echo "$leftover" | grep -q $'^media\t'; then
        has_media=true
    fi

    echo
    log_warning "Found leftover ${APP_DISPLAY_NAME:-assemblrr} files from an earlier attempt:"
    while IFS=$'\t' read -r kind path; do
        [ -n "$path" ] || continue
        case "$kind" in
            install) log_warning "  Install: $path" ;;
            media)   log_warning "  Media:   $path" ;;
            *)       log_warning "  $path" ;;
        esac
    done <<< "$leftover"

    if [ "$has_install" = true ]; then
        local prompt_msg="Remove leftover install files? (Y/n) [Default = y]: "
        if [ "$has_media" = true ]; then
            prompt_msg="Remove leftover install files (keeps media)? (Y/n) [Default = y]: "
        fi
        read -p "$prompt_msg" ans
        ans=${ans:-y}
        if [ "${ans,,}" = "y" ]; then
            while IFS=$'\t' read -r kind path; do
                [ "$kind" = "install" ] && [ -n "$path" ] && safe_rm_rf "$path"
            done <<< "$leftover"
        fi
    fi

    leftover=$(list_assemblrr_leftovers || true)
    if echo "$leftover" | grep -q $'^media\t'; then
        local prompt_media="Remove leftover media directories? (y/N) [Default = n]: "
        if [ "$has_install" = true ]; then
            prompt_media="Also remove leftover media directories? (y/N) [Default = n]: "
        fi
        read -p "$prompt_media" ans
        ans=${ans:-n}
        if [ "${ans,,}" = "y" ]; then
            while IFS=$'\t' read -r kind path; do
                [ "$kind" = "media" ] && [ -n "$path" ] && safe_rm_rf "$path"
            done <<< "$leftover"
        fi
    fi
}

get_installation_paths() {
    ui_intro \
        "Where should assemblrr store config and media? External drives (WSL E:, USB, …) show up in the list." \
        "Change install and media directories. This does not move existing files."

    while true; do
        pick_storage_paths
        install_directory=$(expand_path "$install_directory")
        media_directory=$(expand_path "$media_directory")

        if ! _probe_selected_storage; then
            continue
        fi

        # Record both paths before any copy so uninstall can find an external
        # drive even if setup dies mid-copy.
        write_install_pointer "$install_directory" "$media_directory"

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
        break
    done

    export install_directory media_directory
}
