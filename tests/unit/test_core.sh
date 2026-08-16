#!/bin/bash
# Unit tests for lib/core.sh pure helpers
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../helpers.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/core.sh"
stub_log_error_no_exit

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- expand_path ---
test_suite "expand_path"
assert_eq "$HOME/foo" "$(expand_path "~/foo")" "expands leading tilde"
assert_eq "/abs/path" "$(expand_path "/abs/path")" "leaves absolute paths alone"
assert_eq "relative/path" "$(expand_path "relative/path")" "leaves relative paths alone"
# Nested ~ should not expand mid-path
assert_eq "/tmp/~/not-home" "$(expand_path "/tmp/~/not-home")" "does not expand mid-path tilde"

# --- safe_source ---
test_suite "safe_source"
good="$tmp/good.env"
bad_cmd="$tmp/bad_cmd.env"
bad_syntax="$tmp/bad_syntax.env"
cat >"$good" <<'EOF'
# comment
FOO=bar
BAZ=hello_world
EMPTY=
EOF
cat >"$bad_cmd" <<'EOF'
FOO=bar
EVIL=$(whoami)
EOF
cat >"$bad_syntax" <<'EOF'
not a valid assignment
EOF

assert_success "accepts KEY=VALUE file" bash -c "source '$REPO_ROOT/lib/core.sh'; safe_source '$good'"
# Re-source helpers' stubs after subshell isolation — run in-process:
safe_source "$good"
assert_eq "bar" "${FOO:-}" "sources FOO from good file"
assert_eq "hello_world" "${BAZ:-}" "sources BAZ from good file"

assert_failure "rejects command substitution" bash -c "
  source '$REPO_ROOT/lib/core.sh'
  safe_source '$bad_cmd'
"
assert_failure "rejects non-assignment lines" bash -c "
  source '$REPO_ROOT/lib/core.sh'
  safe_source '$bad_syntax'
"
assert_failure "fails on missing file" bash -c "
  source '$REPO_ROOT/lib/core.sh'
  safe_source '$tmp/no-such-file'
"

# --- _is_safe_rm_path ---
test_suite "_is_safe_rm_path"
assert_failure "refuses empty path" _is_safe_rm_path ""
assert_failure "refuses /" _is_safe_rm_path "/"
assert_failure "refuses /home" _is_safe_rm_path "/home"
assert_failure "refuses /tmp" _is_safe_rm_path "/tmp"
assert_failure "refuses \$HOME" _is_safe_rm_path "$HOME"
assert_failure "refuses /home/user style" _is_safe_rm_path "/home/someuser"
assert_success "allows deep app path" _is_safe_rm_path "/home/someuser/assemblrr"
assert_success "allows nested config path" _is_safe_rm_path "/home/someuser/assemblrr/config/old"

# --- find_install_directory ---
test_suite "find_install_directory (ASSEMBLRR_DIR)"
export ASSEMBLRR_DIR="/custom/install/path"
assert_eq "/custom/install/path" "$(find_install_directory)" "honors ASSEMBLRR_DIR"
unset ASSEMBLRR_DIR

test_suite "find_install_directory prefers home pointer"
fid_home="$tmp/fid-home"
mkdir -p "$fid_home/assemblrr" "$fid_home/on-disk"
printf 'INSTALL_DIRECTORY="%s"\n' "$fid_home/assemblrr" > "$fid_home/assemblrr/.assemblrr-config"
printf 'INSTALL_DIRECTORY="%s"\n' "$fid_home/on-disk" > "$fid_home/.assemblrr-config"
assert_eq "$fid_home/on-disk" "$(HOME="$fid_home" find_install_directory)" \
    "pointer wins over leftover ~/assemblrr"

test_suite "storage_root_label"
assert_eq "Windows E:" "$(storage_root_label /mnt/e)" "WSL E:"
assert_eq "Windows C:" "$(storage_root_label /mnt/c/)" "strips trailing slash"
assert_eq "Seagate" "$(storage_root_label /media/user/Seagate)" "linux /media"
assert_eq "USB" "$(storage_root_label /run/media/user/USB)" "linux /run/media"
assert_eq "/data" "$(storage_root_label /data)" "other path unchanged"

test_suite "ensure_local_bin_on_path"
path_home="$tmp/path-home"
mkdir -p "$path_home"
HOME="$path_home" ensure_local_bin_on_path
assert_contains "$(cat "$path_home/.profile")" '.local/bin' "writes .profile"
assert_contains "$(cat "$path_home/.bashrc")" '.local/bin' "writes .bashrc"
assert_true "does not create .bash_profile" "[ ! -f \"$path_home/.bash_profile\" ]"
HOME="$path_home" ensure_local_bin_on_path
assert_eq "1" "$(grep -cF '.local/bin' "$path_home/.profile")" "idempotent .profile"
assert_eq "1" "$(grep -cF '.local/bin' "$path_home/.bashrc")" "idempotent .bashrc"
mkdir -p "$path_home/.config/fish"
: > "$path_home/.bash_profile"
HOME="$path_home" ensure_local_bin_on_path
assert_contains "$(cat "$path_home/.bash_profile")" '.local/bin' "appends existing .bash_profile"
assert_contains "$(cat "$path_home/.config/fish/config.fish")" '.local/bin' "writes fish config"

test_summary
