#!/bin/bash
# Unit tests for indexer fzf menu formatting / preselect binds
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../helpers.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/core.sh"
stub_log_error_no_exit
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/fzf-tui.sh"

schema='[
  {"name":"Alpha","enable":true,"description":"first\nline"},
  {"name":"Bravo","enable":false,"description":"private tracker"},
  {"name":"Charlie","enable":true,"description":"already added"}
]'

test_suite "format_prowlarr_indexer_menu"
menu=$(format_prowlarr_indexer_menu "$schema" '["Charlie"]')
assert_contains "$menu" $'Alpha\t\tfirst line' "public unused has empty badge"
assert_contains "$menu" $'Bravo\t[P]\tprivate tracker' "private unused marked [P]"
assert_contains "$menu" $'Charlie\t[already enabled]\talready added' "existing marked [already enabled]"

both=$(format_prowlarr_indexer_menu "$schema" '["Bravo"]')
assert_contains "$both" $'Bravo\t[already enabled] [P]\tprivate tracker' "existing private gets both badges"

empty=$(format_prowlarr_indexer_menu "$schema" '[]')
assert_not_contains "$empty" "[already enabled]" "no badge when none installed"

test_suite "fzf_preselect_start_bind"
data=$'Alpha\t\nBravo\t[P]\nCharlie\t[already enabled]'
assert_eq "start:pos(3)+select" "$(fzf_preselect_start_bind "$data" $'Charlie')" "one existing"
assert_eq "start:pos(1)+select+pos(3)+select" "$(fzf_preselect_start_bind "$data" $'Alpha\nCharlie')" "two existing"
assert_eq "" "$(fzf_preselect_start_bind "$data" $'Nope')" "unknown name → empty"
assert_eq "" "$(fzf_preselect_start_bind "$data" "")" "empty names → empty"

test_suite "format_path_menu"
menu=$(format_path_menu /home/u/assemblrr /home/u/assemblrr-media /mnt/e /media/u/disk)
assert_contains "$menu" $'home\tHome (default)\t/home/u/assemblrr  +  /home/u/assemblrr-media\t/home/u/assemblrr\t/home/u/assemblrr-media' \
    "home default row"
assert_contains "$menu" $'all:/mnt/e\tWindows E: — everything here' "WSL drive everything"
assert_contains "$menu" $'media:/mnt/e\tWindows E: — media only (recommended)' "WSL drive media-only"
assert_contains "$menu" $'/mnt/e/assemblrr\t/mnt/e/assemblrr-media' "everything paths on E:"
assert_contains "$menu" $'/home/u/assemblrr\t/mnt/e/assemblrr-media' "media-only keeps home install"
assert_contains "$menu" $'all:/media/u/disk\tdisk — everything here' "linux mount uses basename"
assert_contains "$menu" $'browse\tBrowse for a folder...' "browse row"
assert_contains "$menu" $'custom\tType paths...' "custom row"

test_summary
