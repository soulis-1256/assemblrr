#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# assemblrr Recyclarr TRaSH Guides sync configuration
# Requires: lib/core.sh, lib/quality.sh, config.sh logging

if [ -n "${_ASSEMBLRR_RECYCLARR_SOURCED:-}" ]; then
    return 0
fi
readonly _ASSEMBLRR_RECYCLARR_SOURCED=1

_recyclarr_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/quality.sh
[ -f "$_recyclarr_dir/quality.sh" ] && source "$_recyclarr_dir/quality.sh"

configure_recyclarr() {
    local recyclarr_config_dir="$INSTALL_DIR/config/recyclarr"
    local template_root="$INSTALL_DIR/templates/recyclarr"
    mkdir -p "$recyclarr_config_dir/includes"

    if [ ! -w "$recyclarr_config_dir" ]; then
        log_step_fail "Recyclarr: config directory not writable (${recyclarr_config_dir})"
        return 1
    fi

    export RADARR_API_KEY SONARR_API_KEY

    local default_label
    default_label=$(quality_profile_names radarr)
    default_label="${default_label%%|*}"

    if [ ! -f "$template_root/recyclarr.yml" ]; then
        log_step_fail "Recyclarr: template root not found (${template_root}/recyclarr.yml)"
        return 1
    fi

    # Write with 0600 (contains Radarr/Sonarr API keys)
    if ! (
        umask 077
        envsubst '${RADARR_API_KEY} ${SONARR_API_KEY}' \
            < "$template_root/recyclarr.yml" \
            > "$recyclarr_config_dir/recyclarr.yml"
    ); then
        log_step_fail "Recyclarr: failed to write config (${recyclarr_config_dir}/recyclarr.yml)"
        return 1
    fi
    chmod 600 "$recyclarr_config_dir/recyclarr.yml" 2>/dev/null || true

    local include_src="$template_root/includes"
    if [ ! -d "$include_src" ]; then
        log_step_fail "Recyclarr: includes directory not found (${include_src})"
        return 1
    fi
    rm -f "$recyclarr_config_dir/includes"/*.yml 2>/dev/null || true
    if ! cp "$include_src"/*.yml "$recyclarr_config_dir/includes/"; then
        log_step_fail "Recyclarr: failed to copy include packs"
        return 1
    fi

    local pack_count
    pack_count=$(find "$recyclarr_config_dir/includes" -maxdepth 1 -name '*.yml' | wc -l | tr -d ' ')
    log_step "Recyclarr: generated config (${pack_count} include packs; Seerr default: ${default_label})"

    local sync_out
    if wait_while "Syncing Recyclarr (TRaSH Guides)" run_docker exec recyclarr recyclarr sync; then
        log_step "Recyclarr: synced Custom Formats and Quality Profiles successfully"
    else
        sync_out="${WAIT_WHILE_OUTPUT:-}"
        log_step_fail "Recyclarr: failed to sync to Radarr/Sonarr"
        printf '%s\n' "$sync_out" | grep -E '•|Error|error|Invalid|YAML' | head -5 | while IFS= read -r line; do
            _cfg_log_info "  $line"
        done
        return 1
    fi
}
