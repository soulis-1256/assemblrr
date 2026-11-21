#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Validate all compose files and feature overlays resolve with docker compose config
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../helpers.sh"

if ! command -v docker >/dev/null 2>&1; then
    echo "SKIP: docker not available"
    exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
make_compose_fixture "$tmp"

set -a
# shellcheck disable=SC1091
source "$tmp/.env"
set +a

run_config() {
    local label="$1"
    shift
    echo "  checking: $label"
    if docker compose --project-directory "$tmp" "$@" config --quiet 2>"$tmp/compose-err.txt"; then
        _TEST_PASSES=$((_TEST_PASSES + 1))
        echo "  PASS: $label"
        return 0
    fi
    _TEST_FAILURES=$((_TEST_FAILURES + 1))
    echo "  FAIL: $label"
    sed 's/^/        /' "$tmp/compose-err.txt" || true
    return 0
}

test_suite "docker compose config (default & overlays)"
run_config "base + direct-access" \
    -f "$tmp/compose/base.yaml" \
    -f "$tmp/compose/direct-access.yaml"

run_config "base + direct-access (--profile jellyfin back-compat)" \
    -f "$tmp/compose/base.yaml" \
    -f "$tmp/compose/direct-access.yaml" \
    --profile jellyfin

run_config "base + vpn" \
    -f "$tmp/compose/base.yaml" \
    -f "$tmp/compose/vpn.yaml"

run_config "base + vpn + vuetorrent + gpu-intel + byparr + usenet" \
    -f "$tmp/compose/base.yaml" \
    -f "$tmp/compose/vpn.yaml" \
    -f "$tmp/compose/vuetorrent.yaml" \
    -f "$tmp/compose/gpu-intel.yaml" \
    -f "$tmp/compose/byparr.yaml" \
    -f "$tmp/compose/usenet.yaml"

run_config "base + direct-access + gpu-nvidia + usenet" \
    -f "$tmp/compose/base.yaml" \
    -f "$tmp/compose/direct-access.yaml" \
    -f "$tmp/compose/gpu-nvidia.yaml" \
    -f "$tmp/compose/usenet.yaml"

# Verify a real service in custom overlay with .30+ IP validates cleanly
cat >"$tmp/compose/custom.yaml" <<'EOF'
services:
  lidarr:
    image: lscr.io/linuxserver/lidarr:3.1.0
    container_name: lidarr
    networks:
      assemblrr_network:
        ipv4_address: 172.60.0.32
EOF
run_config "base + direct-access + custom overlay (.32 IP)" \
    -f "$tmp/compose/base.yaml" \
    -f "$tmp/compose/direct-access.yaml" \
    -f "$tmp/compose/custom.yaml"

test_summary
