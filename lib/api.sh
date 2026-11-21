#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# assemblrr API / HTTP helpers — sourced by wiring modules and entrypoints
# Requires: lib/core.sh (logging), API_HOST and INSTALL_DIR set

if [ -n "${_ASSEMBLRR_API_SOURCED:-}" ]; then
    return 0
fi
readonly _ASSEMBLRR_API_SOURCED=1

ASSEMBLRR_CURL_BIN="${ASSEMBLRR_CURL_BIN:-curl}"
API_HOST="${API_HOST:-127.0.0.1}"
HTTP_STATUS=""
HTTP_BODY=""

# --- JSON & encoding helpers ---

jq_json_get() {
    local json="$1"
    local key="$2"
    printf '%s' "$json" | jq -r --arg k "$key" '.[$k] // empty' 2>/dev/null
}

jq_json_has_key() {
    local json="$1"
    local key="$2"
    printf '%s' "$json" | jq -e --arg k "$key" 'has($k)' >/dev/null 2>&1
}

jq_json_list_values() {
    local json="$1"
    local key="$2"
    printf '%s' "$json" | jq -r --arg k "$key" '.[][$k] // empty' 2>/dev/null
}

urlencode() {
    jq -rn --arg v "${1:-}" '$v | @uri' 2>/dev/null || printf '%s' "${1:-}"
}

# --- Shared HTTP transport ---

# Execute curl and populate globals HTTP_STATUS (3-digit code, "000" on network failure)
# and HTTP_BODY. Returns 0 on 2xx, 1 otherwise.
http_request() {
    local method="$1"
    local url="$2"
    shift 2

    local tmp rc=0
    tmp=$(mktemp)
    HTTP_STATUS=""
    HTTP_BODY=""

    HTTP_STATUS=$("$ASSEMBLRR_CURL_BIN" -s -o "$tmp" -w "%{http_code}" --connect-timeout 5 --max-time 30 \
        -X "$method" "$@" "$url" 2>/dev/null) || rc=$?
    HTTP_BODY=$(cat "$tmp" 2>/dev/null || true)
    rm -f "$tmp"

    HTTP_STATUS="${HTTP_STATUS//[^0-9]/}"
    if [ "${#HTTP_STATUS}" -ne 3 ]; then
        HTTP_STATUS="000"
    fi

    if [ "$rc" -eq 0 ] && [ "$HTTP_STATUS" -ge 200 ] && [ "$HTTP_STATUS" -lt 300 ]; then
        return 0
    fi
    return 1
}

# Reusable polling helper: wait_until <label> <max_sec> <interval_sec> <cmd...>
wait_until() {
    local label="$1"
    local max_wait="$2"
    local interval="$3"
    shift 3
    local elapsed=0

    if "$@" 2>/dev/null; then
        return 0
    fi
    while [ "$elapsed" -lt "$max_wait" ]; do
        wait_inline "$label" "$elapsed"
        sleep "$interval"
        elapsed=$((elapsed + interval))
        if "$@" 2>/dev/null; then
            echo >&2
            return 0
        fi
    done
    echo >&2
    return 1
}

# --- API key discovery from config.xml ---

read_api_key() {
    local service="$1"
    local config_file="$INSTALL_DIR/config/$service/config.xml"
    local max_wait=120
    local wait_time=0

    while [ $wait_time -lt $max_wait ]; do
        if [ -f "$config_file" ]; then
            local key
            key=$(sed -n 's/.*<ApiKey>\(.*\)<\/ApiKey>.*/\1/p' "$config_file" 2>/dev/null | head -1 | tr -d '\r')
            if [ -n "$key" ]; then
                [ "$wait_time" -gt 0 ] && echo >&2
                echo "$key"
                return 0
            fi
        fi
        wait_inline "Waiting for $service to initialize" "$wait_time"
        sleep 3
        wait_time=$((wait_time + 3))
    done
    echo >&2
    log_step_fail "$service: config.xml not found or ApiKey missing after ${max_wait}s"
    return 1
}

# --- Servarr API request helpers (use X-Api-Key header, not query strings) ---

api_get() {
    local port="$1"
    local endpoint="$2"
    local apikey="$3"
    local rc=0
    http_request GET "http://${API_HOST}:${port}${endpoint}" -H "X-Api-Key: ${apikey}" || rc=$?
    printf '%s' "$HTTP_BODY"
    return "$rc"
}

api_post() {
    local port="$1"
    local endpoint="$2"
    local apikey="$3"
    local data="$4"
    local rc=0
    http_request POST "http://${API_HOST}:${port}${endpoint}" \
        -H "X-Api-Key: ${apikey}" -H "Content-Type: application/json" -d "$data" || rc=$?
    printf '%s' "$HTTP_BODY"
    return "$rc"
}

api_put() {
    local port="$1"
    local endpoint="$2"
    local apikey="$3"
    local data="$4"
    local rc=0
    http_request PUT "http://${API_HOST}:${port}${endpoint}" \
        -H "X-Api-Key: ${apikey}" -H "Content-Type: application/json" -d "$data" || rc=$?
    printf '%s' "$HTTP_BODY"
    return "$rc"
}

api_delete() {
    local port="$1"
    local endpoint="$2"
    local apikey="$3"
    http_request DELETE "http://${API_HOST}:${port}${endpoint}" -H "X-Api-Key: ${apikey}" || true
    printf '%s' "$HTTP_STATUS"
}

api_post_force() {
    local port="$1"
    local endpoint="$2"
    local apikey="$3"
    local data="$4"
    local sep="?"
    [[ "$endpoint" == *\?* ]] && sep="&"
    local rc=0
    http_request POST "http://${API_HOST}:${port}${endpoint}${sep}forceSave=true" \
        -H "X-Api-Key: ${apikey}" -H "Content-Type: application/json" -d "$data" || rc=$?
    printf '%s' "$HTTP_BODY"
    return "$rc"
}

api_put_force() {
    local port="$1"
    local endpoint="$2"
    local apikey="$3"
    local data="$4"
    local sep="?"
    [[ "$endpoint" == *\?* ]] && sep="&"
    local rc=0
    http_request PUT "http://${API_HOST}:${port}${endpoint}${sep}forceSave=true" \
        -H "X-Api-Key: ${apikey}" -H "Content-Type: application/json" -d "$data" || rc=$?
    printf '%s' "$HTTP_BODY"
    return "$rc"
}

qbit_cookie_sid() {
    local cookie_jar="$1"
    awk '$6 ~ /^QBT_SID/ || $6 == "SID" { print $7; exit }' "$cookie_jar" 2>/dev/null || true
}

# --- Wait for service API to be ready ---

_api_ready() {
    local port="$1"
    local apikey="$2"
    local api_path="$3"
    http_request GET "http://${API_HOST}:${port}${api_path}" -H "X-Api-Key: ${apikey}" || return 1
    [ -n "$HTTP_BODY" ] && [ -n "$(jq_json_get "$HTTP_BODY" "version")" ]
}

wait_for_api() {
    local name="$1"
    local port="$2"
    local apikey="$3"
    local api_path="${4:-/api/v3/system/status}"
    local max_wait="${API_READY_TIMEOUT_SECONDS:-120}"

    if wait_until "Waiting for $name API" "$max_wait" 2 _api_ready "$port" "$apikey" "$api_path"; then
        return 0
    fi
    log_step_fail "$name API not ready after ${max_wait}s"
    return 1
}
