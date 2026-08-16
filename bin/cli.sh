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
if [ -f "$_lib_dir/services.sh" ]; then
    source "$_lib_dir/services.sh"
fi
# Upgrade engine (optional on older installs until first upgrade copies these)
if [ -f "$_lib_dir/managed_files.sh" ]; then
    source "$_lib_dir/managed_files.sh"
fi
if [ -f "$_lib_dir/upgrade.sh" ]; then
    source "$_lib_dir/upgrade.sh"
fi

INSTALL_DIR=$(find_install_directory)
if [ -z "$INSTALL_DIR" ]; then
    log_error "Could not find ${APP_NAME:-assemblrr} installation. Run setup first."
fi

# Pointer first — has MEDIA_DIRECTORY even when the install tree never finished
# (path picker chose /mnt/e, then copy hung). Install-dir config overrides.
load_install_pointer || true
if [ -f "$INSTALL_DIR/.assemblrr-config" ]; then
    safe_source "$INSTALL_DIR/.assemblrr-config"
elif [ -f "$INSTALL_DIR/.${APP_NAME:-assemblrr}-config" ]; then
    safe_source "$INSTALL_DIR/.${APP_NAME:-assemblrr}-config"
fi
VPN_ENABLED="${VPN_ENABLED:-n}"
MEDIA_SERVICE="${MEDIA_SERVICE:-jellyfin}"
MEDIA_DIRECTORY="${MEDIA_DIRECTORY:-${HOME}/assemblrr-media}"

# Source branding from install directory
load_branding "$INSTALL_DIR" 2>/dev/null || true

# Build compose command dynamically (uses lib/compose.sh build_compose_args + adds profile)
if [ -f "$INSTALL_DIR/compose/base.yaml" ]; then
    build_compose_args "$INSTALL_DIR" "${VPN_ENABLED:-n}"
    DC=(run_docker compose "${COMPOSE_ARGS[@]}" "--profile" "${MEDIA_SERVICE:-jellyfin}")
else
    # Mid-setup / incomplete tree — uninstall can still remove dirs and CLI
    DC=(run_docker compose)
    COMPOSE_ARGS=()
fi
# Cold start: Jellyfin/Bazarr start_period is 60s, then the first healthcheck.
readonly WAIT_READY_SECONDS=180
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
    ["status"]="service dashboard (URLs + health); --docker for raw compose ps"
    ["destroy"]="destroys services so you can start from scratch (can specify service names)"
    ["uninstall"]="completely removes the stack (keeps media unless confirmed) — see docs/uninstall.md"
    ["check-vpn"]="checks if the VPN is working as expected"
    ["backup"]="backs up to the destination location"
    ["restore"]="restores from a backup archive"
    ["update-containers"]="updates all containers"
    ["update-cli"]="updates the CLI script to the latest version"
    ["upgrade"]="upgrade install files from git (or --from DIR); runs migrations"
    ["logs"]="shows container logs (optionally specify service name)"
    ["health"]="checks health status of all services"
    ["config"]="configuration: show, or edit one setup section"
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
    echo "  ${APP_CLI_NAME} upgrade             # Upgrade from git main (backup first)"
    echo "  ${APP_CLI_NAME} upgrade --from DIR  # Upgrade from a local source tree"
    echo "  ${APP_CLI_NAME} upgrade --check     # Dry-run upgrade plan"
    echo "  ${APP_CLI_NAME} upgrade --skip-stack  # Files + CLI only (no container restart)"
    echo "  ${APP_CLI_NAME} status             # URLs + health for all services"
    echo "  ${APP_CLI_NAME} status --docker    # Raw docker compose ps"
    echo "  ${APP_CLI_NAME} config              # List config subcommands"
    echo "  ${APP_CLI_NAME} config show         # Show current configuration"
    echo "  ${APP_CLI_NAME} config edit         # Pick a setup section to change"
    echo "  ${APP_CLI_NAME} config edit indexers  # Reopen Prowlarr indexer fzf"
    echo "  ${APP_CLI_NAME} purge --movie-id N  # Full delete (*arr + disk + qB)"
    echo "  ${APP_CLI_NAME} purge --path PATH   # Full delete by library path"
    echo "  ${APP_CLI_NAME} purge --tmdb ID     # Full delete by TMDB id"
}

# Full media purge (*arr + qB + hardlinks). Thin wrapper around scripts/media-purge.sh
purge_media() {
    local install_dir script
    install_dir=$(find_install_directory)
    [ -n "$install_dir" ] || log_error "Could not find installation directory"
    script="$install_dir/scripts/media-purge.sh"
    if [ ! -f "$script" ]; then
        # Dev tree: repo scripts/
        local self_dir
        self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        if [ -f "$self_dir/../scripts/media-purge.sh" ]; then
            script="$self_dir/../scripts/media-purge.sh"
        fi
    fi
    [ -f "$script" ] || log_error "media-purge.sh not found — run upgrade or re-setup"
    chmod +x "$script" 2>/dev/null || true

    set -a
    # shellcheck disable=SC1091
    [ -f "$install_dir/.env" ] && . "$install_dir/.env"
    set +a
    export API_HOST="${API_HOST:-127.0.0.1}"
    export CONFIG_DIR="$install_dir/config"
    export INSTALL_DIR="$install_dir"
    export MEDIA_ROOT="${MEDIA_DIRECTORY:-/data}"
    if [ -f "$install_dir/secrets/auth_username.txt" ]; then
        export AUTH_USERNAME_FILE="$install_dir/secrets/auth_username.txt"
        export AUTH_PASSWORD_FILE="$install_dir/secrets/auth_password.txt"
    fi
    export QBITTORRENT_URL="${QBITTORRENT_URL:-http://127.0.0.1:8081}"
    export RADARR_URL="${RADARR_URL:-http://127.0.0.1:7878}"
    export SONARR_URL="${SONARR_URL:-http://127.0.0.1:8989}"

    bash "$script" "$@"
}

wait_for_services() {
    local wait_time=0
    local timeout="${WAIT_READY_SECONDS:-180}"
    local total=0 ready=0
    local -a waiting=()

    while [ $wait_time -lt "$timeout" ]; do
        total=0
        ready=0
        waiting=()

        local svc state health
        while IFS=$'\t' read -r svc state health; do
            [ -z "$svc" ] && continue
            total=$((total + 1))
            if type service_row_ready >/dev/null 2>&1 && service_row_ready "$state" "$health"; then
                ready=$((ready + 1))
            elif ! type service_row_ready >/dev/null 2>&1 && [ "$(echo "$state" | tr '[:upper:]' '[:lower:]')" = "running" ]; then
                ready=$((ready + 1))
            else
                waiting+=("$svc")
            fi
        done < <(_status_compose_rows)

        if [ "$total" -gt 0 ] && [ "$ready" -eq "$total" ]; then
            echo >&2
            log_success "All $total services are ready."
            return 0
        fi

        if [ "${#waiting[@]}" -gt 0 ] && [ "${#waiting[@]}" -le 6 ]; then
            wait_inline "Waiting for services ($ready/$total ready: ${waiting[*]})" "$wait_time"
        else
            wait_inline "Waiting for services ($ready/$total ready)" "$wait_time"
        fi
        sleep 1
        wait_time=$((wait_time + 1))
    done

    echo >&2
    log_error "Not all services became ready within ${timeout}s ($ready/$total ready${waiting[*]:+: ${waiting[*]}})"
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
    if ! wait_while "Creating backup archive" run_docker run --rm \
        -v "$INSTALL_DIR:/source" \
        -v "$(dirname "$backup_file"):/backup" \
        alpine tar --exclude='./transcoding-temp' --exclude='./config/jellyfin/cache' --exclude='ipc-socket' -czf "/backup/$(basename "$backup_file")" -C /source .; then
        log_error "Failed to create backup archive"
    fi

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
    local removed_config=false
    local removed_media=false
    for arg in "$@"; do
        case "$arg" in
            -f|--force) force=true ;;
            -m|--media) delete_media=true ;;
        esac
    done

    poke_wsl_automounts 2>/dev/null || true
    echo
    print_detected_locations "Detected installation:"
    echo

    # --force already opts out of all confirmation; skip the scary preamble.
    if [ "$force" = false ]; then
        echo "WARNING: This will COMPLETELY remove ${APP_DISPLAY_NAME}!"
        echo "This includes running containers, the Docker network, the CLI, and the config path above."
        if [ "$delete_media" = true ]; then
            echo "Media at $MEDIA_DIRECTORY will also be deleted."
        else
            echo "Media at $MEDIA_DIRECTORY is kept unless you confirm below (or pass --media)."
        fi
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

    echo "Removing config at $INSTALL_DIR ..."
    if [ "$force" = true ]; then
        safe_rm_rf "$INSTALL_DIR"
        removed_config=true
        log_warning "Removed $INSTALL_DIR"
    else
        read -p "Also delete config at $INSTALL_DIR? Type the full path to confirm: " -r
        if [[ "$REPLY" = "$INSTALL_DIR" ]]; then
            safe_rm_rf "$INSTALL_DIR"
            removed_config=true
            log_warning "Removed $INSTALL_DIR"
        else
            log_info "Kept $INSTALL_DIR"
        fi
    fi

    if [ "$delete_media" = true ]; then
        echo "Removing media at $MEDIA_DIRECTORY ..."
        safe_rm_rf "$MEDIA_DIRECTORY"
        removed_media=true
        log_warning "Removed $MEDIA_DIRECTORY"
    elif [ "$force" = false ]; then
        read -p "Also delete media at $MEDIA_DIRECTORY? Type the full path to confirm: " -r
        if [[ "$REPLY" = "$MEDIA_DIRECTORY" ]]; then
            safe_rm_rf "$MEDIA_DIRECTORY"
            removed_media=true
            log_warning "Removed $MEDIA_DIRECTORY"
        else
            log_info "Kept $MEDIA_DIRECTORY"
        fi
    else
        log_info "Kept media at $MEDIA_DIRECTORY (pass --media to delete)"
    fi

    # Path picker / hung setup can leave assemblrr trees on other mounts
    # (e.g. /mnt/e) that the pointer never recorded.
    local leftover_kind leftover_path
    while IFS=$'\t' read -r leftover_kind leftover_path; do
        [ -n "$leftover_path" ] || continue
        case "$leftover_kind" in
            install)
                echo "Removing leftover install at $leftover_path ..."
                safe_rm_rf "$leftover_path"
                log_warning "Removed leftover $leftover_path"
                ;;
            media)
                if [ "$delete_media" = true ]; then
                    echo "Removing leftover media at $leftover_path ..."
                    safe_rm_rf "$leftover_path"
                    log_warning "Removed leftover $leftover_path"
                else
                    log_info "Kept leftover media at $leftover_path (pass --media to delete)"
                fi
                ;;
        esac
    done < <(list_assemblrr_leftovers "$INSTALL_DIR" "$MEDIA_DIRECTORY")

    echo "Removing CLI at $HOME/.local/bin/$APP_CLI_NAME ..."
    if [ -n "${APP_CLI_NAME:-}" ]; then
        rm -f "$HOME/.local/bin/$APP_CLI_NAME" "/usr/local/bin/$APP_CLI_NAME" 2>/dev/null || true
    fi
    local _lib_module
    if type list_cli_lib_modules >/dev/null 2>&1; then
        while IFS= read -r _lib_module; do
            [ -z "$_lib_module" ] && continue
            rm -f "$HOME/.local/bin/lib/${_lib_module}.sh" 2>/dev/null || true
        done < <(list_cli_lib_modules)
    else
        rm -f "$HOME/.local/bin/lib/"*.sh 2>/dev/null || true
    fi
    rmdir "$HOME/.local/bin/lib" 2>/dev/null || true

    # Setup writes this cheat-sheet under $HOME (outside the install dir)
    # Legacy setup wrote ~/assemblrr_services.txt — remove if present
    rm -f "$HOME/assemblrr_services.txt" 2>/dev/null || true
    # Install discovery pointer (may live outside the install dir)
    rm -f "$HOME/.assemblrr-config" "$HOME/.${APP_NAME:-assemblrr}-config" 2>/dev/null || true

    log_success "${APP_DISPLAY_NAME} has been uninstalled!"
    if [ "$removed_config" = true ]; then
        echo "  Removed config: $INSTALL_DIR"
    else
        echo "  Kept config:    $INSTALL_DIR"
    fi
    if [ "$removed_media" = true ]; then
        echo "  Removed media:  $MEDIA_DIRECTORY"
    else
        echo "  Kept media:     $MEDIA_DIRECTORY"
    fi
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
        "${DC[@]}" up -d --remove-orphans || log_error "Failed to start services"
        wait_for_services
    else
        "${DC[@]}" up -d --remove-orphans "$@" || log_error "Failed to start services"
    fi
}

restart_app() {
    _load_install_ids
    prepare_install_dirs "$INSTALL_DIR" "$_HOST_UID" "$_HOST_GID"

    if [ "$#" -eq 0 ]; then
        "${DC[@]}" stop || log_warning "Some services failed to stop"
        "${DC[@]}" up -d --remove-orphans || log_error "Failed to start services"
        wait_for_services
    else
        "${DC[@]}" stop "$@" || log_warning "Some services failed to stop"
        "${DC[@]}" up -d --remove-orphans "$@" || log_error "Failed to start services"
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

# Parse compose ps into associative-ish lines: service -> "state|health"
# Uses Service name (compose key), not container name.
_status_compose_rows() {
    # format: service<TAB>state<TAB>health  (health may be empty)
    "${DC[@]}" ps --format '{{.Service}}\t{{.State}}\t{{.Health}}' 2>/dev/null
}

_status_normalize() {
    # stdin: state, health → stdout: short token + color category
    local state="${1:-}" health="${2:-}"
    state=$(echo "$state" | tr '[:upper:]' '[:lower:]')
    health=$(echo "$health" | tr '[:upper:]' '[:lower:]')

    if [ "$health" = "healthy" ]; then
        echo "healthy"
    elif [ "$health" = "unhealthy" ]; then
        echo "unhealthy"
    elif [ "$health" = "starting" ]; then
        echo "starting"
    elif [ "$state" = "running" ]; then
        echo "running"
    elif [ -z "$state" ]; then
        echo "missing"
    else
        echo "$state"
    fi
}

check_status() {
    local raw_docker=0
    local arg
    for arg in "$@"; do
        case "$arg" in
            --docker|-d) raw_docker=1 ;;
            -h|--help)
                echo "Usage: ${APP_CLI_NAME} status [--docker]"
                echo "  Default: operator dashboard (name, state, URL)."
                echo "  --docker: raw docker compose ps table."
                return 0
                ;;
        esac
    done

    if [ "$raw_docker" = "1" ]; then
        "${DC[@]}" ps || log_error "Failed to check services"
        return 0
    fi

    if ! type list_service_catalog >/dev/null 2>&1; then
        log_warning "Service catalog not loaded — falling back to docker compose ps"
        "${DC[@]}" ps || log_error "Failed to check services"
        return 0
    fi

    # Load live state: service -> state|health
    declare -A st_state=()
    declare -A st_health=()
    local svc state health line
    while IFS=$'\t' read -r svc state health; do
        [ -z "$svc" ] && continue
        st_state["$svc"]="$state"
        st_health["$svc"]="$health"
    done < <(_status_compose_rows)

    local media="${MEDIA_SERVICE:-jellyfin}"
    local vpn="${VPN_ENABLED:-n}"
    local vpn_label="off"
    [ "$vpn" = "y" ] && vpn_label="on"

    echo "${APP_DISPLAY_NAME}  ·  media=${media}  ·  VPN ${vpn_label}"
    print_detected_locations
    echo
    printf "  %-14s %-12s %s\n" "SERVICE" "STATE" "URL / NOTE"
    printf "  %-14s %-12s %s\n" "--------------" "------------" "---------------------------"

    local label port path kind token url note
    local seen=""
    local unhealthy=0
    local total=0

    while IFS='|' read -r svc label port path kind; do
        [ -z "$svc" ] && continue
        total=$((total + 1))
        seen="${seen}|${svc}|"
        state="${st_state[$svc]:-}"
        health="${st_health[$svc]:-}"
        token=$(_status_normalize "$state" "$health")
        if [ "$token" = "unhealthy" ] || [ "$token" = "missing" ] || [ "$token" = "exited" ] || [ "$token" = "dead" ]; then
            unhealthy=$((unhealthy + 1))
        fi

        url=""
        note=""
        if [ "$kind" = "ui" ]; then
            url=$(service_ui_url "$port" "$path" "localhost")
            if [ "$token" = "missing" ] || [ "$token" = "exited" ]; then
                note="(down)"
            fi
        else
            note="(internal)"
        fi

        # STATE column without color for width, then rewrite — use plain token padded + color on same width
        printf "  %-14s " "$label"
        case "$token" in
            healthy)   printf "${GREEN}%-12s${NC}" "healthy" ;;
            running)   printf "${GREEN}%-12s${NC}" "running" ;;
            starting)  printf "${YELLOW}%-12s${NC}" "starting" ;;
            unhealthy) printf "${RED}%-12s${NC}" "unhealthy" ;;
            missing)   printf "${RED}%-12s${NC}" "missing" ;;
            exited)    printf "${RED}%-12s${NC}" "exited" ;;
            *)         printf "${YELLOW}%-12s${NC}" "$token" ;;
        esac
        if [ -n "$url" ]; then
            printf " %s" "$url"
            [ -n "$note" ] && printf " %s" "$note"
            printf "\n"
        else
            printf " %s\n" "${note:-(no UI)}"
        fi
    done < <(list_service_catalog)

    # Any compose services not in the catalog (custom overlays)
    while IFS=$'\t' read -r svc state health; do
        [ -z "$svc" ] && continue
        [[ "$seen" == *"|${svc}|"* ]] && continue
        total=$((total + 1))
        token=$(_status_normalize "$state" "$health")
        if [ "$token" = "unhealthy" ] || [ "$token" = "missing" ] || [ "$token" = "exited" ] || [ "$token" = "dead" ]; then
            unhealthy=$((unhealthy + 1))
        fi
        printf "  %-14s " "$svc"
        case "$token" in
            healthy)   printf "${GREEN}%-12s${NC}" "healthy" ;;
            running)   printf "${GREEN}%-12s${NC}" "running" ;;
            starting)  printf "${YELLOW}%-12s${NC}" "starting" ;;
            unhealthy) printf "${RED}%-12s${NC}" "unhealthy" ;;
            *)         printf "${YELLOW}%-12s${NC}" "$token" ;;
        esac
        printf " (custom / unlisted)\n"
    done < <(_status_compose_rows)

    echo
    if [ "$unhealthy" -gt 0 ]; then
        log_warning "${unhealthy} service(s) need attention (${total} listed)."
        return 1
    fi
    log_success "All ${total} listed services look good."
    return 0
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
    print_detected_locations
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
    printf "  %-12s %s\n" "edit" "Change one first-setup section (picker if omitted)"
    echo
    echo "Examples:"
    echo "  ${APP_CLI_NAME} config                 # List config options"
    echo "  ${APP_CLI_NAME} config show            # Show configuration"
    echo "  ${APP_CLI_NAME} config edit            # Pick a section (indexers, profile, …)"
    echo "  ${APP_CLI_NAME} config edit indexers   # Reopen the Prowlarr indexer fzf"
    echo "  ${APP_CLI_NAME} config edit all        # Re-run the full setup wizard"
    echo
    echo "Run '${APP_CLI_NAME} config edit --help' for every section."
}

_load_config_edit() {
    local src=""
    if [ -f "$INSTALL_DIR/lib/config_edit.sh" ]; then
        src="$INSTALL_DIR/lib/config_edit.sh"
    elif [ -f "$_lib_dir/config_edit.sh" ]; then
        src="$_lib_dir/config_edit.sh"
    else
        log_error "config_edit.sh not found. Run '${APP_CLI_NAME} upgrade' to install modular config edit."
    fi
    # shellcheck source=/dev/null
    source "$src"
}

config_cmd() {
    local sub=${1:-}
    shift || true
    case "$sub" in
        "")
            show_config_help
            ;;
        show)
            show_config
            ;;
        edit)
            _load_config_edit
            config_edit_run "${1:-}"
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
    wait_while "Creating safety snapshot" run_docker run --rm \
        -v "$(dirname "$INSTALL_DIR"):/target_parent" \
        alpine cp -r "/target_parent/$(basename "$INSTALL_DIR")" "/target_parent/$(basename "$backup_dir")" \
        || log_warning "Failed to create safety snapshot"

    wait_while "Clearing install directory" run_docker run --rm \
        -v "$INSTALL_DIR:/target" \
        alpine sh -c 'find /target -mindepth 1 -maxdepth 1 ! -name "media" ! -name "downloads" -exec rm -rf {} +'

    local abs_backup_file; abs_backup_file=$(realpath "$backup_file")
    if ! wait_while "Restoring from backup" run_docker run --rm \
        -v "$INSTALL_DIR:/target" \
        -v "$(dirname "$abs_backup_file"):/backup" \
        alpine tar -xzf "/backup/$(basename "$abs_backup_file")" -C /target; then
        log_error "Failed to extract backup"
    fi

    echo "Starting ${APP_DISPLAY_NAME} services..."
    "${DC[@]}" up -d --remove-orphans || log_warning "Failed to start services"

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
    # Compact pass/fail over compose health (exit 1 if any unhealthy/missing expected UI service)
    echo "${APP_DISPLAY_NAME} Health Check:"
    echo
    local unhealthy=0
    local svc state health token

    while IFS=$'\t' read -r svc state health; do
        [ -z "$svc" ] && continue
        token=$(_status_normalize "$state" "$health")
        case "$token" in
            healthy)
                log_success "  $svc: healthy"
                ;;
            running)
                log_warning "  $svc: running (no healthcheck)"
                ;;
            starting)
                log_warning "  $svc: starting..."
                ;;
            *)
                log_error_inline "  $svc: $token"
                unhealthy=$((unhealthy + 1))
                ;;
        esac
    done < <(_status_compose_rows)

    echo
    if [ "$unhealthy" -gt 0 ]; then
        log_warning "$unhealthy service(s) are unhealthy"
        return 1
    fi
    log_success "All services are healthy"
    return 0
}

update_cli() {
    echo "Updating ${APP_DISPLAY_NAME} CLI..."
    local tmp_dir
    tmp_dir=$(mktemp -d)

    if ! wait_while "Updating CLI from git" git clone --depth=1 "${APP_REPO_URL}" "$tmp_dir/assemblrr"; then
        log_error "Failed to clone ${APP_REPO_URL}. Check your internet connection and repository access."
    fi

    mkdir -p "$HOME/.local/bin/lib"
    if [ -f "$tmp_dir/assemblrr/lib/managed_files.sh" ]; then
        # shellcheck source=/dev/null
        source "$tmp_dir/assemblrr/lib/managed_files.sh"
    fi
    local _m
    while IFS= read -r _m; do
        [ -z "$_m" ] && continue
        if [ -f "$tmp_dir/assemblrr/lib/${_m}.sh" ]; then
            cp "$tmp_dir/assemblrr/lib/${_m}.sh" "$HOME/.local/bin/lib/${_m}.sh"
        fi
    done < <(list_cli_lib_modules)
    cp "$tmp_dir/assemblrr/bin/cli.sh" "$HOME/.local/bin/$APP_CLI_NAME" && chmod +x "$HOME/.local/bin/$APP_CLI_NAME"
    # Remove old system-wide install if it exists
    [ -n "${APP_CLI_NAME:-}" ] && rm -f "/usr/local/bin/$APP_CLI_NAME" 2>/dev/null
    if type ensure_local_bin_on_path >/dev/null 2>&1; then
        ensure_local_bin_on_path
    fi
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
            check_status "${@:2}"
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
        upgrade)
            if ! type upgrade_app >/dev/null 2>&1; then
                log_error "Upgrade engine not found. Update CLI from a current checkout: bash /path/to/repo/bin/cli.sh upgrade --from /path/to/repo"
            fi
            upgrade_app "${@:2}"
            ;;
        logs)
            show_logs "$@"
            ;;
        health)
            check_health
            ;;
        config)
            config_cmd "${@:2}"
            ;;
        purge)
            [ $# -lt 2 ] && log_error "Usage: ${APP_CLI_NAME} purge --movie-id N | --series-id N | --path PATH | --tmdb ID | --tvdb ID"
            purge_media "${@:2}"
            ;;
        *)
            log_error "Unknown command: $command\nRun '${APP_CLI_NAME} --help' for usage information"
            ;;
    esac
}

main "$@"
