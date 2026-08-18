#!/bin/bash
# Unit tests for lib/compose.sh
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
touch "$tmp/compose/base.yaml" "$tmp/compose/vpn.yaml" "$tmp/compose/direct-access.yaml"

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

test_suite "build_compose_args (custom overlay)"
touch "$tmp/compose/custom.yaml"
build_compose_args "$tmp" "n"
joined="${COMPOSE_ARGS[*]}"
assert_contains "$joined" "-f $tmp/compose/custom.yaml" "includes custom.yaml when present"

test_suite "build_compose_args (case-insensitive VPN flag)"
rm -f "$tmp/compose/custom.yaml"
build_compose_args "$tmp" "Y"
joined="${COMPOSE_ARGS[*]}"
assert_contains "$joined" "vpn.yaml" "VPN=Y treated as enabled"

test_suite "recyclarr image tag"
recyclarr_image=$(grep -E '^\s+image:.*recyclarr' "$REPO_ROOT/compose/base.yaml")
assert_contains "$recyclarr_image" "ghcr.io/recyclarr/recyclarr:8.7.1" "pins recyclarr 8.7.1"
assert_not_contains "$recyclarr_image" ":latest" "does not use unpublished :latest"
assert_contains "$(grep CRON "$REPO_ROOT/compose/base.yaml")" "CRON_SCHEDULE" "uses CRON_SCHEDULE"

test_suite "default stack images are version-pinned"
images=$(grep -E '^\s+image:' "$REPO_ROOT/compose/base.yaml" "$REPO_ROOT/compose/vpn.yaml")
assert_not_contains "$images" ":latest" "no :latest in default compose"
assert_contains "$images" "linuxserver/jellyfin:10.11.11" "jellyfin pinned"
assert_contains "$images" "linuxserver/qbittorrent:5.2.3" "qbittorrent pinned"
assert_contains "$images" "seerr-team/seerr:v3.4.1" "seerr pinned"
assert_contains "$images" "python:3.12.14-alpine" "gateway python pinned"
assert_contains "$images" "gluetun:v3.41.3" "gluetun pinned"
assert_contains "$images" "deunhealth:v0.3.0" "deunhealth pinned"
# Local sidecar tags are not registry floats
assert_contains "$images" "assemblrr/media-purge-watch:local" "purge sidecar is local"
assert_contains "$images" "assemblrr/vpn-watchdog:local" "watchdog sidecar is local"

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
assert_not_contains "$(sed -n '/compose_up_stack/,/exit 1/p' "$REPO_ROOT/bin/setup.sh")" \
    "run_docker compose" "setup no longer streams compose up"

test_summary
