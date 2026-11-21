#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# assemblrr CLI — lives in the install tree (or repo bin/). PATH is a thin wrapper.
set -euo pipefail

_cli_self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Leftover full copies in ~/.local/bin must not run standalone; exec the install-tree CLI.
if [ "$_cli_self" = "$HOME/.local/bin" ] || [ "$_cli_self" = "/usr/local/bin" ]; then
    _wrap_dir="${ASSEMBLRR_DIR:-}"
    if [ -z "$_wrap_dir" ]; then
        for _wrap_f in \
            "$HOME/.assemblrr-config" \
            /opt/assemblrr/.assemblrr-config \
            "$HOME/assemblrr/.assemblrr-config"
        do
            if [ -f "$_wrap_f" ]; then
                _wrap_dir=$(grep -E '^INSTALL_DIRECTORY=' "$_wrap_f" | head -1 || true)
                _wrap_dir="${_wrap_dir#INSTALL_DIRECTORY=}"
                _wrap_dir="${_wrap_dir%$'\r'}"
                _wrap_dir="${_wrap_dir#\"}"
                _wrap_dir="${_wrap_dir%\"}"
                [ -n "$_wrap_dir" ] && break
            fi
        done
    fi
    if [ -n "${_wrap_dir:-}" ] && [ -f "$_wrap_dir/cli.sh" ]; then
        exec bash "$_wrap_dir/cli.sh" "$@"
    fi
    echo "assemblrr: could not find the install. Run setup, or set ASSEMBLRR_DIR." >&2
    exit 1
fi

if [ -f "$_cli_self/../lib/core.sh" ]; then
    _lib_dir="$_cli_self/../lib"
elif [ -f "$_cli_self/lib/core.sh" ]; then
    _lib_dir="$_cli_self/lib"
else
    echo -e "\033[0;31mError: lib/core.sh not found. Re-run setup.\033[0m" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$_lib_dir/core.sh"
# shellcheck source=/dev/null
source "$_lib_dir/branding.sh"
# shellcheck source=/dev/null
source "$_lib_dir/compose.sh"
# shellcheck source=/dev/null
[ -f "$_lib_dir/quality.sh" ] && source "$_lib_dir/quality.sh"
# shellcheck source=/dev/null
source "$_lib_dir/vpn.sh"
# shellcheck source=/dev/null
[ -f "$_lib_dir/services.sh" ] && source "$_lib_dir/services.sh"
# shellcheck source=/dev/null
[ -f "$_lib_dir/managed_files.sh" ] && source "$_lib_dir/managed_files.sh"
# shellcheck source=/dev/null
[ -f "$_lib_dir/upgrade.sh" ] && source "$_lib_dir/upgrade.sh"

# Default fallbacks (always initialized cleanly even under set -u)
VPN_ENABLED="${VPN_ENABLED:-n}"
VPN_TYPE="${VPN_TYPE:-openvpn}"
MEDIA_SERVICE="${MEDIA_SERVICE:-jellyfin}"
MEDIA_DIRECTORY="${MEDIA_DIRECTORY:-${HOME}/assemblrr-media}"
TZ="${TZ:-UTC}"

readonly WAIT_READY_SECONDS=180
readonly IP_ENDPOINTS=(
    "https://ipinfo.io/ip"
    "https://api.ipify.org"
    "https://checkip.amazonaws.com"
    "https://tnedi.me"
    "https://api.myip.la"
)

log_error_inline() { echo -e "${RED:-}$1${NC:-}"; }

_cli_init() {
    INSTALL_DIR=$(find_install_directory || true)
    if [ -z "${INSTALL_DIR:-}" ]; then
        log_error "Could not find ${APP_NAME:-assemblrr} installation. Run setup first."
        return 1
    fi

    load_install_pointer || true
    if [ -f "$INSTALL_DIR/.assemblrr-config" ]; then
        safe_source "$INSTALL_DIR/.assemblrr-config"
    elif [ -f "$INSTALL_DIR/.${APP_NAME:-assemblrr}-config" ]; then
        safe_source "$INSTALL_DIR/.${APP_NAME:-assemblrr}-config"
    fi
    if [ -f "$INSTALL_DIR/.env" ]; then
        set -a
        safe_source "$INSTALL_DIR/.env"
        set +a
    fi

    VPN_ENABLED="${VPN_ENABLED:-n}"
    VPN_TYPE="${VPN_TYPE:-openvpn}"
    MEDIA_SERVICE="${MEDIA_SERVICE:-jellyfin}"
    MEDIA_DIRECTORY="${MEDIA_DIRECTORY:-${HOME}/assemblrr-media}"
    TZ="${TZ:-UTC}"

    load_branding "$INSTALL_DIR" 2>/dev/null || load_branding "$_cli_self/.." 2>/dev/null || true

    if [ -f "$INSTALL_DIR/compose/base.yaml" ]; then
        build_compose_args "$INSTALL_DIR" "${VPN_ENABLED:-n}"
        DC=(run_docker compose "${COMPOSE_ARGS[@]}")
    else
        DC=(run_docker compose)
        COMPOSE_ARGS=()
    fi
}

show_help() {
    load_branding "$_cli_self/.." 2>/dev/null || true
    echo "${APP_DISPLAY_NAME:-assemblrr} - ${APP_DESCRIPTION:-Automated media stack}"
    echo
    echo "Usage: ${APP_CLI_NAME:-assemblrr} [command] [options]"
    echo
    echo "Lifecycle:"
    printf "  %-26s %s\n" "start [service...]"   "Start all (or named) services and wait for readiness"
    printf "  %-26s %s\n" "stop [service...]"    "Stop all (or named) services"
    printf "  %-26s %s\n" "restart [service...]" "Restart all (or named) services"
    printf "  %-26s %s\n" "destroy [service...]" "Stop and remove containers/network (keeps config + media)"
    printf "  %-26s %s\n" "uninstall [--force] [--media]" "Remove containers, config, and CLI wrapper"
    echo
    echo "Configuration & Upgrades:"
    printf "  %-26s %s\n" "status [--docker]"      "Operator service dashboard (URLs + health); --docker for raw compose ps"
    printf "  %-26s %s\n" "health"               "Compact health pass/fail across expected stack services"
    printf "  %-26s %s\n" "config [show|edit|apply]" "Inspect config, edit settings interactively, or re-wire APIs"
    printf "  %-26s %s\n" "upgrade [options]"    "Apply managed files, migrations, compose rebuild, and wiring (--check, --from DIR, --ref REF)"
    printf "  %-26s %s\n" "update-containers [-y]" "Rebuild local sidecars & pull unpinned custom overlay images"
    echo
    echo "Operations & Backups:"
    printf "  %-26s %s\n" "logs [service]"       "Follow container logs"
    printf "  %-26s %s\n" "check-vpn"            "Verify public exit IP vs VPN tunnel IP"
    printf "  %-26s %s\n" "purge [options]"      "Remove one movie/series/season from *arr, library disk, and qB/SABnzbd"
    printf "  %-26s %s\n" "backup <dir>"         "Create a 0600 backup archive in <dir>"
    printf "  %-26s %s\n" "restore <archive>"    "Validate and restore stack config/secrets from <archive>"
    echo
    echo "Examples:"
    echo "  ${APP_CLI_NAME:-assemblrr} status"
    echo "  ${APP_CLI_NAME:-assemblrr} config edit"
    echo "  ${APP_CLI_NAME:-assemblrr} upgrade --check"
    echo "  ${APP_CLI_NAME:-assemblrr} purge --tmdb 10378 --dry-run"
}

purge_media() {
    local install_dir="${INSTALL_DIR:-}"
    local script
    [ -n "$install_dir" ] || install_dir=$(find_install_directory || true)
    [ -n "$install_dir" ] || log_error "Could not find installation directory"
    script="$install_dir/scripts/media-purge.sh"
    if [ ! -f "$script" ] && [ -f "$_cli_self/../scripts/media-purge.sh" ]; then
        script="$_cli_self/../scripts/media-purge.sh"
    fi
    [ -f "$script" ] || log_error "media-purge.sh not found — run upgrade or re-setup"

    set -a
    [ -f "$install_dir/.env" ] && safe_source "$install_dir/.env"
    set +a
    export API_HOST="${API_HOST:-127.0.0.1}"
    export CONFIG_DIR="$install_dir/config"
    export INSTALL_DIR="$install_dir"
    export MEDIA_ROOT="${MEDIA_DIRECTORY:-/data}"
    if [ -f "$install_dir/secrets/auth_username.txt" ]; then
        export AUTH_USERNAME_FILE="$install_dir/secrets/auth_username.txt"
        export AUTH_PASSWORD_FILE="$install_dir/secrets/auth_password.txt"
    fi
    if [ -f "$install_dir/secrets/jellyfin_api_key.txt" ]; then
        export JELLYFIN_API_KEY_FILE="$install_dir/secrets/jellyfin_api_key.txt"
    fi
    export QBITTORRENT_URL="${QBITTORRENT_URL:-http://${API_HOST}:8081}"
    export SABNZBD_URL="${SABNZBD_URL:-http://${API_HOST}:8085}"
    export RADARR_URL="${RADARR_URL:-http://${API_HOST}:7878}"
    export SONARR_URL="${SONARR_URL:-http://${API_HOST}:8989}"
    export JELLYFIN_URL="${JELLYFIN_URL:-http://${API_HOST}:8096}"

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

        local svc state health label port path kind
        declare -A st_state=()
        declare -A st_health=()
        while IFS=$'\t' read -r svc state health; do
            [ -z "$svc" ] && continue
            st_state["$svc"]="$state"
            st_health["$svc"]="$health"
        done < <(_status_compose_rows)

        if type list_service_catalog >/dev/null 2>&1; then
            while IFS='|' read -r svc label port path kind; do
                [ -z "$svc" ] && continue
                total=$((total + 1))
                state="${st_state[$svc]:-}"
                health="${st_health[$svc]:-}"
                if type service_row_ready >/dev/null 2>&1 && service_row_ready "$state" "$health"; then
                    ready=$((ready + 1))
                else
                    waiting+=("${label} (${health:-${state:-missing}})")
                fi
            done < <(list_service_catalog)
        fi

        if [ "$total" -gt 0 ] && [ "$ready" -eq "$total" ]; then
            [ "$wait_time" -gt 0 ] && echo >&2
            log_success "All ${total} services ready"
            return 0
        fi

        wait_inline "Waiting for services: ${ready}/${total} ready" "$wait_time"
        sleep 3
        wait_time=$((wait_time + 3))
    done

    echo >&2
    if [ "${#waiting[@]}" -gt 0 ]; then
        log_warning "Timed out after ${timeout}s — still starting: ${waiting[*]}"
    else
        log_warning "Timed out waiting for services after ${timeout}s"
    fi
    return 1
}

get_ip_with_retries() {
    local is_vpn=$1
    local retry=0
    local max_retries=5
    local ip=""

    while [ $retry -lt $max_retries ]; do
        for endpoint in "${IP_ENDPOINTS[@]}"; do
            if [ "$is_vpn" = "true" ]; then
                ip=$(run_docker exec gluetun curl -s --max-time 5 "$endpoint" 2>/dev/null || true)
            else
                ip=$(curl -s --max-time 5 "$endpoint" 2>/dev/null || true)
            fi
            if [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                echo "$ip"
                return 0
            fi
        done
        retry=$((retry + 1))
        sleep 2
    done
    return 1
}

check_vpn() {
    if [ "${VPN_ENABLED:-n}" != "y" ]; then
        log_error "VPN is not enabled in your configuration."
    fi

    echo "Checking VPN connection..."
    local vpn_ip public_ip
    vpn_ip=$(get_ip_with_retries "true")
    public_ip=$(get_ip_with_retries "false")

    [ -z "$vpn_ip" ] && log_error "Failed to obtain VPN IP"
    [ -z "$public_ip" ] && log_error "Failed to obtain public IP"

    echo
    echo "IP check:"
    echo "  Your real IP: $public_ip"
    echo "  VPN exit IP:  $vpn_ip"
    echo

    if [ "$vpn_ip" != "$public_ip" ]; then
        log_success "VPN is active and routing traffic correctly!"
    else
        log_warning "VPN IP matches your real IP — VPN may not be routing properly"
    fi
}

backup_app() {
    local destination="${1:-.}"
    local backup_date backup_file tmp_file
    backup_date=$(date '+%Y-%m-%d-%s')
    backup_file="${destination%/}/${APP_BACKUP_PREFIX:-assemblrr-backup}-$backup_date.tar.gz"
    tmp_file="${backup_file}.tmp"

    if [ ! -d "$destination" ]; then
        log_info "Backup destination \"$destination\" does not exist. Creating it..."
        mkdir -p "$destination" || log_error "Failed to create backup destination directory"
    fi

    echo "Stopping ${APP_DISPLAY_NAME:-assemblrr} services..."
    "${DC[@]}" stop >/dev/null 2>&1 || log_warning "Some services were not running cleanly before backup"

    echo -e "\nBacking up ${APP_DISPLAY_NAME:-assemblrr} to $destination..."
    if ! (umask 077 && wait_while "Creating backup archive" run_docker run --rm \
        -v "$INSTALL_DIR:/source:ro" \
        -v "$(dirname "$tmp_file"):/backup" \
        "${UTILITY_ALPINE_IMAGE:-alpine:3.24.4}" \
        tar --exclude='./transcoding-temp' --exclude='./config/jellyfin/cache' --exclude='ipc-socket' \
        -czf "/backup/$(basename "$tmp_file")" -C /source .); then
        rm -f "$tmp_file"
        log_error "Failed to create backup archive"
    fi
    chmod 600 "$tmp_file"
    mv "$tmp_file" "$backup_file"

    echo -e "\nStarting ${APP_DISPLAY_NAME:-assemblrr} services..."
    "${DC[@]}" start >/dev/null 2>&1 || log_warning "Failed to restart services"

    log_success "Backup completed successfully!"
    echo "Backup file: $backup_file"
}

validate_backup_archive() {
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

destroy_app() {
    if [ "$#" -eq 0 ]; then
        echo -e "\nWARNING: This will destroy all your services, containers, volumes, and the custom network!"
        echo "This is not recoverable!"
        while true; do
            read_prompt "Are you sure you want to continue? [y/N]: "
            local reply=${REPLY:-n}
            if [[ ${reply,,} =~ ^y$ ]]; then
                "${DC[@]}" down || log_error "Failed to destroy services"
                docker network rm "${APP_NETWORK_NAME:-assemblrr_network}" 2>/dev/null || true
                echo -e "\n${APP_DISPLAY_NAME:-assemblrr} services were destroyed. To restart, run: ${APP_CLI_NAME:-assemblrr} start"
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
        echo -e "\nWARNING: This will destroy the service(s): \"${target_label}\"."
        while true; do
            read_prompt "Are you sure you want to continue? [y/N]: "
            local reply=${REPLY:-n}
            if [[ ${reply,,} =~ ^y$ ]]; then
                "${DC[@]}" stop "$@" || log_error "Failed to stop services"
                "${DC[@]}" rm -f -v "$@" || log_error "Failed to destroy services"
                echo -e "\n${APP_DISPLAY_NAME:-assemblrr} service was destroyed. To restart, run: ${APP_CLI_NAME:-assemblrr} start"
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
    local remove_config=true
    local removed_config=false
    local removed_media=false
    local -a extra_removed=()
    local -a extra_kept=()
    local arg
    for arg in "$@"; do
        case "$arg" in
            -f|--force) force=true ;;
            -m|--media) delete_media=true ;;
        esac
    done

    poke_wsl_automounts 2>/dev/null || true

    if [ "$force" = false ]; then
        echo
        print_detected_locations "Detected installation:"
        echo
        echo "WARNING: This will COMPLETELY remove ${APP_DISPLAY_NAME:-assemblrr}!"
        echo "This includes running containers, the Docker network, the CLI, and the config path above."
        if [ "$delete_media" = true ]; then
            echo "Media at $MEDIA_DIRECTORY will also be deleted."
        else
            echo "Media at $MEDIA_DIRECTORY is kept unless you confirm below (or pass --media)."
        fi
        echo "Tip: run '${APP_CLI_NAME:-assemblrr} backup <target-dir>' first if you want to keep your configuration."
        echo
        echo "This is not recoverable!"
        read_prompt "Uninstall ${APP_DISPLAY_NAME:-assemblrr}? [y/N]: "
        if [[ ! "${REPLY:-}" =~ ^[Yy]$ ]]; then
            echo "Uninstall cancelled."
            return 0
        fi
        read_prompt "Also delete config at $INSTALL_DIR? [Y/n]: "
        if [[ "${REPLY:-}" =~ ^[Nn]$ ]]; then
            remove_config=false
        fi
        if [ "$delete_media" = false ]; then
            read_prompt "Also delete media at $MEDIA_DIRECTORY? [y/N]: "
            if [[ "${REPLY:-}" =~ ^[Yy]$ ]]; then
                read_prompt "Type 'delete media' to permanently erase $MEDIA_DIRECTORY: "
                if [ "${REPLY:-}" = "delete media" ]; then
                    delete_media=true
                else
                    log_info "Keeping media at $MEDIA_DIRECTORY."
                fi
            fi
        fi
    fi

    if type wait_while >/dev/null 2>&1; then
        wait_while "Stopping and removing containers" "${DC[@]}" down -v || log_warning "Failed to stop some services"
    else
        "${DC[@]}" down -v 2>/dev/null || log_warning "Failed to stop some services"
    fi

    if run_docker network inspect "${APP_NETWORK_NAME:-assemblrr_network}" &>/dev/null; then
        run_docker network rm "${APP_NETWORK_NAME:-assemblrr_network}" 2>/dev/null || true
    fi

    if [ "$force" = true ] || [ "$remove_config" = true ]; then
        if type wait_while >/dev/null 2>&1; then
            wait_while "Removing configuration files" safe_rm_rf "$INSTALL_DIR"
        else
            safe_rm_rf "$INSTALL_DIR"
        fi
        removed_config=true
    fi

    if [ "$delete_media" = true ]; then
        if type wait_while >/dev/null 2>&1; then
            wait_while "Removing media files" safe_rm_rf "$MEDIA_DIRECTORY"
        else
            safe_rm_rf "$MEDIA_DIRECTORY"
        fi
        removed_media=true
    fi

    local leftover_kind leftover_path ans_left
    while IFS=$'\t' read -r leftover_kind leftover_path; do
        [ -n "$leftover_path" ] || continue
        case "$leftover_kind" in
            install)
                if [ "$force" = true ]; then
                    safe_rm_rf "$leftover_path"
                    extra_removed+=("$leftover_path")
                else
                    read_prompt "Also remove leftover install dir at $leftover_path? [y/N]: " ans_left
                    if [[ ${ans_left:-n} =~ ^[Yy]$ ]]; then
                        safe_rm_rf "$leftover_path"
                        extra_removed+=("$leftover_path")
                    else
                        extra_kept+=("$leftover_path")
                    fi
                fi
                ;;
            media)
                if [ "$delete_media" = true ]; then
                    if [ "$force" = true ]; then
                        safe_rm_rf "$leftover_path"
                        extra_removed+=("$leftover_path")
                    else
                        read_prompt "Also remove leftover media dir at $leftover_path? [y/N]: " ans_left
                        if [[ ${ans_left:-n} =~ ^[Yy]$ ]]; then
                            safe_rm_rf "$leftover_path"
                            extra_removed+=("$leftover_path")
                        else
                            extra_kept+=("$leftover_path")
                        fi
                    fi
                else
                    extra_kept+=("$leftover_path")
                fi
                ;;
        esac
    done < <(list_assemblrr_leftovers "$INSTALL_DIR" "$MEDIA_DIRECTORY")

    if [ -n "${APP_CLI_NAME:-}" ]; then
        rm -f "$HOME/.local/bin/$APP_CLI_NAME" "/usr/local/bin/$APP_CLI_NAME" 2>/dev/null || true
    fi
    if type remove_stale_user_cli_libs >/dev/null 2>&1; then
        remove_stale_user_cli_libs
    else
        rm -f "$HOME/.local/bin/lib/"*.sh 2>/dev/null || true
        rmdir "$HOME/.local/bin/lib" 2>/dev/null || true
    fi

    rm -f "$HOME/assemblrr_services.txt" 2>/dev/null || true
    rm -f "$HOME/.assemblrr-config" "$HOME/.${APP_NAME:-assemblrr}-config" 2>/dev/null || true

    log_success "${APP_DISPLAY_NAME:-assemblrr} uninstalled."
    if [ "$removed_config" = true ]; then
        echo "  Config removed: $INSTALL_DIR"
    else
        echo "  Config kept: $INSTALL_DIR"
    fi
    if [ "$removed_media" = true ]; then
        echo "  Media removed: $MEDIA_DIRECTORY"
    else
        echo "  Media kept: $MEDIA_DIRECTORY"
    fi
    local p
    if [ "${#extra_removed[@]}" -gt 0 ]; then
        for p in "${extra_removed[@]}"; do
            echo "  Leftover removed: $p"
        done
    fi
    if [ "${#extra_kept[@]}" -gt 0 ]; then
        for p in "${extra_kept[@]}"; do
            echo "  Leftover kept: $p"
        done
    fi
}

_load_install_ids() {
    local puid="${PUID:-$(id -u)}"
    local pgid="${PGID:-$(id -g)}"
    if [ -f "$INSTALL_DIR/.env" ]; then
        local _ep _eg
        _ep=$(grep -E '^PUID=' "$INSTALL_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2 || true)
        _eg=$(grep -E '^PGID=' "$INSTALL_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2 || true)
        [[ "$_ep" =~ ^[0-9]+$ ]] && puid="$_ep"
        [[ "$_eg" =~ ^[0-9]+$ ]] && pgid="$_eg"
    fi
    echo "$puid $pgid"
}

start_app() {
    local _ids _puid _pgid
    if [ -d "$INSTALL_DIR/compose" ] && type prepare_install_dirs >/dev/null 2>&1; then
        read -r _puid _pgid < <(_load_install_ids)
        prepare_install_dirs "$INSTALL_DIR" "$_puid" "$_pgid"
    fi
    echo "Starting ${APP_DISPLAY_NAME:-assemblrr} services..."
    if [ "$#" -gt 0 ]; then
        "${DC[@]}" start "$@" || log_error "Failed to start $*"
        log_success "Service(s) started: $*"
    elif [ "${#COMPOSE_ARGS[@]}" -gt 0 ] && type compose_up_stack >/dev/null 2>&1; then
        compose_up_stack "default" || log_error "Failed to start services"
        wait_for_services || true
    else
        "${DC[@]}" up -d --remove-orphans || log_error "Failed to start services"
        wait_for_services || true
    fi
    if [ "$#" -eq 0 ]; then
        echo
        check_status || true
    fi
    echo "Manage anytime: ${APP_CLI_NAME:-assemblrr} status | logs | stop"
}

restart_app() {
    echo "Restarting ${APP_DISPLAY_NAME:-assemblrr} services..."
    "${DC[@]}" restart "$@" || log_error "Failed to restart services"
    if [ "$#" -eq 0 ]; then
        wait_for_services || true
        echo
        check_status || true
    else
        log_success "${APP_DISPLAY_NAME:-assemblrr} restarted: $*"
    fi
}

stop_app() {
    echo "Stopping ${APP_DISPLAY_NAME:-assemblrr} services..."
    "${DC[@]}" stop "$@" || log_error "Failed to stop services"
    if [ "$#" -gt 0 ]; then
        log_success "${APP_DISPLAY_NAME:-assemblrr} stopped: $*"
    else
        log_success "${APP_DISPLAY_NAME:-assemblrr} stopped successfully"
    fi
}

_status_compose_rows() {
    "${DC[@]}" ps -a --format '{{.Service}}\t{{.State}}\t{{.Health}}' 2>/dev/null || true
}

_status_normalize() {
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

_status_short_bg_label() {
    case "${1:-}" in
        "Seerr (internal)")  echo "Gateway" ;;
        "Gluetun (VPN)")     echo "Gluetun" ;;
        "Media purge watch") echo "Purge" ;;
        "VPN watchdog")      echo "Watchdog" ;;
        "Byparr (solver)")   echo "Byparr" ;;
        *)                   echo "${1:-}" ;;
    esac
}

check_status() {
    local raw_docker=0 show_all=0 compact=0 arg
    for arg in "$@"; do
        case "$arg" in
            --docker|-d) raw_docker=1 ;;
            --all|-a)    show_all=1 ;;
            --compact)   compact=1 ;;
            -h|--help)
                echo "Usage: ${APP_CLI_NAME:-assemblrr} status [--all | --docker]"
                echo "  Default: operator dashboard (Web UIs + background summary)."
                echo "  --all:    show every background/internal container individually."
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
        "${DC[@]}" ps || log_error "Failed to check services"
        return 0
    fi

    local rows_raw
    rows_raw=$(_status_compose_rows)

    declare -A st_state=()
    declare -A st_health=()
    local svc state health
    while IFS=$'\t' read -r svc state health; do
        [ -z "$svc" ] && continue
        st_state["$svc"]="$state"
        st_health["$svc"]="$health"
    done <<< "$rows_raw"

    if [ "$compact" -eq 0 ]; then
        local -a badges=()
        if [ "${VPN_ENABLED:-n}" = "y" ]; then
            badges+=("VPN on")
        else
            badges+=("VPN off")
        fi
        [ "${GPU_TRANSCODING:-none}" != "none" ] && badges+=("GPU ${GPU_TRANSCODING}")
        case "$(qbit_ui_mode 2>/dev/null || echo "${QBIT_UI:-stock}")" in
            vuetorrent) badges+=("VueTorrent") ;;
            qui)        badges+=("qui") ;;
        esac
        [ "${BYPARR_ENABLED:-n}" = "y" ] && badges+=("Byparr")
        [ "${USENET_ENABLED:-n}" = "y" ] && badges+=("Usenet")
        local badge_str="" b
        for b in "${badges[@]}"; do
            [ -n "$badge_str" ] && badge_str+="  ·  "
            badge_str+="$b"
        done
        echo "${APP_DISPLAY_NAME:-assemblrr}  ·  ${badge_str}"
        ASSEMBLRR_SHOW_LEFTOVERS=0 print_detected_locations
        echo
    fi

    printf "  %-18s %-12s %s\n" "SERVICE" "STATE" "URL"
    printf "  %-18s %-12s %s\n" "------------------" "------------" "------------------------"

    local label port path kind token url note seen="" unhealthy=0 total=0
    local bg_total=0 bg_ok=0
    local -a bg_names=()
    local ui_host="${API_HOST:-localhost}"
    [ "$ui_host" = "127.0.0.1" ] && ui_host="localhost"

    while IFS='|' read -r svc label port path kind; do
        [ -z "$svc" ] && continue
        total=$((total + 1))
        seen="${seen}|${svc}|"
        state="${st_state[$svc]:-}"
        health="${st_health[$svc]:-}"
        token=$(_status_normalize "$state" "$health")
        case "$token" in
            unhealthy|missing|exited|dead) unhealthy=$((unhealthy + 1)) ;;
        esac

        if [ "$kind" = "internal" ]; then
            bg_total=$((bg_total + 1))
            if [ "$token" = "healthy" ] || [ "$token" = "running" ]; then
                bg_ok=$((bg_ok + 1))
            fi
            bg_names+=("$(_status_short_bg_label "$label")")
            if [ "$show_all" -eq 0 ] && { [ "$token" = "healthy" ] || [ "$token" = "running" ]; }; then
                continue
            fi
        fi

        url="" note=""
        if [ "$kind" = "ui" ]; then
            url=$(service_ui_url "$port" "$path" "$ui_host")
            if [ "$token" = "missing" ] || [ "$token" = "exited" ]; then
                note="(down)"
            fi
        else
            note="(internal)"
        fi

        printf "  %-18s " "$label"
        case "$token" in
            healthy|running)    printf "${GREEN:-}%-12s${NC:-}" "$token" ;;
            starting)           printf "${YELLOW:-}%-12s${NC:-}" "$token" ;;
            unhealthy|missing|exited) printf "${RED:-}%-12s${NC:-}" "$token" ;;
            *)                  printf "${YELLOW:-}%-12s${NC:-}" "$token" ;;
        esac
        if [ -n "$url" ]; then
            printf " %s" "$url"
            [ -n "$note" ] && printf " %s" "$note"
            printf "\n"
        else
            printf " %s\n" "${note:-(no UI)}"
        fi
    done < <(list_service_catalog)

    while IFS=$'\t' read -r svc state health; do
        [ -z "$svc" ] && continue
        [[ "$seen" == *"|${svc}|"* ]] && continue
        total=$((total + 1))
        token=$(_status_normalize "$state" "$health")
        case "$token" in
            unhealthy|missing|exited|dead) unhealthy=$((unhealthy + 1)) ;;
        esac
        printf "  %-18s " "$svc"
        case "$token" in
            healthy|running) printf "${GREEN:-}%-12s${NC:-}" "$token" ;;
            starting)        printf "${YELLOW:-}%-12s${NC:-}" "$token" ;;
            unhealthy)       printf "${RED:-}%-12s${NC:-}" "$token" ;;
            *)               printf "${YELLOW:-}%-12s${NC:-}" "$token" ;;
        esac
        printf " (custom)\n"
    done <<< "$rows_raw"

    if [ "$show_all" -eq 0 ] && [ "$bg_total" -gt 0 ]; then
        local bg_list="" n
        for n in "${bg_names[@]}"; do
            [ -n "$bg_list" ] && bg_list+=", "
            bg_list+="$n"
        done
        echo
        if [ "$bg_ok" -eq "$bg_total" ]; then
            printf "  %-18s ${GREEN:-}%s${NC:-} (%s)\n" "Background:" "${bg_ok}/${bg_total} healthy" "$bg_list"
        else
            local bg_bad=$((bg_total - bg_ok))
            printf "  %-18s ${YELLOW:-}%s healthy, %s need attention${NC:-}\n" "Background:" "${bg_ok}/${bg_total}" "$bg_bad"
        fi
    fi

    if [ "$compact" -eq 0 ]; then
        echo
        if [ "$unhealthy" -gt 0 ]; then
            log_warning "${unhealthy} service(s) need attention (${total} listed)."
            return 1
        fi
        log_success "All ${total} services look good."
    else
        [ "$unhealthy" -eq 0 ] || return 1
    fi
    return 0
}

update_containers() {
    local skip_backup=false
    local assume_yes=false
    local arg

    for arg in "$@"; do
        case "$arg" in
            --skip-backup) skip_backup=true ;;
            -y|--yes) assume_yes=true ;;
        esac
    done

    echo
    log_info "Note: ${APP_DISPLAY_NAME:-assemblrr} pins core service image tags in compose/*.yaml to tested releases."
    log_info "To receive newer upstream service releases + migrations + wiring, use: ${APP_CLI_NAME:-assemblrr} upgrade"
    echo

    if [ "$skip_backup" = false ] && [ "$assume_yes" = false ]; then
        read_prompt "Create a backup before rebuilding sidecars / pulling custom overlay images? [Y/n]: "
        if [[ ! ${REPLY,,} =~ ^n$ ]]; then
            local default_backup_dir="$HOME/${APP_NAME:-assemblrr}-backups"
            echo -e "\nStarting automatic backup to $default_backup_dir..."
            backup_app "$default_backup_dir"
        fi
    fi

    if [ "$assume_yes" = false ]; then
        read_prompt "Rebuild local sidecars and pull any custom overlay images now? [Y/n]: "
        if [[ ${REPLY,,} =~ ^n$ ]]; then
            echo "Update aborted."
            return 0
        fi
    fi

    log_info "Pulling registry images (ignoring locally built sidecars)..."
    "${DC[@]}" pull --ignore-buildable || log_warning "Some registry pulls failed"
    log_info "Rebuilding sidecars and recreating stack..."
    if [ "${#COMPOSE_ARGS[@]}" -gt 0 ] && type compose_up_stack >/dev/null 2>&1; then
        compose_up_stack "default" --build || log_error "Failed to update containers"
    else
        "${DC[@]}" up -d --build --remove-orphans || log_error "Failed to update containers"
    fi
    log_success "Containers refreshed!"
}

show_config() {
    echo "${APP_DISPLAY_NAME:-assemblrr} Configuration:"
    ASSEMBLRR_SHOW_LEFTOVERS=0 print_detected_locations
    echo "  Media service:      ${MEDIA_SERVICE:-jellyfin}"
    echo "  VPN enabled:        ${VPN_ENABLED:-n}"
    echo "  VPN type:           ${VPN_TYPE:-openvpn}"
    echo "  Timezone:           ${TZ:-UTC}"
    echo "  qBittorrent UI:     $(qbit_ui_mode 2>/dev/null || echo "${QBIT_UI:-stock}")"
    echo "  GPU transcoding:    ${GPU_TRANSCODING:-none}"
    echo "  Byparr solver:      ${BYPARR_ENABLED:-n}"
    echo "  SABnzbd / Usenet:   ${USENET_ENABLED:-n}"
    if type quality_tier >/dev/null 2>&1; then
        if [ "$(quality_tier)" = "any" ]; then
            echo "  Quality:            any"
        else
            echo "  Quality:            $(quality_tier) / $(quality_source)"
        fi
    fi
    if [ "${VPN_ENABLED:-n}" = "y" ]; then
        echo "  VPN secrets:        $INSTALL_DIR/secrets/"
    fi
    echo
    echo "Compose files:"
    local _prev="" _arg
    for _arg in "${COMPOSE_ARGS[@]+"${COMPOSE_ARGS[@]}"}"; do
        if [ "$_prev" = "-f" ]; then
            echo "  $_arg"
        fi
        _prev="$_arg"
    done
}

show_config_help() {
    echo "Usage: ${APP_CLI_NAME:-assemblrr} config [subcommand]"
    echo
    echo "Subcommands:"
    printf "  %-12s %s\n" "show" "Show current configuration"
    printf "  %-12s %s\n" "edit" "Pick a setting to change"
    printf "  %-12s %s\n" "apply" "Re-wire running services (no compose replace)"
    echo
    echo "Examples:"
    echo "  ${APP_CLI_NAME:-assemblrr} config                 # List config options"
    echo "  ${APP_CLI_NAME:-assemblrr} config show            # Show configuration"
    echo "  ${APP_CLI_NAME:-assemblrr} config apply           # Re-run service wiring only"
    echo "  ${APP_CLI_NAME:-assemblrr} config edit            # Pick a setting to change"
}

config_apply() {
    if [ ! -f "$INSTALL_DIR/config.sh" ]; then
        log_error "config.sh not found in $INSTALL_DIR. Run '${APP_CLI_NAME:-assemblrr} upgrade' first."
    fi
    log_info "Re-wiring services (no compose replace)..."
    ASSEMBLRR_NONINTERACTIVE=1 bash "$INSTALL_DIR/config.sh"
}

_load_config_edit() {
    local src=""
    if [ -f "$INSTALL_DIR/lib/config_edit.sh" ]; then
        src="$INSTALL_DIR/lib/config_edit.sh"
    elif [ -f "$_lib_dir/config_edit.sh" ]; then
        src="$_lib_dir/config_edit.sh"
    else
        log_error "config_edit.sh not found. Run '${APP_CLI_NAME:-assemblrr} upgrade' to install modular config edit."
    fi
    # shellcheck source=/dev/null
    source "$src"
}

config_cmd() {
    local sub=${1:-}
    shift || true
    case "$sub" in
        "") show_config_help ;;
        show) show_config ;;
        apply|wire) config_apply ;;
        edit)
            _load_config_edit
            config_edit_run "${1:-}"
            ;;
        --help|-h|help) show_config_help ;;
        *) log_error "Unknown config subcommand: $sub\nRun '${APP_CLI_NAME:-assemblrr} config' for usage" ;;
    esac
}

restore_app() {
    local backup_file="${1:-}"
    if ! validate_backup_archive "$backup_file"; then
        log_error "Invalid or unsafe backup archive (must be a valid .tar.gz containing .env with safe relative paths): $backup_file"
    fi

    echo -e "\nWARNING: This will stop all services and overwrite the current installation!"
    echo "Backup file: $backup_file"
    read_prompt "Are you sure you want to restore? [y/N]: "
    if [[ ${REPLY,,} != "y" ]]; then
        echo "Restore cancelled."
        return 0
    fi

    echo "Stopping ${APP_DISPLAY_NAME:-assemblrr} services..."
    "${DC[@]}" down 2>/dev/null || log_warning "Failed to stop services"

    local timestamp backup_dir abs_backup_file
    timestamp=$(date +%Y%m%d_%H%M%S)
    backup_dir="${INSTALL_DIR}_backup_${timestamp}"

    echo "Creating safety snapshot of current state at ${backup_dir}..."
    wait_while "Creating safety snapshot" run_docker run --rm \
        -v "$(dirname "$INSTALL_DIR"):/target_parent" \
        "${UTILITY_ALPINE_IMAGE:-alpine:3.24.4}" \
        cp -r "/target_parent/$(basename "$INSTALL_DIR")" "/target_parent/$(basename "$backup_dir")" \
        || log_warning "Failed to create safety snapshot"

    wait_while "Clearing install directory" run_docker run --rm \
        -v "$INSTALL_DIR:/target" \
        "${UTILITY_ALPINE_IMAGE:-alpine:3.24.4}" \
        sh -c 'find /target -mindepth 1 -maxdepth 1 ! -name "media" ! -name "downloads" -exec rm -rf {} +'

    abs_backup_file=$(realpath "$backup_file")
    if ! wait_while "Restoring from backup" run_docker run --rm \
        -v "$INSTALL_DIR:/target" \
        -v "$(dirname "$abs_backup_file"):/backup:ro" \
        "${UTILITY_ALPINE_IMAGE:-alpine:3.24.4}" \
        tar --no-same-owner -xzf "/backup/$(basename "$abs_backup_file")" -C /target; then
        log_error "Failed to extract backup"
    fi

    # Adapt restored config to current host INSTALL_DIRECTORY / PUID / PGID if moved
    local host_uid host_gid f
    host_uid=$(id -u)
    host_gid=$(id -g)
    for f in "$INSTALL_DIR/.env" "$INSTALL_DIR/.assemblrr-config"; do
        [ -f "$f" ] || continue
        sed -i -E "s|^INSTALL_DIRECTORY=.*|INSTALL_DIRECTORY=\"${INSTALL_DIR}\"|" "$f" 2>/dev/null || true
    done
    [ -f "$INSTALL_DIR/.env" ] && sed -i -E "s|^INSTALL_DIRECTORY=.*|INSTALL_DIRECTORY=${INSTALL_DIR}|" "$INSTALL_DIR/.env" 2>/dev/null || true
    if [ -d "$INSTALL_DIR/secrets" ]; then
        chmod 700 "$INSTALL_DIR/secrets"
        chmod 600 "$INSTALL_DIR/secrets/"* 2>/dev/null || true
    fi
    prepare_install_dirs "$INSTALL_DIR" "$host_uid" "$host_gid" 2>/dev/null || true

    echo "Starting ${APP_DISPLAY_NAME:-assemblrr} services..."
    "${DC[@]}" up -d --remove-orphans || log_warning "Failed to start services"

    echo "Cleaning up old safety snapshots (keeping last 3)..."
    # shellcheck disable=SC2012
    ls -dt "${INSTALL_DIR}_backup_"* 2>/dev/null | tail -n +4 | while IFS= read -r old_backup; do
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
    echo "${APP_DISPLAY_NAME:-assemblrr} Health Check:"
    echo
    local rows_raw svc state health token label port path kind seen="" unhealthy=0
    rows_raw=$(_status_compose_rows)

    declare -A st_state=() st_health=()
    while IFS=$'\t' read -r svc state health; do
        [ -z "$svc" ] && continue
        st_state["$svc"]="$state"
        st_health["$svc"]="$health"
    done <<< "$rows_raw"

    if type list_service_catalog >/dev/null 2>&1; then
        while IFS='|' read -r svc label port path kind; do
            [ -z "$svc" ] && continue
            seen="${seen}|${svc}|"
            token=$(_status_normalize "${st_state[$svc]:-}" "${st_health[$svc]:-}")
            case "$token" in
                healthy) log_success "  $svc: healthy" ;;
                running) log_warning "  $svc: running (no healthcheck)" ;;
                starting) log_warning "  $svc: starting..." ;;
                *) log_error_inline "  $svc: $token"; unhealthy=$((unhealthy + 1)) ;;
            esac
        done < <(list_service_catalog)
    fi

    while IFS=$'\t' read -r svc state health; do
        [ -z "$svc" ] && continue
        [[ "$seen" == *"|${svc}|"* ]] && continue
        token=$(_status_normalize "$state" "$health")
        case "$token" in
            healthy) log_success "  $svc: healthy (custom)" ;;
            running) log_warning "  $svc: running (custom)" ;;
            starting) log_warning "  $svc: starting..." ;;
            *) log_error_inline "  $svc: $token (custom)"; unhealthy=$((unhealthy + 1)) ;;
        esac
    done <<< "$rows_raw"

    echo
    if [ "$unhealthy" -gt 0 ]; then
        log_warning "$unhealthy service(s) need attention"
        return 1
    fi
    log_success "All services are healthy"
    return 0
}

main() {
    local command="${1:---help}"
    case "$command" in
        --help|-h|help)
            show_help
            return 0
            ;;
    esac

    _cli_init

    local destination="${2:-.}"
    if [ "$command" = "backup" ]; then
        destination=$(realpath "$destination" 2>/dev/null || echo "$destination") || log_error "Invalid backup destination path"
    fi

    case "$command" in
        restart) restart_app "${@:2}" ;;
        stop) stop_app "${@:2}" ;;
        start) start_app "${@:2}" ;;
        status) check_status "${@:2}" ;;
        check-vpn) check_vpn ;;
        destroy) destroy_app "${@:2}" ;;
        uninstall) uninstall_app "${@:2}" ;;
        backup) backup_app "$destination" ;;
        restore)
            [ -z "${2:-}" ] && log_error "Usage: ${APP_CLI_NAME:-assemblrr} restore /path/to/backup.tar.gz"
            restore_app "${2}"
            ;;
        update-containers) update_containers "${@:2}" ;;
        update-cli) log_info "The CLI is ${INSTALL_DIR}/cli.sh. Update with: ${APP_CLI_NAME:-assemblrr} upgrade" ;;
        upgrade)
            if ! type upgrade_app >/dev/null 2>&1; then
                log_error "Upgrade engine not found. Update CLI from a current checkout: bash /path/to/repo/bin/cli.sh upgrade --from /path/to/repo"
            fi
            upgrade_app "${@:2}"
            ;;
        logs) show_logs "$@" ;;
        health) check_health ;;
        config) config_cmd "${@:2}" ;;
        purge)
            [ $# -lt 2 ] && log_error "Usage: ${APP_CLI_NAME:-assemblrr} purge --movie-id N | --series-id N | --path PATH | --tmdb ID | --tvdb ID"
            purge_media "${@:2}"
            ;;
        *) log_error "Unknown command: $command\nRun '${APP_CLI_NAME:-assemblrr} --help' for usage information" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
