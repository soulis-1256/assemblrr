#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Unit tests for bin/cli.sh (help, source-safety, archive validation, show_config)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../helpers.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

test_suite "cli.sh --help works without existing install tree"
help_out=$(HOME="$tmp" ASSEMBLRR_DIR="" bash "$REPO_ROOT/bin/cli.sh" --help)
assert_contains "$help_out" "Lifecycle:" "grouped help shows Lifecycle"
assert_contains "$help_out" "Configuration & Upgrades:" "grouped help shows Configuration"
assert_contains "$help_out" "Operations & Backups:" "grouped help shows Operations"
assert_contains "$help_out" "config [show|edit|apply]" "lists config subcommands"

help_short=$(HOME="$tmp" ASSEMBLRR_DIR="" bash "$REPO_ROOT/bin/cli.sh" -h)
assert_eq "$help_out" "$help_short" "-h matches --help deterministically"

test_suite "cli.sh can be sourced without running main or needing install dir"
# shellcheck source=/dev/null
source "$REPO_ROOT/bin/cli.sh"
INSTALL_DIR="$tmp/inst"
MEDIA_DIRECTORY="$tmp/media"
mkdir -p "$INSTALL_DIR" "$MEDIA_DIRECTORY"
cfg_out=$(ASSEMBLRR_SHOW_LEFTOVERS=0 show_config)
assert_contains "$cfg_out" "Media service:      jellyfin" "show_config displays jellyfin"
assert_contains "$cfg_out" "SABnzbd / Usenet:" "show_config displays new feature rows"

test_suite "validate_backup_archive rejects missing .env and path traversal"
bad_noenv="$tmp/noenv.tar.gz"
mkdir -p "$tmp/b1"
touch "$tmp/b1/foo.txt"
tar -czf "$bad_noenv" -C "$tmp/b1" .
assert_failure "rejects archive missing .env" validate_backup_archive "$bad_noenv"

bad_trav="$tmp/trav.tar.gz"
python3 - "$bad_trav" <<'PY'
import io, sys, tarfile
with tarfile.open(sys.argv[1], "w:gz") as tf:
    info = tarfile.TarInfo("../evil.txt")
    data = b"x"
    info.size = len(data)
    tf.addfile(info, io.BytesIO(data))
PY
assert_failure "rejects archive with .. traversal" validate_backup_archive "$bad_trav"

good_arc="$tmp/good.tar.gz"
mkdir -p "$tmp/b2"
echo "PUID=1000" > "$tmp/b2/.env"
tar -czf "$good_arc" -C "$tmp/b2" .
assert_success "accepts valid backup containing .env" validate_backup_archive "$good_arc"

test_suite "update_containers explains pinned images"
uc_fn=$(sed -n '/^update_containers()/,/^}/p' "$REPO_ROOT/bin/cli.sh")
assert_contains "$uc_fn" "pins core service image tags" "mentions pinned core images"
assert_contains "$uc_fn" "upgrade" "points users to assemblrr upgrade"

test_suite "read_prompt 1-arg REPLY and interactive uninstall_app cancel"
REPLY=""
read_prompt "Confirm: " <<< "yes"
assert_eq "yes" "$REPLY" "1-arg read_prompt populates REPLY under set -u"
uninst_out=$(ASSEMBLRR_SHOW_LEFTOVERS=0 HOME="$tmp" uninstall_app <<< "no" 2>&1)
assert_contains "$uninst_out" "Uninstall cancelled." "1-arg read_prompt in uninstall_app cancels cleanly"
assert_true "INSTALL_DIR preserved on cancel" "[ -d \"$INSTALL_DIR\" ]"
uninst_fn=$(sed -n '/^uninstall_app()/,/^}/p' "$REPO_ROOT/bin/cli.sh")
assert_not_contains "$uninst_fn" "Type the full path" "does not require typing full paths"
assert_contains "$uninst_fn" "wait_while" "shows live spinner while stopping containers"

test_suite "status --help documents --all and --docker"
status_help=$(check_status --help)
assert_contains "$status_help" "--all" "status help documents --all"
assert_contains "$status_help" "--docker" "status help documents --docker"

test_summary
