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

test_summary
