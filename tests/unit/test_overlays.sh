#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Unit tests for feature overlays & conditional service catalog (VueTorrent, GPU, Byparr, Usenet)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../helpers.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/core.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/compose.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/services.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/compose"
touch "$tmp/compose/base.yaml" "$tmp/compose/vpn.yaml" "$tmp/compose/direct-access.yaml" \
      "$tmp/compose/vuetorrent.yaml" "$tmp/compose/gpu-intel.yaml" "$tmp/compose/gpu-nvidia.yaml" \
      "$tmp/compose/byparr.yaml" "$tmp/compose/usenet.yaml"

test_suite "Conditional service catalog reflects feature overlays"
VPN_ENABLED=n USENET_ENABLED=n BYPARR_ENABLED=n
cat_off=$(list_service_catalog)
assert_contains "$cat_off" "jellyfin|Jellyfin|8096" "has jellyfin"
assert_not_contains "$cat_off" "sabnzbd|" "omits sabnzbd when USENET_ENABLED=n"
assert_not_contains "$cat_off" "byparr|" "omits byparr when BYPARR_ENABLED=n"
assert_not_contains "$cat_off" "gluetun|" "omits gluetun when VPN_ENABLED=n"

VPN_ENABLED=y USENET_ENABLED=y BYPARR_ENABLED=y
cat_on=$(list_service_catalog)
assert_contains "$cat_on" "sabnzbd|SABnzbd|8085|/|ui" "lists sabnzbd UI when USENET_ENABLED=y"
assert_contains "$cat_on" "byparr|Byparr (solver)|||internal" "lists byparr when BYPARR_ENABLED=y"
assert_contains "$cat_on" "gluetun|Gluetun (VPN)|||internal" "lists gluetun when VPN_ENABLED=y"

test_suite "service_ui_url honors API_HOST"
assert_eq "http://localhost:8085/" "$(service_ui_url 8085 / 127.0.0.1)" "127.0.0.1 -> localhost"
assert_eq "http://192.168.1.50:8085/" "$(service_ui_url 8085 / 192.168.1.50)" "preserves LAN IP host"

test_suite "GPU overlays exclude mutually exclusive configs cleanly"
VUETORRENT_ENABLED=n GPU_TRANSCODING=intel BYPARR_ENABLED=n USENET_ENABLED=n
build_compose_args "$tmp" "n"
assert_contains "${COMPOSE_ARGS[*]}" "gpu-intel.yaml" "intel overlay included"
assert_not_contains "${COMPOSE_ARGS[*]}" "gpu-nvidia.yaml" "nvidia overlay excluded"

GPU_TRANSCODING=amd
build_compose_args "$tmp" "n"
assert_contains "${COMPOSE_ARGS[*]}" "gpu-intel.yaml" "amd selects /dev/dri overlay"
assert_not_contains "${COMPOSE_ARGS[*]}" "gpu-nvidia.yaml" "amd excludes nvidia overlay"

GPU_TRANSCODING=vaapi
build_compose_args "$tmp" "n"
assert_contains "${COMPOSE_ARGS[*]}" "gpu-intel.yaml" "vaapi selects /dev/dri overlay"

GPU_TRANSCODING=nvidia
build_compose_args "$tmp" "n"
assert_contains "${COMPOSE_ARGS[*]}" "gpu-nvidia.yaml" "nvidia overlay included"
assert_not_contains "${COMPOSE_ARGS[*]}" "gpu-intel.yaml" "intel overlay excluded"

test_suite "Express VueTorrent default is y"
# shellcheck source=/dev/null
source "$REPO_ROOT/lib/prompts.sh"
SETUP_MODE=express configure_vuetorrent
assert_eq "y" "${vuetorrent_enabled:-}" "express mode enables VueTorrent by default"

test_summary
