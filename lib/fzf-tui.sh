#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# fzf-based TUI for selections (Prowlarr indexers, Bazarr providers, languages, paths)
# Sets SELECTED_INDEXERS / SELECTED_SUBTITLE_PROVIDERS / SELECTED_SUBTITLE_LANGUAGES arrays.
# Does not set -euo pipefail when sourced.

if [ -n "${_ASSEMBLRR_FZF_TUI_SOURCED:-}" ]; then
    return 0
fi
readonly _ASSEMBLRR_FZF_TUI_SOURCED=1

_fzf_tui_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[ -f "$_fzf_tui_dir/ui.sh" ] && source "$_fzf_tui_dir/ui.sh"
# shellcheck source=/dev/null
[ -f "$_fzf_tui_dir/languages.sh" ] && source "$_fzf_tui_dir/languages.sh"

SELECTED_INDEXERS=()
SELECTED_SUBTITLE_PROVIDERS=()
SELECTED_SUBTITLE_LANGUAGES=()

_fzf_has_tty() {
    [ -t 0 ] && [ -t 2 ]
}

_fzf_can_render() {
    command -v fzf &>/dev/null && echo "test" | timeout 1 fzf --height=5 --no-mouse --filter="test" &>/dev/null
}

# True when installed fzf >= major.minor (handles older distro fzf like 0.29 on Ubuntu 22.04).
_fzf_version_ge() {
    local req_maj="${1:-0}" req_min="${2:-0}" ver maj min
    ver=$(fzf --version 2>/dev/null | awk '{print $1}' | sed 's/[^0-9.].*//')
    maj="${ver%%.*}"
    min="${ver#*.}"; min="${min%%.*}"
    [[ "$maj" =~ ^[0-9]+$ ]] || maj=0
    [[ "$min" =~ ^[0-9]+$ ]] || min=0
    [ "$maj" -gt "$req_maj" ] && return 0
    [ "$maj" -eq "$req_maj" ] && [ "$min" -ge "$req_min" ]
}

# TSV: key<TAB>title<TAB>detail<TAB>install<TAB>media
# Extra args after the two defaults are injected storage roots (tests).
format_path_menu() {
    local def_install="$1"
    local def_media="$2"
    shift 2
    local app="${APP_NAME:-assemblrr}"
    local -a roots=()
    local root title free

    if [ "$#" -gt 0 ]; then
        roots=("$@")
    else
        mapfile -t roots < <(list_storage_roots)
    fi

    printf '%s\t%s\t%s\t%s\t%s\n' \
        "home" "Home (default)" "${def_install}  +  ${def_media}" \
        "$def_install" "$def_media"

    for root in "${roots[@]}"; do
        [ -n "$root" ] || continue
        root="${root%/}"
        [ "$root" = "${HOME:-}" ] && continue
        title=$(storage_root_label "$root")
        free=$(storage_free_label "$root")
        printf '%s\t%s\t%s\t%s\t%s\n' \
            "all:${root}" "${title} — everything here" \
            "${root}/${app}  +  ${root}/${app}-media${free}" \
            "${root}/${app}" "${root}/${app}-media"
        printf '%s\t%s\t%s\t%s\t%s\n' \
            "media:${root}" "${title} — media only (recommended)" \
            "${def_install}  +  ${root}/${app}-media${free}" \
            "$def_install" "${root}/${app}-media"
    done

    printf '%s\t%s\t%s\t%s\t%s\n' \
        "browse" "Browse for a folder..." \
        "Pick a parent, then choose everything vs media-only" "" ""
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "custom" "Type paths..." \
        "Enter install and media directories yourself" "" ""
}

_fzf_select_path_row() {
    local def_install="${1:-}"
    local def_media="${2:-}"
    local data selected="" gen=""
    poke_wsl_automounts 2>/dev/null || true
    data=$(format_path_menu "$def_install" "$def_media")
    if _fzf_can_render && _fzf_has_tty; then
        gen=$(mktemp)
        cat > "$gen" <<EOF
#!/bin/bash
set -euo pipefail
# shellcheck source=/dev/null
source $(printf '%q' "$_fzf_tui_dir/core.sh")
# shellcheck source=/dev/null
source $(printf '%q' "$_fzf_tui_dir/fzf-tui.sh")
poke_wsl_automounts 2>/dev/null || true
format_path_menu $(printf '%q' "$def_install") $(printf '%q' "$def_media")
EOF
        chmod +x "$gen"
        selected=$(echo "$data" | fzf \
            --delimiter=$'\t' \
            --with-nth=2,3 \
            --prompt="Install location> " \
            --header="↑↓=navigate  Enter=confirm  r=refresh drives  Esc=home default" \
            --bind="r:reload($gen)+clear-query" \
            --height=60% \
            --reverse \
            --border \
            2>/dev/null) || true
        rm -f "$gen"
        echo "$selected"
        return 0
    fi

    local i=0 title detail
    echo "$data" | while IFS=$'\t' read -r _ title detail _; do
        i=$((i + 1))
        printf '  %d) %s\n      %s\n' "$i" "$title" "$detail" >&2
    done
    local input=""
    read_prompt "Enter number (default: 1 = home): " input
    input="${input:-1}"
    if [[ "$input" =~ ^[0-9]+$ ]]; then
        echo "$data" | awk -F '\t' -v n="$input" 'NR==n {print}'
    fi
}

_prompt_parent_usage() {
    local parent="$1"
    local def_install="$2"
    local app="${APP_NAME:-assemblrr}"
    local choice=""
    echo >&2
    echo "Use ${parent} for:" >&2
    echo "  1) Media only (recommended) — config stays in ${def_install}" >&2
    echo "  2) Everything — ${parent}/${app} + ${parent}/${app}-media" >&2
    read_prompt "Choose [1]: " choice
    choice="${choice:-1}"
    case "$choice" in
        2)
            install_directory="${parent}/${app}"
            media_directory="${parent}/${app}-media"
            ;;
        *)
            install_directory="$def_install"
            media_directory="${parent}/${app}-media"
            ;;
    esac
}

_browse_parent_folder() {
    local app="${APP_NAME:-assemblrr}"
    local -a roots=()
    local r selected="" list
    list=$(mktemp)
    mapfile -t roots < <(list_storage_roots)
    {
        printf '%s\n' "${HOME:-/}"
        printf '%s\n' "${roots[@]}"
        for r in "${HOME:-/}" "${roots[@]}"; do
            [ -d "$r" ] || continue
            if [ "$r" = "/mnt/c" ]; then
                find "$r" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sed -n '1,80p' || true
            else
                find "$r" -mindepth 1 -maxdepth 2 -type d 2>/dev/null | sed -n '1,200p' || true
            fi
        done
    } | sort -u > "$list"

    if _fzf_can_render && _fzf_has_tty; then
        selected=$(fzf \
            --prompt="Parent folder> " \
            --header="This folder will contain ${app} / ${app}-media. Esc=cancel" \
            --height=60% --reverse --border \
            < "$list" 2>/dev/null) || true
    else
        read_prompt "Enter a parent folder path (blank to cancel): " selected
    fi
    rm -f "$list"
    echo "$selected"
}

_prompt_typed_paths() {
    local def_install="$1"
    local def_media="$2"
    read_prompt "Installation directory? [${def_install}]: " install_directory
    install_directory=${install_directory:-$def_install}
    install_directory=$(expand_path "$install_directory")
    read_prompt "Media directory? [${def_media}]: " media_directory
    media_directory=${media_directory:-$def_media}
    media_directory=$(expand_path "$media_directory")
}

# Sets install_directory and media_directory from an fzf (or numbered) menu.
pick_storage_paths() {
    local def_install="${APP_DEFAULT_INSTALL_DIR:-$HOME/${APP_NAME:-assemblrr}}"
    local def_media="${APP_DEFAULT_MEDIA_DIR:-$HOME/${APP_NAME:-assemblrr}-media}"
    local row key parent

    if [ "${ASSEMBLRR_NONINTERACTIVE:-0}" = "1" ]; then
        install_directory="$def_install"
        media_directory="$def_media"
        return 0
    fi

    while true; do
        row=$(_fzf_select_path_row "$def_install" "$def_media")
        if [ -z "$row" ]; then
            install_directory="$def_install"
            media_directory="$def_media"
            return 0
        fi
        key=$(printf '%s\n' "$row" | cut -f1)
        case "$key" in
            home|all:*|media:*)
                install_directory=$(printf '%s\n' "$row" | cut -f4)
                media_directory=$(printf '%s\n' "$row" | cut -f5)
                return 0
                ;;
            browse)
                parent=$(_browse_parent_folder)
                if [ -z "$parent" ]; then
                    continue
                fi
                parent=$(expand_path "$parent")
                if [ ! -d "$parent" ]; then
                    log_warning "Not a directory: $parent"
                    continue
                fi
                _prompt_parent_usage "$parent" "$def_install"
                return 0
                ;;
            custom)
                _prompt_typed_paths "$def_install" "$def_media"
                return 0
                ;;
            *)
                install_directory="$def_install"
                media_directory="$def_media"
                return 0
                ;;
        esac
    done
}

# Single-select from TSV rows (first column is the value).
fzf_single_select_data() {
    local data="$1"
    local prompt="${2:-Select> }"
    local header="${3:-↑↓=navigate  Enter=confirm  Esc=default}"
    local default="${4:-}"

    if [ -z "$data" ]; then
        echo "$default"
        return 0
    fi

    if [ -n "$default" ]; then
        local preferred_row rest
        preferred_row=$(printf '%s\n' "$data" | awk -F'\t' -v d="$default" '$1 == d { print; exit }')
        rest=$(printf '%s\n' "$data" | awk -F'\t' -v d="$default" '$1 != d { print }')
        if [ -n "$preferred_row" ]; then
            data="$preferred_row"
            [ -n "$rest" ] && data+=$'\n'"$rest"
        fi
    fi

    if ! _fzf_can_render || ! _fzf_has_tty; then
        echo "$data" | head -25 >&2
        local input=""
        read_prompt "Enter selection (default: ${default:-first}): " input
        if [ -z "$input" ]; then
            if [ -n "$default" ]; then
                echo "$default"
            else
                echo "$data" | head -1 | cut -f1
            fi
        else
            echo "$input" | cut -f1
        fi
        return 0
    fi

    local selected
    selected=$(echo "$data" | fzf \
        --prompt="$prompt" \
        --height=40% \
        --reverse \
        --border \
        --header="$header" \
        --delimiter=$'\t' \
        --with-nth=1..2 \
        2>/dev/null | cut -f1) || true

    if [ -z "$selected" ]; then
        echo "$default"
    else
        echo "$selected"
    fi
}

# Format Prowlarr schema JSON + existing-name JSON array into TSV menu rows:
#   name<TAB>badges<TAB>description
format_prowlarr_indexer_menu() {
    local schema="$1"
    local existing_json="${2:-[]}"
    [ -n "$existing_json" ] || existing_json='[]'
    echo "$schema" | jq -r --argjson existing "$existing_json" '
        sort_by(.name | ascii_downcase)[] |
        . as $i |
        (($existing | index($i.name)) != null) as $on |
        ($i.enable | not) as $priv |
        [
            $i.name,
            ([if $on then "[already enabled]" else empty end, if $priv then "[P]" else empty end] | join(" ")),
            (($i.description // "") | gsub("\n"; " ") | .[0:120])
        ] | @tsv
    ' 2>/dev/null || true
}

# Single-pass awk builder for fzf --bind start:... pre-selection.
fzf_preselect_start_bind() {
    local data="$1"
    local names="$2"
    [ -n "$data" ] && [ -n "$names" ] || return 0
    awk -v names="$names" '
        BEGIN {
            n = split(names, arr, /\n/)
            for (k = 1; k <= n; k++) {
                if (arr[k] != "") want[arr[k]] = 1
            }
            binds = ""
        }
        {
            split($0, f, "\t")
            if (f[1] != "" && (f[1] in want)) {
                tok = "pos(" NR ")+select"
                binds = (binds == "" ? tok : binds "+" tok)
            }
        }
        END {
            if (binds != "") print "start:" binds
        }
    ' <<< "$data"
}

# --- Generic multi-select fzf ---
# Args: $1 = tab-separated list lines
#       $2 = prompt, $3 = header, $4 = result array var, $5 = noun, $6 = preselect names, $7 = optional preview col
# Keybindings: Tab = toggle, Enter = confirm, Esc = cancel.
fzf_multi_select() {
    local data="$1"
    local prompt="${2:-Select items> }"
    local header="${3:-TAB=toggle  Enter=confirm  Esc=cancel}"
    local result_var="${4:-SELECTED_INDEXERS}"
    local noun="${5:-item}"
    local preselect_names="${6:-}"
    local show_preview="${7:-0}"
    local has_tty=false
    local -n _fzf_result_ref="$result_var"
    FZF_SELECT_STATUS="cancelled"

    _fzf_has_tty && has_tty=true

    if [ -z "$data" ]; then
        return 1
    fi

    if _fzf_can_render && $has_tty; then
        local selected fzf_rc=0
        local -a fzf_args=(
            --multi
            --prompt="$prompt"
            --delimiter=$'\t'
            --with-nth=1..2
            --bind='tab:toggle'
            --bind='enter:accept'
            --header="$header"
            --height=80%
            --layout=reverse
            --border
        )
        if [ "$show_preview" = "1" ] && _fzf_version_ge 0 29; then
            fzf_args+=(--preview='echo {3}' --preview-window='down,3,wrap')
        fi
        # start:pos(...) requires fzf >= 0.36; skip cleanly on older distros (e.g. Ubuntu 22.04 0.29)
        if _fzf_version_ge 0 36; then
            local start_bind
            start_bind=$(fzf_preselect_start_bind "$data" "$preselect_names")
            if [ -n "$start_bind" ]; then
                fzf_args+=(--sync --bind="$start_bind")
            fi
        fi
        selected=$(echo "$data" | fzf "${fzf_args[@]}" 2>/dev/null) || fzf_rc=$?
        if [ "$fzf_rc" -ne 0 ]; then
            FZF_SELECT_STATUS="cancelled"
            return 1
        fi
        selected=$(printf '%s\n' "$selected" | cut -f1)
        FZF_SELECT_STATUS="confirmed"
        if [ -n "$selected" ]; then
            local idx
            while IFS= read -r idx; do
                [ -n "$idx" ] && _fzf_result_ref+=("$idx")
            done <<< "$selected"
            echo "Selected ${#_fzf_result_ref[@]} ${noun}(s): $(IFS=,; echo "${_fzf_result_ref[*]}")" >&2
        fi
        return 0
    fi

    echo "No interactive fzf terminal available — listing available ${noun}s." >&2
    echo "$data" | cut -f1 | head -40 | sed 's/^/  /' >&2
    local input_line="" idx
    read_prompt "Enter ${noun} names separated by spaces (or blank to cancel): " input_line
    if [ -z "${input_line:-}" ]; then
        FZF_SELECT_STATUS="cancelled"
        return 1
    fi
    FZF_SELECT_STATUS="confirmed"
    for idx in $input_line; do
        _fzf_result_ref+=("$idx")
    done
    return 0
}

# --- Prowlarr Indexer Selection ---
configure_indexers() {
    local provided_key="$1"
    local host="${API_HOST:-127.0.0.1}"
    FZF_SELECT_STATUS="cancelled"
    if [ "${ASSEMBLRR_NONINTERACTIVE:-0}" = "1" ]; then
        log_info "Skipping Prowlarr indexer picker (non-interactive)."
        return 0
    fi
    ui_intro \
        "Optional: pick Prowlarr indexers now, or skip and use the Prowlarr UI later." \
        "Add or remove Prowlarr indexers. Esc keeps the current set."
    log_info "Only enable sources you are authorized to use."

    local prowlarr_key="${provided_key:-}"
    local indexer_data=""

    if [ -z "$prowlarr_key" ]; then
        if command -v docker &>/dev/null && docker ps --format '{{.Names}}' 2>/dev/null | grep -q prowlarr; then
            prowlarr_key=$(docker exec prowlarr cat /config/config.xml 2>/dev/null | sed -n 's/.*<ApiKey>\(.*\)<\/ApiKey>.*/\1/p' | head -1 || true)
        fi
    fi

    if [ -n "$prowlarr_key" ]; then
        indexer_data=$(curl -s --connect-timeout 3 \
            -H "X-Api-Key: $prowlarr_key" \
            "http://${host}:9696/api/v1/indexer/schema" 2>/dev/null || true)
    fi

    if [ -n "$indexer_data" ] && echo "$indexer_data" | jq -e 'type == "array"' >/dev/null 2>&1; then
        local existing_indexers existing_json formatted preselect_names
        existing_indexers=$(curl -s --connect-timeout 3 \
            -H "X-Api-Key: $prowlarr_key" \
            "http://${host}:9696/api/v1/indexer" 2>/dev/null || true)
        existing_json=$(echo "${existing_indexers:-}" | jq -c '[.[].name // empty]' 2>/dev/null || echo '[]')
        [ -n "$existing_json" ] || existing_json='[]'
        formatted=$(format_prowlarr_indexer_menu "$indexer_data" "$existing_json")
        preselect_names=$(echo "$existing_json" | jq -r '.[]' 2>/dev/null || true)
        local prompt header
        if ui_is_edit; then
            prompt="Prowlarr indexers> "
            header="TAB=toggle  Enter=save  Esc=cancel  [P]=private"
        else
            prompt="Prowlarr indexers (optional)> "
            header="TAB=toggle  Enter=confirm  Esc=skip  [P]=private"
        fi
        fzf_multi_select "$formatted" \
            "$prompt" \
            "$header" \
            SELECTED_INDEXERS \
            "indexer" \
            "$preselect_names" \
            1 || true
        ui_picker_done "indexers"
    else
        if ui_is_edit; then
            log_info "Prowlarr is not responding — cannot edit indexers."
        else
            log_info "Prowlarr is not responding — skipping optional indexer setup."
            log_info "You can add indexers later with: ${APP_CLI_NAME:-assemblrr} config edit"
        fi
    fi
}

_list_bazarr_providers_from_container() {
    local dirs=(
        /app/bazarr/bin/custom_libs/subliminal_patch/providers
        /app/bazarr/custom_libs/subliminal_patch/providers
    )
    local d names=""
    if ! command -v docker &>/dev/null; then
        return 1
    fi
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'bazarr'; then
        return 1
    fi
    for d in "${dirs[@]}"; do
        names=$(docker exec bazarr sh -c \
            "ls -1 '${d}'/*.py 2>/dev/null | xargs -n1 basename 2>/dev/null" 2>/dev/null || true)
        if [ -n "$names" ]; then
            echo "$names" | sed 's/\.py$//' | grep -vE '^(mixins|utils|avistaz_network|_.*)$' | sort -u
            return 0
        fi
    done
    return 1
}

configure_subtitle_providers() {
    local host="${API_HOST:-127.0.0.1}"
    SELECTED_SUBTITLE_PROVIDERS=()
    FZF_SELECT_STATUS="cancelled"
    if [ "${ASSEMBLRR_NONINTERACTIVE:-0}" = "1" ]; then
        log_info "Skipping Bazarr provider picker (non-interactive)."
        return 0
    fi
    ui_intro \
        "Optional: pick Bazarr subtitle providers now, or skip and use the Bazarr UI later." \
        "Choose which Bazarr subtitle providers to enable. Esc keeps the current set."
    ui_note \
        "Catalog comes from the running Bazarr image. OpenSubtitles.com is enabled automatically only if you saved credentials." \
        "Catalog comes from the running Bazarr image."

    local names formatted
    if ! names=$(_list_bazarr_providers_from_container); then
        if ui_is_edit; then
            log_info "Bazarr is not running — cannot edit providers."
        else
            log_info "Bazarr is not running — skipping optional provider setup."
            log_info "You can set providers later with: ${APP_CLI_NAME:-assemblrr} config edit"
        fi
        return 0
    fi
    if [ -z "$names" ]; then
        log_info "No providers found in the Bazarr image — skipping."
        return 0
    fi

    formatted=$(echo "$names" | awk '{print $1 "\t"}')
    local prompt header preselect_names=""
    if ui_is_edit; then
        prompt="Bazarr providers> "
        header="TAB=toggle  Enter=save  Esc=cancel"
        if type _bazarr_config_file >/dev/null 2>&1 && type _bazarr_extract_apikey >/dev/null 2>&1; then
            local bcfg bkey
            bcfg=$(_bazarr_config_file 2>/dev/null || true)
            if [ -n "$bcfg" ]; then
                bkey=$(_bazarr_extract_apikey "$bcfg")
            fi
            if [ -n "${bkey:-}" ]; then
                preselect_names=$(curl -s --connect-timeout 5 \
                    -H "X-API-KEY: ${bkey}" \
                    "http://${host}:${BAZARR_PORT:-6767}/api/system/settings" \
                    2>/dev/null | jq -r '.general.enabled_providers[]? // empty' 2>/dev/null || true)
            fi
        fi
    else
        prompt="Bazarr providers (optional)> "
        header="TAB=toggle  Enter=confirm  Esc=skip"
    fi
    fzf_multi_select "$formatted" \
        "$prompt" \
        "$header" \
        SELECTED_SUBTITLE_PROVIDERS \
        "provider" \
        "$preselect_names" || true
    ui_picker_done "providers"
}
