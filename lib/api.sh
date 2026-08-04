#!/bin/bash
# Assemblrr API helpers — sourced by configure.sh
# Provides: jq helpers, API request wrappers, API key discovery, wait_for_api
# Requires: lib/core.sh already sourced (for logging), API_HOST and INSTALL_DIR set

set -euo pipefail

# --- JSON helpers using jq ---

jq_json_get() {
    local json="$1"
    local key="$2"
    echo "$json" | jq -r --arg k "$key" '.[$k] // empty' 2>/dev/null
}

jq_json_has_key() {
    local json="$1"
    local key="$2"
    echo "$json" | jq -e --arg k "$key" 'has($k)' >/dev/null 2>&1
}

jq_json_list_values() {
    local json="$1"
    local key="$2"
    echo "$json" | jq -r --arg k "$key" '.[][$k] // empty' 2>/dev/null
}

# --- API key discovery from config.xml ---

read_api_key() {
    local service="$1"
    local config_file="$INSTALL_DIR/config/$service/config.xml"
    local max_wait=120
    local wait_time=0

    echo -n "Waiting for $service to initialize" >&2
    while [ $wait_time -lt $max_wait ]; do
        if [ -f "$config_file" ]; then
            local key
            key=$(sed -n 's/.*<ApiKey>\(.*\)<\/ApiKey>.*/\1/p' "$config_file" 2>/dev/null | head -1)
            if [ -n "$key" ]; then
                echo >&2
                echo "$key"
                return 0
            fi
        fi
        sleep 3
        wait_time=$((wait_time + 3))
        dot_inline
    done
    echo >&2
    log_step_fail "$service: config.xml not found or ApiKey missing after ${max_wait}s"
    return 1
}

# --- API request helpers ---

api_get() {
    local port="$1"
    local endpoint="$2"
    local apikey="$3"
    curl -s --connect-timeout 5 "http://${API_HOST}:${port}${endpoint}?apikey=${apikey}" 2>/dev/null
}

api_post() {
    local port="$1"
    local endpoint="$2"
    local apikey="$3"
    local data="$4"
    curl -s --connect-timeout 5 -X POST \
        -H "Content-Type: application/json" \
        -d "$data" \
        "http://${API_HOST}:${port}${endpoint}?apikey=${apikey}" 2>/dev/null
}

api_put() {
    local port="$1"
    local endpoint="$2"
    local apikey="$3"
    local data="$4"
    curl -s --connect-timeout 5 -X PUT \
        -H "Content-Type: application/json" \
        -d "$data" \
        "http://${API_HOST}:${port}${endpoint}?apikey=${apikey}" 2>/dev/null
}

api_delete() {
    local port="$1"
    local endpoint="$2"
    local apikey="$3"
    curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 -X DELETE \
        "http://${API_HOST}:${port}${endpoint}?apikey=${apikey}" 2>/dev/null
}

# POST with forceSave query param (bypasses connectivity validation in Prowlarr/Radarr/Sonarr)
api_post_force() {
    local port="$1"
    local endpoint="$2"
    local apikey="$3"
    local data="$4"
    curl -s --connect-timeout 5 -X POST \
        -H "Content-Type: application/json" \
        -d "$data" \
        "http://${API_HOST}:${port}${endpoint}?apikey=${apikey}&forceSave=true" 2>/dev/null
}

qbit_cookie_sid() {
    local cookie_jar="$1"
    awk '$6 ~ /^QBT_SID/ || $6 == "SID" { print $7; exit }' "$cookie_jar" 2>/dev/null || true
}

# --- Wait for service API to be ready ---

wait_for_api() {
    local name="$1"
    local port="$2"
    local apikey="$3"
    local api_path="${4:-/api/v3/system/status}"
    local max_wait="${API_READY_TIMEOUT_SECONDS:-120}"
    local wait_time=0

    echo -n "Waiting for $name API" >&2
    while [ $wait_time -lt $max_wait ]; do
        dot_inline
        local response
        response=$(curl -s --connect-timeout 3 "http://${API_HOST}:${port}${api_path}?apikey=${apikey}" 2>/dev/null || echo "")
        if [ -n "$response" ]; then
            local version
            version=$(jq_json_get "$response" "version")
            if [ -n "$version" ]; then
                echo >&2
                return 0
            fi
        fi
        sleep 2
        wait_time=$((wait_time + 2))
    done
    echo >&2
    log_step_fail "$name API not ready after ${max_wait}s"
    return 1
}
