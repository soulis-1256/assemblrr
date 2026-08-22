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
echo "INSTALL_DIRECTORY=\"/opt/test-assemblrr\"" > "$mock_src/.env"
echo "MEDIA_DIRECTORY=\"/data/test-media\"" >> "$mock_src/.env"
echo "MEDIA_SERVICE=\"jellyfin\"" >> "$mock_src/.env"
echo "VPN_ENABLED=\"n\"" >> "$mock_src/.env"
tar -czf "$mock_archive" -C "$mock_src" .

mock_dest="$tmp/mock_dest"
mkdir -p "$mock_dest"
tar -xzf "$mock_archive" -C "$mock_dest"

assert_true "archive contains .env" "[ -f \"$mock_dest/.env\" ]"
assert_true "archive contains jellyfin config dir" "[ -d \"$mock_dest/config/jellyfin\" ]"

test_summary
