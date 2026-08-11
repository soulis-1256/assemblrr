#!/bin/bash
# assemblrr managed file manifest — files upgrade/setup may replace in the install dir
# Sacred (never overwritten by upgrade): secrets/, config/* service data, .env,
# .assemblrr-config, compose/custom.yaml
#
# Format printed by list_managed_files:  SOURCE_REL|DEST_REL
# SOURCE_REL is relative to the package source tree (repo root).
# DEST_REL is relative to the install directory.

# Re-sourceable: redefines list_managed_files from the active package tree.

list_managed_files() {
    cat <<'EOF'
lib/core.sh|lib/core.sh
lib/branding.sh|lib/branding.sh
lib/compose.sh|lib/compose.sh
lib/vpn.sh|lib/vpn.sh
lib/api.sh|lib/api.sh
lib/arr.sh|lib/arr.sh
lib/jellyfin.sh|lib/jellyfin.sh
lib/seerr.sh|lib/seerr.sh
lib/bazarr.sh|lib/bazarr.sh
lib/prompts.sh|lib/prompts.sh
lib/fzf-tui.sh|lib/fzf-tui.sh
lib/managed_files.sh|lib/managed_files.sh
lib/upgrade.sh|lib/upgrade.sh
lib/services.sh|lib/services.sh
compose/base.yaml|compose/base.yaml
compose/direct-access.yaml|compose/direct-access.yaml
compose/vpn.yaml|compose/vpn.yaml
compose/examples/custom.yaml.example|compose/examples/custom.yaml.example
.env.example|.env.example
templates/recyclarr/recyclarr.yml|templates/recyclarr/recyclarr.yml
templates/recyclarr/includes/radarr-hd.yml|templates/recyclarr/includes/radarr-hd.yml
templates/recyclarr/includes/radarr-uhd.yml|templates/recyclarr/includes/radarr-uhd.yml
templates/recyclarr/includes/radarr-soft-cfs.yml|templates/recyclarr/includes/radarr-soft-cfs.yml
templates/recyclarr/includes/sonarr-web-1080.yml|templates/recyclarr/includes/sonarr-web-1080.yml
templates/recyclarr/includes/sonarr-web-2160.yml|templates/recyclarr/includes/sonarr-web-2160.yml
templates/recyclarr/includes/sonarr-soft-cfs.yml|templates/recyclarr/includes/sonarr-soft-cfs.yml
branding.conf|branding.conf
bin/cli.sh|cli.sh
bin/config.sh|config.sh
bin/setup.sh|setup.sh
bin/docker-install.sh|docker-install.sh
scripts/jellyfin-refresh.sh|scripts/jellyfin-refresh.sh
scripts/vpn-watchdog.sh|scripts/vpn-watchdog.sh
docs/api-reference.md|docs/api-reference.md
docs/trash-guides.md|docs/trash-guides.md
docs/uninstall.md|docs/uninstall.md
README.md|README.md
EOF
    # Migrations (all files under migrations/)
    # Listed dynamically when a source root is available via UPGRADE_SOURCE_ROOT
    if [ -n "${UPGRADE_SOURCE_ROOT:-}" ] && [ -d "$UPGRADE_SOURCE_ROOT/migrations" ]; then
        local f rel
        while IFS= read -r -d '' f; do
            rel=${f#"$UPGRADE_SOURCE_ROOT/"}
            printf '%s|%s\n' "$rel" "$rel"
        done < <(find "$UPGRADE_SOURCE_ROOT/migrations" -type f -print0 2>/dev/null | sort -z)
    fi
}
