#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# assemblrr *arr service wiring facade — sources focused modules

if [ -n "${_ASSEMBLRR_ARR_SOURCED:-}" ]; then
    return 0
fi
readonly _ASSEMBLRR_ARR_SOURCED=1

_arr_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/quality.sh
[ -f "$_arr_dir/quality.sh" ] && source "$_arr_dir/quality.sh"
# shellcheck source=lib/qbit.sh
source "$_arr_dir/qbit.sh"
# shellcheck source=lib/arr_common.sh
source "$_arr_dir/arr_common.sh"
# shellcheck source=lib/arr_quality.sh
source "$_arr_dir/arr_quality.sh"
# shellcheck source=lib/prowlarr.sh
source "$_arr_dir/prowlarr.sh"
# shellcheck source=lib/arr_import.sh
source "$_arr_dir/arr_import.sh"
