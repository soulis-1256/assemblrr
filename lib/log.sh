#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# assemblrr logging and progress indicators

if [ -n "${_ASSEMBLRR_LOG_SOURCED:-}" ]; then
    return 0
fi
readonly _ASSEMBLRR_LOG_SOURCED=1

_log_init_colors() {
    if [ -n "${NO_COLOR:-}" ] || [ "${TERM:-}" = "dumb" ] || { [ ! -t 1 ] && [ ! -t 2 ]; }; then
        RED=''
        GREEN=''
        YELLOW=''
        NC=''
    else
        RED='\033[0;31m'
        GREEN='\033[0;32m'
        YELLOW='\033[1;33m'
        NC='\033[0m'
    fi
}

_log_init_colors
readonly RED GREEN YELLOW NC

_log_to_file() {
    if [ -n "${LOG_FILE:-}" ]; then
        printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE" 2>/dev/null || true
    fi
    return 0
}

log_success()      { printf '%b\n' "${GREEN}$1${NC}"; _log_to_file "INFO: $1"; return 0; }
log_warning()      { printf '%b\n' "${YELLOW}$1${NC}"; _log_to_file "WARN: $1"; return 0; }
log_info()         { printf '%s\n' "$1"; _log_to_file "INFO: $1"; return 0; }
log_debug()        { _log_to_file "DEBUG: $1"; return 0; }
log_error_inline() { printf '%b\n' "${RED}$1${NC}" >&2; _log_to_file "ERROR: $1"; return 0; }
die()              { printf '%b\n' "${RED}$1${NC}" >&2; _log_to_file "ERROR: $1"; exit 1; }
log_error()        { die "$@"; }

# Rewrite the current line on TTY stderr: "Waiting for Radarr API (12s)".
# In non-TTY stderr, avoid carriage-return / ANSI escapes.
wait_inline() {
    local label="$1"
    local secs="${2:-0}"
    if [ -t 2 ]; then
        printf '\r\033[K%s (%ss)' "$label" "$secs" >&2
    else
        printf '%s (%ss)\n' "$label" "$secs" >&2
    fi
}

# Run a command while updating wait_inline every second.
# Captures stdout+stderr in WAIT_WHILE_OUTPUT. Returns the command's exit status.
wait_while() {
    local label="$1"
    shift
    local out ticker rc=0 had_errexit=0
    [ $# -gt 0 ] || return 1
    out=$(mktemp)
    [[ $- == *e* ]] && had_errexit=1

    (
        secs=0
        trap 'exit 0' TERM INT
        while true; do
            wait_inline "$label" "$secs"
            sleep 1
            secs=$((secs + 1))
        done
    ) &
    ticker=$!

    _wait_while_cleanup() {
        kill "$ticker" 2>/dev/null || true
        wait "$ticker" 2>/dev/null || true
        [ -t 2 ] && printf '\r\033[K' >&2
        rm -f "$out" 2>/dev/null || true
    }
    trap '_wait_while_cleanup; exit 130' INT
    trap '_wait_while_cleanup; exit 143' TERM

    set +e
    "$@" >"$out" 2>&1
    rc=$?
    [ "$had_errexit" = 1 ] && set -e

    trap - INT TERM
    kill "$ticker" 2>/dev/null || true
    wait "$ticker" 2>/dev/null || true
    [ -t 2 ] && printf '\r\033[K' >&2
    WAIT_WHILE_OUTPUT=$(cat "$out" 2>/dev/null || true)
    rm -f "$out"
    return "$rc"
}
