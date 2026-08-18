#!/bin/bash
# Unit tests for lib/api.sh wait/key helpers (no live stack).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../helpers.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/core.sh"
stub_log_error_no_exit
log_step() { :; }
log_step_fail() { echo "fail: $1" >&2; }

# shellcheck disable=SC1091
source "$REPO_ROOT/lib/api.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
INSTALL_DIR="$tmp"
API_HOST=127.0.0.1
mkdir -p "$tmp/config/radarr"
printf '<Config><ApiKey>abc123</ApiKey></Config>\n' >"$tmp/config/radarr/config.xml"

test_suite "read_api_key already present"
err=$(mktemp)
key=$(read_api_key radarr 2>"$err")
assert_eq "abc123" "$key" "returns key from config.xml"
assert_eq "" "$(cat "$err")" "no blank wait line when the key is already there"

test_summary
