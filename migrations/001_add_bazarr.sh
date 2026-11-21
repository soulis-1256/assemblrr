#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Migration: ensure Bazarr is part of the stack and can be wired.
# Skip if the install already defines a bazarr service (user-managed).

migration_id="001_add_bazarr"
migration_description="Add Bazarr subtitle service (compose + config dir + wire flag)"

migration_should_skip() {
    local install_dir="${1:-}"
    local f
    for f in \
        "$install_dir/compose/base.yaml" \
        "$install_dir/compose/custom.yaml" \
        "$install_dir/compose/vpn.yaml" \
        "$install_dir/compose/direct-access.yaml"
    do
        [ -f "$f" ] || continue
        if grep -qE '^[[:space:]]*bazarr:[[:space:]]*$' "$f" 2>/dev/null; then
            if [ "$(basename "$f")" = "custom.yaml" ]; then
                return 0
            fi
            if [ -s "$install_dir/secrets/bazarr_api_key.txt" ]; then
                return 0
            fi
        fi
    done

    if [ -d "$install_dir/config/bazarr" ] && [ -n "$(find "$install_dir/config/bazarr" -type f 2>/dev/null | head -1)" ]; then
        if ! grep -qE '^[[:space:]]*bazarr:[[:space:]]*$' "$install_dir/compose/base.yaml" 2>/dev/null; then
            return 0
        fi
    fi

    return 1
}

migration_apply() {
    local install_dir="${1:-}"
    mkdir -p "$install_dir/config/bazarr"
    return 0
}
