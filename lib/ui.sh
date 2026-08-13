#!/bin/bash
# Operator-facing UI mode for shared prompt/picker engines.
# setup  = first install / full wizard (optional picks, skip is fine)
# edit   = post-install `config edit` (change current state, Esc = no change)
# Does not run on source.

if [ -n "${_ASSEMBLRR_UI_SOURCED:-}" ]; then
    return 0
fi
readonly _ASSEMBLRR_UI_SOURCED=1

ASSEMBLRR_UI_MODE="${ASSEMBLRR_UI_MODE:-setup}"
FZF_SELECT_STATUS="${FZF_SELECT_STATUS:-}"

ui_mode() {
    echo "${ASSEMBLRR_UI_MODE:-setup}"
}

ui_is_edit() {
    [ "${ASSEMBLRR_UI_MODE:-setup}" = "edit" ]
}

ui_is_setup() {
    ! ui_is_edit
}

ui_set_mode() {
    case "${1:-}" in
        setup|edit) ASSEMBLRR_UI_MODE="$1" ;;
        *) ASSEMBLRR_UI_MODE="setup" ;;
    esac
}

# Two-line intro: setup copy, then edit copy.
ui_intro() {
    echo
    echo
    if ui_is_edit; then
        log_info "$2"
    else
        log_info "$1"
    fi
}

ui_note() {
    if ui_is_edit; then
        [ -n "${2:-}" ] && log_info "$2"
    else
        [ -n "${1:-}" ] && log_info "$1"
    fi
}

# Picker wrap-up after fzf_multi_select. Uses FZF_SELECT_STATUS.
# $1 = plural noun (indexers, providers)
ui_picker_done() {
    local noun="$1"
    case "${FZF_SELECT_STATUS:-}" in
        cancelled)
            if ui_is_edit; then
                log_info "Cancelled — no change."
            else
                log_info "Skipped ${noun}."
            fi
            ;;
        confirmed)
            if ui_is_setup; then
                local n=0
                case "$noun" in
                    indexers) n=${#SELECTED_INDEXERS[@]} ;;
                    providers) n=${#SELECTED_SUBTITLE_PROVIDERS[@]} ;;
                esac
                if [ "$n" -eq 0 ]; then
                    log_info "No ${noun} selected."
                fi
            fi
            ;;
    esac
}

ui_picker_cancelled() {
    [ "${FZF_SELECT_STATUS:-}" = "cancelled" ]
}
