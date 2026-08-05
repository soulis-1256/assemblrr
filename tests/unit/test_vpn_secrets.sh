#!/bin/bash
# Unit tests for lib/vpn.sh validate_vpn_secrets
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../helpers.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/core.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/vpn.sh"
stub_log_error_no_exit

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/secrets"

test_suite "validate_vpn_secrets (VPN disabled)"
assert_success "skips checks when VPN=n" validate_vpn_secrets "$tmp" "n" "openvpn"

test_suite "validate_vpn_secrets (OpenVPN)"
assert_failure "fails when openvpn secrets missing" validate_vpn_secrets "$tmp" "y" "openvpn"
echo "user" >"$tmp/secrets/openvpn_user.txt"
echo "pass" >"$tmp/secrets/openvpn_password.txt"
assert_success "passes with openvpn secrets present" validate_vpn_secrets "$tmp" "y" "openvpn"

test_suite "validate_vpn_secrets (WireGuard)"
# Clear openvpn files; empty WG key
rm -f "$tmp/secrets/openvpn_user.txt" "$tmp/secrets/openvpn_password.txt"
: >"$tmp/secrets/wireguard_private_key.txt"
unset WIREGUARD_ADDRESSES || true
assert_failure "fails when WG key empty and address missing" validate_vpn_secrets "$tmp" "y" "wireguard"

echo "wg-private-key" >"$tmp/secrets/wireguard_private_key.txt"
assert_failure "fails when WIREGUARD_ADDRESSES missing" validate_vpn_secrets "$tmp" "y" "wireguard"

cat >"$tmp/.env" <<'EOF'
WIREGUARD_ADDRESSES=10.2.0.2/32
EOF
assert_success "passes with WG key and addresses" validate_vpn_secrets "$tmp" "y" "wireguard"

test_summary
