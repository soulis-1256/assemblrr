#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Migration: drop Portainer from the default stack (use assemblrr CLI instead).
# Skip if the user still defines portainer in custom.yaml (optional path).

migration_id="002_remove_portainer"
migration_description="Remove Portainer container when no longer in managed compose"

migration_should_skip() {
    local install_dir="${1:-}"
    local f="$install_dir/compose/custom.yaml"

    if [ -f "$f" ] && grep -qE '^[[:space:]]*portainer:[[:space:]]*$' "$f" 2>/dev/null; then
        return 0
    fi

    if command -v docker >/dev/null 2>&1; then
        if ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx 'portainer'; then
            return 0
        fi
    else
        return 0
    fi

    return 1
}

migration_apply() {
    local _install_dir="${1:-}"
    if command -v docker >/dev/null 2>&1; then
        if docker rm -f portainer >/dev/null 2>&1; then
            echo "Removed portainer container (dropped from default stack)" >&2
        fi
    fi
    return 0
}
