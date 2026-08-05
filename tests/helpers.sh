#!/bin/bash
# Shared helpers for Assemblrr unit and integration tests.
# shellcheck shell=bash

# Repo root (parent of tests/)
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"

# --- Assertion helpers ---

_TEST_FAILURES=0
_TEST_PASSES=0
_TEST_CURRENT=""

test_suite() {
    _TEST_CURRENT="$1"
    echo ""
    echo "=== $1 ==="
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-values equal}"
    if [ "$expected" = "$actual" ]; then
        _TEST_PASSES=$((_TEST_PASSES + 1))
        echo "  PASS: $msg"
        return 0
    fi
    _TEST_FAILURES=$((_TEST_FAILURES + 1))
    echo "  FAIL: $msg"
    echo "        expected: $(printf '%q' "$expected")"
    echo "        actual:   $(printf '%q' "$actual")"
    return 1
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-contains substring}"
    if [[ "$haystack" == *"$needle"* ]]; then
        _TEST_PASSES=$((_TEST_PASSES + 1))
        echo "  PASS: $msg"
        return 0
    fi
    _TEST_FAILURES=$((_TEST_FAILURES + 1))
    echo "  FAIL: $msg"
    echo "        expected to contain: $(printf '%q' "$needle")"
    echo "        actual:              $(printf '%q' "$haystack")"
    return 1
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-does not contain substring}"
    if [[ "$haystack" != *"$needle"* ]]; then
        _TEST_PASSES=$((_TEST_PASSES + 1))
        echo "  PASS: $msg"
        return 0
    fi
    _TEST_FAILURES=$((_TEST_FAILURES + 1))
    echo "  FAIL: $msg"
    echo "        expected NOT to contain: $(printf '%q' "$needle")"
    echo "        actual:                  $(printf '%q' "$haystack")"
    return 1
}

assert_success() {
    local msg="${1:-command succeeds}"
    shift
    local output
    if output=$("$@" 2>&1); then
        _TEST_PASSES=$((_TEST_PASSES + 1))
        echo "  PASS: $msg"
        return 0
    fi
    _TEST_FAILURES=$((_TEST_FAILURES + 1))
    echo "  FAIL: $msg (exit non-zero)"
    [ -n "$output" ] && echo "        output: $output"
    return 1
}

assert_failure() {
    local msg="${1:-command fails}"
    shift
    local output rc=0
    set +e
    output=$("$@" 2>&1)
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        _TEST_PASSES=$((_TEST_PASSES + 1))
        echo "  PASS: $msg"
        return 0
    fi
    _TEST_FAILURES=$((_TEST_FAILURES + 1))
    echo "  FAIL: $msg (expected non-zero exit)"
    [ -n "$output" ] && echo "        output: $output"
    return 1
}

assert_true() {
    local msg="$1"
    if eval "$2"; then
        _TEST_PASSES=$((_TEST_PASSES + 1))
        echo "  PASS: $msg"
        return 0
    fi
    _TEST_FAILURES=$((_TEST_FAILURES + 1))
    echo "  FAIL: $msg"
    return 1
}

assert_false() {
    local msg="$1"
    if eval "$2"; then
        _TEST_FAILURES=$((_TEST_FAILURES + 1))
        echo "  FAIL: $msg"
        return 1
    fi
    _TEST_PASSES=$((_TEST_PASSES + 1))
    echo "  PASS: $msg"
    return 0
}

# Soft log_error for unit tests — core.sh's log_error exits the process.
# Call after sourcing lib/core.sh so we can exercise guard paths.
stub_log_error_no_exit() {
    log_error() {
        echo -e "${RED:-}$1${NC:-}" >&2
        return 1
    }
}

test_summary() {
    echo ""
    echo "----------------------------------------"
    echo "Results: ${_TEST_PASSES} passed, ${_TEST_FAILURES} failed"
    if [ "$_TEST_FAILURES" -gt 0 ]; then
        echo "STATUS: FAILED"
        return 1
    fi
    echo "STATUS: OK"
    return 0
}

# --- Install / config discovery (integration) ---

# Resolve Assemblrr install directory.
# Priority: ASSEMBLRR_DIR, ASSEMBLRR_CONFIG parent, find_install_directory, ~/assemblrr
resolve_install_dir() {
    if [ -n "${ASSEMBLRR_DIR:-}" ]; then
        echo "$ASSEMBLRR_DIR"
        return 0
    fi
    if [ -n "${ASSEMBLRR_CONFIG:-}" ] && [ -f "$ASSEMBLRR_CONFIG" ]; then
        # shellcheck disable=SC1090
        source "$ASSEMBLRR_CONFIG"
        if [ -n "${INSTALL_DIRECTORY:-}" ]; then
            echo "$INSTALL_DIRECTORY"
            return 0
        fi
        dirname "$ASSEMBLRR_CONFIG"
        return 0
    fi

    if [ -f "$REPO_ROOT/lib/core.sh" ]; then
        # shellcheck disable=SC1091
        source "$REPO_ROOT/lib/core.sh"
        local found
        found=$(find_install_directory 2>/dev/null || true)
        if [ -n "$found" ]; then
            echo "$found"
            return 0
        fi
    fi

    if [ -d "$HOME/assemblrr" ]; then
        echo "$HOME/assemblrr"
        return 0
    fi

    return 1
}

load_assemblrr_config() {
    local install_dir="$1"
    local config_file="${ASSEMBLRR_CONFIG:-$install_dir/.assemblrr-config}"
    if [ ! -f "$config_file" ]; then
        echo "Config not found: $config_file" >&2
        return 1
    fi
    # shellcheck disable=SC1090
    source "$config_file"
}

# --- qBittorrent API helpers (integration) ---

QBIT_HOST="${QBIT_HOST:-127.0.0.1:8081}"
QBIT_API="http://${QBIT_HOST}/api/v2"

qbit_login() {
    local cookie_jar="$1"
    local user="$2"
    local pass="$3"
    local http_code
    http_code=$(curl -s -o /tmp/assemblrr_qbit_login_body.txt -w "%{http_code}" \
        -c "$cookie_jar" \
        -H "Referer: http://${QBIT_HOST}" \
        --data "username=${user}&password=${pass}" \
        "${QBIT_API}/auth/login" 2>/dev/null || echo "000")
    [ "$http_code" = "200" ] || [ "$http_code" = "204" ]
}

qbit_api() {
    local cookie_jar="$1"
    shift
    curl -s -b "$cookie_jar" -H "Referer: http://${QBIT_HOST}" "$@"
}

# Create a temporary install-like tree for compose validation.
make_compose_fixture() {
    local dest="$1"
    mkdir -p "$dest/compose" "$dest/config" "$dest/scripts" "$dest/secrets" "$dest/media"
    cp "$REPO_ROOT/compose/"*.yaml "$dest/compose/" 2>/dev/null || true
    if [ -d "$REPO_ROOT/compose/examples" ]; then
        mkdir -p "$dest/compose/examples"
        cp "$REPO_ROOT/compose/examples/"* "$dest/compose/examples/" 2>/dev/null || true
    fi
    # Secret files must exist for `docker compose config` with vpn overlay
    : >"$dest/secrets/openvpn_user.txt"
    : >"$dest/secrets/openvpn_password.txt"
    : >"$dest/secrets/wireguard_private_key.txt"
    : >"$dest/scripts/vpn-watchdog.sh"
    : >"$dest/scripts/jellyfin-refresh.sh"
    cat >"$dest/.env" <<EOF
PUID=1000
PGID=1000
TZ=UTC
MEDIA_DIRECTORY=$dest/media
INSTALL_DIRECTORY=$dest
MEDIA_SERVICE=jellyfin
VPN_SERVICE=protonvpn
VPN_TYPE=openvpn
WIREGUARD_ADDRESSES=
PORT_FORWARD_ONLY=off
VPN_PORT_FORWARDING=off
EOF
}
