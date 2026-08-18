#!/bin/bash
# assemblrr Docker Compose builder — sourced by entry points that manage containers
# Requires: lib/core.sh for compose_up_stack (wait_while, run_docker, log_warning)

if [ -n "${_ASSEMBLRR_COMPOSE_SOURCED:-}" ]; then
    return 0
fi
readonly _ASSEMBLRR_COMPOSE_SOURCED=1

# Builds the docker compose arguments array (COMPOSE_ARGS) based on VPN mode.
# Usage: build_compose_args "$install_dir" "$vpn_enabled"
#   $1 = install directory (e.g. /home/user/assemblrr)
#   $2 = vpn enabled flag ("y" or "n")
# After calling, COMPOSE_ARGS contains -f flags and --project-directory.
# Caller should add "--profile" and "docker compose" prefix as needed.
build_compose_args() {
    local _install_dir="$1"
    local _vpn_enabled="${2:-n}"

    COMPOSE_ARGS=("--project-directory" "$_install_dir")
    COMPOSE_ARGS+=("-f" "$_install_dir/compose/base.yaml")

    if [ "${_vpn_enabled,,}" = "y" ]; then
        COMPOSE_ARGS+=("-f" "$_install_dir/compose/vpn.yaml")
    else
        COMPOSE_ARGS+=("-f" "$_install_dir/compose/direct-access.yaml")
    fi

    # Check for custom overlay
    if [ -f "$_install_dir/compose/custom.yaml" ]; then
        COMPOSE_ARGS+=("-f" "$_install_dir/compose/custom.yaml")
    fi
}

# Bring the stack up. Image pulls and sidecar Dockerfile builds (apk, layers)
# stay off the terminal. Failures print a tail of the captured log.
# Usage: compose_up_stack <profile> [extra docker compose args...]
# Requires COMPOSE_ARGS from build_compose_args.
compose_up_stack() {
    local profile="${1:-}"
    if [ -z "$profile" ]; then
        return 1
    fi
    shift
    if [ "${#COMPOSE_ARGS[@]}" -eq 0 ]; then
        return 1
    fi

    if ! wait_while "Starting services" \
        run_docker compose "${COMPOSE_ARGS[@]}" --profile "$profile" up -d --remove-orphans "$@"; then
        log_warning "Failed to start services"
        if [ -n "${WAIT_WHILE_OUTPUT:-}" ]; then
            echo "$WAIT_WHILE_OUTPUT" | tail -n 40
        fi
        return 1
    fi
    return 0
}
