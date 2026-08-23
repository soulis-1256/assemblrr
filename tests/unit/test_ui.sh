#!/bin/bash
# Unit tests for lib/ui.sh (setup vs edit copy)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../helpers.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/core.sh"
stub_log_error_no_exit
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/ui.sh"

test_suite "ui_mode defaults to setup"
assert_eq "setup" "$(ui_mode)" "default mode is setup"
assert_true "ui_is_setup" ui_is_setup
assert_false "not edit by default" ui_is_edit

test_suite "ui_set_mode"
ui_set_mode edit
assert_eq "edit" "$(ui_mode)" "edit mode"
assert_true "ui_is_edit" ui_is_edit
assert_false "not setup" ui_is_setup
ui_set_mode setup
assert_eq "setup" "$(ui_mode)" "back to setup"
ui_set_mode bogus
assert_eq "setup" "$(ui_mode)" "unknown mode falls back to setup"

test_suite "ui_intro spacing"
ui_set_mode setup
intro=$(ui_intro "Pick indexers." "Change indexers.")
assert_eq $'\nPick indexers.' "$intro" "one blank line before setup copy"
ui_set_mode edit
intro=$(ui_intro "Pick indexers." "Change indexers.")
assert_eq $'\nChange indexers.' "$intro" "one blank line before edit copy"
ui_set_mode setup

test_suite "ui_intro / ui_picker_done copy"
ui_set_mode setup
FZF_SELECT_STATUS=cancelled
SELECTED_INDEXERS=()
out=$(ui_picker_done indexers)
assert_contains "$out" "Skipped indexers." "setup cancel is skip"
ui_set_mode edit
out=$(ui_picker_done indexers)
assert_contains "$out" "Cancelled — no change." "edit cancel is no change"
ui_set_mode setup
FZF_SELECT_STATUS=confirmed
out=$(ui_picker_done indexers)
assert_contains "$out" "No indexers selected." "setup confirm-empty"
SELECTED_SUBTITLE_LANGUAGES=()
out=$(ui_picker_done languages)
assert_contains "$out" "No languages selected." "setup confirm-empty languages"
ui_set_mode edit
out=$(ui_picker_done indexers)
assert_eq "" "$out" "edit confirm-empty is silent (applier syncs)"

test_summary
