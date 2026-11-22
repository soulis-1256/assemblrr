#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# assemblrr service catalog — UI URLs and display labels for status
# Requires: MEDIA_SERVICE, VPN_ENABLED, USENET_ENABLED, BYPARR_ENABLED optional

if [ -n "${_ASSEMBLRR_SERVICES_SOURCED:-}" ]; then
    return 0
fi
readonly _ASSEMBLRR_SERVICES_SOURCED=1

# Emit catalog lines (stable order):
#   compose_service|Display Name|port|path|kind
# kind: ui = browser URL, internal = no public UI
list_service_catalog() {
    printf '%s\n' \
        "jellyfin|Jellyfin|8096|/|ui" \
        "seerr-gateway|Seerr|5055|/|ui" \
        "bazarr|Bazarr|6767|/|ui" \
        "sonarr|Sonarr|8989|/|ui" \
        "radarr|Radarr|7878|/|ui" \
        "prowlarr|Prowlarr|9696|/|ui" \
        "qbittorrent|qBittorrent|8081|/|ui"

    if type qbit_ui_mode >/dev/null 2>&1 && [ "$(qbit_ui_mode)" = "qui" ]; then
        printf '%s\n' "qui|qui (qBit UI)|7476|/|ui"
    fi

    if [ "${USENET_ENABLED:-n}" = "y" ] || [ "${USENET_ENABLED:-n}" = "Y" ]; then
        printf '%s\n' "sabnzbd|SABnzbd|8085|/|ui"
    fi

    printf '%s\n' \
        "recyclarr|Recyclarr|||internal" \
        "seerr|Seerr (internal)|||internal"

    if [ "${BYPARR_ENABLED:-n}" = "y" ] || [ "${BYPARR_ENABLED:-n}" = "Y" ]; then
        printf '%s\n' "byparr|Byparr (solver)|||internal"
    fi

    printf '%s\n' "media-purge-watch|Media purge watch|||internal"

    if [ "${VPN_ENABLED:-n}" = "y" ] || [ "${VPN_ENABLED:-n}" = "Y" ]; then
        printf '%s\n' \
            "gluetun|Gluetun (VPN)|||internal" \
            "deunhealth|Deunhealth|||internal" \
            "vpn-watchdog|VPN watchdog|||internal"
    fi
}

# Build URL for a catalog row (uses localhost unless API_HOST points to a LAN/remote host)
service_ui_url() {
    local port="$1"
    local path="${2:-/}"
    local host="${3:-${API_HOST:-localhost}}"

    case "$host" in
        ""|127.0.0.1|0.0.0.0) host="localhost" ;;
    esac

    [ -z "$port" ] && { echo ""; return 0; }
    if [ "$path" != "/" ] && [[ "$path" != /* ]]; then
        path="/$path"
    fi
    if [ "$path" = "/" ]; then
        echo "http://${host}:${port}/"
    else
        echo "http://${host}:${port}${path}"
    fi
}

# True when a compose ps row is ready for the operator.
# healthy -> ready; starting/unhealthy -> not; no healthcheck + running -> ready.
service_row_ready() {
    local state="${1:-}"
    local health="${2:-}"
    state=$(printf '%s' "$state" | tr '[:upper:]' '[:lower:]')
    health=$(printf '%s' "$health" | tr '[:upper:]' '[:lower:]')
    case "$health" in
        healthy) return 0 ;;
        unhealthy|starting) return 1 ;;
    esac
    [ "$state" = "running" ]
}

# Human-readable service URLs only (setup summary / scripting)
running_services_location() {
    local host_ip="${1:-${API_HOST:-localhost}}"
    local line svc label port path kind

    echo "Service URLs (live: ${APP_CLI_NAME:-assemblrr} status):"
    while IFS='|' read -r svc label port path kind; do
        [ "$kind" = "ui" ] || continue
        printf '  %-14s %s\n' "$label" "$(service_ui_url "$port" "$path" "$host_ip")"
    done < <(list_service_catalog)
}

# Normalize Docker Compose state + health into a single display token.
service_status_normalize() {
    local state="${1:-}" health="${2:-}"
    state=$(printf '%s' "$state" | tr '[:upper:]' '[:lower:]')
    health=$(printf '%s' "$health" | tr '[:upper:]' '[:lower:]')

    if [ "$health" = "healthy" ]; then
        echo "healthy"
    elif [ "$health" = "unhealthy" ]; then
        echo "unhealthy"
    elif [ "$health" = "starting" ]; then
        echo "starting"
    elif [ "$state" = "running" ]; then
        echo "running"
    elif [ -z "$state" ]; then
        echo "missing"
    else
        echo "$state"
    fi
}

# Build pipe-delimited status rows for live startup/restart display.
# Args: <phase: starting|waiting> <rows_raw> [target_service...]
# Output: svc|label|token|ready(0|1)|detail
service_live_snapshot() {
    local phase="${1:-waiting}"
    local rows_raw="${2:-}"
    shift 2 || true
    local -a targets=("$@")

    local -A st_state=() st_health=() cat_label=()
    local svc state health label port path kind
    while IFS=$'\t' read -r svc state health; do
        [ -z "$svc" ] && continue
        st_state["$svc"]="$state"
        st_health["$svc"]="$health"
    done <<< "$rows_raw"

    local -a ordered_svcs=()
    if type list_service_catalog >/dev/null 2>&1; then
        while IFS='|' read -r svc label port path kind; do
            [ -z "$svc" ] && continue
            cat_label["$svc"]="$label"
            if [ "${#targets[@]}" -eq 0 ]; then
                ordered_svcs+=("$svc")
            fi
        done < <(list_service_catalog)
    fi

    if [ "${#targets[@]}" -gt 0 ]; then
        ordered_svcs=("${targets[@]}")
    else
        local seen="" s
        for s in "${ordered_svcs[@]+"${ordered_svcs[@]}"}"; do
            seen="${seen}|${s}|"
        done
        while IFS=$'\t' read -r svc state health; do
            [ -z "$svc" ] && continue
            [[ "$seen" == *"|${svc}|"* ]] && continue
            ordered_svcs+=("$svc")
            seen="${seen}|${svc}|"
        done <<< "$rows_raw"
    fi

    local gluetun_token="" seerr_token=""
    if [ -n "${st_state[gluetun]:-}" ] || [ -n "${st_health[gluetun]:-}" ]; then
        gluetun_token=$(service_status_normalize "${st_state[gluetun]:-}" "${st_health[gluetun]:-}")
    fi
    if [ -n "${st_state[seerr]:-}" ] || [ -n "${st_health[seerr]:-}" ]; then
        seerr_token=$(service_status_normalize "${st_state[seerr]:-}" "${st_health[seerr]:-}")
    fi

    local token ready detail
    for svc in "${ordered_svcs[@]+"${ordered_svcs[@]}"}"; do
        [ -z "$svc" ] && continue
        state="${st_state[$svc]:-}"
        health="${st_health[$svc]:-}"
        label="${cat_label[$svc]:-$svc}"
        token=$(service_status_normalize "$state" "$health")
        ready=0
        if service_row_ready "$state" "$health"; then
            ready=1
        fi
        detail=""
        if [ "$ready" -eq 0 ]; then
            if [ "$token" = "missing" ] && [ "$phase" = "starting" ]; then
                token="pending"
                detail="creating"
            elif [ "$token" = "created" ]; then
                case "$svc" in
                    qbittorrent|vpn-watchdog)
                        if [ -n "$gluetun_token" ] && [ "$gluetun_token" != "healthy" ]; then
                            detail="waiting on gluetun"
                        else
                            detail="waiting to start"
                        fi
                        ;;
                    seerr-gateway)
                        if [ -n "$seerr_token" ] && [ "$seerr_token" != "healthy" ]; then
                            detail="waiting on seerr"
                        else
                            detail="waiting to start"
                        fi
                        ;;
                    *)
                        detail="waiting to start"
                        ;;
                esac
            elif [ "$token" = "starting" ]; then
                detail="healthcheck pending"
            elif [ "$token" = "unhealthy" ] || [ "$token" = "exited" ] || [ "$token" = "dead" ]; then
                detail="needs attention"
            fi
        fi
        printf '%s|%s|%s|%s|%s\n' "$svc" "$label" "$token" "$ready" "$detail"
    done
}

_service_truncate() {
    local text="$1"
    local max_len="$2"
    if [ "$max_len" -le 0 ]; then
        printf ''
    elif [ "${#text}" -le "$max_len" ]; then
        printf '%s' "$text"
    elif [ "$max_len" -le 1 ]; then
        printf '%s' "${text:0:$max_len}"
    else
        printf '%s…' "${text:0:$((max_len - 1))}"
    fi
}

_service_token_style() {
    local token="$1"
    local use_color="${2:-1}"
    local icon="•" color=""
    case "$token" in
        healthy|running)
            icon="✓"
            color="${GREEN:-}"
            ;;
        starting)
            icon="◐"
            color="${YELLOW:-}"
            ;;
        pending|created|restarting)
            icon="○"
            color="${YELLOW:-}"
            ;;
        unhealthy|exited|dead|missing)
            icon="✗"
            color="${RED:-}"
            ;;
        *)
            icon="•"
            color="${YELLOW:-}"
            ;;
    esac
    if [ "$use_color" -eq 0 ] || [ -z "${NC:-}" ]; then
        color=""
    fi
    printf '%s|%s\n' "$icon" "$color"
}

_service_format_cell() {
    local label="$1" token="$2" detail="$3"
    local max_vis="$4" include_detail="$5" use_color="$6"

    local style icon color nc="" dim=""
    style=$(_service_token_style "$token" "$use_color")
    icon="${style%%|*}"
    color="${style#*|}"
    if [ "$use_color" -eq 1 ] && [ -n "${NC:-}" ]; then
        nc="${NC}"
        dim='\033[2m'
    fi

    local lbl_trunc tok_trunc padded_lbl padded_tok
    lbl_trunc=$(_service_truncate "$label" 18)
    tok_trunc=$(_service_truncate "$token" 12)
    printf -v padded_lbl '%-18s' "$lbl_trunc"
    printf -v padded_tok '%-12s' "$tok_trunc"

    local out="  "
    if [ -n "$color" ]; then
        out+="${color}${icon}${nc} ${padded_lbl} ${color}${padded_tok}${nc}"
    else
        out+="${icon} ${padded_lbl} ${padded_tok}"
    fi

    if [ "$include_detail" -eq 1 ] && [ -n "$detail" ]; then
        local rem=$((max_vis - 36))
        if [ "$rem" -ge 4 ]; then
            local det_trunc
            det_trunc=$(_service_truncate "$detail" "$rem")
            if [ -n "$dim" ]; then
                out+=" ${dim}${det_trunc}${nc}"
            else
                out+=" ${det_trunc}"
            fi
        fi
    fi
    printf '%b' "$out"
}

# Format the live service status panel to fit term_rows x term_cols without wrapping.
service_live_format_panel() {
    local snapshot="$1"
    local heading="${2:-Starting services}"
    local elapsed="${3:-0}"
    local term_rows="${4:-24}"
    local term_cols="${5:-80}"
    local use_color="${6:-1}"

    local -a labels=() tokens=() readies=() details=() pending_labels=()
    local svc label token is_ready detail total=0 ready=0

    while IFS='|' read -r svc label token is_ready detail; do
        [ -z "$svc" ] && continue
        labels+=("$label")
        tokens+=("$token")
        readies+=("$is_ready")
        details+=("$detail")
        total=$((total + 1))
        if [ "$is_ready" = "1" ]; then
            ready=$((ready + 1))
        else
            pending_labels+=("$label")
        fi
    done <<< "$snapshot"

    local max_vis=$((term_cols - 1))
    [ "$max_vis" -lt 20 ] && max_vis=20

    if [ "$total" -eq 0 ]; then
        printf '%s\n' "$(_service_truncate "  ${heading} (${elapsed}s)" "$max_vis")"
        return 0
    fi

    local footer="  ${heading}: ${ready}/${total} ready (${elapsed}s)"

    if [ "$term_rows" -ge $((total + 5)) ] && [ "$term_cols" -ge 36 ]; then
        local h1="  SERVICE              STATE        DETAIL"
        local h2="  -------------------- ------------ ----------------------"
        printf '%s\n' "$(_service_truncate "$h1" "$max_vis")"
        printf '%s\n' "$(_service_truncate "$h2" "$max_vis")"
        local i
        for ((i = 0; i < total; i++)); do
            _service_format_cell "${labels[$i]}" "${tokens[$i]}" "${details[$i]}" "$max_vis" 1 "$use_color"
            printf '\n'
        done
        printf '\n'
        printf '%s\n' "$(_service_truncate "$footer" "$max_vis")"
        return 0
    fi

    local half=$(( (total + 1) / 2 ))
    if [ "$term_cols" -ge 74 ] && [ "$term_rows" -ge $((half + 3)) ]; then
        local i left right
        for ((i = 0; i < half; i++)); do
            left=$(_service_format_cell "${labels[$i]}" "${tokens[$i]}" "" 35 0 "$use_color")
            local j=$((i + half))
            if [ "$j" -lt "$total" ]; then
                right=$(_service_format_cell "${labels[$j]}" "${tokens[$j]}" "" 35 0 "$use_color")
                printf '%s%s\n' "$left" "$right"
            else
                printf '%s\n' "$left"
            fi
        done
        printf '\n'
        printf '%s\n' "$(_service_truncate "$footer" "$max_vis")"
        return 0
    fi

    if [ "${#pending_labels[@]}" -gt 0 ]; then
        local pending_str="" p
        for p in "${pending_labels[@]}"; do
            [ -n "$pending_str" ] && pending_str+=", "
            pending_str+="$p"
        done
        footer+=" — pending: ${pending_str}"
    fi
    printf '%s\n' "$(_service_truncate "$footer" "$max_vis")"
}

_LIVE_PREV_LINES=0
_LIVE_CURSOR_HIDDEN=0
_LIVE_PREV_FINGERPRINT=""
_LIVE_LAST_PRINT_TS=0

_services_term_size() {
    local rows="" cols="" sz=""
    if [ -r /dev/tty ]; then
        sz=$(stty size </dev/tty 2>/dev/null || true)
    fi
    if [[ "$sz" =~ ^([0-9]+)[[:space:]]+([0-9]+)$ ]]; then
        rows="${BASH_REMATCH[1]}"
        cols="${BASH_REMATCH[2]}"
    else
        rows="${LINES:-24}"
        cols="${COLUMNS:-80}"
    fi
    [[ "$rows" =~ ^[0-9]+$ ]] && [ "$rows" -gt 0 ] || rows=24
    [[ "$cols" =~ ^[0-9]+$ ]] && [ "$cols" -gt 0 ] || cols=80
    printf '%s %s\n' "$rows" "$cols"
}

_services_compose_rows() {
    if type _status_compose_rows >/dev/null 2>&1; then
        _status_compose_rows
    elif [ -n "${COMPOSE_ARGS+set}" ] && [ "${#COMPOSE_ARGS[@]}" -gt 0 ] && type run_docker >/dev/null 2>&1; then
        run_docker compose "${COMPOSE_ARGS[@]}" ps -a --format '{{.Service}}\t{{.State}}\t{{.Health}}' 2>/dev/null || true
    fi
}

_services_live_clear() {
    if [ -t 2 ] && [ "${TERM:-}" != "dumb" ]; then
        local seq=""
        if [ "${_LIVE_PREV_LINES:-0}" -gt 0 ]; then
            seq+="\033[${_LIVE_PREV_LINES}A\r\033[J"
        fi
        if [ "${_LIVE_CURSOR_HIDDEN:-0}" -eq 1 ]; then
            seq+="\033[?25h"
        fi
        [ -n "$seq" ] && printf '%b' "$seq" >&2
    fi
    _LIVE_PREV_LINES=0
    _LIVE_CURSOR_HIDDEN=0
    _LIVE_PREV_FINGERPRINT=""
    _LIVE_LAST_PRINT_TS=0
}

_services_live_draw() {
    local snapshot="$1"
    local heading="${2:-Starting services}"
    local elapsed="${3:-0}"

    if [ -t 2 ] && [ "${TERM:-}" != "dumb" ]; then
        local rows cols panel line_count=0 line buf=""
        read -r rows cols < <(_services_term_size)
        local use_color=1
        [ -n "${NO_COLOR:-}" ] && use_color=0
        panel=$(service_live_format_panel "$snapshot" "$heading" "$elapsed" "$rows" "$cols" "$use_color")

        if [ "${_LIVE_CURSOR_HIDDEN:-0}" -eq 0 ]; then
            buf+=$'\033[?25l'
            _LIVE_CURSOR_HIDDEN=1
        fi
        if [ "${_LIVE_PREV_LINES:-0}" -gt 0 ]; then
            buf+=$'\033['"${_LIVE_PREV_LINES}"$'A\r'
        fi
        while IFS= read -r line; do
            buf+="${line}"$'\033[K\n'
            line_count=$((line_count + 1))
        done <<< "$panel"
        buf+=$'\033[J'
        printf '%s' "$buf" >&2
        _LIVE_PREV_LINES="$line_count"
        return 0
    fi

    local svc label token is_ready detail
    local total=0 ready=0 pending_str=""
    while IFS='|' read -r svc label token is_ready detail; do
        [ -z "$svc" ] && continue
        total=$((total + 1))
        if [ "$is_ready" = "1" ]; then
            ready=$((ready + 1))
        else
            [ -n "$pending_str" ] && pending_str+=", "
            pending_str+="${label} (${token})"
        fi
    done <<< "$snapshot"

    local now fp last_ts="${_LIVE_LAST_PRINT_TS:-0}"
    now=$(date +%s)
    fp="${ready}/${total}|${pending_str}"
    if [ "$fp" != "${_LIVE_PREV_FINGERPRINT:-}" ] || [ $((now - last_ts)) -ge 15 ]; then
        if [ "$total" -gt 0 ] && [ -n "$pending_str" ]; then
            printf '%s: %s/%s ready (%ss) — waiting: %s\n' "$heading" "$ready" "$total" "$elapsed" "$pending_str" >&2
        elif [ "$total" -gt 0 ]; then
            printf '%s: %s/%s ready (%ss)\n' "$heading" "$ready" "$total" "$elapsed" >&2
        else
            printf '%s (%ss)\n' "$heading" "$elapsed" >&2
        fi
        _LIVE_PREV_FINGERPRINT="$fp"
        _LIVE_LAST_PRINT_TS="$now"
    fi
}

# Run a command in the background while displaying live per-service readiness.
# Captures stdout+stderr in WAIT_WHILE_OUTPUT. Returns the command's exit status.
wait_while_services() {
    local label="$1"
    shift
    [ $# -gt 0 ] || return 1

    local out cmd_pid rc=0 had_errexit=0
    local start_ts="${ASSEMBLRR_LIVE_START_TS:-$(date +%s)}"
    local interval="${ASSEMBLRR_WAIT_INTERVAL:-1}"
    local -a targets=()
    if [ -n "${ASSEMBLRR_LIVE_TARGETS:-}" ]; then
        read -ra targets <<< "$ASSEMBLRR_LIVE_TARGETS"
    fi

    out=$(mktemp)
    [[ $- == *e* ]] && had_errexit=1

    local prev_int_trap prev_term_trap
    prev_int_trap=$(trap -p INT 2>/dev/null || true)
    prev_term_trap=$(trap -p TERM 2>/dev/null || true)
    _wws_restore_traps() {
        if [ -n "$prev_int_trap" ]; then eval "$prev_int_trap"; else trap - INT; fi
        if [ -n "$prev_term_trap" ]; then eval "$prev_term_trap"; else trap - TERM; fi
    }
    # shellcheck disable=SC2329
    _wws_cleanup() {
        kill "$cmd_pid" 2>/dev/null || true
        wait "$cmd_pid" 2>/dev/null || true
        _services_live_clear || true
        rm -f "$out" 2>/dev/null || true
    }
    trap '_wws_cleanup; _wws_restore_traps; exit 130' INT
    trap '_wws_cleanup; _wws_restore_traps; exit 143' TERM

    "$@" </dev/null >"$out" 2>&1 &
    cmd_pid=$!

    local rows_raw snapshot elapsed
    while kill -0 "$cmd_pid" 2>/dev/null; do
        rows_raw=$(_services_compose_rows)
        snapshot=$(service_live_snapshot "starting" "$rows_raw" "${targets[@]+"${targets[@]}"}")
        elapsed=$(( $(date +%s) - start_ts ))
        _services_live_draw "$snapshot" "$label" "$elapsed"
        sleep "$interval"
    done

    set +e
    wait "$cmd_pid"
    rc=$?
    [ "$had_errexit" = 1 ] && set -e

    _wws_restore_traps
    WAIT_WHILE_OUTPUT=$(cat "$out" 2>/dev/null || true)
    rm -f "$out"

    if [ "$rc" -ne 0 ] || [ "${ASSEMBLRR_LIVE_KEEP:-0}" != "1" ]; then
        _services_live_clear || true
    fi
    return "$rc"
}
