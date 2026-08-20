#!/bin/bash
# Migration: remove legacy Recyclarr template files superseded by 4K / 1080p standardization.

migration_id="003_standardize_quality_profiles"
migration_description="Remove superseded Recyclarr include packs from prior versions"

readonly LEGACY_RECYCLARR_INCLUDES=(
    "radarr-hd.yml"
    "radarr-uhd.yml"
    "radarr-web-1080.yml"
    "radarr-web-2160.yml"
    "sonarr-web-1080.yml"
    "sonarr-web-2160.yml"
)

# Return 0 = skip
migration_should_skip() {
    local install_dir="${1:-}"
    local legacy_file
    for legacy_file in "${LEGACY_RECYCLARR_INCLUDES[@]}"; do
        if [ -f "$install_dir/templates/recyclarr/includes/$legacy_file" ] || \
           [ -f "$install_dir/config/recyclarr/includes/$legacy_file" ]; then
            return 1
        fi
    done
    return 0
}

migration_apply() {
    local install_dir="${1:-}"
    local legacy_file
    for legacy_file in "${LEGACY_RECYCLARR_INCLUDES[@]}"; do
        rm -f "$install_dir/templates/recyclarr/includes/$legacy_file" 2>/dev/null || true
        rm -f "$install_dir/config/recyclarr/includes/$legacy_file" 2>/dev/null || true
    done
    return 0
}
