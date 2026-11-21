#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Unit tests for lib/compose.sh and Compose image pinning
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../helpers.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/core.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/compose.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/compose"
touch "$tmp/compose/base.yaml" "$tmp/compose/vpn.yaml" "$tmp/compose/direct-access.yaml" \
      "$tmp/compose/vuetorrent.yaml" "$tmp/compose/qui.yaml" "$tmp/compose/gpu-intel.yaml" "$tmp/compose/gpu-nvidia.yaml" \
      "$tmp/compose/byparr.yaml" "$tmp/compose/usenet.yaml"

QBIT_UI='' VUETORRENT_ENABLED=n GPU_TRANSCODING=none BYPARR_ENABLED=n USENET_ENABLED=n

test_suite "build_compose_args (VPN enabled)"
build_compose_args "$tmp" "y"
joined="${COMPOSE_ARGS[*]}"
assert_contains "$joined" "--project-directory $tmp" "sets project directory"
assert_contains "$joined" "-f $tmp/compose/base.yaml" "includes base.yaml"
assert_contains "$joined" "-f $tmp/compose/vpn.yaml" "includes vpn.yaml when VPN=y"
assert_not_contains "$joined" "direct-access.yaml" "excludes direct-access when VPN=y"

test_suite "build_compose_args (VPN disabled)"
build_compose_args "$tmp" "n"
joined="${COMPOSE_ARGS[*]}"
assert_contains "$joined" "-f $tmp/compose/direct-access.yaml" "includes direct-access when VPN=n"
assert_not_contains "$joined" "vpn.yaml" "excludes vpn when VPN=n"

test_suite "build_compose_args (feature overlays & custom order)"
VUETORRENT_ENABLED=y GPU_TRANSCODING=intel BYPARR_ENABLED=y USENET_ENABLED=y
touch "$tmp/compose/custom.yaml"
build_compose_args "$tmp" "y"
joined="${COMPOSE_ARGS[*]}"
assert_contains "$joined" "-f $tmp/compose/vuetorrent.yaml" "includes vuetorrent.yaml"
assert_contains "$joined" "-f $tmp/compose/gpu-intel.yaml" "includes gpu-intel.yaml"
assert_not_contains "$joined" "gpu-nvidia.yaml" "excludes gpu-nvidia when intel selected"
assert_contains "$joined" "-f $tmp/compose/byparr.yaml" "includes byparr.yaml"
assert_contains "$joined" "-f $tmp/compose/usenet.yaml" "includes usenet.yaml"
assert_contains "$joined" "usenet.yaml -f $tmp/compose/custom.yaml" "custom.yaml appended last"

GPU_TRANSCODING=nvidia
build_compose_args "$tmp" "n"
assert_contains "${COMPOSE_ARGS[*]}" "-f $tmp/compose/gpu-nvidia.yaml" "includes gpu-nvidia.yaml"

QBIT_UI=qui VUETORRENT_ENABLED=n GPU_TRANSCODING=none BYPARR_ENABLED=n USENET_ENABLED=n
build_compose_args "$tmp" "y"
assert_contains "${COMPOSE_ARGS[*]}" "-f $tmp/compose/qui.yaml" "includes qui.yaml when QBIT_UI=qui"
assert_not_contains "${COMPOSE_ARGS[*]}" "vuetorrent.yaml" "excludes vuetorrent.yaml when QBIT_UI=qui"

QBIT_UI='' VUETORRENT_ENABLED=n GPU_TRANSCODING=none BYPARR_ENABLED=n USENET_ENABLED=n
rm -f "$tmp/compose/custom.yaml"

test_suite "build_compose_args (case-insensitive VPN flag)"
build_compose_args "$tmp" "Y"
assert_contains "${COMPOSE_ARGS[*]}" "vpn.yaml" "VPN=Y treated as enabled"

test_suite "recyclarr image tag"
recyclarr_image=$(grep -E '^\s+image:.*recyclarr' "$REPO_ROOT/compose/base.yaml")
assert_contains "$recyclarr_image" "ghcr.io/recyclarr/recyclarr:8.8.1" "pins recyclarr 8.8.1"
assert_not_contains "$recyclarr_image" ":latest" "does not use unpublished :latest"
assert_contains "$(grep CRON "$REPO_ROOT/compose/base.yaml")" "CRON_SCHEDULE" "uses CRON_SCHEDULE"

test_suite "default & feature stack images are pinned (no :latest)"
images=$(grep -E '^\s+image:' \
    "$REPO_ROOT/compose/base.yaml" \
    "$REPO_ROOT/compose/vpn.yaml" \
    "$REPO_ROOT/compose/byparr.yaml" \
    "$REPO_ROOT/compose/usenet.yaml" \
    "$REPO_ROOT/compose/qui.yaml")
assert_not_contains "$images" ":latest" "no :latest in any compose file"
assert_contains "$images" "linuxserver/jellyfin:12.4ubu2604-ls60" "jellyfin 12.4 pinned"
assert_contains "$images" "linuxserver/qbittorrent:5.3.0" "qbittorrent 5.3.0 pinned"
assert_contains "$images" "linuxserver/sonarr:4.0.20.3014-ls6" "sonarr pinned"
assert_contains "$images" "linuxserver/radarr:7.0.3.10918-ls328" "radarr pinned"
assert_contains "$images" "linuxserver/prowlarr:3.0.2.5780-ls169" "prowlarr pinned"
assert_contains "$images" "linuxserver/bazarr:1.6.2" "bazarr 1.6.2 pinned"
assert_contains "$images" "linuxserver/sabnzbd:5.1.3" "sabnzbd 5.1.3 pinned"
assert_contains "$images" "autobrr/qui:v1.36.0" "qui v1.36.0 pinned"
assert_contains "$images" "seerr-team/seerr:v3.5.2" "seerr v3.5.2 pinned"
assert_contains "$images" "python:3.12.16-alpine" "gateway python pinned"
assert_contains "$images" "gluetun:v3.41.3" "gluetun v3.41.3 pinned"
assert_contains "$images" "deunhealth@sha256:db1e4fcd3aceeb0da34a83f7a8a5432df586e6d0388ddb6ad8dd7b479e4aa25d" "deunhealth digest pinned"
assert_contains "$images" "thephaseless/byparr:3.1.1" "byparr 3.1.1 pinned"
assert_contains "$(cat "$REPO_ROOT/compose/vuetorrent.yaml")" "vuetorrent/vuetorrent-lsio-mod:2.37.0" "vuetorrent mod pinned"
assert_contains "$images" "assemblrr/media-purge-watch:local" "purge sidecar is local"
assert_contains "$images" "assemblrr/vpn-watchdog:local" "watchdog sidecar is local"

test_suite "sidecar Dockerfiles pin alpine:3.24.4"
assert_contains "$(cat "$REPO_ROOT/compose/sidecars/media-purge-watch.Dockerfile")" "FROM alpine:3.24.4" "purge-watch alpine pinned"
assert_contains "$(cat "$REPO_ROOT/compose/sidecars/vpn-watchdog.Dockerfile")" "FROM alpine:3.24.4" "vpn-watchdog alpine pinned"

test_suite "jellyfin is default without --profile gate & no broken plex/emby in base.yaml"
assert_not_contains "$(cat "$REPO_ROOT/compose/base.yaml")" 'profiles: ["jellyfin"]' "no jellyfin profile gate"
assert_not_contains "$(cat "$REPO_ROOT/compose/base.yaml")" 'container_name: emby' "emby removed from base.yaml"
assert_not_contains "$(cat "$REPO_ROOT/compose/base.yaml")" 'container_name: plex' "plex removed from base.yaml"

test_suite "local sidecar images do not pull from a registry"
assert_contains "$(awk '/media-purge-watch:/,/^  [a-z]/{print}' "$REPO_ROOT/compose/base.yaml")" \
    "pull_policy: build" "media-purge-watch builds locally"
assert_contains "$(awk '/vpn-watchdog:/,/^  [a-z]/{print}' "$REPO_ROOT/compose/vpn.yaml")" \
    "pull_policy: build" "vpn-watchdog builds locally"

test_suite "compose_up_stack hides build output"
up=$(sed -n '/^compose_up_stack()/,/^}/p' "$REPO_ROOT/lib/compose.sh")
assert_contains "$up" "wait_while" "captures compose up behind a spinner"
assert_contains "$up" "Starting services" "friendly wait label"
assert_contains "$up" "tail -n 40" "prints a log tail on failure"
assert_true "setup uses compose_up_stack" "grep -q 'compose_up_stack' \"$REPO_ROOT/bin/setup.sh\""
assert_true "upgrade uses compose_up_stack" "grep -q 'compose_up_stack' \"$REPO_ROOT/lib/upgrade.sh\""
assert_true "cli uses compose_up_stack" "grep -q 'compose_up_stack' \"$REPO_ROOT/bin/cli.sh\""
assert_not_contains "$(sed -n '/compose_up_stack/,/exit 1/p' "$REPO_ROOT/bin/setup.sh")" \
    "run_docker compose" "setup no longer streams compose up"

test_suite "healthcheck fast-start intervals"
assert_contains "$(grep start_interval "$REPO_ROOT/compose/base.yaml")" "start_interval: 2s" "base.yaml has fast healthcheck start_interval"
assert_contains "$(grep start_interval "$REPO_ROOT/compose/vpn.yaml")" "start_interval: 2s" "vpn.yaml has fast healthcheck start_interval"

test_summary
