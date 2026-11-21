#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# assemblrr branding loader — sourced by entry points that need branding
# Requires: lib/core.sh (for safe_source)

if [ -n "${_ASSEMBLRR_BRANDING_SOURCED:-}" ]; then
    return 0
fi
readonly _ASSEMBLRR_BRANDING_SOURCED=1

# Load branding.conf from a given directory, with fallback defaults for every key.
load_branding() {
    local _branding_dir="$1"
    if [ -f "$_branding_dir/branding.conf" ]; then
        safe_source "$_branding_dir/branding.conf"
    fi

    APP_NAME="${APP_NAME:-assemblrr}"
    APP_DISPLAY_NAME="${APP_DISPLAY_NAME:-assemblrr}"
    APP_DESCRIPTION="${APP_DESCRIPTION:-Your one-click media server}"
    APP_CLI_NAME="${APP_CLI_NAME:-assemblrr}"
    APP_NETWORK_NAME="${APP_NETWORK_NAME:-assemblrr_network}"
    APP_REPO_URL="${APP_REPO_URL:-https://github.com/soulis-1256/assemblrr}"
    APP_DEFAULT_INSTALL_DIR="${APP_DEFAULT_INSTALL_DIR:-$HOME/$APP_NAME}"
    APP_DEFAULT_MEDIA_DIR="${APP_DEFAULT_MEDIA_DIR:-$HOME/$APP_NAME-media}"
    APP_BACKUP_PREFIX="${APP_BACKUP_PREFIX:-assemblrr-backup}"
}
