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
assert_eq "providers" "$(config_edit_resolve subtitles)" "alias subtitles → providers"
assert_eq "profile" "$(config_edit_resolve quality)" "alias quality → profile"
assert_eq "all" "$(config_edit_resolve wizard)" "alias wizard → all"
assert_eq "all" "$(config_edit_resolve ALL)" "case-insensitive"
assert_failure "unknown section" config_edit_resolve not-a-section

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
assert_contains "$usage" "config edit indexers" "usage mentions indexers example"
assert_contains "$usage" "Sections:" "usage lists sections"

test_summary
