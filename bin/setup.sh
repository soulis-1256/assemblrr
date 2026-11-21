#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# assemblrr first-time setup, reconfigure, and backup-restore wizard
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT=""

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
        bin/*) candidate="$APP_ROOT/${relative_path#bin/}" ;;
    esac
    if [ -f "$candidate" ]; then
        echo "$candidate"
        return 0
    fi
    return 1
}

# shellcheck source=/dev/null
source "$APP_ROOT/lib/core.sh"
# shellcheck source=/dev/null
source "$APP_ROOT/lib/branding.sh"
load_branding "$APP_ROOT"
# shellcheck source=/dev/null
source "$APP_ROOT/lib/compose.sh"
# shellcheck source=/dev/null
source "$APP_ROOT/lib/vpn.sh"
# shellcheck source=/dev/null
source "$APP_ROOT/lib/managed_files.sh"
# shellcheck source=/dev/null
source "$APP_ROOT/lib/fzf-tui.sh"
# shellcheck source=/dev/null
source "$APP_ROOT/lib/services.sh"
# shellcheck source=/dev/null
source "$APP_ROOT/lib/quality.sh"
# shellcheck source=/dev/null
[ -f "$APP_ROOT/lib/qbit.sh" ] && source "$APP_ROOT/lib/qbit.sh"
# shellcheck source=/dev/null
[ -f "$APP_ROOT/lib/usenet.sh" ] && source "$APP_ROOT/lib/usenet.sh"
# shellcheck source=/dev/null
source "$APP_ROOT/lib/prompts.sh"

readonly SUPPORTED_MEDIA_SERVICES=("jellyfin")
readonly DEFAULT_MEDIA_SERVICE="jellyfin"
readonly DEFAULT_VPN_SERVICE="protonvpn"
readonly MEDIA_SUBDIRS=("torrents/movies" "torrents/tv" "torrents/incomplete" "usenet/incomplete" "usenet/complete/movies" "usenet/complete/tv" "media/movies" "media/tv" "blackhole")
readonly REQUIRED_COMMANDS=("curl" "jq" "sed" "awk" "envsubst" "fzf" "python3")

setup_show_help() {
    echo "Usage: setup.sh [--express | --manual | --restore [archive.tar.gz] | --reconfigure]"
    echo
    echo "Modes:"
    echo "  --express       Minimal prompts with smart defaults"
    echo "  --manual        Full interactive setup (including optional overlays)"
    echo "  --reconfigure   Re-run wizard on an existing installation"
    echo "  --restore FILE  Rebuild stack from a backup archive"
}

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

_map_distro_package() {
    local pm="$1" cmd="$2"
    case "$cmd" in
        envsubst)
            case "$pm" in
                apt) echo "gettext-base" ;;
                *) echo "gettext" ;;
            esac
            ;;
        python3)
            case "$pm" in
                pacman) echo "python" ;;
                *) echo "python3" ;;
            esac
            ;;
        *)
            echo "$cmd"
            ;;
    esac
}

install_packages() {
    local pm pkgs=() c mapped
    pm=$(detect_package_manager)
    for c in "$@"; do
        mapped=$(_map_distro_package "$pm" "$c")
        pkgs+=("$mapped")
    done

    case "$pm" in
        apt)
            sudo apt-get update -qq && sudo apt-get install -y "${pkgs[@]}"
            ;;
        pacman)
            echo
            log_warning "Arch Linux: about to run a full system upgrade (pacman -Syu)."
            log_info "A partial install (-Sy without -u) can break jq (GLIBC mismatch)."
            sudo pacman -Syu --noconfirm --needed "${pkgs[@]}"
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
    local missing_packages=() pkg works

    for pkg in "${REQUIRED_COMMANDS[@]}"; do
        works=false
        if command -v "$pkg" &>/dev/null; then
            case "$pkg" in
                curl) curl --version &>/dev/null && works=true ;;
                jq) echo "{}" | jq . &>/dev/null && works=true ;;
                awk) echo "" | awk '{print}' &>/dev/null && works=true ;;
                sed) echo "" | sed '' &>/dev/null && works=true ;;
                envsubst) echo "" | envsubst &>/dev/null && works=true ;;
                fzf) fzf --version &>/dev/null && works=true ;;
                python3) python3 --version &>/dev/null && works=true ;;
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
        local install_deps="n"
        read_prompt "Would you like to install the missing packages? (y/N) [Default = n]: " install_deps
        install_deps=${install_deps:-"n"}

        if [ "${install_deps,,}" = "y" ]; then
            echo "Installing missing packages..."
            if ! install_packages "${missing_packages[@]}"; then
                log_error "Failed to install missing packages. Please install manually: ${missing_packages[*]}"
            fi
            log_success "Successfully installed missing packages"
        else
            log_error "Please install the required packages manually: ${missing_packages[*]}"
        fi
    fi

    if ! verify_docker; then
        if ! command -v docker &>/dev/null || ! docker compose version &>/dev/null; then
            log_warning "Docker/Docker Compose not found!"
            if grep -qi microsoft /proc/version 2>/dev/null; then
                log_error "WSL2 detected, but Docker Desktop is not running or not installed on Windows.\n\nPlease install Docker Desktop for Windows and enable WSL2 integration:\n  https://docs.docker.com/desktop/wsl/"
            fi
            local install_docker="n"
            read_prompt "Install Docker and Docker Compose? (y/N) [Default = n]: " install_docker
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

    if command -v docker &>/dev/null; then
        if [ "$(command -v docker)" = "/snap/bin/docker" ]; then
            log_error "Docker is installed via snap. ${APP_DISPLAY_NAME} requires the official Docker installation: https://docs.docker.com/engine/install/"
        fi
        log_success "Docker is installed and running"
    fi
    return 0
}

_copy_stall_error() {
    log_error "Timed out writing to ${install_directory} — the drive looks stuck (flaky USB / WSL). From PowerShell: wsl --shutdown — then check the drive in Explorer, or re-run setup and pick Home."
}

copy_configuration_files() {
    local copied=0 src dest src_path dest_path dest_dir rc
    if storage_needs_probe "$install_directory"; then
        log_info "Copying install files to ${install_directory}..."
        if ! probe_writable_path "$(storage_mount_root "$install_directory")"; then
            log_error "Cannot copy install files to ${install_directory}. Pick Home, or fix the drive and re-run setup."
        fi
    else
        log_debug "Copying install tree into $install_directory"
    fi
    UPGRADE_SOURCE_ROOT="${UPGRADE_SOURCE_ROOT:-$APP_ROOT}"
    while IFS='|' read -r src dest; do
        [ -z "$src" ] && continue
        [[ "$src" =~ ^# ]] && continue
        dest_path="$install_directory/$dest"
        dest_dir=$(dirname "$dest_path")
        if [ ! -d "$dest_dir" ]; then
            rc=0
            run_with_timeout 15 mkdir -p "$dest_dir" || rc=$?
            [ "$rc" -eq 124 ] && _copy_stall_error
            [ "$rc" -eq 0 ] || log_error "Failed to create $dest_dir"
        fi

        if ! src_path=$(resolve_project_file "$src"); then
            if [[ "$src" == compose/examples/* ]] || [[ "$src" == NOTICE ]]; then
                log_debug "Optional file not found: $src"
                continue
            fi
            log_error "Failed to locate source file: $src"
        fi

        log_debug "  $src -> $dest_path"
        rc=0
        run_with_timeout 20 cp "$src_path" "$dest_path" || rc=$?
        if [ "$rc" -eq 124 ]; then
            _copy_stall_error
        elif [ "$rc" -eq 0 ]; then
            case "$src" in
                scripts/*.sh|scripts/*.py|bin/*.sh|migrations/*.sh|platform/linux/*.sh)
                    chmod +x "$dest_path" 2>/dev/null || true
                    ;;
            esac
            copied=$((copied + 1))
        else
            log_error "Failed to copy $src to $dest_path. Check permissions"
        fi
    done < <(list_managed_files)
    log_debug "Copied ${copied} file(s) into $install_directory"
}

generate_env_file() {
    local env_file="$install_directory/.env"
    log_debug "Generating environment configuration..."

    if [ "${setup_vpn,,}" = "y" ]; then
        VPN_ENABLED="y"
        VPN_SERVICE="${vpn_service:-}"
        VPN_TYPE="${vpn_type:-openvpn}"
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

    API_HOST="${API_HOST:-127.0.0.1}"
    export PUID="$puid"
    export PGID="$pgid"
    export MEDIA_DIRECTORY="$media_directory"
    export INSTALL_DIRECTORY="$install_directory"
    export MEDIA_SERVICE="${media_service:-jellyfin}"
    export TZ="$tz"
    export VPN_ENABLED VPN_SERVICE VPN_TYPE
    export WIREGUARD_ADDRESSES
    export PORT_FORWARD_ONLY VPN_PORT_FORWARDING
    export QBIT_UI="${qbit_ui:-vuetorrent}"
    if [ "$QBIT_UI" = "vuetorrent" ]; then
        export VUETORRENT_ENABLED="y"
    else
        export VUETORRENT_ENABLED="n"
    fi
    export GPU_TRANSCODING="${gpu_transcoding:-none}"
    export BYPARR_ENABLED="${byparr_enabled:-n}"
    export USENET_ENABLED="${usenet_enabled:-n}"
    export API_HOST

    local env_template
    if ! env_template=$(resolve_project_file ".env.example"); then
        log_error "Failed to locate .env.example"
    fi
    # Explicit key list matching .env.example 1-to-1
    # shellcheck disable=SC2016
    envsubst '${PUID} ${PGID} ${MEDIA_DIRECTORY} ${INSTALL_DIRECTORY} ${MEDIA_SERVICE} ${TZ} ${VPN_ENABLED} ${VPN_SERVICE} ${VPN_TYPE} ${WIREGUARD_ADDRESSES} ${PORT_FORWARD_ONLY} ${VPN_PORT_FORWARDING} ${QBIT_UI} ${VUETORRENT_ENABLED} ${GPU_TRANSCODING} ${BYPARR_ENABLED} ${USENET_ENABLED} ${API_HOST}' \
        < "$env_template" | tr -d '\r' > "$env_file" || \
        log_error "Failed to generate .env file"

    chmod 600 "$env_file"
    log_debug "Environment configuration generated ($env_file)"
}

write_vpn_secrets() {
    if [ "${setup_vpn,,}" != "y" ]; then
        return 0
    fi
    local secrets_dir="$install_directory/secrets"
    mkdir -p "$secrets_dir"
    chmod 700 "$secrets_dir"

    if [ "$vpn_type" = "openvpn" ]; then
        write_secret_file "$secrets_dir/openvpn_user.txt" "${vpn_user:-}"
        write_secret_file "$secrets_dir/openvpn_password.txt" "${vpn_password:-}"
        write_secret_file "$secrets_dir/wireguard_private_key.txt" ""
    else
        write_secret_file "$secrets_dir/wireguard_private_key.txt" "${wireguard_private_key:-}"
        write_secret_file "$secrets_dir/openvpn_user.txt" ""
        write_secret_file "$secrets_dir/openvpn_password.txt" ""
    fi
    log_success "VPN secrets written to $secrets_dir"
}

write_auth_secrets() {
    local secrets_dir="$install_directory/secrets"
    mkdir -p "$secrets_dir"
    chmod 700 "$secrets_dir"
    write_secret_file "$secrets_dir/auth_username.txt" "${auth_username:-admin}"
    write_secret_file "$secrets_dir/auth_password.txt" "${auth_password:-}"
    log_success "Auth credentials written to $secrets_dir"
}

write_opensubtitles_secrets() {
    local secrets_dir="$install_directory/secrets"
    mkdir -p "$secrets_dir"
    if [ "${opensubtitles_enabled:-n}" = "y" ] && [ -n "${opensubtitles_username:-}" ]; then
        write_secret_file "$secrets_dir/opensubtitles_username.txt" "${opensubtitles_username}"
        write_secret_file "$secrets_dir/opensubtitles_password.txt" "${opensubtitles_password:-}"
        log_success "OpenSubtitles.com credentials written to $secrets_dir"
    else
        rm -f "$secrets_dir/opensubtitles_username.txt" "$secrets_dir/opensubtitles_password.txt" 2>/dev/null || true
    fi
}

write_usenet_secrets() {
    local secrets_dir="$install_directory/secrets"
    if [ "${usenet_enabled:-n}" = "y" ] && [ -n "${usenet_password:-}" ]; then
        mkdir -p "$secrets_dir"
        write_secret_file "$secrets_dir/usenet_password.txt" "${usenet_password}"
    fi
}

validate_vpn_config() {
    validate_vpn_secrets "$install_directory" "${setup_vpn,,}" "${VPN_TYPE:-openvpn}"
}

test_vpn_connection() {
    build_compose_args "$install_directory" "${setup_vpn,,}"
    test_vpn_connection_shared run_docker compose "${COMPOSE_ARGS[@]}"
}

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
    media_service="jellyfin"
    media_service_port=8096
    if [ -z "${tz:-}" ]; then
        tz=$(cat /etc/timezone 2>/dev/null || timedatectl show -p Timezone -v 2>/dev/null | tail -1 || echo "UTC")
        tz=${tz:-UTC}
    fi
    export username puid pgid install_directory media_directory media_service media_service_port tz
}

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
        echo "Credentials live under $install_directory/secrets/ (not in .env)."
        local retry=""
        read_prompt "Re-enter VPN credentials and try again? (Y/n) [Default = y]: " retry
        retry=${retry:-y}
        if [ "${retry,,}" != "y" ]; then
            echo
            echo "Setup stopped — VPN was not verified, so the rest of the wizard was not run."
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
        generate_env_file
    done
}

early_vpn_gate() {
    if [ "${setup_vpn,,}" != "y" ]; then
        return 0
    fi
    echo
    log_info "Testing VPN connection before the rest of setup..."
    set_provisional_vpn_test_defaults
    _ASSEMBLRR_PROVISIONAL_INSTALL="$install_directory"
    export _ASSEMBLRR_PROVISIONAL_INSTALL
    bootstrap_operator
    generate_env_file
    write_vpn_secrets
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
MEDIA_SERVICE="${media_service:-jellyfin}"
VPN_ENABLED="${setup_vpn,,}"
VPN_TYPE="${vpn_type:-openvpn}"
TZ="$tz"
QBIT_UI="${qbit_ui:-vuetorrent}"
VUETORRENT_ENABLED="$([ "${qbit_ui:-vuetorrent}" = "vuetorrent" ] && echo y || echo n)"
GPU_TRANSCODING="${gpu_transcoding:-none}"
BYPARR_ENABLED="${byparr_enabled:-n}"
USENET_ENABLED="${usenet_enabled:-n}"
USENET_HOST="${usenet_host:-}"
USENET_PORT="${usenet_port:-563}"
USENET_SSL="${usenet_ssl:-y}"
USENET_USERNAME="${usenet_username:-}"
USENET_CONNECTIONS="${usenet_connections:-8}"
QUALITY_TIER="$(quality_tier)"
QUALITY_SOURCE="$(quality_source)"
SEERR_IS_4K="$(quality_seerr_is_4k)"
SUBTITLE_LANGUAGE="${subtitle_language:-}"
SUBTITLE_LANGUAGES="${subtitle_languages:-${subtitle_language:-}}"
SETUP_MODE="${SETUP_MODE:-manual}"
EOF
    chmod 600 "$config_file"
    write_install_pointer "$install_directory" "$media_directory"
    log_debug "Runtime config written to $config_file"
}

_record_install_metadata() {
    local channel="${ASSEMBLRR_INSTALL_REF:-main}"
    printf '%s\n' "$channel" > "$install_directory/.assemblrr-channel"

    local sha="unknown"
    if [ -d "$APP_ROOT/.git" ]; then
        sha=$(git -C "$APP_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    fi
    printf 'setup:%s@%s(%s)\n' "${APP_REPO_URL:-https://github.com/soulis-1256/assemblrr}" "$channel" "$sha" \
        > "$install_directory/.assemblrr-version"

    if [ -d "$APP_ROOT/migrations" ]; then
        local mf mid
        : > "$install_directory/.assemblrr-migrations"
        while IFS= read -r -d '' mf; do
            mid=$(sed -n 's/^migration_id=["\x27]\([^"\x27]*\)["\x27].*/\1/p' "$mf" 2>/dev/null | head -1)
            [ -n "$mid" ] && printf '%s\n' "$mid" >> "$install_directory/.assemblrr-migrations"
        done < <(find "$APP_ROOT/migrations" -maxdepth 1 -type f -name '*.sh' -print0 2>/dev/null | sort -z)
    fi
}

install_cli() {
    if [ ! -f "$install_directory/cli.sh" ]; then
        log_warning "CLI source missing at $install_directory/cli.sh — skip install"
        return 1
    fi
    write_install_pointer "$install_directory" "${media_directory:-}"
    install_user_cli_wrapper
    log_debug "CLI installed to $HOME/.local/bin/$APP_CLI_NAME"
}

bootstrap_operator() {
    local quiet="${1:-}"
    mkdir -p "$install_directory"
    if [ "${ASSEMBLRR_RECONFIGURE:-0}" != "1" ]; then
        : > "$install_directory/.assemblrr-setup-in-progress"
    fi
    copy_configuration_files
    write_runtime_config
    if install_cli; then
        if [ "$quiet" != "quiet" ]; then
            log_success "Operator CLI ready: $HOME/.local/bin/$APP_CLI_NAME"
            log_info "Abort anytime with: $APP_CLI_NAME uninstall"
            log_info "If the shell says command not found: $HOME/.local/bin/$APP_CLI_NAME uninstall"
        fi
    fi
}

set_permissions() {
    log_debug "Setting ownership for install and media directories..."
    prepare_install_dirs "$install_directory" "$puid" "$pgid"
    if [ ! -d "$media_directory" ]; then
        mkdir -p "$media_directory" || log_error "Failed to create media directory $media_directory"
    fi
    ensure_owned "$media_directory" "$puid" "$pgid"
    log_debug "Ownership set for $install_directory and $media_directory"
}

_validate_restore_archive() {
    local archive="$1"
    [ -f "$archive" ] || return 1
    gzip -t "$archive" 2>/dev/null || return 1
    local listing has_env=0 bad_path=0 entry
    listing=$(tar -tzf "$archive" 2>/dev/null) || return 1
    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        case "$entry" in
            .env|./.env) has_env=1 ;;
        esac
        case "$entry" in
            /*|..|../*|*/../*|*/..) bad_path=1; break ;;
        esac
    done <<< "$listing"
    [ "$bad_path" -eq 0 ] && [ "$has_env" -eq 1 ]
}

restore_from_backup_wizard() {
    echo ""
    log_info "========================================================"
    log_info "  ${APP_DISPLAY_NAME} — Restore from Backup Archive"
    log_info "========================================================"
    echo ""

    local backup_file="${RESTORE_BACKUP_FILE:-}" backup_input=""
    while [ -z "$backup_file" ] || [ ! -f "$backup_file" ]; do
        read_prompt "Enter path to backup archive (.tar.gz): " backup_input
        backup_input=${backup_input:-}
        if [ -z "$backup_input" ]; then
            log_warning "Please enter a valid file path."
            continue
        fi
        backup_file=$(expand_path "$backup_input")
        if [ ! -f "$backup_file" ]; then
            log_warning "Backup file not found: $backup_file"
            backup_file=""
            continue
        fi
        if ! _validate_restore_archive "$backup_file"; then
            log_warning "Invalid or unsafe backup archive (must contain .env without traversal): $backup_file"
            backup_file=""
            continue
        fi
    done

    echo ""
    local default_install="$APP_DEFAULT_INSTALL_DIR" target_install="" target_input=""
    while true; do
        read_prompt "Enter target installation directory [$default_install]: " target_input
        target_input=${target_input:-$default_install}
        target_install=$(expand_path "$target_input")
        [ -n "$target_install" ] && break
        log_warning "Invalid directory path."
    done

    install_directory="$target_install"
    export install_directory

    if [ -d "$install_directory" ] && [ "$(ls -A "$install_directory" 2>/dev/null)" ]; then
        echo ""
        log_warning "Target directory $install_directory already exists and is not empty."
        local confirm_overwrite="n"
        read_prompt "Overwrite existing directory contents with backup? [y/N]: " confirm_overwrite
        confirm_overwrite=${confirm_overwrite:-n}
        if [[ ! ${confirm_overwrite,,} =~ ^y$ ]]; then
            log_info "Restore cancelled."
            exit 0
        fi
    fi

    mkdir -p "$install_directory"
    log_info "Extracting backup archive into $install_directory..."
    local abs_backup
    abs_backup=$(realpath "$backup_file")

    if ! tar --no-same-owner -xzf "$abs_backup" -C "$install_directory" 2>/dev/null; then
        if ! run_docker run --rm \
            -v "$install_directory:/target" \
            -v "$(dirname "$abs_backup"):/backup:ro" \
            "${UTILITY_ALPINE_IMAGE:-alpine:3.24.4}" \
            tar --no-same-owner -xzf "/backup/$(basename "$abs_backup")" -C /target; then
            log_error "Failed to extract backup archive."
        fi
    fi

    if [ -f "$install_directory/.env" ]; then
        safe_source "$install_directory/.env" 2>/dev/null || true
    fi
    if [ -f "$install_directory/.assemblrr-config" ]; then
        safe_source "$install_directory/.assemblrr-config" 2>/dev/null || true
    elif [ -f "$install_directory/.${APP_NAME}-config" ]; then
        safe_source "$install_directory/.${APP_NAME}-config" 2>/dev/null || true
    fi

    # Cross-host adaptation: rewrite INSTALL_DIRECTORY if extracted to a new host path
    local f
    for f in "$install_directory/.assemblrr-config" "$install_directory/.${APP_NAME}-config"; do
        [ -f "$f" ] && sed -i -E "s|^INSTALL_DIRECTORY=.*|INSTALL_DIRECTORY=\"${install_directory}\"|" "$f" 2>/dev/null || true
    done
    [ -f "$install_directory/.env" ] && sed -i -E "s|^INSTALL_DIRECTORY=.*|INSTALL_DIRECTORY=${install_directory}|" "$install_directory/.env" 2>/dev/null || true

    puid="${PUID:-$(id -u)}"
    pgid="${PGID:-$(id -g)}"
    media_directory="${MEDIA_DIRECTORY:-$APP_DEFAULT_MEDIA_DIR}"
    media_service="${MEDIA_SERVICE:-jellyfin}"
    setup_vpn="${VPN_ENABLED:-n}"
    tz="${TZ:-UTC}"
    export puid pgid media_directory media_service setup_vpn tz

    prepare_install_dirs "$install_directory" "$puid" "$pgid"
    if [ ! -d "$media_directory" ]; then
        mkdir -p "$media_directory" 2>/dev/null || true
    fi
    ensure_owned "$media_directory" "$puid" "$pgid" 2>/dev/null || true
    write_install_pointer "$install_directory" "$media_directory"

    chmod +x "$install_directory/scripts/"*.sh "$install_directory/cli.sh" "$install_directory/config.sh" "$install_directory/setup.sh" 2>/dev/null || true
    install_cli

    log_success "Backup extracted and configuration loaded."
    echo ""
    log_info "Starting restored services..."

    build_compose_args "$install_directory" "${setup_vpn,,}"
    if ! compose_up_stack "default"; then
        log_warning "Failed to start some restored services."
        log_info "Run '$APP_CLI_NAME logs' or '$APP_CLI_NAME status' to inspect."
        exit 1
    fi
    rm -f "$install_directory/.assemblrr-setup-in-progress"

    echo ""
    echo "========================================================"
    log_success "${APP_DISPLAY_NAME} restored and running!"
    echo "========================================================"
    echo ""
    if [ -f "$install_directory/cli.sh" ]; then
        bash "$install_directory/cli.sh" status --compact || true
        echo
    fi
    printf "  %-18s %s  ·  %s\n" "Paths:" "$install_directory" "$media_directory"
    printf "  %-18s %s status | config edit | upgrade | uninstall\n" "Manage:" "$APP_CLI_NAME"
    echo ""
    exit 0
}

setup_on_interrupt() {
    trap - INT TERM
    stty echo 2>/dev/null || true
    echo >&2

    local inst="${install_directory:-${_ASSEMBLRR_PROVISIONAL_INSTALL:-}}"
    local media="${media_directory:-}"
    local has_inst=0 has_media=0 has_containers=0
    if [ -n "$inst" ] && [ -d "$inst" ] && [ -f "$inst/.assemblrr-setup-in-progress" ]; then
        has_inst=1
    fi
    if [ -n "$media" ] && [ -d "$media" ]; then
        has_media=1
    fi
    if command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx 'gluetun'; then
        has_containers=1
    fi

    if [ "$has_inst" -eq 0 ] && [ "$has_containers" -eq 0 ]; then
        log_info "Setup cancelled — nothing was installed."
        exit 130
    fi

    echo
    log_warning "Setup interrupted before completion."
    echo "Created so far:"
    [ "$has_inst" -eq 1 ] && echo "  - Partial config & CLI: $inst"
    [ "$has_containers" -eq 1 ] && echo "  - Temporary VPN container: gluetun"
    [ "$has_media" -eq 1 ] && echo "  - Media folders: $media"
    echo "Not installed yet:"
    echo "  - Core media stack containers & service wiring"
    echo

    local ans="n"
    if [ -t 0 ] && [ -r /dev/tty ]; then
        read_prompt "Clean up partial setup now (stops temp containers & deletes partial config; keeps any media files)? [Y/n]: " ans
        ans=${ans:-y}
    fi

    if [ "${ans,,}" = "y" ]; then
        if [ "$has_inst" -eq 1 ]; then
            type _cleanup_leftover_compose >/dev/null 2>&1 && _cleanup_leftover_compose "$inst"
            safe_rm_rf "$inst"
        elif [ "$has_containers" -eq 1 ]; then
            docker rm -f gluetun >/dev/null 2>&1 || true
            docker network rm "${APP_NETWORK_NAME:-assemblrr_network}" >/dev/null 2>&1 || true
        fi
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
        if [ "$has_media" -eq 1 ]; then
            if [ -z "$(find "$media" -type f -print -quit 2>/dev/null || true)" ]; then
                safe_rm_rf "$media"
                log_info "Empty media folder skeleton removed ($media)."
            else
                log_info "Existing files found under $media — kept untouched."
            fi
        fi
        log_success "Partial setup cleaned up."
    else
        log_info "Partial setup left in place. Re-run setup.sh to clean up, or run: ${APP_CLI_NAME:-assemblrr} uninstall --force"
    fi
    exit 130
}

main() {
    RESTORE_BACKUP_FILE=""
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help) setup_show_help; exit 0 ;;
            --restore)
                SETUP_MODE="restore"
                if [ -n "${2:-}" ] && [[ ! "$2" =~ ^-- ]]; then
                    RESTORE_BACKUP_FILE="$2"
                    shift
                fi
                shift
                ;;
            --restore=*)
                SETUP_MODE="restore"
                RESTORE_BACKUP_FILE="${1#*=}"
                shift
                ;;
            --express) SETUP_MODE="express"; shift ;;
            --manual) SETUP_MODE="manual"; shift ;;
            --reconfigure) ASSEMBLRR_RECONFIGURE=1; export ASSEMBLRR_RECONFIGURE; shift ;;
            *) shift ;;
        esac
    done

    if [[ "${EUID:-$(id -u)}" = 0 ]]; then
        log_error "${APP_DISPLAY_NAME} must run without sudo! Please run with regular permissions"
    fi
    trap 'setup_on_interrupt' INT TERM

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

    if [ -z "${SETUP_MODE:-}" ]; then
        echo "  1) Express (recommended — minimal questions, smart defaults)"
        echo "  2) Manual (full control over every setting)"
        echo "  3) Restore (rebuild stack from an existing backup archive)"
        while true; do
            read_prompt "Choose setup mode [1]: " setup_mode_choice
            setup_mode_choice=${setup_mode_choice:-1}
            case "$setup_mode_choice" in
                1) SETUP_MODE="express"; break ;;
                2) SETUP_MODE="manual"; break ;;
                3) SETUP_MODE="restore"; break ;;
                *) log_warning "Invalid choice. Please choose 1, 2, or 3." ;;
            esac
        done
    fi
    export SETUP_MODE

    if [ "$SETUP_MODE" = "express" ]; then
        echo ""
        log_success "Express mode — we'll use smart defaults and only ask the essentials."
        echo ""
    elif [ "$SETUP_MODE" = "restore" ]; then
        echo ""
        log_info "Restore mode — we'll rebuild your stack from an existing backup archive."
        echo ""
    else
        echo ""
        log_info "Manual mode — you'll configure every setting."
        echo ""
    fi

    LOG_FILE="/tmp/${APP_NAME}-setup-$(date '+%Y%m%d-%H%M%S').log"
    log_info "Setup log: $LOG_FILE"
    log_info "Checking prerequisites..."
    check_dependencies

    if [ "${SETUP_MODE:-}" = "restore" ]; then
        restore_from_backup_wizard
    fi

    refuse_setup_if_already_installed
    offer_leftover_cleanup

    configure_vpn
    early_vpn_gate

    get_user_info
    get_installation_paths
    bootstrap_operator quiet
    configure_media_service
    configure_quality_profile
    configure_subtitle_language
    configure_opensubtitles
    configure_qbit_ui
    configure_gpu_transcoding
    configure_byparr
    configure_usenet
    configure_timezone
    configure_auth

    echo
    echo "========================================================"
    echo "  ${APP_DISPLAY_NAME} — Installation Summary"
    echo "========================================================"
    echo "  User:              $username (PUID=$puid, PGID=$pgid)"
    echo "  Install directory: $install_directory"
    echo "  Media directory:   $media_directory"
    setup_vpn="${setup_vpn:-n}"
    enable_port_forwarding="${enable_port_forwarding:-n}"
    if [ "${setup_vpn,,}" = "y" ]; then
        echo "  VPN:               ENABLED (${vpn_service:-}, ${vpn_type:-wireguard})"
        echo "  Port forwarding:   ${enable_port_forwarding:-n}"
    else
        echo "  VPN:               DISABLED"
    fi
    echo "  Media service:     $media_service (port $media_service_port)"
    echo "  qBittorrent UI:    ${qbit_ui:-vuetorrent}"
    echo "  GPU transcoding:   ${gpu_transcoding:-none}"
    echo "  Byparr solver:     ${byparr_enabled:-n}"
    echo "  SABnzbd / Usenet:  ${usenet_enabled:-n}"
    if [ "$QUALITY_TIER" = "any" ]; then
        echo "  Quality profile:   any"
    else
        echo "  Quality profile:   $QUALITY_TIER / ${QUALITY_SOURCE:-bluray} (4K=${seerr_is_4k:-false})"
    fi
    if [ -n "${subtitle_languages:-}" ] && [ "${subtitle_languages}" != "${subtitle_language:-}" ]; then
        echo "  Subtitle languages: ${subtitle_language} (preferred), ${subtitle_languages#*,}"
    else
        echo "  Subtitle language: ${subtitle_language:-en (Bazarr default)}"
    fi
    if [ "${opensubtitles_enabled:-n}" = "y" ]; then
        echo "  OpenSubtitles.com: yes (username=${opensubtitles_username})"
    else
        echo "  OpenSubtitles.com: no"
    fi
    echo "  Timezone:          $tz"
    echo "  Service login:     $auth_username"
    echo "========================================================"
    echo

    if [ "${SETUP_MODE:-}" != "express" ]; then
        while true; do
            read_prompt "Proceed with installation? (Y/n) [Default = y]: " proceed
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

    copy_configuration_files
    generate_env_file
    write_vpn_secrets
    prepare_install_dirs "$install_directory" "$puid" "$pgid"

    if [ "${setup_vpn,,}" = "y" ] && [ "${VPN_ALREADY_VERIFIED:-}" != "1" ]; then
        ensure_vpn_connection
    elif [ "${setup_vpn,,}" = "y" ]; then
        log_debug "VPN already verified earlier — not re-testing."
    fi

    write_auth_secrets
    write_opensubtitles_secrets
    write_usenet_secrets
    QBIT_UI="${qbit_ui:-vuetorrent}" VUETORRENT_ENABLED="${vuetorrent_enabled:-y}" write_qbittorrent_config
    write_runtime_config
    _record_install_metadata
    install_cli
    set_permissions

    log_success "Install files ready — starting services..."
    prepare_install_dirs "$install_directory" "$puid" "$pgid"
    build_compose_args "$install_directory" "${setup_vpn,,}"
    if ! compose_up_stack "default"; then
        echo
        log_warning "Failed to start ${APP_DISPLAY_NAME} services"
        echo
        log_info "The operator CLI is already installed. From a WSL or Linux shell:"
        log_info "  $HOME/.local/bin/$APP_CLI_NAME status"
        log_info "  $HOME/.local/bin/$APP_CLI_NAME uninstall"
        log_info "If '$APP_CLI_NAME' is not found, use that full path (or open a new terminal)."
        echo
        exit 1
    fi
    rm -f "$install_directory/.assemblrr-setup-in-progress"
    trap - INT TERM

    local wiring_ok=1
    if [ -f "$install_directory/config.sh" ]; then
        if ! ASSEMBLRR_FROM_SETUP=1 bash "$install_directory/config.sh"; then
            wiring_ok=0
            log_warning "Service wiring had critical failures. Containers are still running."
            log_warning "Fix the issues above, then re-run: $APP_CLI_NAME config apply"
        fi
    fi
    rm -f "$install_directory/configure.sh" 2>/dev/null || true
    rm -f "$HOME/assemblrr_services.txt" 2>/dev/null || true

    local -a ready_badges=()
    if [ "${setup_vpn,,}" = "y" ]; then
        ready_badges+=("VPN on")
    else
        ready_badges+=("VPN off")
    fi
    [ "${gpu_transcoding:-none}" != "none" ] && ready_badges+=("GPU ${gpu_transcoding}")
    case "${qbit_ui:-vuetorrent}" in
        vuetorrent) ready_badges+=("VueTorrent") ;;
        qui)        ready_badges+=("qui") ;;
    esac
    [ "${byparr_enabled:-n}" = "y" ] && ready_badges+=("Byparr")
    [ "${usenet_enabled:-n}" = "y" ] && ready_badges+=("Usenet")
    local badge_str="" _b
    for _b in "${ready_badges[@]}"; do
        [ -n "$badge_str" ] && badge_str+=" · "
        badge_str+="$_b"
    done

    local ui_host="${API_HOST:-localhost}"
    [ "$ui_host" = "127.0.0.1" ] && ui_host="localhost"

    echo
    echo "========================================================"
    if [ "$wiring_ok" -eq 1 ]; then
        log_success "${APP_DISPLAY_NAME} is ready!  (${badge_str})"
    else
        log_warning "${APP_DISPLAY_NAME} started with wiring warnings  (${badge_str})"
    fi
    echo "========================================================"
    echo

    if [ -f "$install_directory/cli.sh" ]; then
        bash "$install_directory/cli.sh" status --compact || true
        echo
    elif type running_services_location >/dev/null 2>&1; then
        running_services_location
        echo
    fi

    if [ -n "${auth_username:-}" ]; then
        printf "  %-18s %s / <your setup password>\n" "Login:" "$auth_username"
    fi
    printf "  %-18s %s  ·  %s\n" "Paths:" "$install_directory" "$media_directory"
    echo
    printf "  %-18s Request in Seerr (http://%s:5055/), watch in Jellyfin (http://%s:8096/)\n" "Start here:" "$ui_host" "$ui_host"
    printf "  %-18s %s status | config edit | upgrade | uninstall\n" "Manage:" "$APP_CLI_NAME"
    if [ "$wiring_ok" -eq 0 ]; then
        printf "  %-18s %s config apply\n" "Fix wiring:" "$APP_CLI_NAME"
    fi
    echo

    [ "$wiring_ok" -eq 1 ] && exit 0
    exit 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
