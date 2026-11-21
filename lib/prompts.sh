#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# assemblrr setup prompts — sourced by setup.sh & config_edit.sh
# Provides: interactive prompt functions for service and feature configuration
# Does not set -euo pipefail when sourced.

if [ -n "${_ASSEMBLRR_PROMPTS_SOURCED:-}" ]; then
    return 0
fi
readonly _ASSEMBLRR_PROMPTS_SOURCED=1

_prompts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[ -f "$_prompts_dir/ui.sh" ] && source "$_prompts_dir/ui.sh"
# shellcheck source=/dev/null
[ -f "$_prompts_dir/languages.sh" ] && source "$_prompts_dir/languages.sh"

configure_media_service() {
    media_service="jellyfin"
    media_service_port=8096
    log_success "Media service: Jellyfin (port $media_service_port)"
    export media_service media_service_port
    return 0
}

configure_quality_profile() {
    ui_intro \
        "What default quality should movies and TV use (Radarr, Sonarr, and Seerr)?" \
        "Change the default quality on Radarr, Sonarr, and Seerr."
    echo "  1) 4K (Ultra-HD — TV: assemblrr 4K WEB)"
    echo "  2) 1080p (TV: assemblrr 1080p WEB)"
    echo "  3) Any (stock *arr profile — no quality preference)"

    local quality_choice source_choice
    while true; do
        read_prompt "Choose your default quality profile [1]: " quality_choice
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
            read_prompt "Choose movie source [2]: " source_choice
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

configure_seerr_profile() {
    configure_quality_profile
}

configure_subtitle_language() {
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
        log_info "Could not fetch full ISO-639 list online — using bundled common languages."
        data=$(iso639_bundled_menu)
    fi

    local prompt header preselect_names=""
    preselect_names=$(_subtitle_stored_lang_codes)
    if ui_is_edit; then
        prompt="Subtitle languages> "
        header="TAB=toggle  Enter=save  Esc=cancel"
    else
        prompt="Subtitle languages> "
        header="TAB=toggle  Enter=confirm  Esc=skip"
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

# Collect OpenSubtitles.com username/password cleanly (Bazarr validates them directly).
_opensubtitles_collect() {
    local cancel_on_empty="${1:-0}"
    opensubtitles_username=""
    opensubtitles_password=""

    while [ -z "$opensubtitles_username" ]; do
        read_prompt "OpenSubtitles.com username (profile name, not email; blank to cancel): " opensubtitles_username
        if [ -z "$opensubtitles_username" ]; then
            if [ "$cancel_on_empty" = "1" ]; then
                return 1
            fi
            return 1
        fi
        if [[ "$opensubtitles_username" == *@* ]]; then
            log_warning "That looks like an email. Bazarr / OpenSubtitles API require your profile username."
            opensubtitles_username=""
        fi
    done

    while [ -z "$opensubtitles_password" ]; do
        read_masked "OpenSubtitles.com password: " opensubtitles_password
        if [ -z "$opensubtitles_password" ]; then
            log_warning "Password cannot be empty."
        fi
    done
    log_success "OpenSubtitles.com credentials collected (Bazarr will store and validate them)."
    return 0
}

configure_opensubtitles() {
    opensubtitles_enabled="n"
    opensubtitles_username=""
    opensubtitles_password=""

    if ui_is_edit; then
        echo
        if _opensubtitles_collect 1; then
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
    log_info "The website login accepts email or username; Bazarr requires your profile username."
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

    if _opensubtitles_collect 0; then
        opensubtitles_enabled="y"
    else
        opensubtitles_enabled="n"
        opensubtitles_username=""
        opensubtitles_password=""
        log_info "OpenSubtitles.com: skipped"
    fi
    export opensubtitles_enabled opensubtitles_username opensubtitles_password
}

configure_vuetorrent() {
    vuetorrent_enabled="y"
    if [ "${SETUP_MODE:-}" = "express" ]; then
        export vuetorrent_enabled
        return 0
    fi
    ui_intro \
        "Optional: VueTorrent gives qBittorrent a modern responsive WebUI theme." \
        "Enable or disable VueTorrent theme on qBittorrent (restarts stack)."
    local ans="y"
    read_prompt "Enable VueTorrent WebUI theme for qBittorrent? (Y/n) [Default = y]: " ans
    ans=${ans:-y}
    [ "${ans,,}" = "n" ] && vuetorrent_enabled="n" || vuetorrent_enabled="y"
    log_success "VueTorrent: $vuetorrent_enabled"
    export vuetorrent_enabled
}

# Detect host GPU acceleration safely: NVIDIA only if Docker runtime exists, else /dev/dri vendor.
detect_gpu_transcoding() {
    if command -v nvidia-smi >/dev/null 2>&1; then
        if docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -qi '"nvidia"' || \
           docker info 2>/dev/null | grep -qiE 'Runtimes:.*nvidia'; then
            echo "nvidia"
            return 0
        fi
    fi

    local dev node vendor=""
    for dev in /dev/dri/renderD*; do
        [ -c "$dev" ] || continue
        node=$(basename "$dev")
        if [ -r "/sys/class/drm/${node}/device/vendor" ]; then
            vendor=$(cat "/sys/class/drm/${node}/device/vendor" 2>/dev/null || echo "")
        fi
        case "$vendor" in
            0x1002) echo "amd"; return 0 ;;
            0x8086) echo "intel"; return 0 ;;
            *) echo "vaapi"; return 0 ;;
        esac
    done

    echo "none"
}

configure_gpu_transcoding() {
    gpu_transcoding=$(detect_gpu_transcoding)
    if [ "${SETUP_MODE:-}" = "express" ]; then
        export gpu_transcoding
        return 0
    fi

    local has_nvidia_smi=0
    command -v nvidia-smi >/dev/null 2>&1 && has_nvidia_smi=1

    local hinted="1" amd_note="" intel_note="" nv_note=""
    case "$gpu_transcoding" in
        amd) hinted="2"; amd_note=" [detected]" ;;
        vaapi) hinted="2"; amd_note=" [detected]" ;;
        intel) hinted="3"; intel_note=" [detected]" ;;
        nvidia) hinted="4"; nv_note=" [detected]" ;;
        *)
            if [ "$has_nvidia_smi" -eq 1 ]; then
                nv_note=" [nvidia-smi found, install nvidia-container-toolkit first]"
            fi
            ;;
    esac

    ui_intro \
        "Optional: hardware GPU transcoding passthrough and Jellyfin auto-configuration." \
        "Select hardware GPU transcoding mode for Jellyfin (restarts stack & configures Jellyfin)."
    echo "  1) None (CPU software transcoding)"
    echo "  2) AMD (VAAPI via /dev/dri)${amd_note}"
    echo "  3) Intel (QSV via /dev/dri)${intel_note}"
    echo "  4) NVIDIA (NVENC via nvidia-container-toolkit)${nv_note}"

    local choice
    while true; do
        read_prompt "Choose GPU transcoding mode [${hinted}]: " choice
        choice=${choice:-$hinted}
        case "${choice,,}" in
            1|none) gpu_transcoding="none"; break ;;
            2|amd|vaapi) gpu_transcoding="amd"; break ;;
            3|intel|qsv) gpu_transcoding="intel"; break ;;
            4|nvidia) gpu_transcoding="nvidia"; break ;;
            *) log_warning "Invalid choice. Choose 1, 2, 3, or 4." ;;
        esac
    done
    log_success "GPU transcoding: $gpu_transcoding"
    export gpu_transcoding
}

configure_byparr() {
    byparr_enabled="n"
    if [ "${SETUP_MODE:-}" = "express" ]; then
        export byparr_enabled
        return 0
    fi
    ui_intro \
        "Optional: Byparr solves Cloudflare challenges for Prowlarr indexers (FlareSolverr drop-in)." \
        "Enable or disable Byparr Cloudflare solver in Prowlarr (restarts stack)."
    local ans="n"
    read_prompt "Enable Byparr challenge solver container? (y/N) [Default = n]: " ans
    ans=${ans:-n}
    [ "${ans,,}" = "y" ] && byparr_enabled="y" || byparr_enabled="n"
    log_success "Byparr: $byparr_enabled"
    export byparr_enabled
}

configure_usenet() {
    usenet_enabled="n"
    usenet_host=""
    usenet_port="563"
    usenet_ssl="y"
    usenet_username=""
    usenet_password=""
    usenet_connections="8"
    if [ "${SETUP_MODE:-}" = "express" ]; then
        export usenet_enabled usenet_host usenet_port usenet_ssl usenet_username usenet_password usenet_connections
        return 0
    fi

    ui_intro \
        "Optional: SABnzbd Usenet downloader (wired automatically into Sonarr/Radarr/Prowlarr)." \
        "Enable or configure SABnzbd Usenet downloader and NNTP provider (restarts stack)."
    log_info "Note: real Usenet downloads require your own NNTP provider account (no subscription is bundled)."
    local ans="n"
    read_prompt "Enable SABnzbd Usenet downloader? (y/N) [Default = n]: " ans
    ans=${ans:-n}
    if [ "${ans,,}" != "y" ]; then
        usenet_enabled="n"
        log_success "SABnzbd / Usenet: disabled"
        export usenet_enabled usenet_host usenet_port usenet_ssl usenet_username usenet_password usenet_connections
        return 0
    fi

    usenet_enabled="y"
    local add_nntp="n"
    read_prompt "Configure an NNTP server now? (y/N, or 'n' to add in SABnzbd UI later): " add_nntp
    add_nntp=${add_nntp:-n}
    if [ "${add_nntp,,}" = "y" ]; then
        read_prompt "NNTP host (e.g. news.provider.example): " usenet_host
        read_prompt "NNTP port [563]: " usenet_port
        usenet_port=${usenet_port:-563}
        read_prompt "Use SSL/TLS? (Y/n) [Default = y]: " usenet_ssl
        usenet_ssl=${usenet_ssl:-y}
        read_prompt "NNTP username: " usenet_username
        read_masked "NNTP password: " usenet_password
        read_prompt "Max connections [8]: " usenet_connections
        usenet_connections=${usenet_connections:-8}
    fi
    log_success "SABnzbd / Usenet: enabled"
    export usenet_enabled usenet_host usenet_port usenet_ssl usenet_username usenet_password usenet_connections
}

configure_vpn() {
    ui_intro \
        "Time to set up the VPN." \
        "Change VPN settings. This restarts the stack and can interrupt downloads."
    log_info "Supported VPN providers: https://github.com/qdm12/gluetun-wiki"

    while true; do
        read_prompt "Configure VPN? (Y/n) [Default = y]: " setup_vpn
        setup_vpn=${setup_vpn:-"y"}
        case "${setup_vpn,,}" in
            y|yes) setup_vpn="y"; break ;;
            n|no)
                export setup_vpn="n"
                export vpn_service=""
                export vpn_type="openvpn"
                export wireguard_addresses=""
                export enable_port_forwarding="n"
                return 0
                ;;
            *) log_warning "Please answer y or n." ;;
        esac
    done

    local -a vpn_providers=(
        "protonvpn"
        "surfshark"
        "mullvad"
        "nordvpn"
        "expressvpn"
        "private internet access"
        "windscribe"
        "ivpn"
        "custom"
    )

    echo "  1) ProtonVPN"
    echo "  2) Surfshark"
    echo "  3) Mullvad"
    echo "  4) NordVPN"
    echo "  5) ExpressVPN"
    echo "  6) Private Internet Access"
    echo "  7) Windscribe"
    echo "  8) IVPN"
    echo "  9) Custom (manual configuration)"

    local vpn_choice vpn_type_choice
    while true; do
        read_prompt "Choose your VPN provider [1]: " vpn_choice
        vpn_choice=${vpn_choice:-1}
        if [[ "$vpn_choice" =~ ^[0-9]+$ ]]; then
            if [ "$vpn_choice" -ge 1 ] && [ "$vpn_choice" -le ${#vpn_providers[@]} ]; then
                vpn_service="${vpn_providers[$((vpn_choice-1))]}"
                break
            fi
            log_warning "Please choose a number from 1 to ${#vpn_providers[@]} (or type a Gluetun provider slug)."
        else
            vpn_service="${vpn_choice,,}"
            break
        fi
    done

    echo
    echo "  1) WireGuard (recommended)"
    echo "  2) OpenVPN"
    while true; do
        read_prompt "Choose VPN type [1]: " vpn_type_choice
        vpn_type_choice=${vpn_type_choice:-1}
        case "$vpn_type_choice" in
            1|wireguard) vpn_type="wireguard"; break ;;
            2|openvpn) vpn_type="openvpn"; break ;;
            *) log_warning "Unsupported VPN type. Please choose 1 or 2." ;;
        esac
    done

    echo
    log_info "Provider docs: https://github.com/qdm12/gluetun-wiki/blob/main/setup/providers/${vpn_service// /-}.md"
    echo

    prompt_vpn_credentials

    log_info "Port forwarding only helps if your provider supports it (and Gluetun can use it)."
    read_prompt "Enable port forwarding? (y/N) [Default = n]: " enable_port_forwarding
    enable_port_forwarding=${enable_port_forwarding:-"n"}
    case "${enable_port_forwarding,,}" in
        y|yes) enable_port_forwarding="y" ;;
        *) enable_port_forwarding="n" ;;
    esac

    export setup_vpn vpn_service vpn_type enable_port_forwarding
    export vpn_user vpn_password wireguard_private_key wireguard_addresses
}

prompt_vpn_credentials() {
    if [ "${vpn_type:-}" = "wireguard" ]; then
        wireguard_private_key=""
        while [ -z "$wireguard_private_key" ]; do
            read_masked "WireGuard private key: " wireguard_private_key
            [ -z "$wireguard_private_key" ] && log_warning "Private key cannot be empty. Try again."
        done
        wireguard_addresses=""
        while [ -z "$wireguard_addresses" ]; do
            read_prompt "WireGuard interface addresses (e.g., 10.64.0.1/32): " wireguard_addresses
            [ -z "$wireguard_addresses" ] && log_warning "Addresses cannot be empty. Try again."
        done
        vpn_user=""
        vpn_password=""
    else
        vpn_user=""
        while [ -z "$vpn_user" ]; do
            read_prompt "VPN username (without spaces): " vpn_user
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
        "Same login on Radarr, Sonarr, Prowlarr, qBittorrent, Jellyfin, Bazarr, and SABnzbd (when enabled). Seerr signs in via Jellyfin." \
        "Updates Radarr, Sonarr, Prowlarr, qBittorrent, Jellyfin, Bazarr, and SABnzbd (when enabled). Seerr signs in via Jellyfin."
    echo

    auth_username=""
    while [ -z "$auth_username" ]; do
        read_prompt "Username for service login? [$USER]: " auth_username
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

    if [ "${SETUP_MODE:-}" = "express" ]; then
        tz="$detected_tz"
        log_success "Timezone: $tz (auto-detected)"
        export tz
        return 0
    fi

    while true; do
        read_prompt "Timezone? [$detected_tz]: " tz
        tz=${tz:-$detected_tz}
        if [ -d /usr/share/zoneinfo ] && [ ! -f "/usr/share/zoneinfo/${tz}" ]; then
            log_warning "Timezone '$tz' not found under /usr/share/zoneinfo (example: Europe/Athens, America/New_York, UTC)."
            local keep="n"
            read_prompt "Keep '$tz' anyway? (y/N) [Default = n]: " keep
            [ "${keep,,}" = "y" ] && break
            continue
        fi
        break
    done

    export tz
}

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
    if [ "${SETUP_MODE:-}" = "express" ]; then
        username="$USER"
        puid=$(id -u "$username")
        pgid=$(id -g "$username")
        log_success "User: $username (PUID=$puid, PGID=$pgid)"
        export username puid pgid
        return 0
    fi

    while true; do
        read_prompt "User to own the media server files? [$USER]: " username
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

refuse_setup_if_already_installed() {
    if [ "${ASSEMBLRR_RECONFIGURE:-0}" = "1" ]; then
        return 0
    fi
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

# Stop containers created by an aborted setup before removing the leftover directory.
_cleanup_leftover_compose() {
    local path="$1"
    command -v docker >/dev/null 2>&1 || return 0
    [ -f "$path/compose/base.yaml" ] || return 0

    local vpn_enabled="n" cfg=""
    if [ -f "$path/.assemblrr-config" ]; then
        cfg="$path/.assemblrr-config"
    elif [ -f "$path/.${APP_NAME:-assemblrr}-config" ]; then
        cfg="$path/.${APP_NAME:-assemblrr}-config"
    elif [ -f "$path/.env" ]; then
        cfg="$path/.env"
    fi
    if [ -n "$cfg" ]; then
        vpn_enabled=$(_pointer_get "$cfg" "VPN_ENABLED")
    fi

    local -a cargs=(--project-directory "$path" -f "$path/compose/base.yaml")
    if [ "${vpn_enabled,,}" = "y" ] && [ -f "$path/compose/vpn.yaml" ]; then
        cargs+=(-f "$path/compose/vpn.yaml")
    elif [ -f "$path/compose/direct-access.yaml" ]; then
        cargs+=(-f "$path/compose/direct-access.yaml")
    fi
    [ -f "$path/.env" ] && cargs+=(--env-file "$path/.env")

    docker compose "${cargs[@]}" down --remove-orphans >/dev/null 2>&1 || true
}

offer_leftover_cleanup() {
    poke_wsl_automounts 2>/dev/null || true
    local leftover kind path ans
    leftover=$(list_assemblrr_leftovers || true)
    [ -n "$leftover" ] || return 0

    local has_install=false has_media=false has_incomplete=false removed_install=false
    while IFS=$'\t' read -r kind path; do
        [ -n "$path" ] || continue
        case "$kind" in
            install)
                has_install=true
                [ -f "$path/.assemblrr-setup-in-progress" ] && has_incomplete=true
                ;;
            media)
                has_media=true
                ;;
        esac
    done <<< "$leftover"

    echo
    if [ "$has_incomplete" = true ]; then
        log_warning "Found an incomplete ${APP_DISPLAY_NAME:-assemblrr} setup from an earlier attempt:"
    else
        log_warning "Found leftover ${APP_DISPLAY_NAME:-assemblrr} files from an earlier attempt:"
    fi
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
        read_prompt "$prompt_msg" ans
        ans=${ans:-y}
        if [ "${ans,,}" = "y" ]; then
            removed_install=true
            while IFS=$'\t' read -r kind path; do
                if [ "$kind" = "install" ] && [ -n "$path" ]; then
                    _cleanup_leftover_compose "$path"
                    safe_rm_rf "$path"
                fi
            done <<< "$leftover"
        fi
    fi

    leftover=$(list_assemblrr_leftovers || true)
    if echo "$leftover" | grep -q $'^media\t'; then
        local prompt_media="Remove leftover media directories? (y/N) [Default = n]: "
        if [ "$has_install" = true ]; then
            prompt_media="Also remove leftover media directories? (y/N) [Default = n]: "
        fi
        read_prompt "$prompt_media" ans
        ans=${ans:-n}
        if [ "${ans,,}" = "y" ]; then
            while IFS=$'\t' read -r kind path; do
                [ "$kind" = "media" ] && [ -n "$path" ] && safe_rm_rf "$path"
            done <<< "$leftover"
        fi
    fi

    if [ "$removed_install" = true ]; then
        local ptr ptr_inst removed_ptr=false
        for ptr in "$HOME/.assemblrr-config" "$HOME/.${APP_NAME:-assemblrr}-config"; do
            [ -f "$ptr" ] || continue
            ptr_inst=$(_pointer_get "$ptr" "INSTALL_DIRECTORY")
            if [ -n "$ptr_inst" ] && [ ! -d "$ptr_inst" ]; then
                rm -f "$ptr"
                removed_ptr=true
            fi
        done
        if [ "$removed_ptr" = true ]; then
            rm -f "$HOME/.local/bin/${APP_CLI_NAME:-assemblrr}" 2>/dev/null || true
        fi
    fi
}

get_installation_paths() {
    ui_intro \
        "Where should assemblrr store config and media? External drives (WSL E:, USB, ...) show up in the list." \
        "Change install and media directories. This does not move existing files."

    while true; do
        pick_storage_paths
        install_directory=$(expand_path "$install_directory")
        media_directory=$(expand_path "$media_directory")

        if ! _probe_selected_storage; then
            continue
        fi

        write_install_pointer "$install_directory" "$media_directory"

        if [ -n "${_ASSEMBLRR_PROVISIONAL_INSTALL:-}" ] && \
           [ "$install_directory" != "$_ASSEMBLRR_PROVISIONAL_INSTALL" ] && \
           [ -d "$_ASSEMBLRR_PROVISIONAL_INSTALL" ]; then
            log_info "Install path changed — stopping temporary containers and removing $_ASSEMBLRR_PROVISIONAL_INSTALL"
            if command -v docker >/dev/null 2>&1 && [ -f "$_ASSEMBLRR_PROVISIONAL_INSTALL/compose/base.yaml" ]; then
                docker compose --project-directory "$_ASSEMBLRR_PROVISIONAL_INSTALL" \
                    -f "$_ASSEMBLRR_PROVISIONAL_INSTALL/compose/base.yaml" \
                    -f "$_ASSEMBLRR_PROVISIONAL_INSTALL/compose/vpn.yaml" \
                    down --remove-orphans >/dev/null 2>&1 || true
            fi
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
