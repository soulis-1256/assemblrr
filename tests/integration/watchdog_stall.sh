#!/bin/bash
# Live test: stall qBittorrent and check vpn-watchdog.
# Mutates a real install — requires ASSEMBLRR_ALLOW_LIVE_TEST=1.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../helpers.sh"

# Ubuntu 22.04 desktop infohash (official FOSS image)
TARGET_HASH="3b245504cf5f11bbdbe1201cea6a6bf45aee1bc0"
MAGNET="magnet:?xt=urn:btih:${TARGET_HASH}&dn=ubuntu-22.04.4-desktop-amd64.iso&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce&tr=udp%3A%2F%2Ftracker.openbittorrent.com%3A6969%2Fannounce"

COOKIE_JAR="${TMPDIR:-/tmp}/assemblrr_watchdog_test_cookie.txt"
RESTORED_MAX_CONNECS=500
CLEANED_UP=0

die() {
    echo "ERROR: $*" >&2
    exit 1
}

require_live_opt_in() {
    if [ "${ASSEMBLRR_ALLOW_LIVE_TEST:-}" != "1" ]; then
        cat >&2 <<'EOF'
Refusing to run live integration test.

This script temporarily sets qBittorrent max_connecs=0 and adds a test torrent
against your real install. Re-run with:

  ASSEMBLRR_ALLOW_LIVE_TEST=1 ./tests/integration/watchdog_stall.sh

Optional:
  ASSEMBLRR_DIR=/path/to/install
  ASSEMBLRR_CONFIG=/path/to/.assemblrr-config
  QBIT_HOST=127.0.0.1:8081
EOF
        exit 2
    fi
}

require_live_opt_in

cleanup() {
    [ "$CLEANED_UP" -eq 1 ] && return 0
    CLEANED_UP=1
    echo ""
    echo ">>> Cleanup <<<"
    if [ -f "$COOKIE_JAR" ] && [ -n "${AUTH_USERNAME:-}" ] && [ -n "${AUTH_PASSWORD:-}" ]; then
        qbit_api "$COOKIE_JAR" -d "json={\"max_connecs\": ${RESTORED_MAX_CONNECS}}" \
            "${QBIT_API}/app/setPreferences" >/dev/null 2>&1 || true
        qbit_api "$COOKIE_JAR" -d "hashes=${TARGET_HASH}&deleteFiles=true" \
            "${QBIT_API}/torrents/delete" >/dev/null 2>&1 || true
        echo "  Restored max_connecs=${RESTORED_MAX_CONNECS} and deleted test torrent (best effort)."
    fi
    rm -f "$COOKIE_JAR"
}
trap cleanup EXIT INT TERM

resolve_watchdog_script() {
    local install_dir="$1"
    if [ -f "$install_dir/scripts/vpn-watchdog.sh" ]; then
        echo "$install_dir/scripts/vpn-watchdog.sh"
        return 0
    fi
    if [ -f "$REPO_ROOT/scripts/vpn-watchdog.sh" ]; then
        echo "$REPO_ROOT/scripts/vpn-watchdog.sh"
        return 0
    fi
    return 1
}

prepare_watchdog_env() {
    local install_dir="$1"
    local secrets="$install_dir/secrets"
    if [ -f "$secrets/auth_username.txt" ] && [ -f "$secrets/auth_password.txt" ]; then
        export AUTH_USERNAME_FILE="$secrets/auth_username.txt"
        export AUTH_PASSWORD_FILE="$secrets/auth_password.txt"
        return 0
    fi
    if [ -n "${AUTH_USERNAME:-}" ] && [ -n "${AUTH_PASSWORD:-}" ]; then
        local staged
        staged=$(mktemp -d)
        printf '%s' "$AUTH_USERNAME" >"$staged/auth_username.txt"
        printf '%s' "$AUTH_PASSWORD" >"$staged/auth_password.txt"
        export AUTH_USERNAME_FILE="$staged/auth_username.txt"
        export AUTH_PASSWORD_FILE="$staged/auth_password.txt"
        # shellcheck disable=SC2064
        trap "rm -rf '$staged'; cleanup" EXIT INT TERM
        return 0
    fi
    return 1
}

torrent_summary() {
    qbit_api "$COOKIE_JAR" "${QBIT_API}/torrents/info" \
        | jq -r --arg h "$TARGET_HASH" \
            '.[] | select(.hash == $h or (.hash | ascii_downcase) == ($h | ascii_downcase))
             | "name=\(.name) state=\(.state) seeds=\(.num_seeds)/\(.num_complete) conn=\(.num_leechs)"' \
        2>/dev/null || true
}

command -v curl >/dev/null || die "curl is required"
command -v jq >/dev/null || die "jq is required"

install_dir=$(resolve_install_dir) || die "Could not resolve install directory. Set ASSEMBLRR_DIR."
load_assemblrr_config "$install_dir" || die "Could not load config from $install_dir"

if [ -z "${AUTH_USERNAME:-}" ] || [ -z "${AUTH_PASSWORD:-}" ]; then
    if [ -f "$install_dir/secrets/auth_username.txt" ]; then
        AUTH_USERNAME=$(cat "$install_dir/secrets/auth_username.txt")
        AUTH_PASSWORD=$(cat "$install_dir/secrets/auth_password.txt")
    else
        die "AUTH_USERNAME/AUTH_PASSWORD not set and secrets/auth_*.txt missing"
    fi
fi

watchdog=$(resolve_watchdog_script "$install_dir") \
    || die "vpn-watchdog.sh not found in install or repo"
prepare_watchdog_env "$install_dir" \
    || die "Could not prepare watchdog credential files"

echo "Install dir:  $install_dir"
echo "qBittorrent:  $QBIT_HOST"
echo "Watchdog:     $watchdog"
echo ""

echo "[1] Authenticating..."
rm -f "$COOKIE_JAR"
qbit_login "$COOKIE_JAR" "$AUTH_USERNAME" "$AUTH_PASSWORD" \
    || die "qBittorrent login failed (is the stack up on $QBIT_HOST?)"

echo "[2] Adding test torrent (Ubuntu ISO magnet)..."
qbit_api "$COOKIE_JAR" -d "urls=${MAGNET}" "${QBIT_API}/torrents/add" >/dev/null \
    || die "Failed to add torrent"

echo "[3] Waiting 15s for tracker contact..."
sleep 15
echo "    $(torrent_summary || echo 'torrent not listed yet')"

echo "[4] Sabotaging max_connecs=0..."
qbit_api "$COOKIE_JAR" -d 'json={"max_connecs": 0}' "${QBIT_API}/app/setPreferences" >/dev/null

qbit_api "$COOKIE_JAR" -d "hashes=${TARGET_HASH}" "${QBIT_API}/torrents/stop" >/dev/null 2>&1 || true
sleep 2
qbit_api "$COOKIE_JAR" -d "hashes=${TARGET_HASH}" "${QBIT_API}/torrents/start" >/dev/null 2>&1 || true

echo "[5] Waiting 15s to stall..."
sleep 15
summary=$(torrent_summary || true)
echo "    ${summary:-no status}"

echo "[6] Running vpn-watchdog..."
set +e
watchdog_out=$(bash "$watchdog" 2>&1)
watchdog_rc=$?
set -e
echo "$watchdog_out" | sed 's/^/    /'

echo ""
echo ">>> Assertions <<<"
failures=0

if [ "$watchdog_rc" -ne 0 ]; then
    echo "  PASS: watchdog exited non-zero (rc=$watchdog_rc) — expected under stall"
else
    if echo "$watchdog_out" | grep -qiE 'DETECTED|routing failure|VPN routing'; then
        echo "  PASS: watchdog reported routing failure"
    else
        echo "  FAIL: watchdog exited 0 without a detection message"
        echo "        (needs stalled torrent + failed trackers — see vpn-watchdog.sh)"
        failures=$((failures + 1))
    fi
fi

if qbit_api "$COOKIE_JAR" "${QBIT_API}/app/version" >/dev/null 2>&1 \
    || qbit_login "$COOKIE_JAR" "$AUTH_USERNAME" "$AUTH_PASSWORD"; then
    echo "  PASS: qBittorrent API still reachable after watchdog"
else
    echo "  FAIL: qBittorrent API unreachable after watchdog"
    failures=$((failures + 1))
fi

echo "[7] Restoring max_connecs and deleting torrent (via trap)..."

if [ "$failures" -gt 0 ]; then
    echo ""
    echo "STATUS: FAILED ($failures assertion(s))"
    exit 1
fi

echo ""
echo "STATUS: OK"
exit 0
