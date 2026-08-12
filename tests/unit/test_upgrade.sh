#!/bin/bash
# Unit tests for upgrade helpers + service catalog (no live stack)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../helpers.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/core.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/managed_files.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/bazarr.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/services.sh"

test_suite "list_managed_files includes Bazarr and upgrade engine"
list=$(list_managed_files)
assert_true "has lib/bazarr.sh" "echo \"\$list\" | grep -q 'lib/bazarr.sh|lib/bazarr.sh'"
assert_true "has lib/upgrade.sh" "echo \"\$list\" | grep -q 'lib/upgrade.sh|lib/upgrade.sh'"
assert_true "has lib/services.sh" "echo \"\$list\" | grep -q 'lib/services.sh|lib/services.sh'"
assert_true "has compose/base.yaml" "echo \"\$list\" | grep -q 'compose/base.yaml|compose/base.yaml'"
assert_true "cli maps bin/cli.sh to cli.sh" "echo \"\$list\" | grep -q 'bin/cli.sh|cli.sh'"

test_suite "_bazarr_lang_code2 maps eng and 2-letter"
assert_eq "en" "$(_bazarr_lang_code2 eng)" "eng → en"
assert_eq "en" "$(_bazarr_lang_code2 en)" "en → en"
assert_eq "el" "$(_bazarr_lang_code2 gre)" "gre → el"
assert_eq "en" "$(_bazarr_lang_code2 '')" "empty → en"

test_suite "migration 001 skip when custom.yaml has bazarr"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp" "$tmp2"' EXIT
mkdir -p "$tmp/compose"
cat >"$tmp/compose/custom.yaml" <<'EOF'
services:
  bazarr:
    image: lscr.io/linuxserver/bazarr
EOF
# shellcheck source=/dev/null
source "$REPO_ROOT/migrations/001_add_bazarr.sh"
if migration_should_skip "$tmp"; then
    _TEST_PASSES=$((_TEST_PASSES + 1))
    echo "  PASS: skips when custom.yaml defines bazarr"
else
    _TEST_FAILURES=$((_TEST_FAILURES + 1))
    echo "  FAIL: expected skip for custom.yaml bazarr"
fi

test_suite "migration 001 does not skip empty install"
tmp2=$(mktemp -d)
mkdir -p "$tmp2/compose"
echo "services: {}" >"$tmp2/compose/base.yaml"
unset -f migration_should_skip migration_apply 2>/dev/null || true
# shellcheck source=/dev/null
source "$REPO_ROOT/migrations/001_add_bazarr.sh"
if migration_should_skip "$tmp2"; then
    _TEST_FAILURES=$((_TEST_FAILURES + 1))
    echo "  FAIL: should not skip empty install"
else
    _TEST_PASSES=$((_TEST_PASSES + 1))
    echo "  PASS: empty install is not skipped"
fi

test_suite "service catalog has UI URLs for core apps"
MEDIA_SERVICE=jellyfin
VPN_ENABLED=y
cat=$(list_service_catalog)
assert_contains "$cat" "bazarr|Bazarr|6767" "bazarr in catalog"
assert_contains "$cat" "jellyfin|Jellyfin|8096" "jellyfin in catalog"
assert_contains "$cat" "seerr-gateway|Seerr|5055" "Seerr UI via seerr-gateway"
assert_contains "$cat" "gluetun|" "gluetun when VPN on"
url=$(service_ui_url 6767 / localhost)
assert_eq "http://localhost:6767/" "$url" "bazarr url"

test_summary
