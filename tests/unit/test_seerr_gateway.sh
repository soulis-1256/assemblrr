#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Unit tests for scripts/seerr-gateway.py (offline mock Seerr via unittest suite)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../helpers.sh"

test_suite "seerr-gateway unittest suite"

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: python3 not available"
    exit 0
fi

gw="$REPO_ROOT/scripts/seerr-gateway.py"
suite="$REPO_ROOT/tests/unit/test_seerr_gateway_suite.py"
assert_true "gateway script exists" "[ -f \"$gw\" ]"
assert_true "gateway unittest suite exists" "[ -f \"$suite\" ]"

if python3 "$suite"; then
    _TEST_PASSES=$((_TEST_PASSES + 1))
    echo "  PASS: seerr-gateway unittest suite"
else
    _TEST_FAILURES=$((_TEST_FAILURES + 1))
    echo "  FAIL: seerr-gateway unittest suite"
fi

# Compose wiring: seerr-gateway publishes 5055; seerr does not bind host 5055
test_suite "compose seerr-gateway wiring"
base="$REPO_ROOT/compose/base.yaml"
assert_contains "$(grep -A2 'container_name: seerr-gateway' "$base" || true)" "seerr-gateway" "gateway service present"
seerr_block=$(awk '/^  seerr:/{p=1} p&&/^  [a-z]/{if(!/^  seerr:/)exit} p' "$base")
assert_not_contains "$seerr_block" "5055:5055" "seerr service does not publish host 5055"
gw_block=$(awk '/^  seerr-gateway:/{p=1} p&&/^  [a-z]/{if(!/^  seerr-gateway:/)exit} p' "$base")
assert_contains "$gw_block" "5055:5055" "seerr-gateway publishes 5055"
assert_contains "$gw_block" "SEERR_DELETE_REQUEST_PURGE" "purge flag wired in compose"
assert_contains "$gw_block" "SONARR_URL" "gateway has Sonarr URL for TV season purge"
assert_contains "$gw_block" "RADARR_URL" "gateway has Radarr URL for movie queue drain"
assert_contains "$gw_block" "config/sonarr:/config/sonarr" "gateway mounts Sonarr config dir"
assert_contains "$gw_block" "config/radarr:/config/radarr" "gateway mounts Radarr config dir"
assert_not_contains "$gw_block" "config.xml:/config/sonarr/config.xml" "gateway does not file-mount config.xml"

# Catalog: Seerr UI is the gateway
test_suite "service catalog points Seerr UI at gateway"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/services.sh"
cat=$(list_service_catalog)
assert_contains "$cat" "seerr-gateway|Seerr|5055" "catalog UI is seerr-gateway:5055"
assert_contains "$cat" "seerr|Seerr (internal)" "seerr listed internal"

# Managed files include gateway + docs
test_suite "managed files include seerr-gateway"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/managed_files.sh"
mf=$(list_managed_files)
assert_contains "$mf" "scripts/seerr-gateway.py|scripts/seerr-gateway.py" "gateway script managed"
assert_contains "$mf" "docs/seerr-delete-request.md|docs/seerr-delete-request.md" "docs managed"

test_summary
