#!/bin/bash
# Unit tests for modular config edit (no live stack required)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../helpers.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/core.sh"
stub_log_error_no_exit
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/config_edit.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

test_suite "config_edit_section_ids"
ids=$(config_edit_section_ids)
assert_contains "$ids" "indexers" "lists indexers"
assert_contains "$ids" "providers" "lists providers"
assert_contains "$ids" "profile" "lists profile"
assert_contains "$ids" "vpn" "lists vpn"
assert_contains "$ids" "all" "lists all (full wizard)"

test_suite "config_edit_resolve"
assert_eq "indexers" "$(config_edit_resolve indexers)" "resolves indexers"
assert_eq "all" "$(config_edit_resolve ALL)" "case-insensitive"
assert_failure "unknown section" config_edit_resolve not-a-section
assert_failure "old CLI alias is not a shortcut" config_edit_resolve subtitles

test_suite "config_set_kv"
cfg="$tmp/.assemblrr-config"
cat >"$cfg" <<'EOF'
INSTALL_DIRECTORY="/old"
TZ="UTC"
EOF
config_set_kv "$cfg" "TZ" "Europe/Athens"
config_set_kv "$cfg" "SEERR_IS_4K" "false"
assert_contains "$(cat "$cfg")" 'TZ="Europe/Athens"' "updates existing quoted key"
assert_contains "$(cat "$cfg")" 'SEERR_IS_4K="false"' "appends new quoted key"
assert_contains "$(cat "$cfg")" 'INSTALL_DIRECTORY="/old"' "leaves other keys"
# duplicate TZ lines should not remain
tz_count=$(grep -c '^TZ=' "$cfg" || true)
assert_eq "1" "$tz_count" "only one TZ= line after update"

envf="$tmp/.env"
cat >"$envf" <<'EOF'
TZ=UTC
VPN_ENABLED=n
EOF
config_set_kv "$envf" "TZ" "Europe/Athens" 0
config_set_kv "$envf" "VPN_ENABLED" "y" 0
assert_contains "$(cat "$envf")" "TZ=Europe/Athens" "updates unquoted .env key"
assert_contains "$(cat "$envf")" "VPN_ENABLED=y" "updates VPN_ENABLED"
env_tz=$(grep -c '^TZ=' "$envf" || true)
assert_eq "1" "$env_tz" "only one TZ= line in .env"

test_suite "config_edit_usage"
usage=$(config_edit_usage)
assert_contains "$usage" "config edit" "usage is just config edit"
assert_not_contains "$usage" "config edit indexers" "no per-section CLI"
assert_contains "$usage" "In the picker:" "usage lists picker entries"

test_suite "auth section is every UI"
auth_line=$(_config_edit_catalog | grep '^auth|' || true)
assert_contains "$auth_line" "every service UI" "auth catalog says every UI"
profile_line=$(_config_edit_catalog | grep '^profile|' || true)
assert_contains "$profile_line" "Radarr" "profile catalog mentions Radarr"

test_suite "vpn edit chmods only vpn secret files"
vpn_fn=$(sed -n '/^_config_edit_vpn()/,/^}/p' "$REPO_ROOT/lib/config_edit.sh")
assert_not_contains "$vpn_fn" 'chmod 600 "$secrets_dir"/*.txt' "vpn edit does not chmod every secret"
assert_contains "$vpn_fn" "openvpn_user.txt" "vpn chmod names openvpn_user"
assert_contains "$vpn_fn" "wireguard_private_key.txt" "vpn chmod names wireguard key"

test_suite "cli has config apply"
assert_true "config apply is a subcommand" "grep -q 'apply|wire)' \"$REPO_ROOT/bin/cli.sh\""
assert_true "config apply runs config.sh" "grep -q 'ASSEMBLRR_NONINTERACTIVE=1 bash' \"$REPO_ROOT/bin/cli.sh\""
assert_contains "$(grep 'config apply' "$REPO_ROOT/README.md" || true)" "config apply" "README lists config apply"

test_summary
