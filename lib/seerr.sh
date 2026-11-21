#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# assemblrr Seerr configuration — sourced by config.sh / config_edit.sh
# Requires: lib/core.sh, lib/api.sh, lib/quality.sh, lib/arr_quality.sh

if [ -n "${_ASSEMBLRR_SEERR_SOURCED:-}" ]; then
    return 0
fi
readonly _ASSEMBLRR_SEERR_SOURCED=1

_seerr_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/quality.sh
[ -f "$_seerr_dir/quality.sh" ] && source "$_seerr_dir/quality.sh"

seerr_connect_service() {
    local service_type="$1"
    local service_port="$2"
    local api_key="$3"
    local profile_func="$4"
    local active_dir="$5"
    local is_4k="$6"
    local cookie_jar="$7"
    local existing_id="${8:-}"

    if [ -z "$api_key" ]; then
        log_step_fail "Seerr: ${service_type} API key not provided"
        return 1
    fi
    if [ -z "$cookie_jar" ] || [ ! -f "$cookie_jar" ]; then
        log_step_fail "Seerr: cookie jar not found for ${service_type} connection"
        return 1
    fi

    local profile profile_id profile_name
    profile=$($profile_func "$api_key")
    profile_id="${profile%%:*}"
    profile_name="${profile##*:}"

    local payload
    payload=$(jq -nc \
        --arg name "${service_type^}" \
        --arg host "$service_type" \
        --argjson port "$service_port" \
        --arg apikey "$api_key" \
        --argjson is4k "$is_4k" \
        --argjson pid "$profile_id" \
        --arg pname "$profile_name" \
        --arg dir "$active_dir" \
        --arg stype "$service_type" '
        {
          name: $name,
          hostname: $host,
          port: $port,
          apiKey: $apikey,
          useSsl: false,
          baseUrl: "",
          isDefault: true,
          is4k: $is4k,
          minimumAvailability: "released",
          syncEnabled: true,
          activeProfileId: $pid,
          activeProfileName: $pname,
          activeDirectory: $dir,
          tags: []
        } + (if $stype == "sonarr" then {enableSeasonFolders: true} else {} end)
    ' 2>/dev/null || echo "")

    if [ -z "$payload" ]; then
        log_step_fail "Seerr: failed to build ${service_type} payload"
        return 1
    fi

    if [ -n "$existing_id" ]; then
        if http_request PUT "http://${API_HOST}:5055/api/v1/settings/${service_type}/${existing_id}" \
            -b "$cookie_jar" -H "Content-Type: application/json" -d "$payload"; then
            log_step "Seerr: updated ${service_type^} profile → ${profile_name}"
            return 0
        fi
        log_step_fail "Seerr: failed to update ${service_type} (HTTP ${HTTP_STATUS})"
        return 1
    fi

    if http_request POST "http://${API_HOST}:5055/api/v1/settings/${service_type}" \
        -b "$cookie_jar" -H "Content-Type: application/json" -d "$payload"; then
        log_step "Seerr: connected ${service_type^} (profile: ${profile_name})"
        return 0
    fi
    log_step_fail "Seerr: failed to connect ${service_type} (HTTP ${HTTP_STATUS})"
    return 1
}

seerr_service_id() {
    local service_type="$1"
    local cookie_jar="$2"
    if ! http_request GET "http://${API_HOST}:5055/api/v1/settings/${service_type}" -b "$cookie_jar"; then
        echo ""
        return 1
    fi
    if [ -z "$HTTP_BODY" ] || [ "$HTTP_BODY" = "[]" ]; then
        echo ""
        return 1
    fi
    printf '%s' "$HTTP_BODY" | jq -r '.[0].id // empty' 2>/dev/null || echo ""
}

seerr_get_cookie() {
    local cookie_jar="$1"
    local include_hostname="$2"
    local payload

    if [ "$include_hostname" = "true" ]; then
        payload=$(jq -nc \
            --arg user "$AUTH_USERNAME" \
            --arg pass "$AUTH_PASSWORD" \
            '{username:$user,password:$pass,hostname:"jellyfin",port:8096,useSsl:false,urlBase:"",email:"",serverType:2}')
    else
        payload=$(jq -nc --arg user "$AUTH_USERNAME" --arg pass "$AUTH_PASSWORD" \
            '{username:$user,password:$pass}')
    fi

    http_request POST "http://${API_HOST}:5055/api/v1/auth/jellyfin" \
        -c "$cookie_jar" -H "Content-Type: application/json" -d "$payload" >/dev/null || true

    if [ ! -s "$cookie_jar" ] || ! grep -q "connect.sid" "$cookie_jar" 2>/dev/null; then
        return 1
    fi
    return 0
}

_seerr_ready() {
    http_request GET "http://${API_HOST}:5055/api/v1/settings/public"
}

configure_seerr() {
    local seerr_port=5055
    local max_wait=120

    if ! wait_until "Waiting for Seerr to start" "$max_wait" 3 _seerr_ready; then
        log_step_fail "Seerr: not responsive after ${max_wait}s"
        return 1
    fi

    if [ "${MEDIA_SERVICE:-jellyfin}" != "jellyfin" ]; then
        log_step_fail "Seerr: unsupported media service '${MEDIA_SERVICE:-}' (core stack supports Jellyfin)"
        return 1
    fi

    local public_settings initialized=""
    http_request GET "http://${API_HOST}:${seerr_port}/api/v1/settings/public" || true
    public_settings="$HTTP_BODY"
    if [ -n "$public_settings" ]; then
        initialized=$(printf '%s' "$public_settings" | jq -r '.initialized // ""' 2>/dev/null || echo "")
    fi

    local seerr_cookie_jar
    seerr_cookie_jar=$(mktemp)

    if [ "$initialized" = "True" ] || [ "$initialized" = "true" ]; then
        log_step "Seerr: setup already completed — configuring services"
        if ! seerr_get_cookie "$seerr_cookie_jar" "false"; then
            rm -f "$seerr_cookie_jar"
            log_step_fail "Seerr: failed to get session cookie for reconfiguration"
            return 1
        fi

        # Single-instance setup: Seerr treats is4k=true as a secondary 4K-only server and fails
        # default requests when no non-4K server exists; 4K quality is governed by activeProfileName.
        local connect_errors=0 is_4k="false"
        if [ -n "${RADARR_API_KEY:-}" ]; then
            local radarr_id
            radarr_id=$(seerr_service_id "radarr" "$seerr_cookie_jar" || true)
            if ! seerr_connect_service "radarr" 7878 "$RADARR_API_KEY" "lookup_radarr_profile" \
                "/data/media/movies" "$is_4k" "$seerr_cookie_jar" "$radarr_id"; then
                log_step_fail "Seerr: failed to configure Radarr (re-run to retry)"
                connect_errors=$((connect_errors + 1))
            fi
        fi
        if [ -n "${SONARR_API_KEY:-}" ]; then
            local sonarr_id
            sonarr_id=$(seerr_service_id "sonarr" "$seerr_cookie_jar" || true)
            if ! seerr_connect_service "sonarr" 8989 "$SONARR_API_KEY" "lookup_sonarr_profile" \
                "/data/media/tv" "$is_4k" "$seerr_cookie_jar" "$sonarr_id"; then
                log_step_fail "Seerr: failed to configure Sonarr (re-run to retry)"
                connect_errors=$((connect_errors + 1))
            fi
        fi

        echo >&2
        rm -f "$seerr_cookie_jar"
        [ "$connect_errors" -eq 0 ]
        return $?
    fi

    local auth_payload
    auth_payload=$(jq -nc \
        --arg user "$AUTH_USERNAME" \
        --arg pass "$AUTH_PASSWORD" \
        '{username:$user,password:$pass,hostname:"jellyfin",port:8096,useSsl:false,urlBase:"",email:"",serverType:2}')

    _cfg_log_info "Seerr: authenticating against Jellyfin..."

    http_request POST "http://${API_HOST}:${seerr_port}/api/v1/auth/jellyfin" \
        -c "$seerr_cookie_jar" -H "Content-Type: application/json" -d "$auth_payload" || true
    local auth_response="$HTTP_BODY"

    if [ -z "$auth_response" ]; then
        rm -f "$seerr_cookie_jar"
        log_step_fail "Seerr: failed to authenticate (empty response)"
        _cfg_log_info "  Complete setup manually at http://${API_HOST}:${seerr_port}"
        return 1
    fi

    local auth_error
    auth_error=$(printf '%s' "$auth_response" | jq -r '.error // ""' 2>/dev/null || echo "")
    if [ -n "$auth_error" ]; then
        if echo "$auth_error" | grep -qi "already configured"; then
            log_step "Seerr: media server already connected"
        else
            local auth_message
            auth_message=$(printf '%s' "$auth_response" | jq -r '.message // .error // "unknown error"' 2>/dev/null || echo "unknown error")
            rm -f "$seerr_cookie_jar"
            log_step_fail "Seerr: authentication failed — ${auth_message}"
            _cfg_log_info "  Complete setup manually at http://${API_HOST}:${seerr_port}"
            return 1
        fi
    else
        local auth_id
        auth_id=$(printf '%s' "$auth_response" | jq -r '.id // ""' 2>/dev/null || echo "")
        if [ -n "$auth_id" ]; then
            log_step "Seerr: authenticated against Jellyfin (admin user created)"
        else
            rm -f "$seerr_cookie_jar"
            log_step_fail "Seerr: authentication returned unexpected response"
            _cfg_log_info "  Complete setup manually at http://${API_HOST}:${seerr_port}"
            return 1
        fi
    fi

    if [ ! -s "$seerr_cookie_jar" ] || ! grep -q "connect.sid" "$seerr_cookie_jar" 2>/dev/null; then
        if ! seerr_get_cookie "$seerr_cookie_jar" "true" && ! seerr_get_cookie "$seerr_cookie_jar" "false"; then
            rm -f "$seerr_cookie_jar"
            log_step_fail "Seerr: failed to get session cookie"
            return 1
        fi
    fi

    if http_request POST "http://${API_HOST}:${seerr_port}/api/v1/settings/initialize" \
        -b "$seerr_cookie_jar" -H "Content-Type: application/json"; then
        log_step "Seerr: setup completed successfully"
    else
        rm -f "$seerr_cookie_jar"
        log_step_fail "Seerr: failed to finalize setup (HTTP ${HTTP_STATUS})"
        _cfg_log_info "  Complete setup manually at http://${API_HOST}:${seerr_port}"
        return 1
    fi

    # Single-instance setup: Seerr treats is4k=true as a secondary 4K-only server and fails
    # default requests when no non-4K server exists; 4K quality is governed by activeProfileName.
    local connect_errors=0 is_4k="false"
    if [ -n "${RADARR_API_KEY:-}" ]; then
        if ! seerr_connect_service "radarr" 7878 "$RADARR_API_KEY" "lookup_radarr_profile" \
            "/data/media/movies" "$is_4k" "$seerr_cookie_jar"; then
            connect_errors=$((connect_errors + 1))
        fi
    fi
    if [ -n "${SONARR_API_KEY:-}" ]; then
        if ! seerr_connect_service "sonarr" 8989 "$SONARR_API_KEY" "lookup_sonarr_profile" \
            "/data/media/tv" "$is_4k" "$seerr_cookie_jar"; then
            connect_errors=$((connect_errors + 1))
        fi
    fi

    rm -f "$seerr_cookie_jar"
    [ "$connect_errors" -eq 0 ]
}

seerr_verify_login() {
    local seerr_cookie_jar
    seerr_cookie_jar=$(mktemp)
    if seerr_get_cookie "$seerr_cookie_jar" "false" || seerr_get_cookie "$seerr_cookie_jar" "true"; then
        rm -f "$seerr_cookie_jar"
        log_step "Seerr: session works with the new Jellyfin password"
        return 0
    fi
    rm -f "$seerr_cookie_jar"
    log_step_fail "Seerr: could not open a session (it uses the Jellyfin login)"
    return 1
}
