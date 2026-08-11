#!/bin/bash
# Migration: ensure Bazarr is part of the stack and can be wired.
# Skip if the install already defines a bazarr service (user-managed).

migration_id="001_add_bazarr"
migration_description="Add Bazarr subtitle service (compose + config dir + wire flag)"

# Return 0 = skip (already satisfied / user owns it)
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
        # Service key at start of a line (compose service name)
        if grep -qE '^[[:space:]]*bazarr:[[:space:]]*$' "$f" 2>/dev/null; then
            # If only custom.yaml has it, user added it themselves before our managed base did
            if [ "$(basename "$f")" = "custom.yaml" ]; then
                return 0
            fi
            # base.yaml already has bazarr: either previous upgrade or we just applied managed files.
            # Skip only if config already looks configured (api key secret from prior wire).
            if [ -s "$install_dir/secrets/bazarr_api_key.txt" ]; then
                return 0
            fi
        fi
    done

    # Running container not from our compose project is rare; still skip re-wiring if present
    # and has non-empty bazarr config from a manual setup
    if [ -d "$install_dir/config/bazarr" ] && [ -n "$(find "$install_dir/config/bazarr" -type f 2>/dev/null | head -1)" ]; then
        if ! grep -qE '^[[:space:]]*bazarr:[[:space:]]*$' "$install_dir/compose/base.yaml" 2>/dev/null; then
            # Data dir exists but base has no bazarr — treat as user-managed external
            return 0
        fi
    fi

    return 1
}

# Return 0 on success. May set UPGRADE_NEED_CONFIG_SYNC=1
migration_apply() {
    local install_dir="${1:-}"
    mkdir -p "$install_dir/config/bazarr"
    # Managed base.yaml already includes the service after apply_managed_files.
    # Flag post-upgrade wiring.
    UPGRADE_NEED_CONFIG_SYNC=1
    return 0
}
