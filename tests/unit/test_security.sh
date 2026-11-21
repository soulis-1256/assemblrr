#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Security & legal-hygiene regression tests (safe_source, safe_rm_rf, secrets, API headers, neutral content)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../helpers.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/core.sh"
stub_log_error_no_exit

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

test_suite "safe_source blocks shell injection"
evil1="$tmp/evil1.env"
cat > "$evil1" <<'EOF'
FOO=$(id)
EOF
assert_failure "rejects command substitution" safe_source "$evil1"

evil2="$tmp/evil2.env"
cat > "$evil2" <<'EOF'
FOO=`id`
EOF
assert_failure "rejects backticks" safe_source "$evil2"

evil3="$tmp/evil3.env"
cat > "$evil3" <<'EOF'
FOO=bar; rm -rf /tmp/x
EOF
assert_failure "rejects unquoted semicolons" safe_source "$evil3"

good_brand="$tmp/branding.conf"
cat > "$good_brand" <<'EOF'
APP_NAME="assemblrr"
APP_DEFAULT_INSTALL_DIR="$HOME/$APP_NAME"
EOF
safe_source "$good_brand"
assert_eq "$HOME/assemblrr" "$APP_DEFAULT_INSTALL_DIR" "expands safe vars in branding.conf without eval"

test_suite "_is_safe_rm_path rejects traversal and shallow roots"
assert_failure "rejects .. traversal" _is_safe_rm_path "/home/user/../assemblrr"
assert_failure "rejects trailing .." _is_safe_rm_path "/home/user/assemblrr/.."
assert_failure "rejects relative path" _is_safe_rm_path "assemblrr/config"
assert_failure "rejects /tmp" _is_safe_rm_path "/tmp"
assert_failure "rejects $HOME" _is_safe_rm_path "$HOME"
assert_success "accepts install dir" _is_safe_rm_path "$HOME/assemblrr/config"

test_suite "write_secret_file sets 0600 and omits trailing newline"
sec="$tmp/secret.txt"
write_secret_file "$sec" "s3cr3t!"
assert_eq "s3cr3t!" "$(cat "$sec")" "secret content exact"
perm=$(stat -c '%a' "$sec" 2>/dev/null || stat -f '%Lp' "$sec")
assert_eq "600" "$perm" "secret permissions 0600"

test_suite "No borrowed OpenSubtitles API key or X-Emby-Token in runtime code"
assert_not_contains "$(cat "$REPO_ROOT/lib/prompts.sh")" "s38zmzVlW7IlYruWi7mHwDYl2SfMQoC1" "no borrowed OpenSubtitles key"
emby_hits=$(grep -rn 'X-Emby-Token' "$REPO_ROOT/bin" "$REPO_ROOT/lib" "$REPO_ROOT/scripts" 2>/dev/null || true)
assert_eq "" "$emby_hits" "no X-Emby-Token anywhere in bin/lib/scripts"

test_suite "No piracy domains or copyrighted sample titles in repository"
bad_hits=$(grep -rniE 'uindex\.org|DSNP\.WEB-DL|The Avengers|Age of Ultron|It Comes at Night|The Hobbit|Lost in Space|Iron Man' \
    "$REPO_ROOT/bin" "$REPO_ROOT/lib" "$REPO_ROOT/scripts" "$REPO_ROOT/docs" "$REPO_ROOT/tests" \
    --exclude="test_security.sh" 2>/dev/null || true)
assert_eq "" "$bad_hits" "zero copyrighted/piracy strings in repo code, docs, or tests"

test_summary
