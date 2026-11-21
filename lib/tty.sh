#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# assemblrr terminal input helpers (prompting, TTY drain, masked passwords)

if [ -n "${_ASSEMBLRR_TTY_SOURCED:-}" ]; then
    return 0
fi
readonly _ASSEMBLRR_TTY_SOURCED=1

readonly PROMPT_CANCEL_RC=2
PROMPT_CANCELLED=0

# Discard a pending line on the tty (e.g., fzf's confirming Enter). Non-blocking.
flush_tty_input() {
    local __ft_junk
    [ -t 0 ] && [ -r /dev/tty ] || return 0
    while read -r -t 0.01 __ft_junk </dev/tty 2>/dev/null; do
        :
    done
    return 0
}

# Shared character-by-character TTY reader supporting masked output, Ctrl+U/W, and bare Esc cancel.
_tty_read_line() {
    local prompt="$1"
    local var_name="$2"
    local masked="${3:-0}"
    local allow_esc="${4:-0}"
    local value=""
    local charcount=0
    local old_settings=""

    PROMPT_CANCELLED=0

    _tty_rl_clear() {
        while [ "$charcount" -gt 0 ]; do
            printf '\b \b' >&2
            charcount=$((charcount - 1))
        done
        value=""
    }

    printf '%s' "$prompt" >&2
    old_settings=$(stty -g </dev/tty 2>/dev/null || true)

    _tty_rl_restore_tty() {
        if [ -n "$old_settings" ]; then
            stty "$old_settings" </dev/tty 2>/dev/null || stty echo </dev/tty 2>/dev/null || true
        else
            stty echo </dev/tty 2>/dev/null || true
        fi
    }

    local prev_int_trap prev_term_trap
    prev_int_trap=$(trap -p INT 2>/dev/null || true)
    prev_term_trap=$(trap -p TERM 2>/dev/null || true)
    _tty_rl_restore_traps() {
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

    trap '_tty_rl_restore_tty; printf "\n" >&2; _tty_rl_restore_traps; kill -s INT "$$"' INT
    trap '_tty_rl_restore_tty; printf "\n" >&2; _tty_rl_restore_traps; kill -s TERM "$$"' TERM
    stty -echo </dev/tty 2>/dev/null || true

    local char="" read_rc=0
    while true; do
        read_rc=0
        IFS= read -r -n 1 char </dev/tty || read_rc=$?
        if [ "$read_rc" -ne 0 ]; then
            if [ "$allow_esc" = "1" ] && [ -z "$value" ]; then
                _tty_rl_restore_traps
                _tty_rl_restore_tty
                printf '\n' >&2
                PROMPT_CANCELLED=1
                printf -v "$var_name" '%s' ""
                return "$PROMPT_CANCEL_RC"
            fi
            break
        fi
        if [[ $char == $'\n' ]] || [[ -z "$char" ]]; then
            break
        fi
        if [[ $char == $'\177' ]] || [[ $char == $'\b' ]]; then
            if [ "$charcount" -gt 0 ]; then
                charcount=$((charcount - 1))
                printf '\b \b' >&2
                value="${value%?}"
            fi
        elif [[ $char == $'\025' ]] || [[ $char == $'\027' ]]; then
            _tty_rl_clear
        elif [[ $char == $'\e' ]]; then
            local next="" seq="" ch=""
            if IFS= read -r -s -n 1 -t 0.05 next </dev/tty 2>/dev/null; then
                seq="$next"
                if [ "$next" = "[" ]; then
                    while IFS= read -r -s -n 1 -t 0.02 ch </dev/tty 2>/dev/null; do
                        seq+="$ch"
                        [[ "$ch" == [@-~] ]] && break
                        [ "${#seq}" -ge 12 ] && break
                    done
                elif [ "$next" = "O" ]; then
                    IFS= read -r -s -n 1 -t 0.02 ch </dev/tty 2>/dev/null && seq+="$ch" || true
                fi
                case "$seq" in
                    "[3;5~"|"[127;5u"|"[8;5~")
                        _tty_rl_clear
                        ;;
                esac
            elif [ "$allow_esc" = "1" ]; then
                _tty_rl_restore_traps
                _tty_rl_restore_tty
                printf '\n' >&2
                PROMPT_CANCELLED=1
                printf -v "$var_name" '%s' ""
                return "$PROMPT_CANCEL_RC"
            fi
        else
            charcount=$((charcount + 1))
            if [ "$masked" = "1" ]; then
                printf '*' >&2
            else
                printf '%s' "$char" >&2
            fi
            value+="$char"
        fi
    done

    _tty_rl_restore_traps
    _tty_rl_restore_tty
    printf '\n' >&2
    printf -v "$var_name" '%s' "$value"
    return 0
}

# Prompt and read a line cleanly (always -r, EOF-safe under set -e; defaults to REPLY).
read_prompt() {
    local prompt="$1"
    local __rp_var="${2:-REPLY}"
    local __rp_reply=""
    PROMPT_CANCELLED=0

    if [ "${PROMPT_ALLOW_ESC:-0}" = "1" ] && [ -t 0 ] && [ -r /dev/tty ]; then
        _tty_read_line "$prompt" "$__rp_var" 0 1
        return $?
    fi

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
    PROMPT_CANCELLED=0

    if [ ! -t 0 ] || [ ! -r /dev/tty ]; then
        printf '%s' "$prompt" >&2
        IFS= read -r value || true
        printf '\n' >&2
        printf -v "$var_name" '%s' "$value"
        return 0
    fi

    _tty_read_line "$prompt" "$var_name" 1 "${PROMPT_ALLOW_ESC:-0}"
}
