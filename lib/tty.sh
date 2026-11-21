#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# assemblrr terminal input helpers (prompting, TTY drain, masked passwords)

if [ -n "${_ASSEMBLRR_TTY_SOURCED:-}" ]; then
    return 0
fi
readonly _ASSEMBLRR_TTY_SOURCED=1

# Discard a pending line on the tty (e.g., fzf's confirming Enter). Non-blocking.
flush_tty_input() {
    local __ft_junk
    [ -t 0 ] && [ -r /dev/tty ] || return 0
    while read -r -t 0.01 __ft_junk </dev/tty 2>/dev/null; do
        :
    done
    return 0
}

# Prompt and read a line cleanly (always -r, EOF-safe under set -e; defaults to REPLY).
read_prompt() {
    local prompt="$1"
    local __rp_var="${2:-REPLY}"
    local __rp_reply=""

    if [ -t 0 ] && [ -r /dev/tty ]; then
        read -r -p "$prompt" __rp_reply </dev/tty || true
    else
        read -r -p "$prompt" __rp_reply || true
    fi
    printf -v "$__rp_var" '%s' "$__rp_reply"
}

# Read masked input (shows asterisks for each character, restores terminal on Ctrl+C).
read_masked() {
    local prompt="$1"
    local var_name="$2"
    local value=""
    local charcount=0
    local old_settings=""

    _clear_masked_input() {
        while [ "$charcount" -gt 0 ]; do
            printf '\b \b' >&2
            charcount=$((charcount - 1))
        done
        value=""
    }

    if [ ! -t 0 ]; then
        printf '%s' "$prompt" >&2
        IFS= read -r value || true
        printf '\n' >&2
        printf -v "$var_name" '%s' "$value"
        return 0
    fi

    printf '%s' "$prompt" >&2
    old_settings=$(stty -g 2>/dev/null || true)

    _restore_masked_tty() {
        if [ -n "$old_settings" ]; then
            stty "$old_settings" 2>/dev/null || stty echo 2>/dev/null || true
        else
            stty echo 2>/dev/null || true
        fi
    }

    local prev_int_trap prev_term_trap
    prev_int_trap=$(trap -p INT 2>/dev/null || true)
    prev_term_trap=$(trap -p TERM 2>/dev/null || true)
    _restore_masked_traps() {
        if [ -n "$prev_int_trap" ]; then
            eval "$prev_int_trap"
        else
            trap - INT
        fi
        if [ -n "$prev_term_trap" ]; then
            eval "$prev_term_trap"
        else
            trap - TERM
        fi
    }

    trap '_restore_masked_tty; printf "\n" >&2; _restore_masked_traps; kill -s INT "$$"' INT
    trap '_restore_masked_tty; printf "\n" >&2; _restore_masked_traps; kill -s TERM "$$"' TERM
    stty -echo 2>/dev/null || true

    local char=""
    while IFS= read -r -n 1 char; do
        if [[ $char == $'\n' ]] || [[ -z "$char" ]]; then
            break
        fi
        if [[ $char == $'\177' ]] || [[ $char == $'\b' ]]; then
            if [ $charcount -gt 0 ]; then
                charcount=$((charcount - 1))
                printf '\b \b' >&2
                value="${value%?}"
            fi
        elif [[ $char == $'\025' ]] || [[ $char == $'\027' ]]; then
            _clear_masked_input
        elif [[ $char == $'\e' ]]; then
            local seq="" next=""
            while IFS= read -r -s -n 1 -t 0.01 next; do
                seq+="$next"
                [[ $next == "~" ]] && break
                [ ${#seq} -ge 8 ] && break
            done
            case "$seq" in
                "[3;5~"|"[127;5u"|"[8;5~")
                    _clear_masked_input
                    ;;
            esac
        else
            charcount=$((charcount + 1))
            printf '*' >&2
            value+="$char"
        fi
    done

    _restore_masked_traps
    _restore_masked_tty
    printf '\n' >&2
    printf -v "$var_name" '%s' "$value"
}
