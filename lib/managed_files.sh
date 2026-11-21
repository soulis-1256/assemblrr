#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# assemblrr managed file manifest — files upgrade/setup may replace in the install dir
# Sacred (never overwritten by upgrade): secrets/, config/* service data, .env,
# .assemblrr-config, .assemblrr-channel, .assemblrr-version, .assemblrr-migrations, compose/custom.yaml
#
# Format printed by list_managed_files:  SOURCE_REL|DEST_REL

list_managed_files() {
    cat <<'EOF'
lib/core.sh|lib/core.sh
lib/log.sh|lib/log.sh
lib/tty.sh|lib/tty.sh
lib/paths.sh|lib/paths.sh
lib/fs.sh|lib/fs.sh
lib/docker.sh|lib/docker.sh
lib/languages.sh|lib/languages.sh
lib/branding.sh|lib/branding.sh
lib/compose.sh|lib/compose.sh
lib/vpn.sh|lib/vpn.sh
lib/api.sh|lib/api.sh
lib/arr.sh|lib/arr.sh
lib/qbit.sh|lib/qbit.sh
lib/arr_common.sh|lib/arr_common.sh
lib/arr_quality.sh|lib/arr_quality.sh
lib/prowlarr.sh|lib/prowlarr.sh
lib/arr_import.sh|lib/arr_import.sh
lib/recyclarr.sh|lib/recyclarr.sh
lib/quality.sh|lib/quality.sh
lib/jellyfin.sh|lib/jellyfin.sh
lib/seerr.sh|lib/seerr.sh
lib/bazarr.sh|lib/bazarr.sh
lib/usenet.sh|lib/usenet.sh
lib/prompts.sh|lib/prompts.sh
lib/fzf-tui.sh|lib/fzf-tui.sh
lib/managed_files.sh|lib/managed_files.sh
lib/upgrade.sh|lib/upgrade.sh
lib/services.sh|lib/services.sh
lib/ui.sh|lib/ui.sh
lib/config_edit.sh|lib/config_edit.sh
compose/base.yaml|compose/base.yaml
compose/direct-access.yaml|compose/direct-access.yaml
compose/vpn.yaml|compose/vpn.yaml
compose/vuetorrent.yaml|compose/vuetorrent.yaml
compose/gpu-intel.yaml|compose/gpu-intel.yaml
compose/gpu-nvidia.yaml|compose/gpu-nvidia.yaml
compose/byparr.yaml|compose/byparr.yaml
compose/usenet.yaml|compose/usenet.yaml
compose/examples/custom.yaml.example|compose/examples/custom.yaml.example
compose/sidecars/vpn-watchdog.Dockerfile|compose/sidecars/vpn-watchdog.Dockerfile
compose/sidecars/media-purge-watch.Dockerfile|compose/sidecars/media-purge-watch.Dockerfile
.env.example|.env.example
templates/recyclarr/recyclarr.yml|templates/recyclarr/recyclarr.yml
templates/recyclarr/includes/radarr-1080p-bluray.yml|templates/recyclarr/includes/radarr-1080p-bluray.yml
templates/recyclarr/includes/radarr-4k-bluray.yml|templates/recyclarr/includes/radarr-4k-bluray.yml
templates/recyclarr/includes/radarr-1080p-web.yml|templates/recyclarr/includes/radarr-1080p-web.yml
templates/recyclarr/includes/radarr-4k-web.yml|templates/recyclarr/includes/radarr-4k-web.yml
templates/recyclarr/includes/radarr-soft-cfs.yml|templates/recyclarr/includes/radarr-soft-cfs.yml
templates/recyclarr/includes/sonarr-1080p-web.yml|templates/recyclarr/includes/sonarr-1080p-web.yml
templates/recyclarr/includes/sonarr-4k-web.yml|templates/recyclarr/includes/sonarr-4k-web.yml
templates/recyclarr/includes/sonarr-soft-cfs.yml|templates/recyclarr/includes/sonarr-soft-cfs.yml
branding.conf|branding.conf
NOTICE|NOTICE
bin/cli.sh|cli.sh
bin/config.sh|config.sh
bin/setup.sh|setup.sh
bin/docker-install.sh|docker-install.sh
scripts/jellyfin-refresh.sh|scripts/jellyfin-refresh.sh
scripts/vpn-watchdog.sh|scripts/vpn-watchdog.sh
scripts/media-purge.sh|scripts/media-purge.sh
scripts/arr-purge-hook.sh|scripts/arr-purge-hook.sh
scripts/media-purge-watch.sh|scripts/media-purge-watch.sh
scripts/seerr-gateway.py|scripts/seerr-gateway.py
docs/api-reference.md|docs/api-reference.md
docs/komodo.md|docs/komodo.md
docs/trash-guides.md|docs/trash-guides.md
docs/uninstall.md|docs/uninstall.md
docs/seerr-delete-request.md|docs/seerr-delete-request.md
README.md|README.md
EOF
    if [ -n "${UPGRADE_SOURCE_ROOT:-}" ] && [ -d "$UPGRADE_SOURCE_ROOT/migrations" ]; then
        local f rel
        while IFS= read -r -d '' f; do
            rel=${f#"$UPGRADE_SOURCE_ROOT/"}
            printf '%s|%s\n' "$rel" "$rel"
        done < <(find "$UPGRADE_SOURCE_ROOT/migrations" -type f -print0 2>/dev/null | sort -z)
    fi
}
