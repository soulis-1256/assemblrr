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
assert_contains "$ids" "language" "lists language"
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

test_suite "config_unset_kv"
config_set_kv "$cfg" "SEERR_DEFAULT_PROFILE" "5"
assert_contains "$(cat "$cfg")" 'SEERR_DEFAULT_PROFILE="5"' "legacy key present"
config_unset_kv "$cfg" "SEERR_DEFAULT_PROFILE"
assert_not_contains "$(cat "$cfg")" "SEERR_DEFAULT_PROFILE=" "legacy key removed"
assert_contains "$(cat "$cfg")" 'TZ="Europe/Athens"' "other keys kept"

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
assert_contains "$profile_line" "Sonarr" "profile catalog mentions Sonarr"
assert_contains "$profile_line" "Seerr" "profile catalog mentions Seerr"
lang_line=$(_config_edit_catalog | grep '^language|' || true)
assert_contains "$lang_line" "preferred" "language catalog mentions preferred"
lang_fn=$(sed -n '/^_config_edit_language()/,/^}/p' "$REPO_ROOT/lib/config_edit.sh")
assert_contains "$lang_fn" "SUBTITLE_LANGUAGES" "language edit persists extras"
assert_contains "$lang_fn" "ui_picker_cancelled" "language edit honors Esc"
run_fn=$(sed -n '/^config_edit_run()/,/^}/p' "$REPO_ROOT/lib/config_edit.sh")
assert_contains "$run_fn" "flush_tty_input" "edit flushes fzf Enter before section prompts"
os_fn=$(sed -n '/^configure_opensubtitles()/,/^}/p' "$REPO_ROOT/lib/prompts.sh")
assert_contains "$os_fn" "read_prompt" "opensubtitles uses read_prompt after the picker"
edit_os=$(sed -n '/^_config_edit_opensubtitles()/,/^}/p' "$REPO_ROOT/lib/config_edit.sh")
assert_contains "$edit_os" "Cancelled." "failed/cancelled edit is one line and does not delete secrets"

test_suite "profile edit persists QUALITY_SOURCE and resyncs Recyclarr"
profile_fn=$(sed -n '/^_config_edit_profile()/,/^}/p' "$REPO_ROOT/lib/config_edit.sh")
assert_contains "$profile_fn" 'QUALITY_SOURCE' "writes QUALITY_SOURCE"
assert_contains "$profile_fn" "configure_recyclarr" "resyncs Recyclarr so WEB packs exist"

test_suite "vpn edit chmods only vpn secret files"
vpn_fn=$(sed -n '/^_config_edit_vpn()/,/^}/p' "$REPO_ROOT/lib/config_edit.sh")
assert_not_contains "$vpn_fn" 'chmod 600 "$secrets_dir"/*.txt' "vpn edit does not chmod every secret"
assert_contains "$vpn_fn" "openvpn_user.txt" "vpn chmod names openvpn_user"
assert_contains "$vpn_fn" "wireguard_private_key.txt" "vpn chmod names wireguard key"

test_suite "auth edit writes secrets only after every UI succeeds"
auth_fn=$(sed -n '/^_config_edit_auth()/,/^}/p' "$REPO_ROOT/lib/config_edit.sh")
fail_at=$(echo "$auth_fn" | grep -n 'fail" -ne 0' | head -1 | cut -d: -f1)
write_at=$(echo "$auth_fn" | grep -n 'echo -n "$AUTH_PASSWORD"' | head -1 | cut -d: -f1)
assert_true "fail check exists" "[ -n \"$fail_at\" ]"
assert_true "password write exists" "[ -n \"$write_at\" ]"
assert_true "secrets written after fail check" "[ \"$fail_at\" -lt \"$write_at\" ]"
assert_contains "$auth_fn" "Secrets were left unchanged" "failure keeps old secrets"
assert_contains "$auth_fn" "config edit" "failure says retry config edit"
assert_not_contains "$auth_fn" "config apply" "failure does not point at apply"

test_suite "cli has config apply"
assert_true "config apply is a subcommand" "grep -q 'apply|wire)' \"$REPO_ROOT/bin/cli.sh\""
assert_true "config apply runs config.sh" "grep -q 'ASSEMBLRR_NONINTERACTIVE=1 bash' \"$REPO_ROOT/bin/cli.sh\""
assert_contains "$(grep 'config apply' "$REPO_ROOT/README.md" || true)" "config apply" "README lists config apply"

test_suite "uninstall --force is quiet"
un=$(sed -n '/^uninstall_app()/,/^}/p' "$REPO_ROOT/bin/cli.sh")
assert_contains "$un" 'if [ "$force" = false ]; then' "inventory only when not --force"
assert_not_contains "$un" "Stopping all services" "no step-by-step stop line"
assert_not_contains "$un" "Removing config at" "no Removing-config play-by-play"
assert_not_contains "$un" "Docker images were left" "no leftover-images lecture"
assert_contains "$un" "uninstalled." "one done line"
assert_contains "$un" "Config removed:" "removed config is labeled removed"
assert_contains "$un" "Media removed:" "removed media is labeled removed"
assert_contains "$un" "Config kept:" "kept config is labeled kept"
assert_contains "$un" "Media kept:" "kept media is labeled kept"
assert_not_contains "$un" 'echo "  Config: $INSTALL_DIR"' "does not print a status-style Config path"
assert_not_contains "$un" 'echo "  Media:  $MEDIA_DIRECTORY"' "does not print a status-style Media path"

test_suite "config show survives missing VPN_TYPE/TZ"
cli="$REPO_ROOT/bin/cli.sh"
assert_contains "$(grep -n 'VPN_TYPE=' "$cli" | head -5)" 'VPN_TYPE="${VPN_TYPE:-openvpn}"' "CLI defaults VPN_TYPE"
assert_contains "$(grep -n 'TZ=' "$cli" | head -5)" 'TZ="${TZ:-UTC}"' "CLI defaults TZ"
show_fn=$(sed -n '/^show_config()/,/^}/p' "$cli")
assert_contains "$show_fn" '${VPN_TYPE:-openvpn}' "show_config defaults VPN type"
assert_contains "$show_fn" '${TZ:-UTC}' "show_config defaults timezone"

# Reproduce the old set -u crash: print those fields with vars unset.
out=$(bash -c 'set -u
MEDIA_SERVICE=jellyfin
VPN_ENABLED=n
# VPN_TYPE and TZ deliberately unset
echo "  Media service:      ${MEDIA_SERVICE:-jellyfin}"
echo "  VPN enabled:        ${VPN_ENABLED:-n}"
echo "  VPN type:           ${VPN_TYPE:-openvpn}"
echo "  Timezone:           ${TZ:-UTC}"
')
assert_contains "$out" "VPN type:           openvpn" "unset VPN_TYPE prints default"
assert_contains "$out" "Timezone:           UTC" "unset TZ prints default"

test_suite "seerr and jellyfin first-run auth use jq --arg"
assert_contains "$(sed -n '/^seerr_get_cookie()/,/^}/p' "$REPO_ROOT/lib/seerr.sh")" \
    '--arg pass' "seerr cookie payload jq-escapes password"
assert_contains "$(sed -n '/^configure_seerr()/,/^seerr_verify_login()/p' "$REPO_ROOT/lib/seerr.sh")" \
    '--arg pass' "seerr setup payload jq-escapes password"
assert_contains "$(sed -n '/^configure_jellyfin_libraries()/,/^}/p' "$REPO_ROOT/lib/jellyfin.sh")" \
    'jq -nc --arg u' "jellyfin library auth jq-escapes password"

test_summary
