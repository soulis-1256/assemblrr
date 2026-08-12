#!/bin/bash
# Migration: drop Portainer from the default stack (use assemblrr CLI instead).
# Skip if the user still defines portainer in custom.yaml (optional path).

migration_id="002_remove_portainer"
migration_description="Remove Portainer container when no longer in managed compose"

# Return 0 = skip
migration_should_skip() {
    local install_dir="${1:-}"
    local f="$install_dir/compose/custom.yaml"

    # User opted back in via custom overlay — leave their Portainer alone
    if [ -f "$f" ] && grep -qE '^[[:space:]]*portainer:[[:space:]]*$' "$f" 2>/dev/null; then
        return 0
    fi

    # Nothing to do if no container is present
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
    local install_dir="${1:-}"
    # Container only — leave config/portainer on disk (user can delete manually)
    if command -v docker >/dev/null 2>&1; then
        if docker rm -f portainer >/dev/null 2>&1; then
            echo "Removed portainer container (dropped from default stack)" >&2
        fi
    fi
    return 0
}
