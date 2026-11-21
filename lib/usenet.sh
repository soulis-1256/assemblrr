#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# assemblrr SABnzbd / Usenet wiring — sourced by config.sh / config_edit.sh / setup.sh
# Requires: lib/core.sh, lib/api.sh

if [ -n "${_ASSEMBLRR_USENET_SOURCED:-}" ]; then
    return 0
fi
readonly _ASSEMBLRR_USENET_SOURCED=1

SABNZBD_PORT="${SABNZBD_PORT:-8080}"

sabnzbd_enabled() {
    case "${USENET_ENABLED:-n}" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

# Read api_key from sabnzbd.ini (handles `api_key = xxx` or `api_key=xxx`).
sabnzbd_extract_api_key() {
    local ini_file="$1"
    [ -f "$ini_file" ] || return 1
    awk -F= '/^[[:space:]]*api_key[[:space:]]*=/{
        val=$2
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
        gsub(/\r/, "", val)
        print val
        exit
    }' "$ini_file" 2>/dev/null
}

read_sabnzbd_api_key() {
    local ini_file="$INSTALL_DIR/config/sabnzbd/sabnzbd.ini"
    local max_wait=120 wait_time=0 key=""
    while [ "$wait_time" -lt "$max_wait" ]; do
        key=$(sabnzbd_extract_api_key "$ini_file" || true)
        if [ -n "$key" ]; then
            [ "$wait_time" -gt 0 ] && echo >&2
            echo "$key"
            return 0
        fi
        wait_inline "Waiting for SABnzbd to initialize" "$wait_time"
        sleep 3
        wait_time=$((wait_time + 3))
    done
    echo >&2
    log_step_fail "SABnzbd: sabnzbd.ini api_key missing after ${max_wait}s"
    return 1
}

# Pre-seed sabnzbd.ini before first start (or update whitelist/paths cleanly if absent).
write_sabnzbd_config() {
    local base_dir="${install_directory:-${INSTALL_DIR:-}}"
    [ -n "$base_dir" ] || return 1
    local ini_dir="$base_dir/config/sabnzbd"
    local ini_file="$ini_dir/sabnzbd.ini"
    mkdir -p "$ini_dir"

    # Never overwrite an existing initialized sabnzbd.ini (preserve generated api_key & user tweaks).
    [ -f "$ini_file" ] && return 0

    local user="${auth_username:-${AUTH_USERNAME:-}}"
    local pass="${auth_password:-${AUTH_PASSWORD:-}}"
    local host_api="${API_HOST:-127.0.0.1}"

    (
        umask 077
        cat > "$ini_file" <<EOF
__version__ = 19
[misc]
host = 0.0.0.0
port = 8080
host_whitelist = sabnzbd, localhost, 127.0.0.1, ${host_api}
username = ${user}
password = ${pass}
download_dir = /data/usenet/incomplete
complete_dir = /data/usenet/complete
permissions = 755
[categories]
[[*]]
name = *
order = 0
pp = 3
script = None
priority = 0
[[movies]]
name = movies
order = 1
dir = movies
pp = 3
script = Default
priority = -100
[[tv]]
name = tv
order = 2
dir = tv
pp = 3
script = Default
priority = -100
EOF
    )
    chmod 600 "$ini_file" 2>/dev/null || true
}

_sabnzbd_ready() {
    local apikey="$1"
    http_request GET "http://${API_HOST}:${SABNZBD_PORT}/api?mode=version&output=json&apikey=${apikey}" || return 1
    [ -n "$HTTP_BODY" ] && printf '%s' "$HTTP_BODY" | jq -e '.version // empty' >/dev/null 2>&1
}

_sab_set_config_misc() {
    local apikey="$1"
    local keyword="$2"
    local value="$3"
    local enc_val
    enc_val=$(urlencode "$value")
    http_request GET "http://${API_HOST}:${SABNZBD_PORT}/api?mode=set_config&section=misc&keyword=${keyword}&value=${enc_val}&output=json&apikey=${apikey}"
}

_sab_set_category() {
    local apikey="$1"
    local name="$2"
    local dir="$3"
    http_request GET "http://${API_HOST}:${SABNZBD_PORT}/api?mode=set_config&section=categories&name=${name}&dir=${dir}&pp=3&output=json&apikey=${apikey}"
}

_sab_set_server() {
    local apikey="$1"
    local host="$2"
    local port="$3"
    local ssl="$4"
    local user="$5"
    local pass="$6"
    local enc_host enc_user enc_pass
    enc_host=$(urlencode "$host")
    enc_user=$(urlencode "$user")
    enc_pass=$(urlencode "$pass")
    http_request GET \
        "http://${API_HOST}:${SABNZBD_PORT}/api?mode=set_config&section=servers&name=${enc_host}&host=${enc_host}&port=${port}&ssl=${ssl}&username=${enc_user}&password=${enc_pass}&connections=8&enable=1&output=json&apikey=${apikey}"
}

configure_sabnzbd() {
    sabnzbd_enabled || return 0
    local sab_key
    if ! sab_key=$(read_sabnzbd_api_key); then
        return 1
    fi
    if ! wait_until "Waiting for SABnzbd API" "${API_READY_TIMEOUT_SECONDS:-120}" 3 _sabnzbd_ready "$sab_key"; then
        log_step_fail "SABnzbd: API not ready"
        return 1
    fi

    write_secret_file "$INSTALL_DIR/secrets/sabnzbd_api_key.txt" "$sab_key"

    _sab_set_config_misc "$sab_key" "host_whitelist" "sabnzbd, localhost, 127.0.0.1, ${API_HOST:-127.0.0.1}" || true
    _sab_set_config_misc "$sab_key" "download_dir" "/data/usenet/incomplete" || true
    _sab_set_config_misc "$sab_key" "complete_dir" "/data/usenet/complete" || true
    if [ -n "${AUTH_USERNAME:-}" ] && [ -n "${AUTH_PASSWORD:-}" ]; then
        _sab_set_config_misc "$sab_key" "username" "$AUTH_USERNAME" || true
        _sab_set_config_misc "$sab_key" "password" "$AUTH_PASSWORD" || true
    fi
    _sab_set_category "$sab_key" "movies" "movies" || true
    _sab_set_category "$sab_key" "tv" "tv" || true

    # Optional Usenet NNTP server credentials stored in secrets/usenet_*.txt
    local nntp_host="" nntp_port="563" nntp_ssl="1" nntp_user="" nntp_pass=""
    [ -s "$INSTALL_DIR/secrets/usenet_host.txt" ] && nntp_host=$(tr -d '\r\n' < "$INSTALL_DIR/secrets/usenet_host.txt")
    [ -s "$INSTALL_DIR/secrets/usenet_port.txt" ] && nntp_port=$(tr -d '\r\n' < "$INSTALL_DIR/secrets/usenet_port.txt")
    [ -s "$INSTALL_DIR/secrets/usenet_ssl.txt" ] && nntp_ssl=$(tr -d '\r\n' < "$INSTALL_DIR/secrets/usenet_ssl.txt")
    [ -s "$INSTALL_DIR/secrets/usenet_user.txt" ] && nntp_user=$(tr -d '\r\n' < "$INSTALL_DIR/secrets/usenet_user.txt")
    [ -s "$INSTALL_DIR/secrets/usenet_password.txt" ] && nntp_pass=$(tr -d '\r\n' < "$INSTALL_DIR/secrets/usenet_password.txt")

    if [ -n "$nntp_host" ]; then
        if _sab_set_server "$sab_key" "$nntp_host" "$nntp_port" "$nntp_ssl" "$nntp_user" "$nntp_pass"; then
            log_step "SABnzbd: wired NNTP server (${nntp_host}:${nntp_port})"
        else
            log_step_fail "SABnzbd: failed to configure NNTP server (${nntp_host})"
        fi
    fi

    log_step "SABnzbd: configured folders (/data/usenet/complete) & categories (movies, tv)"
    return 0
}

# Wire SABnzbd as a download client inside Radarr or Sonarr via /api/v3/downloadclient/schema.
arr_build_sabnzbd_payload() {
    local schemas_json="$1"
    local sab_key="$2"
    local category_field="$3"
    local category_val="$4"
    local sab_host="${5:-sabnzbd}"
    local sab_port="${6:-8080}"

    local base_schema
    base_schema=$(printf '%s' "$schemas_json" | jq '[.[] | select(.implementation == "Sabnzbd")][0] // empty' 2>/dev/null || true)

    if [ -n "$base_schema" ]; then
        printf '%s' "$base_schema" | jq -c \
            --arg host "$sab_host" \
            --argjson port "$sab_port" \
            --arg key "$sab_key" \
            --arg cf "$category_field" \
            --arg cv "$category_val" '
            .enable = true |
            .removeCompletedDownloads = true |
            .removeFailedDownloads = true |
            .name = "SABnzbd" |
            .priority = 1 |
            .tags = [] |
            .fields = [.fields[] |
                if .name == "host" then .value = $host
                elif .name == "port" then .value = $port
                elif .name == "useSsl" then .value = false
                elif .name == "urlBase" then .value = ""
                elif .name == "apiKey" then .value = $key
                elif .name == $cf then .value = $cv
                else . end
            ]
        ' 2>/dev/null || echo ""
        return 0
    fi

    jq -nc \
        --arg host "$sab_host" \
        --argjson port "$sab_port" \
        --arg key "$sab_key" \
        --arg cf "$category_field" \
        --arg cv "$category_val" '
        {
            enable: true,
            removeCompletedDownloads: true,
            removeFailedDownloads: true,
            name: "SABnzbd",
            implementation: "Sabnzbd",
            implementationName: "SABnzbd",
            configContract: "SabnzbdSettings",
            priority: 1,
            tags: [],
            fields: [
                {name: "host", value: $host},
                {name: "port", value: $port},
                {name: "useSsl", value: false},
                {name: "urlBase", value: ""},
                {name: "apiKey", value: $key},
                {name: $cf, value: $cv}
            ]
        }'
}

arr_configure_sabnzbd() {
    sabnzbd_enabled || return 0
    if [ "$#" -eq 0 ]; then
        local rc=0
        local r_key="${RADARR_API_KEY:-}" s_key="${SONARR_API_KEY:-}"
        [ -z "$r_key" ] && [ -f "${INSTALL_DIR:-}/config/radarr/config.xml" ] && \
            r_key=$(sed -n 's/.*<ApiKey>\(.*\)<\/ApiKey>.*/\1/p' "$INSTALL_DIR/config/radarr/config.xml" | head -1)
        [ -z "$s_key" ] && [ -f "${INSTALL_DIR:-}/config/sonarr/config.xml" ] && \
            s_key=$(sed -n 's/.*<ApiKey>\(.*\)<\/ApiKey>.*/\1/p' "$INSTALL_DIR/config/sonarr/config.xml" | head -1)
        if [ -n "$r_key" ]; then
            arr_configure_sabnzbd "Radarr" "7878" "$r_key" "movieCategory" "movies" || rc=1
        fi
        if [ -n "$s_key" ]; then
            arr_configure_sabnzbd "Sonarr" "8989" "$s_key" "tvCategory" "tv" || rc=1
        fi
        return "$rc"
    fi
    local app_name="$1"
    local port="$2"
    local arr_apikey="$3"
    local category_field="$4"
    local category_val="$5"

    local sab_key=""
    [ -s "$INSTALL_DIR/secrets/sabnzbd_api_key.txt" ] && sab_key=$(cat "$INSTALL_DIR/secrets/sabnzbd_api_key.txt" 2>/dev/null || true)
    [ -z "$sab_key" ] && sab_key=$(sabnzbd_extract_api_key "$INSTALL_DIR/config/sabnzbd/sabnzbd.ini" || true)
    if [ -z "$sab_key" ]; then
        log_step_fail "${app_name}: SABnzbd API key missing — cannot wire Usenet client"
        return 1
    fi

    local clients schemas payload existing_id result
    clients=$(api_get "$port" "/api/v3/downloadclient" "$arr_apikey" || echo "[]")
    schemas=$(api_get "$port" "/api/v3/downloadclient/schema" "$arr_apikey" || echo "[]")
    payload=$(arr_build_sabnzbd_payload "$schemas" "$sab_key" "$category_field" "$category_val")
    if [ -z "$payload" ]; then
        log_step_fail "${app_name}: failed to build SABnzbd payload"
        return 1
    fi

    existing_id=$(printf '%s' "$clients" | jq -r '[.[] | select(.implementation == "Sabnzbd")][0].id // empty' 2>/dev/null || true)
    if [ -n "$existing_id" ]; then
        payload=$(printf '%s' "$payload" | jq -c --argjson id "$existing_id" '.id = $id')
        result=$(api_put "$port" "/api/v3/downloadclient/${existing_id}" "$arr_apikey" "$payload" || echo "")
    else
        result=$(api_post_force "$port" "/api/v3/downloadclient" "$arr_apikey" "$payload" || echo "")
    fi

    if jq_json_has_key "$result" "id"; then
        log_step "${app_name}: wired SABnzbd download client (category: ${category_val})"
        return 0
    fi
    log_step_fail "${app_name}: failed to wire SABnzbd download client"
    return 1
}

sabnzbd_change_credentials() {
    sabnzbd_enabled || return 0
    local sab_key=""
    [ -s "$INSTALL_DIR/secrets/sabnzbd_api_key.txt" ] && sab_key=$(cat "$INSTALL_DIR/secrets/sabnzbd_api_key.txt" 2>/dev/null || true)
    [ -z "$sab_key" ] && sab_key=$(sabnzbd_extract_api_key "$INSTALL_DIR/config/sabnzbd/sabnzbd.ini" || true)
    [ -n "$sab_key" ] || { log_step_fail "SABnzbd: API key missing"; return 1; }

    if _sab_set_config_misc "$sab_key" "username" "$AUTH_USERNAME" && \
       _sab_set_config_misc "$sab_key" "password" "$AUTH_PASSWORD"; then
        log_step "SABnzbd: set login (${AUTH_USERNAME})"
        return 0
    fi
    log_step_fail "SABnzbd: failed to update login"
    return 1
}
