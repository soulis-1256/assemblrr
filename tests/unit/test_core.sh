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

# --- tty helpers used after fzf ---
test_suite "flush_tty_input / read_prompt"
assert_success "flush_tty_input returns 0" flush_tty_input
assert_true "read_prompt exists" "type read_prompt >/dev/null"
# EOF on stdin must not trip set -e when /dev/tty is unavailable to the helper's else branch.
src=$(sed -n '/^read_prompt()/,/^}/p' "$REPO_ROOT/lib/core.sh")
assert_contains "$src" '</dev/tty' "read_prompt reads the tty"
assert_contains "$src" '|| true' "read_prompt ignores EOF"
flush_src=$(sed -n '/^flush_tty_input()/,/^}/p' "$REPO_ROOT/lib/core.sh")
assert_contains "$flush_src" 'read -r -t' "flush drains leftover Enter"
assert_not_contains "$flush_src" 'stty' "flush does not change stty"
assert_contains "$src" 'EPOCHREALTIME' "read_prompt ignores instant empty (leaked Enter)"
os_fn=$(sed -n '/^configure_opensubtitles()/,/^}/p' "$REPO_ROOT/lib/prompts.sh")
assert_contains "$os_fn" 'ui_is_edit' "edit skips the optional y/N"
assert_contains "$os_fn" '_opensubtitles_ask_and_verify 1' "edit goes straight to username/password"
assert_not_contains "$os_fn" 'Answer n to clear' "edit does not ask n to clear"
edit_os=$(sed -n '/^_config_edit_opensubtitles()/,/^}/p' "$REPO_ROOT/lib/config_edit.sh")
assert_contains "$edit_os" 'Cancelled.' "edit cancel is one line"
assert_not_contains "$os_fn" 'cancelled — no change' "prompt layer does not also log cancel"

# --- wait_inline ---
test_suite "wait_inline"
assert_contains "$(wait_inline "Waiting for Radarr API" 12 2>&1)" \
    "Waiting for Radarr API (12s)" "shows elapsed seconds"
WAIT_WHILE_OUTPUT=""
wait_while "unit-test" bash -c 'printf hi' >/dev/null 2>&1
assert_eq "hi" "$WAIT_WHILE_OUTPUT" "captures command output"
rc=0
wait_while "unit-fail" bash -c 'exit 3' >/dev/null 2>&1 || rc=$?
assert_eq "3" "$rc" "propagates exit status"

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

crlf="$tmp/crlf.env"
printf 'FOO=from_crlf\r\nBAZ=ok\r\n' > "$crlf"
assert_success "accepts CRLF KEY=VALUE file" bash -c "
  source '$REPO_ROOT/lib/core.sh'
  safe_source '$crlf'
"
unset FOO BAZ
safe_source "$crlf"
assert_eq "from_crlf" "${FOO:-}" "CRLF FOO has no carriage return"
assert_eq "ok" "${BAZ:-}" "CRLF BAZ sourced"

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

test_suite "write_install_pointer + leftovers"
ptr_home="$tmp/ptr-home"
mkdir -p "$ptr_home"
HOME="$ptr_home" write_install_pointer /mnt/e/assemblrr /mnt/e/assemblrr-media
assert_contains "$(cat "$ptr_home/.assemblrr-config")" 'INSTALL_DIRECTORY="/mnt/e/assemblrr"' "pointer has install"
assert_contains "$(cat "$ptr_home/.assemblrr-config")" 'MEDIA_DIRECTORY="/mnt/e/assemblrr-media"' "pointer has media"
HOME="$ptr_home" load_install_pointer
assert_eq "/mnt/e/assemblrr" "${INSTALL_DIRECTORY:-}" "load install"
assert_eq "/mnt/e/assemblrr-media" "${MEDIA_DIRECTORY:-}" "load media"

empty_inst="$ptr_home/assemblrr"
mkdir -p "$empty_inst"
mkdir -p "$ptr_home/assemblrr-media/torrents/movies"
mkdir -p "$ptr_home/not-ours/assemblrr-media"
assert_success "empty named tree is leftover install" is_assemblrr_install_tree "$empty_inst"
assert_success "torrents/movies is leftover media" is_assemblrr_media_tree "$ptr_home/assemblrr-media"
assert_failure "unrelated folder is not leftover media" is_assemblrr_media_tree "$ptr_home/not-ours/assemblrr-media"
left=$(HOME="$ptr_home" list_assemblrr_leftovers)
assert_contains "$left" $'install\t'"$empty_inst" "lists home leftover install"
assert_contains "$left" $'media\t'"$ptr_home/assemblrr-media" "lists home leftover media"
skipped=$(HOME="$ptr_home" list_assemblrr_leftovers "$empty_inst" "$ptr_home/assemblrr-media")
assert_not_contains "$skipped" "$empty_inst" "skips passed install"
assert_not_contains "$skipped" "$ptr_home/assemblrr-media" "skips passed media"

test_suite "pointer remembers previous installs"
mem_home="$tmp/mem-home"
old_inst="$tmp/old-stack/assemblrr"
old_media="$tmp/old-stack/vids"
mkdir -p "$mem_home" "$old_inst" "$old_media/torrents/movies"
printf '%s\n' '#!/bin/bash' >"$old_inst/cli.sh"
HOME="$mem_home" write_install_pointer "$old_inst" "$old_media"
new_inst="$mem_home/assemblrr"
new_media="$mem_home/assemblrr-media"
mkdir -p "$new_inst" "$new_media/torrents/movies"
HOME="$mem_home" write_install_pointer "$new_inst" "$new_media"
ptr=$(cat "$mem_home/.assemblrr-config")
assert_contains "$ptr" "KNOWN_INSTALLS=" "records known installs"
assert_contains "$ptr" "$old_inst" "keeps previous install path"
assert_contains "$ptr" "$old_media" "keeps previous media path"
left=$(HOME="$mem_home" list_assemblrr_leftovers "$new_inst" "$new_media")
assert_contains "$left" $'install\t'"$old_inst" "finds remembered install"
assert_contains "$left" $'media\t'"$old_media" "finds remembered media"

test_suite "leftovers find nested trees and config media"
nest_home="$tmp/nest-home"
mkdir -p "$nest_home/data/assemblrr"
mkdir -p "$tmp/elsewhere-media/torrents/movies"
printf 'MEDIA_DIRECTORY="%s"\n' "$tmp/elsewhere-media" >"$nest_home/data/assemblrr/.assemblrr-config"
left=$(HOME="$nest_home" list_assemblrr_leftovers)
assert_contains "$left" $'install\t'"$nest_home/data/assemblrr" "one level under home"
assert_contains "$left" $'media\t'"$tmp/elsewhere-media" "media from leftover install config"

test_suite "is_complete_assemblrr_install"
done="$tmp/complete/assemblrr"
mkdir -p "$done/compose"
: >"$done/.assemblrr-config"
: >"$done/cli.sh"
assert_success "config+cli is complete" is_complete_assemblrr_install "$done"
empty="$tmp/empty/assemblrr"
mkdir -p "$empty"
assert_failure "empty dir is not complete" is_complete_assemblrr_install "$empty"
assert_failure "missing path is not complete" is_complete_assemblrr_install "$tmp/no-such"
partial="$tmp/partial/assemblrr"
mkdir -p "$partial"
: >"$partial/cli.sh"
assert_failure "cli without runtime config is not complete" is_complete_assemblrr_install "$partial"

test_suite "setup refuses a complete install"
assert_true "setup calls the gate" "grep -q refuse_setup_if_already_installed \"$REPO_ROOT/bin/setup.sh\""
assert_true "setup offers leftover cleanup" "grep -q offer_leftover_cleanup \"$REPO_ROOT/bin/setup.sh\""
gate=$(sed -n '/^refuse_setup_if_already_installed()/,/^}/p' "$REPO_ROOT/lib/prompts.sh")
assert_contains "$gate" "already installed" "says already installed"
assert_contains "$gate" "uninstall" "points at uninstall"
assert_contains "$gate" "upgrade" "points at upgrade"
assert_contains "$gate" "exit 1" "stops setup"

test_suite "offer_leftover_cleanup"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/prompts.sh"

media_only_home="$tmp/media-only-home"
mkdir -p "$media_only_home/assemblrr-media/torrents/movies"
out_media=$(HOME="$media_only_home" offer_leftover_cleanup <<< "n" 2>&1 || true)
assert_contains "$out_media" "Media:   $media_only_home/assemblrr-media" "media labeled in leftover output"
assert_not_contains "$out_media" "Install:" "no install label when only media leftover"
assert_true "media directory kept when answering n" "[ -d \"$media_only_home/assemblrr-media\" ]"

HOME="$media_only_home" offer_leftover_cleanup <<< "y" >/dev/null 2>&1 || true
assert_false "media directory removed when answering y" "[ -d \"$media_only_home/assemblrr-media\" ]"

inst_only_home="$tmp/inst-only-home"
mkdir -p "$inst_only_home/assemblrr"
out_inst=$(HOME="$inst_only_home" offer_leftover_cleanup <<< "n" 2>&1 || true)
assert_contains "$out_inst" "Install: $inst_only_home/assemblrr" "install labeled in leftover output"
assert_not_contains "$out_inst" "Media:" "no media label when only install leftover"
assert_true "install directory kept when answering n" "[ -d \"$inst_only_home/assemblrr\" ]"

HOME="$inst_only_home" offer_leftover_cleanup <<< "y" >/dev/null 2>&1 || true
assert_false "install directory removed when answering y" "[ -d \"$inst_only_home/assemblrr\" ]"

both_home="$tmp/both-home"
mkdir -p "$both_home/assemblrr" "$both_home/assemblrr-media/torrents/movies"
out_both=$(HOME="$both_home" offer_leftover_cleanup <<< $'n\nn' 2>&1 || true)
assert_contains "$out_both" "Install: $both_home/assemblrr" "both: install labeled"
assert_contains "$out_both" "Media:   $both_home/assemblrr-media" "both: media labeled"

# Remove install only (answer y, then n)
HOME="$both_home" offer_leftover_cleanup <<< $'y\nn' >/dev/null 2>&1 || true
assert_false "install directory removed on y" "[ -d \"$both_home/assemblrr\" ]"
assert_true "media directory kept on n" "[ -d \"$both_home/assemblrr-media\" ]"

test_suite "print_detected_locations"
loc=$(INSTALL_DIR=/mnt/e/assemblrr MEDIA_DIRECTORY=/mnt/e/assemblrr-media \
    HOME="$ptr_home" print_detected_locations "Detected installation:")
assert_contains "$loc" "Detected installation:" "optional heading"
assert_contains "$loc" "Config:  /mnt/e/assemblrr" "prints config path"
assert_contains "$loc" "Media:   /mnt/e/assemblrr-media" "prints media path"
assert_not_contains "$loc" "Extra:" "does not use Extra label"

test_suite "storage_root_label"
assert_eq "Windows E:" "$(storage_root_label /mnt/e)" "WSL E:"
assert_eq "Windows C:" "$(storage_root_label /mnt/c/)" "strips trailing slash"
assert_eq "Seagate" "$(storage_root_label /media/user/Seagate)" "linux /media"
assert_eq "USB" "$(storage_root_label /run/media/user/USB)" "linux /run/media"
assert_eq "/data" "$(storage_root_label /data)" "other path unchanged"

test_suite "storage_mount_root / storage_needs_probe"
assert_eq "/mnt/e" "$(storage_mount_root /mnt/e)" "letter is the root"
assert_eq "/mnt/e" "$(storage_mount_root /mnt/e/assemblrr)" "strips under WSL letter"
assert_eq "/mnt/e" "$(storage_mount_root /mnt/e/assemblrr-media/)" "media path"
assert_eq "/media/u/disk" "$(storage_mount_root /media/u/disk/foo)" "linux /media label"
assert_eq "/run/media/u/USB" "$(storage_mount_root /run/media/u/USB/data)" "run/media label"
assert_eq "/home/u/assemblrr" "$(storage_mount_root /home/u/assemblrr)" "home unchanged"
assert_success "WSL letter needs probe" storage_needs_probe /mnt/e/assemblrr
assert_success "linux media needs probe" storage_needs_probe /media/u/disk
assert_failure "home does not need probe" storage_needs_probe /home/u/assemblrr

test_suite "probe_writable_path"
probe_ok="$tmp/probe-ok"
mkdir -p "$probe_ok"
assert_success "writable tmp is ok" probe_writable_path "$probe_ok"
assert_true "probe file cleaned up" "[ -z \"\$(ls -A \"$probe_ok\"/.assemblrr-write-test.* 2>/dev/null)\" ]"
assert_failure "missing path fails" probe_writable_path "$tmp/no-such-dir/nested"

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

test_suite "PATH CLI wrapper"
wrap_home="$tmp/wrap-home"
wrap_inst="$tmp/wrap-install"
mkdir -p "$wrap_home/.local/bin/lib" "$wrap_inst"
printf '%s\n' '#!/bin/bash' 'echo real-cli' >"$wrap_inst/cli.sh"
chmod +x "$wrap_inst/cli.sh"
echo stale >"$wrap_home/.local/bin/lib/core.sh"
echo leftover >"$wrap_home/.local/bin/lib/config_edit.sh"
HOME="$wrap_home" APP_CLI_NAME=assemblrr install_user_cli_wrapper
assert_true "wrapper is executable" "[ -x \"$wrap_home/.local/bin/assemblrr\" ]"
assert_false "stale core.sh removed" "[ -f \"$wrap_home/.local/bin/lib/core.sh\" ]"
assert_false "stale config_edit.sh removed" "[ -f \"$wrap_home/.local/bin/lib/config_edit.sh\" ]"
assert_false "empty lib dir removed" "[ -d \"$wrap_home/.local/bin/lib\" ]"
assert_not_contains "$(cat "$wrap_home/.local/bin/assemblrr")" "find_install_directory" "wrapper is not the full CLI"
out=$(HOME="$wrap_home" ASSEMBLRR_DIR="$wrap_inst" "$wrap_home/.local/bin/assemblrr")
assert_eq "real-cli" "$out" "ASSEMBLRR_DIR runs install cli.sh"

printf 'INSTALL_DIRECTORY="%s"\r\n' "$wrap_inst" >"$wrap_home/.assemblrr-config"
out=$(HOME="$wrap_home" env -u ASSEMBLRR_DIR "$wrap_home/.local/bin/assemblrr")
assert_eq "real-cli" "$out" "CRLF pointer runs install cli.sh"

assert_failure "missing install fails" \
    env HOME="$wrap_home" ASSEMBLRR_DIR="$tmp/no-such-install" "$wrap_home/.local/bin/assemblrr"

other="$tmp/wrap-other"
mkdir -p "$other"
printf '%s\n' '#!/bin/bash' 'echo other-cli' >"$other/cli.sh"
chmod +x "$other/cli.sh"
out=$(HOME="$wrap_home" ASSEMBLRR_DIR="$other" "$wrap_home/.local/bin/assemblrr")
assert_eq "other-cli" "$out" "ASSEMBLRR_DIR wins over pointer"

test_summary
