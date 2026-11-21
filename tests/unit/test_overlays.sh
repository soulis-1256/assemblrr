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
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/qbit.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/compose"
touch "$tmp/compose/base.yaml" "$tmp/compose/vpn.yaml" "$tmp/compose/direct-access.yaml" \
      "$tmp/compose/vuetorrent.yaml" "$tmp/compose/qui.yaml" "$tmp/compose/gpu-intel.yaml" "$tmp/compose/gpu-nvidia.yaml" \
      "$tmp/compose/byparr.yaml" "$tmp/compose/usenet.yaml"

test_suite "Conditional service catalog reflects feature overlays"
VPN_ENABLED=n USENET_ENABLED=n BYPARR_ENABLED=n QBIT_UI=vuetorrent VUETORRENT_ENABLED=y
cat_off=$(list_service_catalog)
assert_contains "$cat_off" "jellyfin|Jellyfin|8096" "has jellyfin"
assert_not_contains "$cat_off" "qui|" "omits qui when QBIT_UI=vuetorrent"
assert_not_contains "$cat_off" "sabnzbd|" "omits sabnzbd when USENET_ENABLED=n"
assert_not_contains "$cat_off" "byparr|" "omits byparr when BYPARR_ENABLED=n"
assert_not_contains "$cat_off" "gluetun|" "omits gluetun when VPN_ENABLED=n"

VPN_ENABLED=y USENET_ENABLED=y BYPARR_ENABLED=y QBIT_UI=qui VUETORRENT_ENABLED=n
cat_on=$(list_service_catalog)
assert_contains "$cat_on" "qui|qui (qBit UI)|7476|/|ui" "lists qui UI when QBIT_UI=qui"
assert_contains "$cat_on" "sabnzbd|SABnzbd|8085|/|ui" "lists sabnzbd UI when USENET_ENABLED=y"
assert_contains "$cat_on" "byparr|Byparr (solver)|||internal" "lists byparr when BYPARR_ENABLED=y"
assert_contains "$cat_on" "gluetun|Gluetun (VPN)|||internal" "lists gluetun when VPN_ENABLED=y"

test_suite "qbit_ui_mode & qui payload"
assert_eq "vuetorrent" "$(QBIT_UI='' VUETORRENT_ENABLED=y qbit_ui_mode)" "legacy VUETORRENT_ENABLED=y -> vuetorrent"
assert_eq "qui" "$(QBIT_UI=qui VUETORRENT_ENABLED=y qbit_ui_mode)" "explicit QBIT_UI=qui overrides legacy flag"
assert_eq "stock" "$(QBIT_UI=stock VUETORRENT_ENABLED=y qbit_ui_mode)" "explicit QBIT_UI=stock"
assert_eq "stock" "$(QBIT_UI='' VUETORRENT_ENABLED=n qbit_ui_mode)" "empty QBIT_UI + n -> stock"

qui_json=$(qui_build_instance_payload "http://gluetun:8081" "alice" 'p"q')
assert_eq "http://gluetun:8081" "$(printf '%s' "$qui_json" | jq -r '.host')" "qui payload sets host"
assert_eq "true" "$(printf '%s' "$qui_json" | jq -r '.hasLocalFilesystemAccess')" "qui payload enables local FS"
assert_eq 'p"q' "$(printf '%s' "$qui_json" | jq -r '.password')" "qui payload escapes password"

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

test_suite "configure_qbit_ui defaults & picker selection"
# shellcheck source=/dev/null
source "$REPO_ROOT/lib/prompts.sh"
SETUP_MODE=express QBIT_UI='' VUETORRENT_ENABLED='' configure_qbit_ui
assert_eq "vuetorrent" "${qbit_ui:-}" "express mode defaults qbit_ui=vuetorrent"
assert_eq "y" "${vuetorrent_enabled:-}" "express mode syncs vuetorrent_enabled=y"

# Non-TTY fallback preserves selection cleanly
# shellcheck source=/dev/null
source "$REPO_ROOT/lib/fzf-tui.sh"
SETUP_MODE=manual QBIT_UI='' VUETORRENT_ENABLED='' configure_qbit_ui <<< "qui"
assert_eq "qui" "${qbit_ui:-}" "manual picker selects qui"
assert_eq "n" "${vuetorrent_enabled:-}" "selecting qui clears vuetorrent_enabled"

edit_qbit_out=$(ui_set_mode edit && QBIT_UI=vuetorrent SETUP_MODE=manual configure_qbit_ui <<< "vuetorrent" 2>&1)
assert_contains "$edit_qbit_out" "[active]" "edit mode marks current qBittorrent UI [active]"

test_suite "qui password precedence and <8-char validation"
# shellcheck source=/dev/null
source "$REPO_ROOT/lib/api.sh"
log_step() { :; }
log_step_fail() { echo "fail: $1" >&2; }

mkdir -p "$tmp/secrets"
assert_eq "fallback" "$(INSTALL_DIR="$tmp" QUI_PASSWORD='' AUTH_PASSWORD=fallback _qui_login_password)" "falls back to AUTH_PASSWORD when no qui_password.txt"
printf '%s' 'from-secret-file' > "$tmp/secrets/qui_password.txt"
assert_eq "from-secret-file" "$(INSTALL_DIR="$tmp" QUI_PASSWORD='' AUTH_PASSWORD=fallback _qui_login_password)" "prefers secrets/qui_password.txt over AUTH_PASSWORD"
assert_eq "from-env" "$(INSTALL_DIR="$tmp" QUI_PASSWORD=from-env AUTH_PASSWORD=fallback _qui_login_password)" "prefers QUI_PASSWORD env over secret file"

rm -f "$tmp/secrets/qui_password.txt"
qui_short_out=""
qui_short_rc=0
qui_short_out=$(ASSEMBLRR_NONINTERACTIVE=1 QBIT_UI=qui INSTALL_DIR="$tmp" AUTH_USERNAME=alice AUTH_PASSWORD=short configure_qui 17476 2>&1) || qui_short_rc=$?
assert_eq "1" "$qui_short_rc" "configure_qui rejects <8-char password in non-interactive mode"
assert_contains "$qui_short_out" "at least 8 characters" "failure message explains 8-character minimum"

test_summary
