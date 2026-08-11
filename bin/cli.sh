#!/bin/bash
set -euo pipefail

# assemblrr CLI — manages your media server
# This file is installed to ~/.local/bin/<APP_CLI_NAME> during setup

# Source shared library (safe_source, find_install_directory, logging, colors)
# CLI is installed to ~/.local/bin, lib/ lives next to it or in the install dir
_cli_self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Locate lib directory (repo: lib/ sibling of bin/; installed: lib/ next to CLI)
if [ -f "$_cli_self/../lib/core.sh" ]; then
    _lib_dir="$_cli_self/../lib"
elif [ -f "$_cli_self/lib/core.sh" ]; then
    _lib_dir="$_cli_self/lib"
else
    # Fallback: find install dir first, then source from there
    _tmp_install=$(grep -r "^INSTALL_DIRECTORY=" /opt/assemblrr/.assemblrr-config "$HOME/assemblrr/.assemblrr-config" "$HOME/.assemblrr-config" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '"' || true)
    if [ -n "$_tmp_install" ] && [ -f "$_tmp_install/lib/core.sh" ]; then
        _lib_dir="$_tmp_install/lib"
    else
        echo -e "\033[0;31mError: lib/core.sh not found. Re-run setup.\033[0m" >&2
        exit 1
    fi
fi

source "$_lib_dir/core.sh"
source "$_lib_dir/branding.sh"
source "$_lib_dir/compose.sh"
source "$_lib_dir/vpn.sh"

INSTALL_DIR=$(find_install_directory)
if [ -z "$INSTALL_DIR" ]; then
    log_error "Could not find ${APP_NAME:-assemblrr} installation. Run setup first."
fi

# Source runtime config
safe_source "$INSTALL_DIR/.assemblrr-config"

# Source branding from install directory
load_branding "$INSTALL_DIR"

# Build compose command dynamically (uses lib/compose.sh build_compose_args + adds profile)
build_compose_args "$INSTALL_DIR" "${VPN_ENABLED:-n}"
DC=(run_docker compose "${COMPOSE_ARGS[@]}" "--profile" "${MEDIA_SERVICE:-jellyfin}")
readonly TIMEOUT_SECONDS=60
readonly IP_ENDPOINTS=(
    "https://ipinfo.io/ip"
    "https://api.ipify.org"
    "https://checkip.amazonaws.com"
    "https://tnedi.me"
    "https://api.myip.la"
    "https://wtfismyip.com/text"
)

# Commands
declare -A COMMANDS=(
    ["--help"]="displays this help message"
    ["restart"]="restarts services (can specify service names)"
    ["stop"]="stops all services (can specify service names)"
    ["start"]="starts services (can specify service names)"
    ["status"]="checks services status"
    ["destroy"]="destroys services so you can start from scratch (can specify service names)"
    ["uninstall"]="completely removes the stack (keeps media unless confirmed) — see docs/uninstall.md"
    ["check-vpn"]="checks if the VPN is working as expected"
    ["backup"]="backs up to the destination location"
    ["restore"]="restores from a backup archive"
    ["update-containers"]="updates all containers"
    ["update-cli"]="updates the CLI script to the latest version"
    ["logs"]="shows container logs (optionally specify service name)"
    ["health"]="checks health status of all services"
    ["config"]="configuration: show options, or run show / edit / sync"
)

# log_error_inline — same as log_error but without exit (used by check_health)
log_error_inline() { echo -e "${RED}$1${NC}"; }



show_help() {
    echo "${APP_DISPLAY_NAME} - ${APP_DESCRIPTION:-Your one-click media server}"
    echo
    echo "Usage: ${APP_CLI_NAME} [command] [options]"
    echo
    echo "Commands:"
    for cmd in "${!COMMANDS[@]}"; do
        printf "%-25s %s\n" "$cmd" "${COMMANDS[$cmd]}"
    done
    echo
    echo "Examples:"
    echo "  ${APP_CLI_NAME} start              # Start all services"
    echo "  ${APP_CLI_NAME} start jellyfin     # Start the 'jellyfin' service"
    echo "  ${APP_CLI_NAME} stop jellyfin      # Stop the 'jellyfin' service"
    echo "  ${APP_CLI_NAME} restart jellyfin   # Restart the 'jellyfin' service"
    echo "  ${APP_CLI_NAME} destroy jellyfin   # Destroy the 'jellyfin' service"
    echo "  ${APP_CLI_NAME} backup /path/to/backup  # Backup to specified directory"
    echo "  ${APP_CLI_NAME} restore /path/to/backup.tar.gz  # Restore from backup"
    echo "  ${APP_CLI_NAME} uninstall          # Remove everything (asks before deleting data)"
    echo "  ${APP_CLI_NAME} uninstall --force  # Remove without prompts (keeps media)"
    echo "  ${APP_CLI_NAME} uninstall --force --media  # Remove everything including media"
    echo "  ${APP_CLI_NAME} logs               # View all container logs"
    echo "  ${APP_CLI_NAME} logs jellyfin       # View specific service logs"
    echo "  ${APP_CLI_NAME} health              # Check health of all services"
    echo "  ${APP_CLI_NAME} update-cli          # Update CLI to latest version"
    echo "  ${APP_CLI_NAME} config              # List config subcommands"
    echo "  ${APP_CLI_NAME} config show         # Show current configuration"
    echo "  ${APP_CLI_NAME} config edit         # Re-run setup wizard"
    echo "  ${APP_CLI_NAME} config sync         # Re-wire service APIs"
}

wait_for_services() {
    local wait_time=0
    echo -n "Waiting for services to start"

    while [ $wait_time -lt $TIMEOUT_SECONDS ]; do
        local total_services
        local running_services

        total_services=$("${DC[@]}" ps --format '{{.Name}}' | wc -l)
        running_services=$("${DC[@]}" ps --format '{{.Status}}' | grep -c "Up")

        if [ "$total_services" -eq "$running_services" ] && [ "$total_services" -gt 0 ]; then
            echo
            log_success "All $total_services services are up and running!"
            return 0
        fi

        echo -n "."
        sleep 1
        ((wait_time++))

        if [ $((wait_time % 10)) -eq 0 ]; then
            echo
            echo -n "$running_services/$total_services services running"
        fi
    done

    echo
    log_error "Not all services started within ${TIMEOUT_SECONDS} seconds ($running_services/$total_services running)"
}

get_ip_with_retries() {
    local context=$1
    local cmd_prefix=""

    if [ "$context" = "qbittorrent" ]; then
        cmd_prefix="run_docker exec qbittorrent"
    fi

    for endpoint in "${IP_ENDPOINTS[@]}"; do
        local ip
        if [ "$context" = "local" ]; then
            ip=$(curl -s --connect-timeout 5 "$endpoint")
        else
            ip=$($cmd_prefix curl -s --connect-timeout 5 "$endpoint")
        fi

        if [ -n "$ip" ] && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

check_vpn() {
    echo "Getting your IP..."
    local your_ip
    your_ip=$(get_ip_with_retries "local") || log_error "Failed to get your IP address from any endpoint"
    echo "Your IP: $your_ip"

    local country
    country=$(curl -s --connect-timeout 5 "https://am.i.mullvad.net/country") || log_warning "Couldn't determine your country"
    [ -n "$country" ] && echo "Your local IP country is $country"

    echo -e "\nGetting your qBittorrent IP..."
    local qbit_ip
    qbit_ip=$(get_ip_with_retries "qbittorrent") || log_error "Failed to get qBittorrent IP from any endpoint"
    echo "qBittorrent IP: $qbit_ip"

    local qbit_country
    qbit_country=$(run_docker exec qbittorrent curl -s --connect-timeout 5 "https://am.i.mullvad.net/country") || log_warning "Couldn't determine qBittorrent country"
    [ -n "$qbit_country" ] && echo "qBittorrent country is $qbit_country"

    if [ "$qbit_ip" == "$your_ip" ]; then
        log_error "WARNING: Your IPs are the same! qBittorrent is exposing your IP!"
    else
        log_success "Success: Your IPs are different. qBittorrent is masking your IP!"
    fi
}

backup_app() {
    local destination=$1
    local backup_date
    backup_date=$(date '+%Y-%m-%d-%s')
    local backup_file="$destination/${APP_BACKUP_PREFIX}-$backup_date.tar.gz"

    # Verify destination exists or create it
    if [ ! -d "$destination" ]; then
        log_info "Backup destination \"$destination\" does not exist. Creating it..."
        mkdir -p "$destination" || log_error "Failed to create backup destination directory"
    fi

    echo "Stopping ${APP_DISPLAY_NAME} services..."
    "${DC[@]}" stop > /dev/null 2>&1 || log_error "Failed to stop services"

    echo -e "\nBacking up ${APP_DISPLAY_NAME} to $destination..."
    echo "This may take a while depending on the size of your installation."

    # Copy current CLI script and lib modules, create backup (skip copy if running from install dir)
    local running_cli; running_cli="$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${_cli_self}/cli.sh")"
    local target_cli; target_cli="$(realpath "$INSTALL_DIR/cli.sh" 2>/dev/null || echo "$INSTALL_DIR/cli.sh")"
    if [ -f "$running_cli" ] && [ "$running_cli" != "$target_cli" ]; then
        cp "$running_cli" "$INSTALL_DIR/cli.sh" 2>/dev/null || log_warning "Failed to backup CLI script"
    fi
    
    # Copy lib modules if they exist outside target dir
    if [ -d "$HOME/.local/bin/lib" ] && [ "$(realpath "$HOME/.local/bin/lib" 2>/dev/null)" != "$(realpath "$INSTALL_DIR/lib" 2>/dev/null)" ]; then
        cp -r "$HOME/.local/bin/lib" "$INSTALL_DIR/" 2>/dev/null || true
    fi
    
    # Run tar inside an alpine container bound to the INSTALL_DIR and the destination (excluding temp/cache and sockets)
    run_docker run --rm \
        -v "$INSTALL_DIR:/source" \
        -v "$(dirname "$backup_file"):/backup" \
        alpine tar --exclude='./transcoding-temp' --exclude='./config/jellyfin/cache' --exclude='ipc-socket' -czf "/backup/$(basename "$backup_file")" -C /source . ||
        log_error "Failed to create backup archive"

    echo -e "\nStarting ${APP_DISPLAY_NAME} services..."
    "${DC[@]}" start > /dev/null 2>&1 || log_warning "Failed to restart services"

    log_success "Backup completed successfully!"
    echo "Backup file: $backup_file"
}

destroy_app() {
    if [ "$#" -eq 0 ]; then
        echo -e "\nWARNING: This will destroy all your services, containers, volumes, and the custom network!"
        echo "This is not recoverable!"
        while true; do
            read -p "Are you sure you want to continue? [y/N]: " -r
            local reply=${REPLY:-n}
            if [[ ${reply,,} =~ ^y$ ]]; then
                "${DC[@]}" down || log_error "Failed to destroy services"
                docker network rm "$APP_NETWORK_NAME" 2>/dev/null || log_warning "Failed to remove $APP_NETWORK_NAME. It might not exist or was already removed."
                echo -e "\n${APP_DISPLAY_NAME} services were destroyed. To restart, run: ${APP_CLI_NAME} start"
                break
            elif [[ ${reply,,} =~ ^n$ ]]; then
                log_info "Destroy cancelled."
                break
            else
                log_warning "Please answer y or n."
            fi
        done
    else
        local target_label="$*"
        echo -e "\nWARNING: This will destroy the service(s): \"${target_label}\". This includes their associated containers and volumes!"
        echo "This is not recoverable!"
        while true; do
            read -p "Are you sure you want to continue? [y/N]: " -r
            local reply=${REPLY:-n}
            if [[ ${reply,,} =~ ^y$ ]]; then
                "${DC[@]}" stop "$@" || log_error "Failed to stop services"
                "${DC[@]}" rm -f -v "$@" || log_error "Failed to destroy services"
                echo -e "\n${APP_DISPLAY_NAME} service was destroyed. To restart, run: ${APP_CLI_NAME} start"
                break
            elif [[ ${reply,,} =~ ^n$ ]]; then
                log_info "Destroy cancelled."
                break
            else
                log_warning "Please answer y or n."
            fi
        done
    fi
}

uninstall_app() {
    local force=false
    local delete_media=false
    for arg in "$@"; do
        case "$arg" in
            -f|--force) force=true ;;
            -m|--media) delete_media=true ;;
        esac
    done

    # --force already opts out of all confirmation; skip the scary preamble.
    if [ "$force" = false ]; then
        echo -e "\nWARNING: This will COMPLETELY remove ${APP_DISPLAY_NAME}!"
        echo "This includes:"
        echo "  - All running containers and volumes"
        echo "  - The installation directory: $INSTALL_DIR"
        echo "  - The CLI command: $APP_CLI_NAME"
        echo "  - The Docker network: $APP_NETWORK_NAME"
        echo
        echo "Your media directory ($MEDIA_DIRECTORY) is kept unless you explicitly delete it."
        echo "Tip: run '${APP_CLI_NAME} backup <target-dir>' first if you want to keep your configuration."
        echo
        echo "This is not recoverable!"
        read -p "Are you ABSOLUTELY sure? Type 'yes' to confirm: " -r
        if [[ "$REPLY" != "yes" ]]; then
            echo "Uninstall cancelled."
            return 0
        fi
    fi

    echo "Stopping all services and removing volumes..."
    "${DC[@]}" down -v 2>/dev/null || log_warning "Failed to stop some services"

    echo "Removing Docker network..."
    if run_docker network inspect "$APP_NETWORK_NAME" &>/dev/null; then
        run_docker network rm "$APP_NETWORK_NAME" 2>/dev/null || log_warning "Failed to remove Docker network $APP_NETWORK_NAME"
    fi

    echo "Removing installation directory..."
    if [ "$force" = true ]; then
        safe_rm_rf "$INSTALL_DIR"
        log_warning "Installation directory deleted"
    else
        read -p "Also delete config at $INSTALL_DIR? Type the full path to confirm: " -r
        if [[ "$REPLY" = "$INSTALL_DIR" ]]; then
            safe_rm_rf "$INSTALL_DIR"
            log_warning "Installation directory deleted"
        else
            log_info "Installation directory preserved at $INSTALL_DIR"
        fi
    fi

    if [ "$delete_media" = true ]; then
        safe_rm_rf "$MEDIA_DIRECTORY"
        log_warning "Media directory deleted"
    elif [ "$force" = false ]; then
        read -p "Also delete media at $MEDIA_DIRECTORY? Type the full path to confirm: " -r
        if [[ "$REPLY" = "$MEDIA_DIRECTORY" ]]; then
            safe_rm_rf "$MEDIA_DIRECTORY"
            log_warning "Media directory deleted"
        else
            log_info "Media directory preserved at $MEDIA_DIRECTORY"
        fi
    else
        log_info "Media directory preserved at $MEDIA_DIRECTORY"
    fi

    echo "Removing CLI..."
    if [ -n "${APP_CLI_NAME:-}" ]; then
        rm -f "$HOME/.local/bin/$APP_CLI_NAME" "/usr/local/bin/$APP_CLI_NAME" 2>/dev/null || true
    fi
    local _lib_module
    for _lib_module in core branding compose vpn; do
        rm -f "$HOME/.local/bin/lib/${_lib_module}.sh" 2>/dev/null || true
    done
    rmdir "$HOME/.local/bin/lib" 2>/dev/null || true

    # Setup writes this cheat-sheet under $HOME (outside the install dir)
    if [ -n "${APP_SERVICE_FILE:-}" ]; then
        rm -f "$HOME/${APP_SERVICE_FILE}" 2>/dev/null || true
    fi

    log_success "${APP_DISPLAY_NAME} has been uninstalled!"
    log_info "Docker images were left on disk — see docs/uninstall.md to remove them."
}

# Load PUID/PGID from install .env when present (for prepare_install_dirs)
_load_install_ids() {
    local env_file="$INSTALL_DIR/.env"
    if [ -f "$env_file" ]; then
        # shellcheck disable=SC1090
        set -a
        safe_source "$env_file" 2>/dev/null || true
        set +a
    fi
    _HOST_UID="${PUID:-$(id -u)}"
    _HOST_GID="${PGID:-$(id -g)}"
}

start_app() {
    _load_install_ids
    prepare_install_dirs "$INSTALL_DIR" "$_HOST_UID" "$_HOST_GID"

    # Validate VPN config before starting (if VPN is enabled)
    if [ "${VPN_ENABLED:-n}" = "y" ]; then
        if ! validate_vpn_secrets "$INSTALL_DIR" "${VPN_ENABLED:-n}" "${VPN_TYPE:-openvpn}"; then
            log_error "Set VPN credentials in $INSTALL_DIR/secrets before starting services"
        fi

        # Test VPN connection by starting Gluetun first
        if ! test_vpn_connection_shared "${DC[@]}"; then
            log_error "VPN startup failed. Fix credentials in $INSTALL_DIR/secrets (and .env if needed), then retry."
        fi
    fi

    if [ "$#" -eq 0 ]; then
        "${DC[@]}" up -d || log_error "Failed to start services"
        wait_for_services
    else
        "${DC[@]}" up -d "$@" || log_error "Failed to start services"
    fi
}

restart_app() {
    _load_install_ids
    prepare_install_dirs "$INSTALL_DIR" "$_HOST_UID" "$_HOST_GID"

    if [ "$#" -eq 0 ]; then
        "${DC[@]}" stop || log_warning "Some services failed to stop"
        "${DC[@]}" up -d || log_error "Failed to start services"
        wait_for_services
    else
        "${DC[@]}" stop "$@" || log_warning "Some services failed to stop"
        "${DC[@]}" up -d "$@" || log_error "Failed to start services"
    fi
}

stop_app() {
    if [ $# -eq 0 ]; then
        "${DC[@]}" stop || log_error "Failed to stop services"
    else
        "${DC[@]}" stop "$@" || log_error "Failed to stop services: $*"
    fi
    log_success "Services stopped successfully"
}

check_status() {
    "${DC[@]}" ps || log_error "Failed to check services"
}

update_containers() {
    local skip_backup=false
    local assume_yes=false
    
    for arg in "$@"; do
        case "$arg" in
            --skip-backup) skip_backup=true ;;
            -y|--yes) assume_yes=true ;;
        esac
    done

    echo -e "\nWARNING: Updating containers may cause data loss or compatibility issues if new versions have breaking changes!"
    
    if [ "$skip_backup" = false ] && [ "$assume_yes" = false ]; then
        read -p "Would you like to back up your current configuration first? [Y/n]: " -r
        if [[ ! ${REPLY,,} =~ ^n$ ]]; then
            local default_backup_dir="$HOME/assemblrr-backups"
            echo -e "\nStarting automatic backup to $default_backup_dir..."
            backup_app "$default_backup_dir"
            echo -e "\nBackup complete. Proceeding with container update..."
        fi
    fi

    if [ "$assume_yes" = false ]; then
        read -p "Are you sure you want to update all containers? [Y/n]: " -r
        if [[ ${REPLY,,} =~ ^n$ ]]; then
            echo "Update aborted."
            return 0
        fi
    fi

    echo "Pulling latest container images..."
    "${DC[@]}" pull || log_error "Failed to pull containers"
    echo "Restarting ${APP_DISPLAY_NAME} services..."
    restart_app
    log_success "Containers updated successfully!"
}

show_config() {
    echo "${APP_DISPLAY_NAME} Configuration:"
    echo "  Install directory:  $INSTALL_DIR"
    echo "  Media directory:    $MEDIA_DIRECTORY"
    echo "  Media service:      $MEDIA_SERVICE"
    echo "  VPN enabled:        $VPN_ENABLED"
    echo "  VPN type:           $VPN_TYPE"
    echo "  Timezone:           $TZ"
    if [ "${VPN_ENABLED:-n}" = "y" ]; then
        echo "  VPN secrets:        $INSTALL_DIR/secrets/"
    fi
    echo
    echo "Compose files:"
    local _prev="" _arg
    for _arg in "${COMPOSE_ARGS[@]}"; do
        if [ "$_prev" = "-f" ]; then
            echo "  $_arg"
        fi
        _prev="$_arg"
    done
}

show_config_help() {
    echo "Usage: ${APP_CLI_NAME} config [subcommand]"
    echo
    echo "Subcommands:"
    printf "  %-12s %s\n" "show" "Show current configuration"
    printf "  %-12s %s\n" "edit" "Re-run the setup wizard (current values as defaults)"
    printf "  %-12s %s\n" "sync" "Re-wire service APIs (Radarr, Sonarr, Prowlarr, Bazarr, Seerr, …)"
    echo
    echo "Examples:"
    echo "  ${APP_CLI_NAME} config           # List config options"
    echo "  ${APP_CLI_NAME} config show      # Show configuration"
    echo "  ${APP_CLI_NAME} config edit      # Change install choices"
    echo "  ${APP_CLI_NAME} config sync      # Repair / re-apply app wiring"
}

# Re-run setup wizard (write files, restart stack, wire apps)
config_edit() {
    echo "Re-running ${APP_DISPLAY_NAME} setup wizard..."
    echo "Current configuration will be used as defaults."
    echo

    local setup_script
    if [ -f "$INSTALL_DIR/setup.sh" ]; then
        setup_script="$INSTALL_DIR/setup.sh"
    else
        local tmp_dir
        tmp_dir=$(mktemp -d)
        if ! git clone --depth=1 "${APP_REPO_URL}" "$tmp_dir/assemblrr" 2>/dev/null; then
            log_error "Failed to clone ${APP_REPO_URL}. Check your internet connection and repository access."
        fi
        setup_script="$tmp_dir/assemblrr/bin/setup.sh"
    fi

    bash "$setup_script"
}

# Re-wire service APIs only (post-install automation)
config_sync() {
    if [ -f "$INSTALL_DIR/config.sh" ]; then
        bash "$INSTALL_DIR/config.sh"
    elif [ -f "$INSTALL_DIR/configure.sh" ]; then
        # Legacy install name
        bash "$INSTALL_DIR/configure.sh"
    else
        log_error "config.sh not found in $INSTALL_DIR"
    fi
}

config_cmd() {
    local sub=${1:-}
    case "$sub" in
        "")
            show_config_help
            ;;
        show)
            show_config
            ;;
        edit)
            config_edit
            ;;
        sync)
            config_sync
            ;;
        --help|-h|help)
            show_config_help
            ;;
        *)
            log_error "Unknown config subcommand: $sub\nRun '${APP_CLI_NAME} config' for usage"
            ;;
    esac
}

restore_app() {
    local backup_file="$1"

    if [ ! -f "$backup_file" ]; then
        log_error "Backup file not found: $backup_file"
    fi

    echo -e "\nWARNING: This will stop all services and overwrite the current installation!"
    echo "Backup file: $backup_file"
    read -p "Are you sure you want to restore? [y/N]: " -r
    if [[ ${REPLY,,} != "y" ]]; then
        echo "Restore cancelled."
        return 0
    fi

    echo "Stopping ${APP_DISPLAY_NAME} services..."
    "${DC[@]}" down 2>/dev/null || log_warning "Failed to stop services"

    echo "Restoring from backup..."
    
    # Safely clear the current configuration instead of blindly overwriting
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_dir="${INSTALL_DIR}_backup_${timestamp}"
    
    echo "Creating safety snapshot of current state at ${backup_dir}..."
    # Use alpine container to copy the snapshot safely
    run_docker run --rm \
        -v "$(dirname "$INSTALL_DIR"):/target_parent" \
        alpine cp -r "/target_parent/$(basename "$INSTALL_DIR")" "/target_parent/$(basename "$backup_dir")" || log_warning "Failed to create safety snapshot"
    
    # Remove files using alpine so we don't hit permission denied issues
    run_docker run --rm \
        -v "$INSTALL_DIR:/target" \
        alpine sh -c 'find /target -mindepth 1 -maxdepth 1 ! -name "media" ! -name "downloads" -exec rm -rf {} +'
    
    # Extract using alpine
    local abs_backup_file; abs_backup_file=$(realpath "$backup_file")
    run_docker run --rm \
        -v "$INSTALL_DIR:/target" \
        -v "$(dirname "$abs_backup_file"):/backup" \
        alpine tar -xzf "/backup/$(basename "$abs_backup_file")" -C /target || log_error "Failed to extract backup"

    echo "Starting ${APP_DISPLAY_NAME} services..."
    "${DC[@]}" up -d || log_warning "Failed to start services"

    echo "Cleaning up old safety snapshots (keeping last 3)..."
    # Keep only the 3 most recent backups, remove the rest
    ls -dt "${INSTALL_DIR}_backup_"* 2>/dev/null | tail -n +4 | while read -r old_backup; do
        rm -rf "$old_backup" 2>/dev/null || true
    done

    log_success "Restore completed successfully!"
    echo "Safety snapshot kept at: $backup_dir"
}

show_logs() {
    if [ "${2:-}" ]; then
        "${DC[@]}" logs -f "${@:2}"
    else
        "${DC[@]}" logs -f
    fi
}

check_health() {
    echo "${APP_DISPLAY_NAME} Health Check:"
    echo
    local unhealthy=0

    while IFS= read -r line; do
        local name status health
        name=$(echo "$line" | awk '{print $1}')
        status=$(echo "$line" | awk '{print $2}')
        health=$(echo "$line" | awk '{print $3}')

        if [ "$health" = "healthy" ]; then
            log_success "  $name: $health"
        elif [ "$status" = "Up" ] && [ -z "$health" ]; then
            log_warning "  $name: running (no healthcheck defined)"
        elif [ "$health" = "starting" ]; then
            log_warning "  $name: starting..."
        else
            log_error_inline "  $name: $health"
            ((unhealthy++))
        fi
    done < <("${DC[@]}" ps --format '{{.Name}} {{.Status}}' 2>/dev/null | sed 's/(/ /;s/)/ /' | awk '{print $1, $2, $3}')

    echo
    if [ $unhealthy -gt 0 ]; then
        log_warning "$unhealthy service(s) are unhealthy"
    else
        log_success "All services are healthy"
    fi
}

update_cli() {
    echo "Updating ${APP_DISPLAY_NAME} CLI..."
    local tmp_dir
    tmp_dir=$(mktemp -d)

    if ! git clone --depth=1 "${APP_REPO_URL}" "$tmp_dir/assemblrr" 2>/dev/null; then
        log_error "Failed to clone ${APP_REPO_URL}. Check your internet connection and repository access."
    fi

    mkdir -p "$HOME/.local/bin/lib"
    cp "$tmp_dir/assemblrr/lib/core.sh" "$HOME/.local/bin/lib/core.sh"
    cp "$tmp_dir/assemblrr/lib/branding.sh" "$HOME/.local/bin/lib/branding.sh"
    cp "$tmp_dir/assemblrr/lib/compose.sh" "$HOME/.local/bin/lib/compose.sh"
    cp "$tmp_dir/assemblrr/lib/vpn.sh" "$HOME/.local/bin/lib/vpn.sh"
    cp "$tmp_dir/assemblrr/bin/cli.sh" "$HOME/.local/bin/$APP_CLI_NAME" && chmod +x "$HOME/.local/bin/$APP_CLI_NAME"
    # Remove old system-wide install if it exists
    [ -n "${APP_CLI_NAME:-}" ] && rm -f "/usr/local/bin/$APP_CLI_NAME" 2>/dev/null
    log_success "CLI updated successfully!"

    [ -n "$tmp_dir" ] && rm -rf "$tmp_dir"
}

main() {
    local command=${1:-"--help"}
    local destination=${2:-.}

    if [ "$command" = "backup" ]; then
        destination=$(realpath "$destination" 2>/dev/null || echo "$destination") || log_error "Invalid backup destination path"
    fi

    case "$command" in
        --help)
            show_help
            ;;
        restart)
            restart_app "${@:2}"
            ;;
        stop)
            stop_app "${@:2}"
            ;;
        start)
            start_app "${@:2}"
            ;;
        status)
            check_status
            ;;
        check-vpn)
            check_vpn
            ;;
        destroy)
            destroy_app "${@:2}"
            ;;
        uninstall)
            uninstall_app "${@:2}"
            ;;
        backup)
            backup_app "$destination"
            ;;
        restore)
            [ -z "${2:-}" ] && log_error "Usage: ${APP_CLI_NAME} restore /path/to/backup.tar.gz"
            restore_app "${2}"
            ;;
        update-containers)
            update_containers "${@:2}"
            ;;
        update-cli)
            update_cli
            ;;
        logs)
            show_logs "$@"
            ;;
        health)
            check_health
            ;;
        config)
            config_cmd "${2:-}"
            ;;
        # Deprecated aliases (hidden from help)
        reconfigure)
            log_warning "'reconfigure' is deprecated — use: ${APP_CLI_NAME} config edit"
            config_edit
            ;;
        configure)
            log_warning "'configure' is deprecated — use: ${APP_CLI_NAME} config sync"
            config_sync
            ;;
        *)
            log_error "Unknown command: $command\nRun '${APP_CLI_NAME} --help' for usage information"
            ;;
    esac
}

main "$@"
