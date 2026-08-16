#!/bin/bash
# Unit tests for lib/compose.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../helpers.sh"
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
assert_contains "$recyclarr_image" "ghcr.io/recyclarr/recyclarr:8" "pins major tag 8"
assert_not_contains "$recyclarr_image" ":latest" "does not use unpublished :latest"
assert_contains "$(grep CRON "$REPO_ROOT/compose/base.yaml")" "CRON_SCHEDULE" "uses CRON_SCHEDULE"

test_suite "local sidecar images do not pull from a registry"
assert_contains "$(awk '/media-purge-watch:/,/^  [a-z]/{print}' "$REPO_ROOT/compose/base.yaml")" \
    "pull_policy: build" "media-purge-watch builds locally"
assert_contains "$(awk '/vpn-watchdog:/,/^  [a-z]/{print}' "$REPO_ROOT/compose/vpn.yaml")" \
    "pull_policy: build" "vpn-watchdog builds locally"

test_summary
