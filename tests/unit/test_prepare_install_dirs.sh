#!/bin/bash
# prepare_install_dirs creates bind-mount targets before Docker can own them
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../helpers.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/core.sh"
stub_log_error_no_exit

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

uid=$(id -u)
gid=$(id -g)

test_suite "prepare_install_dirs creates bind-mount skeleton"
prepare_install_dirs "$tmp" "$uid" "$gid"

for rel in \
    config \
    config/gluetun \
    config/jellyfin \
    config/qbittorrent \
    config/sonarr \
    config/radarr \
    config/prowlarr \
    config/seerr \
    config/recyclarr \
    config/bazarr \
    secrets \
    scripts
do
    assert_true "has $rel" "[ -d \"$tmp/$rel\" ]"
done

assert_true "config writable by creator" "[ -w \"$tmp/config\" ]"
assert_eq "$uid" "$(stat -c '%u' "$tmp/config")" "config owned by uid"
assert_eq "$gid" "$(stat -c '%g' "$tmp/config")" "config owned by gid"

test_suite "prepare_install_dirs is idempotent"
prepare_install_dirs "$tmp" "$uid" "$gid"
assert_true "still writable after second call" "[ -w \"$tmp/config/radarr\" ]"

test_suite "mkdir under config after prepare"
assert_success "can create sibling of gluetun" mkdir -p "$tmp/config/__test_sibling"
assert_true "sibling exists" "[ -d \"$tmp/config/__test_sibling\" ]"

test_suite "ensure_owned prefers Docker chown before sudo"
mkdir -p "$tmp/root_owned_sim"
(
    # shellcheck disable=SC2032
    chown() { return 1; }
    run_docker() {
        printf '%s\n' "$*" > "$tmp/docker_called"
        return 0
    }
    sudo() {
        : > "$tmp/sudo_called"
        return 0
    }
    ensure_owned "$tmp/root_owned_sim" 9999 9999
)
assert_true "Docker chown fallback ran" "[ -f \"$tmp/docker_called\" ]"
assert_contains "$(cat "$tmp/docker_called")" "chown -R 9999:9999 /target" "Docker runs chown -R on /target"
assert_false "sudo was not invoked when Docker chown succeeded" "[ -f \"$tmp/sudo_called\" ]"

test_summary
