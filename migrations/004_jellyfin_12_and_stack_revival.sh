#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Migration: Jellyfin 12.4 upgrade readiness, SABnzbd dir prep, and new overlay flag defaults.

migration_id="004_jellyfin_12_and_stack_revival"
migration_description="Backfill feature flags, create config/sabnzbd, and emit Jellyfin 12.4 upgrade notes"

_m004_append_if_missing() {
    local file="$1" key="$2" line="$3"
    [ -f "$file" ] || return 0
    if ! grep -qE "^[[:space:]]*${key}=" "$file" 2>/dev/null; then
        printf '%s\n' "$line" >> "$file"
    fi
}

migration_should_skip() {
    local install_dir="${1:-}"
    [ -d "$install_dir/config/sabnzbd" ] || return 1
    [ -d "$install_dir/config/qui" ] || return 1

    local key
    for key in QBIT_UI VUETORRENT_ENABLED GPU_TRANSCODING BYPARR_ENABLED USENET_ENABLED; do
        if [ -f "$install_dir/.env" ] && ! grep -qE "^[[:space:]]*${key}=" "$install_dir/.env" 2>/dev/null; then
            return 1
        fi
        if [ -f "$install_dir/.assemblrr-config" ] && ! grep -qE "^[[:space:]]*${key}=" "$install_dir/.assemblrr-config" 2>/dev/null; then
            return 1
        fi
    done
    return 0
}

migration_apply() {
    local install_dir="${1:-}"
    mkdir -p "$install_dir/config/sabnzbd" "$install_dir/config/qui"

    _m004_append_if_missing "$install_dir/.env" "QBIT_UI" "QBIT_UI=stock"
    _m004_append_if_missing "$install_dir/.env" "VUETORRENT_ENABLED" "VUETORRENT_ENABLED=n"
    _m004_append_if_missing "$install_dir/.env" "GPU_TRANSCODING" "GPU_TRANSCODING=none"
    _m004_append_if_missing "$install_dir/.env" "BYPARR_ENABLED" "BYPARR_ENABLED=n"
    _m004_append_if_missing "$install_dir/.env" "USENET_ENABLED" "USENET_ENABLED=n"

    _m004_append_if_missing "$install_dir/.assemblrr-config" "QBIT_UI" 'QBIT_UI="stock"'
    _m004_append_if_missing "$install_dir/.assemblrr-config" "VUETORRENT_ENABLED" 'VUETORRENT_ENABLED="n"'
    _m004_append_if_missing "$install_dir/.assemblrr-config" "GPU_TRANSCODING" 'GPU_TRANSCODING="none"'
    _m004_append_if_missing "$install_dir/.assemblrr-config" "BYPARR_ENABLED" 'BYPARR_ENABLED="n"'
    _m004_append_if_missing "$install_dir/.assemblrr-config" "USENET_ENABLED" 'USENET_ENABLED="n"'

    if [ -f "$install_dir/.assemblrr-config" ] && grep -qE '^MEDIA_SERVICE="(emby|plex)"' "$install_dir/.assemblrr-config" 2>/dev/null; then
        echo "NOTICE: Emby/Plex are no longer in core compose/base.yaml; move your container override to compose/custom.yaml (see compose/examples/custom.yaml.example). Existing config/* data was untouched." >&2
    fi
    echo "NOTICE: Stack upgraded to Jellyfin 12.4 (Authorization: MediaBrowser auth). Keep your pre-upgrade backup in case rollback is ever needed." >&2
    return 0
}
