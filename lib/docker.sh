#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# assemblrr Docker & WSL2 Docker Desktop helpers

if [ -n "${_ASSEMBLRR_DOCKER_SOURCED:-}" ]; then
    return 0
fi
readonly _ASSEMBLRR_DOCKER_SOURCED=1

_wait_for_wsl_docker_desktop() {
    local wait_msg="$1"
    local check_cli="$2"
    local docker_exe="/mnt/c/Program Files/Docker/Docker/Docker Desktop.exe"
    grep -qi microsoft /proc/version 2>/dev/null || return 1
    [ -f "$docker_exe" ] && command -v cmd.exe &>/dev/null || return 1

    log_info "Docker daemon is not running. Attempting to start Docker Desktop on Windows..."
    cmd.exe /c start "" "C:\\Program Files\\Docker\\Docker\\Docker Desktop.exe" < /dev/null > /dev/null 2>&1 &
    local i
    for i in {1..45}; do
        wait_inline "$wait_msg" "$i"
        sleep 1
        if { [ "$check_cli" != "1" ] || command -v docker &>/dev/null; } && docker info &>/dev/null; then
            [ -t 2 ] && printf '\r\033[K' >&2
            log_success "Docker Desktop started successfully and is ready."
            return 0
        fi
    done
    [ -t 2 ] && printf '\r\033[K' >&2
    return 1
}

ensure_docker_running() {
    if ! command -v docker &>/dev/null; then
        if _wait_for_wsl_docker_desktop "Waiting for Docker Desktop integration" 1; then
            return 0
        fi
        log_warning "Docker is not installed or not in PATH."
        return 1
    fi

    if ! docker info &>/dev/null; then
        if _wait_for_wsl_docker_desktop "Waiting for Docker daemon" 0; then
            return 0
        fi
        return 1
    fi

    return 0
}

# Backwards-compatible alias
verify_docker() {
    ensure_docker_running "$@"
}

# Wrapper around `docker` that attempts WSL2 Docker Desktop auto-start on failure,
# while preserving the caller's errexit (`set -e`) setting.
run_docker() {
    local had_errexit=0 exit_code=0
    [[ $- == *e* ]] && had_errexit=1

    set +e
    docker "$@"
    exit_code=$?
    [ "$had_errexit" = 1 ] && set -e

    if [ "$exit_code" -ne 0 ]; then
        if ! command -v docker &>/dev/null || ! docker info &>/dev/null; then
            log_warning "Docker daemon is not running or integration is offline. Attempting auto-start..."
            if ensure_docker_running; then
                set +e
                docker "$@"
                exit_code=$?
                [ "$had_errexit" = 1 ] && set -e
                return "$exit_code"
            else
                log_error "Docker daemon is not running. Please start Docker and try again."
                return 1
            fi
        fi
    fi

    return "$exit_code"
}
