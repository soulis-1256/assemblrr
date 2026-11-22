#!/bin/bash
# Unit tests for setup.sh restore mode and argument parsing
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../helpers.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/core.sh"
stub_log_error_no_exit

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

test_suite "setup mode menu"
setup_script="$REPO_ROOT/bin/setup.sh"
assert_true "setup menu includes Restore option" "grep -q 'Restore (rebuild stack' \"$setup_script\""
assert_true "setup handles option 3" "grep -q '3) SETUP_MODE=\"restore\"' \"$setup_script\""

test_suite "setup CLI argument parsing"
assert_true "setup parses --restore" "grep -q '\--restore)' \"$setup_script\""
assert_true "setup parses --restore=" "grep -q '\--restore=\*)' \"$setup_script\""
assert_true "setup parses --express" "grep -q '\--express)' \"$setup_script\""
assert_true "setup parses --manual" "grep -q '\--manual)' \"$setup_script\""

test_suite "setup restore wizard logic"
assert_true "setup has restore_from_backup_wizard" "grep -q 'restore_from_backup_wizard()' \"$setup_script\""
assert_true "main calls restore_from_backup_wizard" "grep -q 'restore_from_backup_wizard' \"$setup_script\""

# Test archive extraction & config discovery mock
mock_archive="$tmp/mock-backup.tar.gz"
mock_src="$tmp/mock_src"
mkdir -p "$mock_src/config/jellyfin" "$mock_src/secrets" "$mock_src/compose"
{
    echo "INSTALL_DIRECTORY=\"/opt/test-assemblrr\""
    echo "MEDIA_DIRECTORY=\"/data/test-media\""
    echo "MEDIA_SERVICE=\"jellyfin\""
    echo "VPN_ENABLED=\"n\""
} > "$mock_src/.env"
tar -czf "$mock_archive" -C "$mock_src" .

mock_dest="$tmp/mock_dest"
mkdir -p "$mock_dest"
tar -xzf "$mock_archive" -C "$mock_dest"

assert_true "archive contains .env" "[ -f \"$mock_dest/.env\" ]"
assert_true "archive contains jellyfin config dir" "[ -d \"$mock_dest/config/jellyfin\" ]"

test_suite "write_runtime_config & generate_env_file handle unset tz (issue #4)"
# shellcheck source=/dev/null
source "$REPO_ROOT/bin/setup.sh"
setup_home="$tmp/setup-home"
install_directory="$tmp/setup-install"
media_directory="$tmp/setup-media"
mkdir -p "$setup_home" "$install_directory" "$media_directory"
unset tz setup_vpn vpn_type qbit_ui gpu_transcoding byparr_enabled usenet_enabled QUALITY_TIER QUALITY_SOURCE SEERR_IS_4K || true
setup_vpn="n"
puid=1000
pgid=1000
HOME="$setup_home" write_runtime_config
assert_contains "$(cat "$install_directory/.${APP_NAME}-config")" 'TZ="UTC"' "write_runtime_config defaults unset tz to UTC"
assert_contains "$(cat "$install_directory/.${APP_NAME}-config")" 'VPN_ENABLED="n"' "write_runtime_config records VPN_ENABLED=n"
HOME="$setup_home" generate_env_file
assert_contains "$(cat "$install_directory/.env")" 'TZ=UTC' "generate_env_file defaults unset tz to UTC"

test_summary
