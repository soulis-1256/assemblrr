#!/bin/bash
# Validate compose files resolve with docker compose config
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
    if docker compose --project-directory "$tmp" "$@" --profile jellyfin config --quiet 2>"$tmp/compose-err.txt"; then
        _TEST_PASSES=$((_TEST_PASSES + 1))
        echo "  PASS: $label"
        return 0
    fi
    _TEST_FAILURES=$((_TEST_FAILURES + 1))
    echo "  FAIL: $label"
    sed 's/^/        /' "$tmp/compose-err.txt" || true
    return 0
}

test_suite "docker compose config"
run_config "base + direct-access" \
    -f "$tmp/compose/base.yaml" \
    -f "$tmp/compose/direct-access.yaml"

run_config "base + vpn" \
    -f "$tmp/compose/base.yaml" \
    -f "$tmp/compose/vpn.yaml"

# example custom.yaml has only commented services; use a valid empty overlay
cat >"$tmp/compose/custom.yaml" <<'EOF'
services: {}
EOF
run_config "base + direct-access + custom overlay" \
    -f "$tmp/compose/base.yaml" \
    -f "$tmp/compose/direct-access.yaml" \
    -f "$tmp/compose/custom.yaml"

test_summary
