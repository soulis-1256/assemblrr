#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT=""

# Support both repository layout (`bin/` + `lib/`) and installed layout
# (entrypoints copied into the install root with `lib/` underneath).
if [ -f "$SCRIPT_DIR/../lib/core.sh" ]; then
    APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
elif [ -f "$SCRIPT_DIR/lib/core.sh" ]; then
    APP_ROOT="$SCRIPT_DIR"
else
    echo -e "\033[0;31mError: lib/core.sh not found. Re-run setup from a complete assemblrr tree.\033[0m" >&2
    exit 1
fi

resolve_project_file() {
    local relative_path="$1"
    local candidate="$APP_ROOT/$relative_path"

    if [ -f "$candidate" ]; then
        echo "$candidate"
        return 0
    fi

    case "$relative_path" in
        bin/*)
            candidate="$APP_ROOT/${relative_path#bin/}"
            ;;
    esac

    if [ -f "$candidate" ]; then
        echo "$candidate"
        return 0
    fi

    return 1
}

# Source core library (logging, colors, safe_source, path utilities)
source "$APP_ROOT/lib/core.sh"

# Source branding — all names/paths come from here
source "$APP_ROOT/lib/branding.sh"
load_branding "$APP_ROOT"

# Source Docker Compose builder
source "$APP_ROOT/lib/compose.sh"

# Source VPN helpers
source "$APP_ROOT/lib/vpn.sh"

echo "===================================================="
echo "                             | |   | |          "
echo "  __ _ ___ ___  ___ _ __ ___ | |__ | |_ __ _ __ "
echo " / _\` / __/ __|/ _ \ '_ \` _ \\| '_ \\| | '__| '__|"
echo "| (_| \\__ \\__ \\  __/ | | | | | |_) | | |  | |   "
echo " \\__,_|___/___/\\___|_| |_| |_|_.__/|_|_|  |_|   "
echo "                                                 "
echo "===================================================="
echo "Welcome to ${APP_DISPLAY_NAME} (${APP_DESCRIPTION})"
echo "===================================================="
echo ""

# --- Setup mode ---
SETUP_MODE=""
echo "  1) Express (recommended — minimal questions, smart defaults)"
echo "  2) Manual (full control over every setting)"
while true; do
    read -p "Choose setup mode [1]: " setup_mode_choice
    setup_mode_choice=${setup_mode_choice:-1}
    case "$setup_mode_choice" in
        1) SETUP_MODE="express"; break ;;
        2) SETUP_MODE="manual"; break ;;
        *) log_warning "Invalid choice. Please choose 1 or 2." ;;
    esac
done
export SETUP_MODE

if [ "$SETUP_MODE" = "express" ]; then
    echo ""
    log_success "Express mode — we'll use smart defaults and only ask the essentials."
    echo ""
else
    echo ""
    log_info "Manual mode — you'll configure every setting."
    echo ""
fi

# Constants
readonly SUPPORTED_MEDIA_SERVICES=("jellyfin" "emby" "plex")
readonly DEFAULT_MEDIA_SERVICE="jellyfin"
readonly DEFAULT_VPN_SERVICE="protonvpn"
readonly MEDIA_SUBDIRS=("torrents/movies" "torrents/tv" "media/movies" "media/tv" "blackhole")

# Dependencies
readonly REQUIRED_COMMANDS=("curl" "jq" "sed" "awk" "envsubst" "fzf")

# LOG_FILE is set in main() — lib/core.sh log_info/log_debug handle file logging natively
# Path utilities (expand_path, read_masked, create_and_verify_directory, etc.) are in lib/core.sh

detect_package_manager() {
    if command -v apt-get &>/dev/null; then
        echo "apt"
    elif command -v pacman &>/dev/null; then
        echo "pacman"
    elif command -v dnf &>/dev/null; then
        echo "dnf"
    elif command -v zypper &>/dev/null; then
        echo "zypper"
    else
        echo "unknown"
    fi
}

install_packages() {
    local pkgs=("$@")
    local pm
    pm=$(detect_package_manager)

    case "$pm" in
        apt)
            sudo apt-get update -qq && sudo apt-get install -y "${pkgs[@]}"
            ;;
        pacman)
            sudo pacman -Sy --noconfirm --needed "${pkgs[@]}"
            ;;
        dnf)
            sudo dnf install -y "${pkgs[@]}"
            ;;
        zypper)
            sudo zypper -n in "${pkgs[@]}"
            ;;
        *)
            log_error "Unsupported package manager. Please install manually: ${pkgs[*]}"
            ;;
    esac
}

check_dependencies() {
    local missing_packages=()

    for pkg in "${REQUIRED_COMMANDS[@]}"; do
        local works=false
        if command -v "$pkg" &>/dev/null; then
            case "$pkg" in
                curl) curl --version &>/dev/null && works=true ;;
                jq) echo "{}" | jq . &>/dev/null && works=true ;;
                awk) echo "" | awk '{print}' &>/dev/null && works=true ;;
                sed) echo "" | sed '' &>/dev/null && works=true ;;
                envsubst) echo "" | envsubst &>/dev/null && works=true ;;
                fzf) fzf --version &>/dev/null && works=true ;;
                *) works=true ;;
            esac
        fi

        if ! $works; then
            missing_packages+=("$pkg")
        else
            log_success "$pkg works"
        fi
    done

    if [ ${#missing_packages[@]} -gt 0 ]; then
        log_warning "Missing required packages: ${missing_packages[*]}"
        read -p "Would you like to install the missing packages? (y/N) [Default = n]: " install_deps
        install_deps=${install_deps:-"n"}

        if [ "${install_deps,,}" = "y" ]; then
            echo "Installing missing packages..."
            if ! install_packages "${missing_packages[@]}"; then
                log_error "Failed to install missing packages. Please install them manually: ${missing_packages[*]}"
            fi
            log_success "Successfully installed missing packages"
        else
            log_error "Please install the required packages manually: ${missing_packages[*]}"
        fi
    fi

    # Check Docker and Docker Compose
    if ! verify_docker; then
        if ! command -v docker &>/dev/null || ! docker compose version &>/dev/null; then
            log_warning "Docker/Docker Compose not found!"
            
            # If in WSL2, do not attempt to install Docker inside the distro.
            # Recommend installing Docker Desktop on Windows.
            if grep -qi microsoft /proc/version 2>/dev/null; then
                log_error "WSL2 environment detected, but Docker Desktop is not running or not installed on Windows.\n\nPlease install Docker Desktop for Windows and enable WSL2 integration:\n  https://docs.docker.com/desktop/wsl/"
            fi

            read -p "Install Docker and Docker Compose? (y/N) [Default = n]: " install_docker
            install_docker=${install_docker:-"n"}

            if [ "${install_docker,,}" = "y" ]; then
                bash "$SCRIPT_DIR/docker-install.sh"
                if ! verify_docker; then
                    log_error "Docker daemon is not running. Please start Docker and try again."
                fi
            else
                log_error "Please install Docker and Docker Compose first"
            fi
        else
            log_error "Docker daemon is not running. Please start Docker and try again."
        fi
    fi

    # Perform snap check if docker is installed
    if command -v docker &>/dev/null; then
        if [[ $(which docker) == "/snap/bin/docker" ]]; then
            log_error "Docker is installed via snap. ${APP_DISPLAY_NAME} requires the official Docker installation. Please remove snap Docker and install from https://docs.docker.com/engine/install/"
        fi
        log_success "Docker is installed and running"
    fi

    return 0
}

# --- Setup prompts (sourced from lib/prompts.sh) ---
# Requires: lib/core.sh already sourced, constants defined above
# fzf-tui helpers (fzf_single_select, fzf_multi_select) must be sourced before prompts
source "$APP_ROOT/lib/fzf-tui.sh"
source "$APP_ROOT/lib/services.sh"
source "$APP_ROOT/lib/prompts.sh"

copy_configuration_files() {
    local -A files=(
        ["lib/core.sh"]="lib/core.sh"
        ["lib/branding.sh"]="lib/branding.sh"
        ["lib/compose.sh"]="lib/compose.sh"
        ["lib/vpn.sh"]="lib/vpn.sh"
        ["lib/api.sh"]="lib/api.sh"
        ["lib/arr.sh"]="lib/arr.sh"
        ["lib/jellyfin.sh"]="lib/jellyfin.sh"
        ["lib/seerr.sh"]="lib/seerr.sh"
        ["lib/bazarr.sh"]="lib/bazarr.sh"
        ["lib/prompts.sh"]="lib/prompts.sh"
        ["lib/fzf-tui.sh"]="lib/fzf-tui.sh"
        ["lib/managed_files.sh"]="lib/managed_files.sh"
        ["lib/upgrade.sh"]="lib/upgrade.sh"
        ["lib/services.sh"]="lib/services.sh"
        ["compose/base.yaml"]="compose/base.yaml"
        ["compose/direct-access.yaml"]="compose/direct-access.yaml"
        ["compose/vpn.yaml"]="compose/vpn.yaml"
        ["compose/examples/custom.yaml.example"]="compose/examples/custom.yaml.example"
        [".env.example"]=".env.example"
        ["templates/recyclarr/recyclarr.yml"]="templates/recyclarr/recyclarr.yml"
        ["templates/recyclarr/includes/radarr-hd.yml"]="templates/recyclarr/includes/radarr-hd.yml"
        ["templates/recyclarr/includes/radarr-uhd.yml"]="templates/recyclarr/includes/radarr-uhd.yml"
        ["templates/recyclarr/includes/radarr-soft-cfs.yml"]="templates/recyclarr/includes/radarr-soft-cfs.yml"
        ["templates/recyclarr/includes/sonarr-web-1080.yml"]="templates/recyclarr/includes/sonarr-web-1080.yml"
        ["templates/recyclarr/includes/sonarr-web-2160.yml"]="templates/recyclarr/includes/sonarr-web-2160.yml"
        ["templates/recyclarr/includes/sonarr-soft-cfs.yml"]="templates/recyclarr/includes/sonarr-soft-cfs.yml"
        ["branding.conf"]="branding.conf"
        ["bin/cli.sh"]="cli.sh"
        ["bin/config.sh"]="config.sh"
        ["bin/setup.sh"]="setup.sh"
        ["bin/docker-install.sh"]="docker-install.sh"
        ["scripts/jellyfin-refresh.sh"]="scripts/jellyfin-refresh.sh"
        ["scripts/vpn-watchdog.sh"]="scripts/vpn-watchdog.sh"
        ["scripts/media-purge.sh"]="scripts/media-purge.sh"
        ["scripts/arr-purge-hook.sh"]="scripts/arr-purge-hook.sh"
        ["scripts/media-purge-watch.sh"]="scripts/media-purge-watch.sh"
    )

    for src in "${!files[@]}"; do
        local dest="$install_directory/${files[$src]}"
        local dest_dir
        local src_path=""
        dest_dir=$(dirname "$dest")

        if [ ! -d "$dest_dir" ]; then
            mkdir -p "$dest_dir"
        fi

        if ! src_path=$(resolve_project_file "$src"); then
            if [ "$src" = "compose/examples/custom.yaml.example" ]; then
                log_warning "Optional example file not found: $src"
                continue
            fi
            log_error "Failed to locate source file: $src"
        fi

        log_info "Copying $src to $dest..."
        if cp "$src_path" "$dest"; then
            # Custom scripts mounted into *arr containers must be executable;
            # Radarr/Sonarr validate CustomScript paths by exec'ing them on save.
            case "$src" in
                scripts/*) chmod +x "$dest" ;;
            esac
            log_success "$src copied successfully"
        else
            log_error "Failed to copy $src to $dest. Check permissions"
        fi
    done
}

generate_env_file() {
    local env_file="$install_directory/.env"

    log_info "Generating environment configuration..."

    # Set VPN-related variables for envsubst (credentials go to secrets/)
    if [ "${setup_vpn,,}" == "y" ]; then
        VPN_ENABLED="y"
        VPN_SERVICE="$vpn_service"
        VPN_TYPE="$vpn_type"
        WIREGUARD_ADDRESSES="${wireguard_addresses:-}"
        if [ "${enable_port_forwarding,,}" = "y" ]; then
            PORT_FORWARD_ONLY="on"
            VPN_PORT_FORWARDING="on"
        else
            PORT_FORWARD_ONLY="off"
            VPN_PORT_FORWARDING="off"
        fi
    else
        VPN_ENABLED="n"
        VPN_SERVICE=""
        VPN_TYPE="openvpn"
        WIREGUARD_ADDRESSES=""
        PORT_FORWARD_ONLY="off"
        VPN_PORT_FORWARDING="off"
    fi

    # Export all variables for envsubst
    API_HOST="${API_HOST:-127.0.0.1}"
    export PUID="$puid"
    export PGID="$pgid"
    export MEDIA_DIRECTORY="$media_directory"
    export INSTALL_DIRECTORY="$install_directory"
    export MEDIA_SERVICE="$media_service"
    export TZ="$tz"
    export VPN_ENABLED VPN_SERVICE VPN_TYPE
    export WIREGUARD_ADDRESSES
    export PORT_FORWARD_ONLY VPN_PORT_FORWARDING
    export API_HOST

    local env_template
    if ! env_template=$(resolve_project_file ".env.example"); then
        log_error "Failed to locate .env.example"
    fi
    # Explicit key list so envsubst does not pull in unrelated shell variables
    envsubst '${PUID} ${PGID} ${MEDIA_DIRECTORY} ${INSTALL_DIRECTORY} ${MEDIA_SERVICE} ${TZ} ${VPN_ENABLED} ${VPN_SERVICE} ${VPN_TYPE} ${WIREGUARD_ADDRESSES} ${PORT_FORWARD_ONLY} ${VPN_PORT_FORWARDING} ${API_HOST}' \
        < "$env_template" > "$env_file" || \
        log_error "Failed to generate .env file"

    chmod 600 "$env_file"

    log_success "Environment configuration generated"
}

write_vpn_secrets() {
    if [ "${setup_vpn,,}" != "y" ]; then
        return 0
    fi

    local secrets_dir="$install_directory/secrets"
    mkdir -p "$secrets_dir"

    if [ "$vpn_type" = "openvpn" ]; then
        echo -n "${vpn_user:-}" > "$secrets_dir/openvpn_user.txt"
        echo -n "${vpn_password:-}" > "$secrets_dir/openvpn_password.txt"
        # Create empty WireGuard secret so the secret definition always resolves
        : > "$secrets_dir/wireguard_private_key.txt"
    else
        echo -n "${wireguard_private_key:-}" > "$secrets_dir/wireguard_private_key.txt"
        # Create empty OpenVPN secrets so the secret definitions always resolve
        : > "$secrets_dir/openvpn_user.txt"
        : > "$secrets_dir/openvpn_password.txt"
    fi

    chmod 600 "$secrets_dir"/*.txt
    log_success "VPN secrets written to $secrets_dir"
}

write_auth_secrets() {
    local secrets_dir="$install_directory/secrets"
    mkdir -p "$secrets_dir"

    echo -n "${auth_username:-admin}" > "$secrets_dir/auth_username.txt"
    echo -n "${auth_password:-}" > "$secrets_dir/auth_password.txt"
    chmod 600 "$secrets_dir/auth_username.txt" "$secrets_dir/auth_password.txt"
    log_success "Auth credentials written to $secrets_dir"
}

write_opensubtitles_secrets() {
    local secrets_dir="$install_directory/secrets"
    mkdir -p "$secrets_dir"

    if [ "${opensubtitles_enabled:-n}" = "y" ] && [ -n "${opensubtitles_username:-}" ]; then
        echo -n "${opensubtitles_username}" > "$secrets_dir/opensubtitles_username.txt"
        echo -n "${opensubtitles_password:-}" > "$secrets_dir/opensubtitles_password.txt"
        chmod 600 "$secrets_dir/opensubtitles_username.txt" "$secrets_dir/opensubtitles_password.txt"
        log_success "OpenSubtitles.com credentials written to $secrets_dir"
    else
        # Clear stale creds if user opted out on re-run
        rm -f "$secrets_dir/opensubtitles_username.txt" "$secrets_dir/opensubtitles_password.txt" 2>/dev/null || true
    fi
}

write_qbittorrent_config() {
    local qbit_config_dir="$install_directory/config/qbittorrent/qBittorrent"
    mkdir -p "$qbit_config_dir"

    local pbkdf2_hash
    pbkdf2_hash=$(qbit_generate_pbkdf2 "${auth_password:-}")

    if [ -n "$pbkdf2_hash" ]; then
        cat > "$qbit_config_dir/qBittorrent.conf" << EOF
[Preferences]
WebUI\Username=${auth_username:-admin}
WebUI\Password_PBKDF2=$pbkdf2_hash
WebUI\Port=8081
EOF
        log_success "Pre-configured qBittorrent credentials (bypassing WebAPI restrictions)"
    fi
}

validate_vpn_config() {
    validate_vpn_secrets "$install_directory" "${setup_vpn,,}" "${VPN_TYPE:-openvpn}"
}

test_vpn_connection() {
    # Profile is only needed for media services; Gluetun has no profile.
    local profile="${media_service:-jellyfin}"
    build_compose_args "$install_directory" "${setup_vpn,,}"
    test_vpn_connection_shared run_docker compose "${COMPOSE_ARGS[@]}" --profile "$profile"
}

# Provisional host vars so Gluetun can start before the rest of the wizard.
# Final paths/user are collected after a successful tunnel test and may change.
set_provisional_vpn_test_defaults() {
    username="${username:-$USER}"
    puid="${puid:-$(id -u)}"
    pgid="${pgid:-$(id -g)}"
    install_directory="${install_directory:-$APP_DEFAULT_INSTALL_DIR}"
    media_directory="${media_directory:-$APP_DEFAULT_MEDIA_DIR}"
    if declare -F expand_path >/dev/null 2>&1; then
        install_directory=$(expand_path "$install_directory")
        media_directory=$(expand_path "$media_directory")
    fi
    media_service="${media_service:-jellyfin}"
    media_service_port="${media_service_port:-8096}"
    if [ -z "${tz:-}" ]; then
        tz=$(cat /etc/timezone 2>/dev/null || timedatectl show -p Timezone -v 2>/dev/null | tail -1 || echo "UTC")
        tz=${tz:-UTC}
    fi
    export username puid pgid install_directory media_directory media_service media_service_port tz
}

# Gate the rest of setup on a working tunnel. On failure, re-prompt credentials
# and retry instead of abandoning a half-finished install.
ensure_vpn_connection() {
    if [ "${setup_vpn,,}" != "y" ]; then
        return 0
    fi

    while true; do
        if test_vpn_connection; then
            VPN_ALREADY_VERIFIED=1
            export VPN_ALREADY_VERIFIED
            return 0
        fi

        echo
        echo -e "${RED}VPN test failed — cannot continue setup without a working VPN.${NC}"
        echo -e "${YELLOW}Download clients (qBittorrent, SABnzbd) require the VPN to function.${NC}"
        echo
        echo "Credentials live under $install_directory/secrets/ (not as passwords in .env)."
        if [ "${vpn_type:-openvpn}" = "wireguard" ]; then
            echo "  WireGuard key:  $install_directory/secrets/wireguard_private_key.txt"
            echo "  WG address:     WIREGUARD_ADDRESSES in $install_directory/.env"
        else
            echo "  OpenVPN user:   $install_directory/secrets/openvpn_user.txt"
            echo "  OpenVPN pass:   $install_directory/secrets/openvpn_password.txt"
        fi
        echo "Gluetun logs above usually show why the tunnel failed."
        echo

        local retry=""
        read -p "Re-enter VPN credentials and try again? (Y/n) [Default = y]: " retry
        retry=${retry:-y}
        if [ "${retry,,}" != "y" ]; then
            echo
            echo "Setup stopped — VPN was not verified, so the rest of the wizard was not run."
            echo "When you are ready, re-run setup and enter correct VPN details:"
            local raw_base="${APP_REPO_URL:-https://github.com/soulis-1256/assemblrr}"
            raw_base="${raw_base/github.com/raw.githubusercontent.com}/main"
            echo "  Linux / WSL2:  bash <(curl -fsSL ${raw_base}/platform/linux/bootstrap.sh)"
            echo "  Windows:       irm ${raw_base}/platform/windows/bootstrap.ps1 | iex"
            if [ -f "$install_directory/setup.sh" ]; then
                echo "  On disk:       bash $install_directory/setup.sh"
            fi
            echo
            exit 1
        fi

        echo
        log_info "Re-enter VPN credentials for ${vpn_service:-your provider} (${vpn_type:-openvpn})."
        prompt_vpn_credentials
        write_vpn_secrets
        # WIREGUARD_ADDRESSES and related values live in .env
        generate_env_file
    done
}

# Right after VPN prompts: materialize a minimal install and prove the tunnel
# before asking about users, paths, media, etc.
early_vpn_gate() {
    if [ "${setup_vpn,,}" != "y" ]; then
        return 0
    fi

    echo
    log_info "Testing VPN connection before the rest of setup..."
    set_provisional_vpn_test_defaults
    mkdir -p "$install_directory"
    copy_configuration_files
    generate_env_file
    write_vpn_secrets
    # Bind mounts must exist as the host user before Gluetun starts
    prepare_install_dirs "$install_directory" "$puid" "$pgid"
    ensure_vpn_connection
    log_success "VPN is working — continuing with the rest of setup."
    echo
}

write_runtime_config() {
    local config_file="$install_directory/.${APP_NAME}-config"
    cat > "$config_file" << EOF
INSTALL_DIRECTORY="$install_directory"
MEDIA_DIRECTORY="$media_directory"
MEDIA_SERVICE="$media_service"
VPN_ENABLED="${setup_vpn,,}"
VPN_TYPE="${vpn_type:-openvpn}"
TZ="$tz"
SEERR_DEFAULT_PROFILE="${seerr_default_profile:-1}"
SEERR_IS_4K="${seerr_is_4k:-false}"
SUBTITLE_LANGUAGE="${subtitle_language:-}"
SETUP_MODE="${SETUP_MODE:-manual}"
EOF
    chmod 600 "$config_file"
    log_success "Runtime config written to $config_file"
}

# build_compose_args is defined in lib/compose.sh
# Usage: build_compose_args "$install_directory" "${setup_vpn,,}"

install_cli() {
    echo
    log_info "Installing ${APP_DISPLAY_NAME} CLI..."

    # Copy from install directory (persistent), not SCRIPT_DIR (may be /tmp)
    local cli_source="$install_directory/cli.sh"

    mkdir -p "$HOME/.local/bin/lib"
    # Copy lib modules (CLI sources them from lib/ subdirectory)
    for _lib_module in core branding compose vpn managed_files upgrade services; do
        if [ -f "$install_directory/lib/${_lib_module}.sh" ]; then
            cp "$install_directory/lib/${_lib_module}.sh" "$HOME/.local/bin/lib/${_lib_module}.sh"
        fi
    done
    cp "$cli_source" "$HOME/.local/bin/$APP_CLI_NAME" && chmod +x "$HOME/.local/bin/$APP_CLI_NAME"
    if ! grep -q '.local/bin' "$HOME/.profile" 2>/dev/null; then
        log_info "Adding $HOME/.local/bin to your PATH (in ~/.profile)..."
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.profile"
        export PATH="$HOME/.local/bin:$PATH"
    fi
    # fish ignores ~/.profile, so register the path in its own config too
    if command -v fish &>/dev/null; then
        local fish_config="$HOME/.config/fish/config.fish"
        mkdir -p "$HOME/.config/fish"
        if ! grep -q '.local/bin' "$fish_config" 2>/dev/null; then
            log_info "Adding $HOME/.local/bin to your fish PATH (in $fish_config)..."
            echo 'fish_add_path $HOME/.local/bin' >> "$fish_config"
        fi
    fi
    log_success "${APP_DISPLAY_NAME} CLI installed to $HOME/.local/bin/$APP_CLI_NAME"
}

set_permissions() {
    log_info "Setting ownership for install and media directories..."

    # Install bind-mount tree (idempotent; also fixes root-owned leftovers)
    prepare_install_dirs "$install_directory" "$puid" "$pgid"

    if [ ! -d "$media_directory" ]; then
        mkdir -p "$media_directory" || log_error "Failed to create media directory $media_directory"
    fi
    ensure_owned "$media_directory" "$puid" "$pgid"

    log_success "Ownership set for $install_directory and $media_directory"
}

main() {
# Prevent running as root
if [[ "$EUID" = 0 ]]; then
    log_error "${APP_DISPLAY_NAME} must run without sudo! Please run with regular permissions"
fi

# Setup logging
LOG_FILE="/tmp/${APP_NAME}-setup-$(date '+%Y%m%d-%H%M%S').log"
log_info "Setup log: $LOG_FILE"
log_info "Checking prerequisites..."
check_dependencies

# 1) VPN questions, then immediately test the tunnel (fail fast).
configure_vpn
early_vpn_gate

# 2) Only after VPN works (or is disabled): rest of the wizard
get_user_info
get_installation_paths
configure_media_service
configure_seerr_profile
configure_subtitle_language
configure_opensubtitles
configure_timezone
configure_auth

# ---- Installation summary / confirmation ----
echo
echo "========================================================"
echo "  ${APP_DISPLAY_NAME} — Installation Summary"
echo "========================================================"
echo "  User:              $username (PUID=$puid, PGID=$pgid)"
echo "  Install directory: $install_directory"
echo "  Media directory:   $media_directory"
if [ "${setup_vpn,,}" = "y" ]; then
    echo "  VPN:               ENABLED ($vpn_service, $vpn_type)"
    echo "  Port forwarding:   ${enable_port_forwarding:-n}"
else
    echo "  VPN:               DISABLED"
fi
echo "  Media service:     $media_service (port $media_service_port)"
echo "  Seerr Profile:     $seerr_default_profile (4K=$seerr_is_4k)"
echo "  Subtitle language: ${subtitle_language:-en (Bazarr default)}"
if [ "${opensubtitles_enabled:-n}" = "y" ]; then
    echo "  OpenSubtitles.com: yes (username=${opensubtitles_username})"
else
    echo "  OpenSubtitles.com: no (free providers only)"
fi
echo "  Timezone:          $tz"
echo "  Service login:     $auth_username"
echo "========================================================"
echo
if [ "${SETUP_MODE:-}" != "express" ]; then
    while true; do
        read -p "Proceed with installation? (Y/n) [Default = y]: " proceed
        proceed=${proceed:-"y"}
        if [ "${proceed,,}" = "y" ]; then
            break
        elif [ "${proceed,,}" = "n" ]; then
            log_info "Installation cancelled by user"
            exit 0
        else
            log_warning "Please answer y or n."
        fi
    done
fi

log_info "Configuring ${APP_DISPLAY_NAME} for user \"$username\" in \"$install_directory\"..."

# Refresh install tree for final paths/settings (may differ from provisional VPN test defaults)
copy_configuration_files
generate_env_file
write_vpn_secrets

# Final bind-mount skeleton + ownership before any further compose operations
prepare_install_dirs "$install_directory" "$puid" "$pgid"

# Re-check only if we never verified (VPN disabled skips; early gate already set the flag)
if [ "${setup_vpn,,}" = "y" ] && [ "${VPN_ALREADY_VERIFIED:-}" != "1" ]; then
    ensure_vpn_connection
elif [ "${setup_vpn,,}" = "y" ]; then
    log_info "VPN already verified earlier — not re-testing."
fi

write_auth_secrets
write_opensubtitles_secrets
write_qbittorrent_config
write_runtime_config

log_success "Install files ready — starting services..."

log_info "Starting ${APP_DISPLAY_NAME} services..."
log_info "This may take a while..."
# Ensure mounts still exist/owned immediately before the full stack comes up
prepare_install_dirs "$install_directory" "$puid" "$pgid"
build_compose_args "$install_directory" "${setup_vpn,,}"
if ! run_docker compose "${COMPOSE_ARGS[@]}" --profile "$media_service" up -d; then
    log_error "Failed to start ${APP_DISPLAY_NAME} services"
fi

# Wire services (Radarr, Prowlarr, etc.)
local wiring_ok=1
if [ -f "$install_directory/config.sh" ]; then
    if ! bash "$install_directory/config.sh"; then
        wiring_ok=0
        log_warning "Service wiring had critical failures. Containers are still running."
        log_warning "Fix the issues above, then re-run setup or: $APP_CLI_NAME upgrade"
    fi
fi
# Drop legacy name if an older install left it behind
rm -f "$install_directory/configure.sh" 2>/dev/null || true

# Install CLI (needed for status/upgrade even if wiring failed)
echo
log_info "Installing CLI and configuring permissions..."
install_cli
set_permissions

echo
# Live dashboard (no stale ~/…_services.txt)
if [ -f "$install_directory/lib/services.sh" ]; then
    # shellcheck source=/dev/null
    source "$install_directory/lib/services.sh"
fi
if [ -x "$HOME/.local/bin/$APP_CLI_NAME" ]; then
    log_info "Service dashboard:"
    # Use install CLI if present; fall back to URL list
    if bash "$install_directory/cli.sh" status 2>/dev/null; then
        :
    else
        running_services_location
        log_info "Run: $APP_CLI_NAME status"
    fi
else
    running_services_location
    log_info "After install, run: $APP_CLI_NAME status"
fi
# Drop legacy cheat-sheet if an older setup left one behind
rm -f "$HOME/assemblrr_services.txt" 2>/dev/null || true

log_info "========================================================"
if [ "$wiring_ok" -eq 1 ]; then
    log_success "All done! Enjoy ${APP_DISPLAY_NAME}!"
    log_info "Install directory: $install_directory"
    log_info "Docs: ${APP_REPO_URL}"
    exit 0
fi

log_warning "Setup finished, but service wiring failed."
log_warning "Install directory: $install_directory"
log_warning "Fix issues, then re-run setup or: $APP_CLI_NAME upgrade"
log_info "Docs: ${APP_REPO_URL}"
exit 1
}

main "$@"
