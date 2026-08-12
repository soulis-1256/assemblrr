#!/bin/bash
# fzf-based TUI for selections (Prowlarr indexers, Bazarr providers, languages)
# Provides reusable fzf selection patterns for assemblrr.
# Sets SELECTED_INDEXERS / SELECTED_SUBTITLE_PROVIDERS arrays.
# Usage: source lib/fzf-tui.sh; configure_indexers "$api_key"

set -euo pipefail

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

# --- Generic multi-select fzf ---
# Args: $1 = tab-separated list lines
#       $2 = prompt (optional)
#       $3 = header (optional)
#       $4 = result array name (optional; default SELECTED_INDEXERS)
#       $5 = noun for log messages (optional; default "item")
# Appends selected first-column values into the named array.
fzf_multi_select() {
    local data="$1"
    local prompt="${2:-Select items> }"
    local header="${3:-Enter/TAB=toggle  Ctrl-O=confirm  Esc=skip}"
    local result_var="${4:-SELECTED_INDEXERS}"
    local noun="${5:-item}"
    local has_tty=false
    local -n _fzf_result_ref="$result_var"

    _fzf_has_tty && has_tty=true

    if [ -z "$data" ]; then
        return 1
    fi

    if _fzf_can_render && $has_tty; then
        local selected
        selected=$(echo "$data" | fzf \
            --multi \
            --prompt="$prompt" \
            --delimiter='\t' \
            --with-nth=1..2 \
            --bind='enter:toggle' \
            --bind='tab:toggle' \
            --bind='ctrl-o:accept' \
            --header="$header" \
            --height=80% \
            --layout=reverse \
            --border \
            2>/dev/null | cut -f1 || true)

        if [ -n "$selected" ]; then
            while IFS= read -r idx; do
                [ -n "$idx" ] && _fzf_result_ref+=("$idx")
            done <<< "$selected"
            echo "Selected ${#_fzf_result_ref[@]} ${noun}(s): $(IFS=,; echo "${_fzf_result_ref[*]}")" >&2
        else
            echo "No ${noun}s selected." >&2
        fi
    else
        echo "No interactive terminal available — listing available ${noun}s." >&2
        echo "$data" | cut -f1 | head -40 | sed 's/^/  /' >&2
        echo "Enter ${noun} names separated by spaces (or blank to skip):" >&2
        read -r input_line || true
        for idx in $input_line; do
            _fzf_result_ref+=("$idx")
        done
    fi
}

# --- Prowlarr Indexer Selection ---
configure_indexers() {
    local provided_key="$1"
    if [ "${ASSEMBLRR_NONINTERACTIVE:-0}" = "1" ]; then
        echo "Skipping optional Prowlarr indexer selection (non-interactive)." >&2
        return 0
    fi
    echo >&2
    log_info "Optional: configure Prowlarr indexers now, or skip and use the Prowlarr UI later." >&2
    log_info "Only enable sources you are authorized to use." >&2

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
        local formatted
        formatted=$(echo "$indexer_data" | jq -r 'sort_by(.name | ascii_downcase)[] | "\(.name)\t\(if .enable then "" else "[P]" end)\t\(.description // "" | gsub("\n"; " ") | .[0:120])"' 2>/dev/null)
        fzf_multi_select "$formatted" \
            "Prowlarr indexers (optional)> " \
            "Enter/TAB=toggle  Ctrl-O=confirm  Esc=skip  [P]=private" \
            SELECTED_INDEXERS \
            "indexer"
    else
        echo "Prowlarr is not responding — skipping optional indexer configuration." >&2
        echo "You can configure indexers later in the Prowlarr web UI if needed." >&2
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
    if [ "${ASSEMBLRR_NONINTERACTIVE:-0}" = "1" ]; then
        echo "Skipping optional Bazarr provider selection (non-interactive)." >&2
        return 0
    fi
    echo >&2
    log_info "Optional: configure Bazarr subtitle providers now, or skip and use the Bazarr UI later." >&2
    echo "Catalog comes from the running Bazarr image. Nothing is enabled unless you select it." >&2
    echo "OpenSubtitles.com is enabled automatically only if you saved credentials during setup." >&2

    local names formatted
    if ! names=$(_list_bazarr_providers_from_container); then
        echo "Bazarr container not available — skipping optional provider configuration." >&2
        echo "You can configure providers later in the Bazarr web UI if needed." >&2
        return 0
    fi
    if [ -z "$names" ]; then
        echo "No providers found in Bazarr image — skipping." >&2
        return 0
    fi

    formatted=$(echo "$names" | awk '{print $1 "\t"}')
    fzf_multi_select "$formatted" \
        "Bazarr providers (optional)> " \
        "Enter/TAB=toggle  Ctrl-O=confirm  Esc=skip (enable none)" \
        SELECTED_SUBTITLE_PROVIDERS \
        "provider"
}
