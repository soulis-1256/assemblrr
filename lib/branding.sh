#!/bin/bash
# assemblrr branding loader — sourced by entry points that need branding
# Requires: lib/core.sh (for safe_source)

if [ -n "${_ASSEMBLRR_BRANDING_SOURCED:-}" ]; then
    return 0
fi
readonly _ASSEMBLRR_BRANDING_SOURCED=1

# Load branding.conf from a given directory, with hardcoded fallback defaults.
# Usage: load_branding "$dir_containing_branding_conf"
load_branding() {
    local _branding_dir="$1"
    if [ -f "$_branding_dir/branding.conf" ]; then
        safe_source "$_branding_dir/branding.conf"
    else
        APP_NAME="assemblrr"
        APP_DISPLAY_NAME="assemblrr"
        APP_CLI_NAME="assemblrr"
        APP_NETWORK_NAME="assemblrr_network"
        APP_BACKUP_PREFIX="assemblrr-backup"
        APP_SERVICE_FILE="assemblrr_services.txt"
    fi
}
