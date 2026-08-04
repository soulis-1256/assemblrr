#!/bin/bash
# fzf-based TUI for selections (Prowlarr indexers, Jellyfin languages)
# Provides reusable fzf selection patterns for assemblrr.
# Sets PUBLIC_INDEXERS array for indexers.
# Usage: source lib/fzf-tui.sh; configure_indexers "$api_key"

set -euo pipefail

PUBLIC_INDEXERS=()

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

# --- Generic multi-select fzf (for indexers) ---
# Args: $1 = data_source (jq expression or curl), $2 = awk filter
# Sets PUBLIC_INDEXERS array
fzf_multi_select() {
    local data="$1"
    local has_tty=false

    _fzf_has_tty && has_tty=true

    if [ -z "$data" ]; then
        return 1
    fi

    if _fzf_can_render && $has_tty; then
        # fzf TUI: multi-select with toggle+confirm
        local selected
        selected=$(echo "$data" | fzf \
            --multi \
            --prompt="Select indexers> " \
            --delimiter='\t' \
            --with-nth=1..2 \
            --bind='enter:toggle' \
            --bind='tab:toggle' \
            --bind='ctrl-o:accept' \
            --header='Enter/TAB=toggle  Ctrl-O=confirm  Esc=skip  [P]=private' \
            --height=80% \
            --layout=reverse \
            --border \
            2>/dev/null | cut -f1 || true)

        if [ -n "$selected" ]; then
            while IFS= read -r idx; do
                [ -n "$idx" ] && PUBLIC_INDEXERS+=("$idx")
            done <<< "$selected"
            echo "Selected ${#PUBLIC_INDEXERS[@]} indexer(s): $(IFS=,; echo "${PUBLIC_INDEXERS[*]}")" >&2
        else
            echo "No indexers selected." >&2
        fi
    else
        # No TTY or no fzf — show top public indexers and prompt
        echo "No interactive terminal available — listing popular public indexers." >&2
        echo "$data" | jq -r 'sort_by(.name | ascii_downcase) | .[0:20][] | "  \(.name)"' 2>/dev/null >&2
        echo "Enter indexer names separated by spaces (or blank to skip):" >&2
        read -r input_line || true
        for idx in $input_line; do
            PUBLIC_INDEXERS+=("$idx")
        done
    fi
}

# --- Prowlarr Indexer Selection ---
configure_indexers() {
    local provided_key="$1"
    echo >&2
    log_warning "Time to add some Indexers into Prowlarr." >&2

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
        fzf_multi_select "$formatted"
    else
        echo "Prowlarr is not responding — skipping indexer selection." >&2
        echo "You can add indexers later via the Prowlarr web UI." >&2
    fi
}
