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

test_suite "setup.sh --express with VPN=n and unset USER completes setup steps under set -u"
e2e_home="$tmp/e2e-home"
e2e_bin="$tmp/e2e-bin"
mkdir -p "$e2e_home" "$e2e_bin"
cat > "$e2e_bin/docker" <<'EOF'
#!/bin/sh
if [ "$1" = "compose" ]; then
    case " $* " in
        *" up "*) echo "mock-compose-up-stop"; exit 1 ;;
    esac
fi
exit 0
EOF
cat > "$e2e_bin/curl" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then
    echo "curl 8.0.0"
    exit 0
fi
exit 1
EOF
cat > "$e2e_bin/fzf" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then
    echo "0.42.0"
    exit 0
fi
exit 1
EOF
chmod +x "$e2e_bin/docker" "$e2e_bin/curl" "$e2e_bin/fzf"

e2e_rc=0
e2e_out=$(
    env -u USER HOME="$e2e_home" PATH="$e2e_bin:$PATH" \
        bash "$REPO_ROOT/bin/setup.sh" --express <<'INPUTS' 2>&1
n
1
1
2

n

testpass123
testpass123
INPUTS
) || e2e_rc=$?
assert_eq "1" "$e2e_rc" "reaches mock compose_up_stack cleanly"
assert_not_contains "$e2e_out" "unbound variable" "no unbound variable errors anywhere in express setup"
assert_contains "$e2e_out" "Installation Summary" "prints full installation summary"
assert_contains "$e2e_out" "Install files ready" "completes config and secret generation"
assert_true "generated .assemblrr-config" "[ -f \"$e2e_home/assemblrr/.assemblrr-config\" ]"
assert_true "generated .env" "[ -f \"$e2e_home/assemblrr/.env\" ]"
assert_contains "$(cat "$e2e_home/assemblrr/.assemblrr-config")" 'VPN_ENABLED="n"' "persists VPN_ENABLED=n"
assert_contains "$(cat "$e2e_home/assemblrr/.env")" 'TZ=' "persists TZ in .env"

test_summary
