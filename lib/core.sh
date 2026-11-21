#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# assemblrr core facade — sources modular core libraries

if [ -n "${_ASSEMBLRR_CORE_SOURCED:-}" ]; then
    return 0
fi
readonly _ASSEMBLRR_CORE_SOURCED=1

_core_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/log.sh
source "$_core_lib_dir/log.sh"
# shellcheck source=lib/tty.sh
source "$_core_lib_dir/tty.sh"
# shellcheck source=lib/paths.sh
source "$_core_lib_dir/paths.sh"
# shellcheck source=lib/fs.sh
source "$_core_lib_dir/fs.sh"
# shellcheck source=lib/docker.sh
source "$_core_lib_dir/docker.sh"
