#!/bin/bash
# Unit tests for scripts/seerr-gateway.py (offline mock Seerr via --self-test)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../helpers.sh"

test_suite "seerr-gateway self-test"

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: python3 not available"
    exit 0
fi

gw="$REPO_ROOT/scripts/seerr-gateway.py"
assert_true "gateway script exists" "[ -f \"$gw\" ]"

if python3 "$gw" --self-test; then
    _TEST_PASSES=$((_TEST_PASSES + 1))
    echo "  PASS: seerr-gateway --self-test"
else
    _TEST_FAILURES=$((_TEST_FAILURES + 1))
    echo "  FAIL: seerr-gateway --self-test"
fi

# Compose wiring: seerr-gateway publishes 5055; seerr does not bind host 5055
test_suite "compose seerr-gateway wiring"
base="$REPO_ROOT/compose/base.yaml"
assert_contains "$(grep -A2 'container_name: seerr-gateway' "$base" || true)" "seerr-gateway" "gateway service present"
# Host publish 5055 should appear under seerr-gateway, not as seerr's ports block alone
seerr_block=$(awk '/^  seerr:/{p=1} p&&/^  [a-z]/{if(!/^  seerr:/)exit} p' "$base")
assert_not_contains "$seerr_block" "5055:5055" "seerr service does not publish host 5055"
gw_block=$(awk '/^  seerr-gateway:/{p=1} p&&/^  [a-z]/{if(!/^  seerr-gateway:/)exit} p' "$base")
assert_contains "$gw_block" "5055:5055" "seerr-gateway publishes 5055"
assert_contains "$gw_block" "SEERR_DELETE_REQUEST_PURGE" "purge flag wired in compose"

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
