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
assert_true "has lib/config_edit.sh" "echo \"\$list\" | grep -q 'lib/config_edit.sh|lib/config_edit.sh'"
assert_true "has lib/quality.sh" "echo \"\$list\" | grep -q 'lib/quality.sh|lib/quality.sh'"
assert_true "has radarr 1080p WEB pack" "echo \"\$list\" | grep -q 'radarr-1080p-web.yml'"
assert_true "has radarr 4K WEB pack" "echo \"\$list\" | grep -q 'radarr-4k-web.yml'"
assert_true "has lib/ui.sh" "echo \"\$list\" | grep -q 'lib/ui.sh|lib/ui.sh'"
assert_true "has compose/base.yaml" "echo \"\$list\" | grep -q 'compose/base.yaml|compose/base.yaml'"
assert_true "has vpn-watchdog Dockerfile" "echo \"\$list\" | grep -q 'compose/sidecars/vpn-watchdog.Dockerfile'"
assert_true "has media-purge-watch Dockerfile" "echo \"\$list\" | grep -q 'compose/sidecars/media-purge-watch.Dockerfile'"
assert_true "cli maps bin/cli.sh to cli.sh" "echo \"\$list\" | grep -q 'bin/cli.sh|cli.sh'"

test_suite "_bazarr_lang_code2 maps eng and 2-letter"
assert_eq "en" "$(_bazarr_lang_code2 eng)" "eng → en"
assert_eq "en" "$(_bazarr_lang_code2 en)" "en → en"
assert_eq "el" "$(_bazarr_lang_code2 gre)" "gre → el"
assert_eq "en" "$(_bazarr_lang_code2 '')" "empty → en"

test_suite "migration 001 skip when custom.yaml has bazarr"
tmp="" tmp2=""
tmp=$(mktemp -d)
trap 'rm -rf "${tmp:-}" "${tmp2:-}"' EXIT
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
assert_true "portainer not in catalog" "! echo \"$cat\" | grep -q '^portainer|'"
url=$(service_ui_url 6767 / localhost)
assert_eq "http://localhost:6767/" "$url" "bazarr url"

test_suite "service_row_ready uses Docker health"
assert_true "healthy is ready" "service_row_ready running healthy"
assert_false "starting is not ready" "service_row_ready running starting"
assert_false "unhealthy is not ready" "service_row_ready running unhealthy"
assert_true "no healthcheck + running is ready" "service_row_ready running ''"
assert_false "exited is not ready" "service_row_ready exited ''"
assert_false "created is not ready" "service_row_ready created ''"

test_suite "migration 002 skips when custom.yaml keeps portainer"
tmp3=$(mktemp -d)
mkdir -p "$tmp3/compose"
cat >"$tmp3/compose/custom.yaml" <<'EOF'
services:
  portainer:
    image: portainer/portainer-ce
EOF
unset -f migration_should_skip migration_apply 2>/dev/null || true
# shellcheck source=/dev/null
source "$REPO_ROOT/migrations/002_remove_portainer.sh"
if migration_should_skip "$tmp3"; then
    _TEST_PASSES=$((_TEST_PASSES + 1))
    echo "  PASS: skips when custom.yaml defines portainer"
else
    _TEST_FAILURES=$((_TEST_FAILURES + 1))
    echo "  FAIL: expected skip for custom.yaml portainer"
fi

test_suite "migration 003 cleans up legacy recyclarr include files"
tmp4=$(mktemp -d)
mkdir -p "$tmp4/templates/recyclarr/includes" "$tmp4/config/recyclarr/includes"
touch "$tmp4/templates/recyclarr/includes/radarr-hd.yml" "$tmp4/config/recyclarr/includes/sonarr-web-2160.yml"
unset -f migration_should_skip migration_apply 2>/dev/null || true
# shellcheck source=/dev/null
source "$REPO_ROOT/migrations/003_standardize_quality_profiles.sh"
if migration_should_skip "$tmp4"; then
    _TEST_FAILURES=$((_TEST_FAILURES + 1))
    echo "  FAIL: should not skip when legacy files present"
else
    _TEST_PASSES=$((_TEST_PASSES + 1))
    echo "  PASS: detects legacy recyclarr include files"
fi
migration_apply "$tmp4"
assert_true "removes legacy template include" "[ ! -f '$tmp4/templates/recyclarr/includes/radarr-hd.yml' ]"
assert_true "removes legacy config include" "[ ! -f '$tmp4/config/recyclarr/includes/sonarr-web-2160.yml' ]"
if migration_should_skip "$tmp4"; then
    _TEST_PASSES=$((_TEST_PASSES + 1))
    echo "  PASS: skips after cleanup"
else
    _TEST_FAILURES=$((_TEST_FAILURES + 1))
    echo "  FAIL: should skip after files removed"
fi
rm -rf "$tmp3"

test_suite "upgrade uses --build --remove-orphans and non-interactive wiring"
assert_true "upgrade rebuilds via compose_up_stack --build" \
    "grep -q 'compose_up_stack .* --build' \"$REPO_ROOT/lib/upgrade.sh\""
assert_true "compose_up_stack passes --remove-orphans" \
    "grep -q 'up -d --remove-orphans' \"$REPO_ROOT/lib/compose.sh\""
assert_true "upgrade wires with ASSEMBLRR_NONINTERACTIVE" "grep -q 'ASSEMBLRR_NONINTERACTIVE=1' \"$REPO_ROOT/lib/upgrade.sh\""
assert_true "upgrade accepts --skip-stack" "grep -q -- '--skip-stack' \"$REPO_ROOT/lib/upgrade.sh\""
assert_true "upgrade accepts --skip-wire" "grep -q -- '--skip-wire' \"$REPO_ROOT/lib/upgrade.sh\""
refresh=$(sed -n '/^refresh_user_cli()/,/^}/p' "$REPO_ROOT/lib/upgrade.sh")
assert_contains "$refresh" "install_user_cli_wrapper" "refresh writes PATH wrapper"
assert_not_contains "$refresh" "list_cli_lib_modules" "refresh does not copy PATH libs"

test_suite "arr-purge-hook reads in-container API key and media root"
hook=$(cat "$REPO_ROOT/scripts/arr-purge-hook.sh")
assert_contains "$hook" "/config/config.xml" "hook reads /config/config.xml"
assert_contains "$hook" "MEDIA_ROOT=" "hook sets MEDIA_ROOT"
assert_contains "$hook" "SONARR_API_KEY" "hook exports Sonarr key"

test_suite "Windows bootstrap strips CRLF on new file types"
win=$(cat "$REPO_ROOT/platform/windows/bootstrap.ps1")
dev=$(cat "$REPO_ROOT/platform/windows/bootstrap-dev.ps1")
assert_contains "$win" "find /tmp/\$AppName -type f" "bootstrap.ps1 uses find for CRLF strip"
assert_contains "$win" "-name '*.py'" "bootstrap.ps1 strips Python"
assert_contains "$win" "-name '*.Dockerfile'" "bootstrap.ps1 strips sidecar Dockerfiles"
assert_contains "$dev" "find /tmp/\$AppName -type f" "bootstrap-dev.ps1 uses find for CRLF strip"
assert_contains "$dev" "-name '*.py'" "bootstrap-dev.ps1 strips Python"
assert_contains "$dev" "-name '*.Dockerfile'" "bootstrap-dev.ps1 strips sidecar Dockerfiles"
assert_not_contains "$win" "sed -i 's/\\r\$//' /tmp/\$AppName/.env.example /tmp/\$AppName/bin/*.sh" \
    "bootstrap.ps1 no longer uses the stale glob list"

test_summary
