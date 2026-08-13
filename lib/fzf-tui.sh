#!/bin/bash
# fzf-based TUI for selections (Prowlarr indexers, Bazarr providers, languages)
# Provides reusable fzf selection patterns for assemblrr.
# Sets SELECTED_INDEXERS / SELECTED_SUBTITLE_PROVIDERS arrays.
# Usage: source lib/fzf-tui.sh; configure_indexers "$api_key"

set -euo pipefail

_fzf_tui_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[ -f "$_fzf_tui_dir/ui.sh" ] && source "$_fzf_tui_dir/ui.sh"

SELECTED_INDEXERS=()
SELECTED_SUBTITLE_PROVIDERS=()

# --- TTY detection (reused across functions) ---
_fzf_has_tty() {
    [ -t 0 ] && [ -t 2 ]
}

_fzf_can_render() {
    command -v fzf &>/dev/null && echo "test" | timeout 1 fzf --height=5 --no-mouse --filter="test" &>/dev/null
}

# --- Generic single-select fzf (for languages, etc.) ---
# Args: $1 = url, $2 = awk filter, $3 = default (on failure)
# Output: selected value or $3
# Pre-selects "None" by default; Enter confirms, arrows change selection
fzf_single_select() {
    local url="$1"
    local awk_filter="$2"
    local default="${3:-}"

    local has_tty=false
    _fzf_has_tty && has_tty=true

    # Download and parse
    local data
    data=$(curl -sf --connect-timeout 5 "$url" 2>/dev/null | awk -F'|' "$awk_filter" | sort -k2) || true

    if [ -z "$data" ]; then
        [ -n "$default" ] && echo "$default"
        return 0
    fi

    # Prepend "None" as first option (pre-selected)
    data=$'None\tNo subtitle language preference\n'"$data"

    # If no TTY, show list and prompt
    if ! $has_tty; then
        echo "$data" | head -25 >&2
        echo "Enter selection (default: None): " >&2
        read -r input || true
        if [ -z "$input" ]; then
            [ -n "$default" ] && echo "$default"
        else
            echo "$input" | cut -f1
        fi
        return 0
    fi

    # fzf single-select with None pre-selected
    local selected
    selected=$(echo "$data" | fzf \
        --prompt="Subtitle language> " \
        --height=60% \
        --reverse \
        --border \
        --header="↑↓=navigate  Enter=confirm  Esc=default" \
        --scrollbar='│' \
        2>/dev/null | cut -f1) || true

    if [ -z "$selected" ] || [ "$selected" = "None" ]; then
        [ -n "$default" ] && echo "$default" || echo ""
    else
        echo "$selected"
    fi
}

# Format Prowlarr schema JSON + existing-name JSON array into TSV menu rows:
#   name<TAB>badges<TAB>description
# Badges: [already enabled], [P] private (schema enable=false).
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

# fzf --bind start:… string that pre-selects rows whose first TSV field is in $2
# (newline-separated names). Empty if nothing matches.
fzf_preselect_start_bind() {
    local data="$1"
    local names="$2"
    [ -n "$data" ] && [ -n "$names" ] || return 0
    local i=0 name binds=""
    while IFS=$'\t' read -r name _; do
        i=$((i + 1))
        [ -n "$name" ] || continue
        if printf '%s\n' "$names" | grep -q -F -x "$name"; then
            if [ -n "$binds" ]; then
                binds="${binds}+pos(${i})+select"
            else
                binds="pos(${i})+select"
            fi
        fi
    done <<< "$data"
    [ -n "$binds" ] && echo "start:${binds}"
}

# --- Generic multi-select fzf ---
# Args: $1 = tab-separated list lines
#       $2 = prompt (optional)
#       $3 = header (optional)
#       $4 = result array name (optional; default SELECTED_INDEXERS)
#       $5 = noun for log messages (optional; default "item")
#       $6 = newline-separated names to pre-select (optional)
# Sets FZF_SELECT_STATUS=confirmed|cancelled.
# Return 0 on confirm (array may be empty), 1 on cancel (Esc).
# Appends selected first-column values into the named array.
fzf_multi_select() {
    local data="$1"
    local prompt="${2:-Select items> }"
    local header="${3:-Enter/TAB=toggle  Ctrl-O=confirm  Esc=cancel}"
    local result_var="${4:-SELECTED_INDEXERS}"
    local noun="${5:-item}"
    local preselect_names="${6:-}"
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
            --bind='enter:toggle'
            --bind='tab:toggle'
            --bind='ctrl-o:accept'
            --header="$header"
            --height=80%
            --layout=reverse
            --border
        )
        local start_bind
        start_bind=$(fzf_preselect_start_bind "$data" "$preselect_names")
        if [ -n "$start_bind" ]; then
            fzf_args+=(--sync --bind="$start_bind")
        fi
        selected=$(echo "$data" | fzf "${fzf_args[@]}" 2>/dev/null) || fzf_rc=$?
        if [ "$fzf_rc" -ne 0 ]; then
            FZF_SELECT_STATUS="cancelled"
            return 1
        fi
        selected=$(printf '%s\n' "$selected" | cut -f1)
        FZF_SELECT_STATUS="confirmed"
        if [ -n "$selected" ]; then
            while IFS= read -r idx; do
                [ -n "$idx" ] && _fzf_result_ref+=("$idx")
            done <<< "$selected"
            echo "Selected ${#_fzf_result_ref[@]} ${noun}(s): $(IFS=,; echo "${_fzf_result_ref[*]}")" >&2
        fi
        return 0
    fi

    echo "No interactive terminal available — listing available ${noun}s." >&2
    echo "$data" | cut -f1 | head -40 | sed 's/^/  /' >&2
    echo "Enter ${noun} names separated by spaces (or blank to cancel):" >&2
    local input_line=""
    read -r input_line || true
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
    FZF_SELECT_STATUS="cancelled"
    if [ "${ASSEMBLRR_NONINTERACTIVE:-0}" = "1" ]; then
        log_info "Skipping Prowlarr indexer picker (non-interactive)."
        return 0
    fi
    ui_intro \
        "Optional: pick Prowlarr indexers now, or skip and use the Prowlarr UI later." \
        "Add or remove Prowlarr indexers. Esc keeps the current set."
    log_info "Only enable sources you are authorized to use."

    # Try to fetch indexer list from a running Prowlarr instance
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
            "http://localhost:9696/api/v1/indexer/schema" 2>/dev/null || true)
    fi

    if [ -n "$indexer_data" ] && echo "$indexer_data" | jq -e 'type == "array"' >/dev/null 2>&1; then
        local existing_indexers existing_json formatted preselect_names
        existing_indexers=$(curl -s --connect-timeout 3 \
            -H "X-Api-Key: $prowlarr_key" \
            "http://localhost:9696/api/v1/indexer" 2>/dev/null || true)
        existing_json=$(echo "${existing_indexers:-}" | jq -c '[.[].name // empty]' 2>/dev/null || echo '[]')
        [ -n "$existing_json" ] || existing_json='[]'
        formatted=$(format_prowlarr_indexer_menu "$indexer_data" "$existing_json")
        preselect_names=$(echo "$existing_json" | jq -r '.[]' 2>/dev/null || true)
        local prompt header
        if ui_is_edit; then
            prompt="Prowlarr indexers> "
            header="Enter/TAB=toggle  Ctrl-O=save  Esc=cancel  [P]=private"
        else
            prompt="Prowlarr indexers (optional)> "
            header="Enter/TAB=toggle  Ctrl-O=confirm  Esc=skip  [P]=private"
        fi
        fzf_multi_select "$formatted" \
            "$prompt" \
            "$header" \
            SELECTED_INDEXERS \
            "indexer" \
            "$preselect_names" || true
        ui_picker_done "indexers"
    else
        if ui_is_edit; then
            log_info "Prowlarr is not responding — cannot edit indexers."
        else
            log_info "Prowlarr is not responding — skipping optional indexer setup."
            log_info "You can add indexers later with: ${APP_CLI_NAME:-assemblrr} config edit indexers"
        fi
    fi
}

# List subtitle provider keys from the running Bazarr container (Bazarr's catalog, not ours).
# Skips internal modules only (mixins/utils/helpers), not branded providers.
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

# --- Bazarr subtitle provider selection (live from container, same idea as Prowlarr) ---
configure_subtitle_providers() {
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
            log_info "You can set providers later with: ${APP_CLI_NAME:-assemblrr} config edit providers"
        fi
        return 0
    fi
    if [ -z "$names" ]; then
        log_info "No providers found in the Bazarr image — skipping."
        return 0
    fi

    formatted=$(echo "$names" | awk '{print $1 "\t"}')
    local prompt header
    if ui_is_edit; then
        prompt="Bazarr providers> "
        header="Enter/TAB=toggle  Ctrl-O=save  Esc=cancel"
    else
        prompt="Bazarr providers (optional)> "
        header="Enter/TAB=toggle  Ctrl-O=confirm  Esc=skip (enable none)"
    fi
    fzf_multi_select "$formatted" \
        "$prompt" \
        "$header" \
        SELECTED_SUBTITLE_PROVIDERS \
        "provider" || true
    ui_picker_done "providers"
}
