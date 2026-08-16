#!/bin/bash
# qB session prefs JSON (VPN tun0 bind)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../helpers.sh"

# arr.sh requires helpers used only in other functions; stub logging.
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/core.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/arr.sh"

test_suite "qbit_core_prefs_json VPN on binds tun0"
VPN_ENABLED=y
json=$(qbit_core_prefs_json)
assert_contains "$json" '"current_network_interface":"tun0"' "VPN=y sets tun0"
assert_contains "$json" '"save_path":"/data/torrents"' "save path always set"
assert_contains "$json" '"temp_path_enabled":true' "incomplete path on"
assert_contains "$json" '"auto_tmm_enabled":true' "ATM on so category paths are used"

test_suite "qbit_core_prefs_json VPN off clears interface"
VPN_ENABLED=n
json=$(qbit_core_prefs_json)
assert_contains "$json" '"current_network_interface":""' "VPN=n clears leftover tun0"
assert_contains "$json" '"save_path":"/data/torrents"' "save path still set"
assert_contains "$json" '"auto_tmm_enabled":true' "ATM still on without VPN"

test_suite "qbit_core_prefs_json extras merge"
VPN_ENABLED=y
json=$(qbit_core_prefs_json "x" 'p&q"r')
assert_contains "$json" '"current_network_interface":"tun0"' "tun0 kept with extras"
assert_contains "$json" '"web_ui_username":"x"' "username field set"
assert_contains "$json" '"web_ui_password":"p&q\"r"' "password JSON-escaped"

test_suite "qbit login form encodes reserved characters"
src=$(sed -n '/^qbit_login_form()/,/^}/p' "$REPO_ROOT/lib/arr.sh")
assert_contains "$src" "--data-urlencode" "qbit_login_form url-encodes fields"
assert_not_contains "$src" '-d "username=' "qbit_login_form does not raw-concat form body"

src=$(sed -n '/^qbit_apply_prefs()/,/^}/p' "$REPO_ROOT/lib/arr.sh")
assert_contains "$src" "--data-urlencode" "setPreferences url-encodes json="
assert_contains "$src" "qbit_core_prefs_json" "prefs built via jq helper"

test_suite "qbit_vpn_enabled"
VPN_ENABLED=y
assert_true "y is enabled" "qbit_vpn_enabled"
VPN_ENABLED=Y
assert_true "Y is enabled" "qbit_vpn_enabled"
VPN_ENABLED=n
assert_false "n is disabled" "qbit_vpn_enabled"

test_summary
