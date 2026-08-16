#!/bin/bash
# assemblrr VPN helpers — sourced by entry points that handle VPN orchestration
# Requires: lib/core.sh (for logging, safe_source)

# Guard against double-sourcing
if [ -n "${_ASSEMBLRR_VPN_SOURCED:-}" ]; then
    return 0
fi
readonly _ASSEMBLRR_VPN_SOURCED=1

# Tests VPN connection by starting Gluetun first and waiting for it to become healthy.
# Usage: test_vpn_connection_shared "${DC[@]}"
test_vpn_connection_shared() {
    local docker_cmd=("$@")
    
    log_info "Testing VPN connection by starting Gluetun first..."

    # Force recreate so updated secrets/.env from a credential retry always apply.
    if ! "${docker_cmd[@]}" up -d --force-recreate gluetun 2>/dev/null; then
        log_warning "Failed to start Gluetun container. VPN configuration may be incorrect."
        log_info "Check secrets/ (credentials) and .env (VPN_SERVICE, VPN_TYPE, WIREGUARD_ADDRESSES)."
        return 1
    fi

    local wait_time=0
    local max_wait=90
    while [ $wait_time -lt $max_wait ]; do
        local health
        health=$(docker inspect --format='{{.State.Health.Status}}' gluetun 2>/dev/null || echo "unknown")

        if [ "$health" = "healthy" ]; then
            echo >&2
            log_success "VPN connection established successfully!"
            return 0
        elif [ "$health" = "unhealthy" ]; then
            echo >&2
            log_warning "VPN connection failed. Gluetun logs:"
            "${docker_cmd[@]}" logs gluetun --tail=20 2>/dev/null
            echo
            log_info "Fix VPN credentials in secrets/ (and WIREGUARD_ADDRESSES in .env if using WireGuard), then try again."
            "${docker_cmd[@]}" stop gluetun 2>/dev/null
            return 1
        fi

        wait_inline "Waiting for VPN connection" "$wait_time"
        sleep 3
        wait_time=$((wait_time + 3))
    done

    echo >&2
    log_warning "VPN connection timed out after ${max_wait}s. Gluetun logs:"
    "${docker_cmd[@]}" logs gluetun --tail=20 2>/dev/null
    echo
    log_info "The VPN may need more time, or credentials may be incorrect (see secrets/ and .env)."
    "${docker_cmd[@]}" stop gluetun 2>/dev/null
    return 1
}

# Validate that VPN secrets exist when VPN is enabled.
# Usage: validate_vpn_secrets "$install_dir" "$vpn_enabled" "$vpn_type"
# Returns 0 if OK, 1 if secrets are missing (prints warnings).
validate_vpn_secrets() {
    local _install_dir="$1"
    local _vpn_enabled="${2:-n}"
    local _vpn_type="${3:-openvpn}"

    if [ "${_vpn_enabled,,}" != "y" ]; then
        return 0
    fi

    # Source .env for WIREGUARD_ADDRESSES
    local _env_file="$_install_dir/.env"
    if [ -f "$_env_file" ]; then
        set -a; safe_source "$_env_file"; set +a
    fi

    local _secrets_dir="$_install_dir/secrets"
    local _missing=()

    if [ "${_vpn_type,,}" = "wireguard" ]; then
        [ ! -s "$_secrets_dir/wireguard_private_key.txt" ] && _missing+=("secrets/wireguard_private_key.txt")
        [ -z "${WIREGUARD_ADDRESSES:-}" ] && _missing+=("WIREGUARD_ADDRESSES in .env")
    else
        [ ! -s "$_secrets_dir/openvpn_user.txt" ] && _missing+=("secrets/openvpn_user.txt")
        [ ! -s "$_secrets_dir/openvpn_password.txt" ] && _missing+=("secrets/openvpn_password.txt")
    fi

    if [ ${#_missing[@]} -gt 0 ]; then
        log_warning "VPN is enabled but the following required secrets are missing:"
        for var in "${_missing[@]}"; do
            log_warning "  - $var"
        done
        echo
        log_warning "Services will NOT start until these are set."
        log_info "Edit secrets in $_secrets_dir and try again."
        return 1
    fi

    return 0
}
