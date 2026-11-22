#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# assemblrr Docker Compose builder — sourced by entry points that manage containers
# Requires: lib/core.sh for compose_up_stack (wait_while, run_docker, log_warning)

if [ -n "${_ASSEMBLRR_COMPOSE_SOURCED:-}" ]; then
    return 0
fi
readonly _ASSEMBLRR_COMPOSE_SOURCED=1

# Builds the docker compose arguments array (COMPOSE_ARGS) based on VPN & feature flags.
# Usage: build_compose_args "$install_dir" "$vpn_enabled"
# Reads optional env flags: QBIT_UI (or legacy VUETORRENT_ENABLED), GPU_TRANSCODING, BYPARR_ENABLED, USENET_ENABLED.
# custom.yaml is always appended last so user overrides win.
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

    case "$(qbit_ui_mode)" in
        vuetorrent)
            [ -f "$_install_dir/compose/vuetorrent.yaml" ] && COMPOSE_ARGS+=("-f" "$_install_dir/compose/vuetorrent.yaml")
            ;;
        qui)
            [ -f "$_install_dir/compose/qui.yaml" ] && COMPOSE_ARGS+=("-f" "$_install_dir/compose/qui.yaml")
            ;;
    esac

    case "${GPU_TRANSCODING:-none}" in
        intel|INTEL|amd|AMD|vaapi|VAAPI)
            [ -f "$_install_dir/compose/gpu-intel.yaml" ] && COMPOSE_ARGS+=("-f" "$_install_dir/compose/gpu-intel.yaml")
            ;;
        nvidia|NVIDIA)
            [ -f "$_install_dir/compose/gpu-nvidia.yaml" ] && COMPOSE_ARGS+=("-f" "$_install_dir/compose/gpu-nvidia.yaml")
            ;;
    esac

    if [ "${BYPARR_ENABLED:-n}" = "y" ] || [ "${BYPARR_ENABLED:-n}" = "Y" ]; then
        if [ -f "$_install_dir/compose/byparr.yaml" ]; then
            COMPOSE_ARGS+=("-f" "$_install_dir/compose/byparr.yaml")
        fi
    fi

    if [ "${USENET_ENABLED:-n}" = "y" ] || [ "${USENET_ENABLED:-n}" = "Y" ]; then
        if [ -f "$_install_dir/compose/usenet.yaml" ]; then
            COMPOSE_ARGS+=("-f" "$_install_dir/compose/usenet.yaml")
        fi
    fi

    # User custom overlay always last so overrides win cleanly
    if [ -f "$_install_dir/compose/custom.yaml" ]; then
        COMPOSE_ARGS+=("-f" "$_install_dir/compose/custom.yaml")
    fi
}

# Bring the stack up. Image pulls and sidecar Dockerfile builds (apk, layers)
# stay off the terminal. Failures print a tail of the captured log.
# Usage: compose_up_stack [profile] [extra docker compose args...]
compose_up_stack() {
    local profile="${1:-}"
    local -a profile_args=()
    if [ -n "$profile" ]; then
        shift
        if [ "$profile" != "default" ]; then
            profile_args=(--profile "$profile")
        fi
    fi
    if [ "${#COMPOSE_ARGS[@]}" -eq 0 ]; then
        return 1
    fi

    local wait_fn="wait_while"
    if [ "${ASSEMBLRR_LIVE_SERVICES:-0}" = "1" ] && type wait_while_services >/dev/null 2>&1; then
        wait_fn="wait_while_services"
    fi

    if ! "$wait_fn" "Starting services" \
        run_docker compose "${COMPOSE_ARGS[@]}" "${profile_args[@]}" up -d --remove-orphans "$@"; then
        log_warning "Failed to start services"
        if [ -n "${WAIT_WHILE_OUTPUT:-}" ]; then
            echo "$WAIT_WHILE_OUTPUT" | tail -n 40
        fi
        return 1
    fi
    return 0
}
