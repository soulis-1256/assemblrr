#!/bin/bash
# assemblrr Seerr & Recyclarr configuration — sourced by configure.sh
# Provides: configure_seerr, configure_recyclarr
# Requires: lib/core.sh (logging), lib/api.sh (api_get/post helpers),
#           lib/arr.sh (lookup_radarr_profile, lookup_sonarr_profile),
#           configure.sh (_cfg_log_info, log_step, log_step_fail, etc.)

set -euo pipefail

# --- Shared helper: connect a service (Radarr/Sonarr) to Seerr ---
# Usage: seerr_connect_service <service_type> <port> <api_key> <profile_func> <active_dir> <is_4k> <cookie_jar>
# Example: seerr_connect_service "radarr" 7878 "$RADARR_API_KEY" "lookup_radarr_profile" "/data/media/movies" "true" "$cookie_jar"
seerr_connect_service() {
    local service_type="$1"
    local service_port="$2"
    local api_key="$3"
    local profile_func="$4"
    local active_dir="$5"
    local is_4k="$6"
    local cookie_jar="$7"

    if [ -z "$api_key" ]; then
        log_step_fail "Seerr: ${service_type} API key not provided"
        return 1
    fi

    if [ -z "$cookie_jar" ] || [ ! -f "$cookie_jar" ]; then
        log_step_fail "Seerr: cookie jar not found for ${service_type} connection"
        return 1
    fi

    # Look up quality profile from the service (created by Recyclarr)
    local profile
    profile=$($profile_func "$api_key")
    local profile_id="${profile%%:*}"
    local profile_name="${profile##*:}"

    # Build the service payload
    local payload
    payload=$(cat <<EOF
{
  "name": "${service_type^}",
  "hostname": "${service_type}",
  "port": ${service_port},
  "apiKey": "${api_key}",
  "useSsl": false,
  "baseUrl": "",
  "isDefault": true,
  "is4k": ${is_4k},
  "minimumAvailability": "released",
  "syncEnabled": true,
  "activeProfileId": ${profile_id},
  "activeProfileName": "${profile_name}",
  "activeDirectory": "${active_dir}",
  "tags": []
}
EOF
)

    # Special handling for Sonarr (needs enableSeasonFolders)
    if [ "$service_type" = "sonarr" ]; then
        payload=$(echo "$payload" | jq '.enableSeasonFolders = true' 2>/dev/null || echo "$payload")
    fi

    # POST to Seerr
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 -X POST -b "$cookie_jar" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "http://${API_HOST}:5055/api/v1/settings/${service_type}" 2>/dev/null || echo "000")

    if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
        log_step "Seerr: connected ${service_type^}"
        return 0
    else
        log_step_fail "Seerr: failed to connect ${service_type} (HTTP $http_code)"
        return 1
    fi
}

# --- Shared helper: check if a service is already connected to Seerr ---
# Usage: seerr_service_connected <service_type> <cookie_jar>
# Returns 0 and prints count if connected, or 1 on failure
seerr_service_connected() {
    local service_type="$1"
    local cookie_jar="$2"

    local svc_list
    svc_list=$(curl -sf --connect-timeout 5 -b "$cookie_jar" \
        "http://${API_HOST}:5055/api/v1/service/${service_type}" 2>/dev/null || echo "")

    if [ -z "$svc_list" ]; then
        return 1
    fi

    local count
    count=$(echo "$svc_list" | jq 'length' 2>/dev/null || echo "0")
    echo "$count"
    return 0
}

# --- Shared helper: get Seerr session cookie ---
# Usage: seerr_get_cookie <cookie_jar> <include_hostname>
# Returns 0 on success, cookie file will be populated
seerr_get_cookie() {
    local cookie_jar="$1"
    local include_hostname="$2"  # "true" or "false"

    local payload
    if [ "$include_hostname" = "true" ]; then
        # Full auth with hostname (for initial setup)
        local media_host="jellyfin"
        case "${MEDIA_SERVICE:-jellyfin}" in
            jellyfin) media_host="jellyfin"; media_port=8096; media_type=2 ;;
            emby)     media_host="emby"; media_port=8096; media_type=3 ;;
            plex)     media_host="host.docker.internal"; media_port=32400; media_type=1 ;;
        esac

        payload=$(cat <<EOF
{
  "username": "${AUTH_USERNAME}",
  "password": "${AUTH_PASSWORD}",
  "hostname": "${media_host}",
  "port": ${media_port},
  "useSsl": false,
  "urlBase": "",
  "email": "",
  "serverType": ${media_type}
}
EOF
)
    else
        # Login-only (for re-runs when media server is already configured)
        payload=$(cat <<EOF
{
  "username": "${AUTH_USERNAME}",
  "password": "${AUTH_PASSWORD}"
}
EOF
)
    fi

    local auth_endpoint="jellyfin"
    curl -s --connect-timeout 5 -c "$cookie_jar" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "http://${API_HOST}:5055/api/v1/auth/${auth_endpoint}" 2>/dev/null >/dev/null || return 1

    # Verify cookie was created
    if [ ! -s "$cookie_jar" ] || ! grep -q "connect.sid" "$cookie_jar" 2>/dev/null; then
        return 1
    fi

    return 0
}

# --- Recyclarr configuration ---

configure_recyclarr() {
    local recyclarr_config_dir="$INSTALL_DIR/config/recyclarr"
    mkdir -p "$recyclarr_config_dir"

    if [ ! -w "$recyclarr_config_dir" ]; then
        log_step_fail "Recyclarr: config directory not writable (${recyclarr_config_dir})"
        return 1
    fi

    # Export variables for envsubst
    export RADARR_API_KEY SONARR_API_KEY

    # Pick the right template based on user's 4K choice
    local template_file="recyclarr-full_hd.yml"  # default: 1080p
    local profile_label="HD Bluray + WEB"
    if [ "${SEERR_IS_4K}" = "true" ]; then
        template_file="recyclarr-ultra_hd.yml"    # 4K
        profile_label="UHD Bluray + WEB"
    fi

    if [ -f "$INSTALL_DIR/templates/${template_file}" ]; then
        if envsubst < "$INSTALL_DIR/templates/${template_file}" > "$recyclarr_config_dir/recyclarr.yml"; then
            log_step "Recyclarr: generated config (${profile_label} profile)"
        else
            log_step_fail "Recyclarr: failed to write config (${recyclarr_config_dir}/recyclarr.yml)"
            return 1
        fi
    else
        log_step_fail "Recyclarr: template ${template_file} not found"
        return 1
    fi

    # Trigger a sync
    _cfg_log_info "Recyclarr: syncing TRaSH Guides to Radarr and Sonarr... this might take a moment"
    if docker exec recyclarr recyclarr sync > /dev/null 2>&1; then
        log_step "Recyclarr: synced Custom Formats and Quality Profiles successfully"
    else
        log_step_fail "Recyclarr: failed to sync to Radarr/Sonarr (check docker logs recyclarr)"
    fi
}

# --- Seerr configuration ---

configure_seerr() {
    local seerr_port=5055
    local max_wait=120
    local wait_time=0

    # Step 1: Wait for Seerr to be responsive
    echo >&2
    echo -n "Waiting for Seerr to start" >&2
    while [ $wait_time -lt $max_wait ]; do
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 \
            "http://${API_HOST}:${seerr_port}/api/v1/settings/public" 2>/dev/null || echo "000")
        if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
            break
        fi
        sleep 3
        wait_time=$((wait_time + 3))
        dot_inline
    done
    echo >&2

    if [ $wait_time -ge $max_wait ]; then
        log_step_fail "Seerr: not responsive after ${max_wait}s"
        return 1
    fi

    # Step 2: Check if setup is already complete
    local public_settings
    public_settings=$(curl -s --connect-timeout 5 \
        "http://${API_HOST}:${seerr_port}/api/v1/settings/public" 2>/dev/null || echo "")

    if [ -n "$public_settings" ]; then
        local initialized
        initialized=$(echo "$public_settings" | jq -r '.initialized // ""' 2>/dev/null || echo "")
        if [ "$initialized" = "True" ] || [ "$initialized" = "true" ]; then
            log_step "Seerr: setup already completed — configuring services"
            local seerr_cookie_jar="/tmp/seerr_cookie_jar_$$_${seerr_port}"

            # Get session cookie (no hostname needed — already configured)
            if ! seerr_get_cookie "$seerr_cookie_jar" "false"; then
                log_step_fail "Seerr: failed to get session cookie for reconfiguration"
                return 1
            fi

            echo "Connecting Seerr services" >&2

            # Connect Radarr if not already connected
            if [ -n "$RADARR_API_KEY" ]; then
                local radarr_count
                radarr_count=$(seerr_service_connected "radarr" "$seerr_cookie_jar") || radarr_count=0
                if [ "$radarr_count" -eq 0 ]; then
                    if ! seerr_connect_service "radarr" 7878 "$RADARR_API_KEY" "lookup_radarr_profile" \
                        "/data/media/movies" "${SEERR_IS_4K:-false}" "$seerr_cookie_jar"; then
                        log_step_fail "Seerr: failed to connect Radarr (re-run to retry)"
                    fi
                else
                    log_step "Seerr: Radarr already connected"
                fi
            fi

            # Connect Sonarr if not already connected
            if [ -n "$SONARR_API_KEY" ]; then
                local sonarr_count
                sonarr_count=$(seerr_service_connected "sonarr" "$seerr_cookie_jar") || sonarr_count=0
                if [ "$sonarr_count" -eq 0 ]; then
                    if ! seerr_connect_service "sonarr" 8989 "$SONARR_API_KEY" "lookup_sonarr_profile" \
                        "/data/media/tv" "false" "$seerr_cookie_jar"; then
                        log_step_fail "Seerr: failed to connect Sonarr (re-run to retry)"
                    fi
                else
                    log_step "Seerr: Sonarr already connected"
                fi
            fi

            echo >&2
            rm -f "$seerr_cookie_jar"
            return 0
        fi
    fi

    # Step 3: Determine media server connection details
    local media_server_type=""
    local media_server_host=""
    local media_server_port=0

    case "${MEDIA_SERVICE:-jellyfin}" in
        jellyfin)
            media_server_type="2"
            media_server_host="jellyfin"
            media_server_port=8096
            ;;
        emby)
            media_server_type="3"
            media_server_host="emby"
            media_server_port=8096
            ;;
        plex)
            # Plex uses host networking — Seerr needs the host IP
            media_server_type="1"
            media_server_host="host.docker.internal"
            media_server_port=32400
            ;;
    esac

    if [ -z "$media_server_type" ]; then
        log_step_fail "Seerr: unsupported media service '${MEDIA_SERVICE:-}'"
        return 1
    fi

    # Step 4: Authenticate against the media server via Seerr's setup endpoint
    # This creates the admin user in Seerr and stores the media server connection
    local auth_payload
    if [ "${MEDIA_SERVICE:-}" = "plex" ]; then
        # Plex requires an authToken from Plex.tv OAuth — cannot automate without user interaction
        log_step "Seerr: Plex detected — manual setup required via web UI at http://${API_HOST}:${seerr_port}"
        _cfg_log_info "  Log in with your Plex account to complete Seerr setup"
        return 0
    fi

    # Jellyfin/Emby: use credential-based auth (both use /auth/jellyfin endpoint)
    local auth_endpoint="jellyfin"

    auth_payload=$(cat <<EOF
{
  "username": "${AUTH_USERNAME}",
  "password": "${AUTH_PASSWORD}",
  "hostname": "${media_server_host}",
  "port": ${media_server_port},
  "useSsl": false,
  "urlBase": "",
  "email": "",
  "serverType": ${media_server_type}
}
EOF
)

    _cfg_log_info "Seerr: authenticating against ${MEDIA_SERVICE:-jellyfin}..."

    # Use -s (not -sf) so we can capture error responses too
    local auth_response
    auth_response=$(curl -s --connect-timeout 10 -X POST \
        -H "Content-Type: application/json" \
        -d "$auth_payload" \
        "http://${API_HOST}:${seerr_port}/api/v1/auth/${auth_endpoint}" 2>/dev/null || echo "")

    if [ -z "$auth_response" ]; then
        log_step_fail "Seerr: failed to authenticate (empty response)"
        _cfg_log_info "  Complete setup manually at http://${API_HOST}:${seerr_port}"
        return 1
    fi

    # Check for error in response — "hostname already configured" means media server
    # was connected by a previous run, which is fine (admin user already exists)
    local auth_error
    auth_error=$(echo "$auth_response" | jq -r '.error // ""' 2>/dev/null || echo "")
    if [ -n "$auth_error" ]; then
        if echo "$auth_error" | grep -qi "already configured"; then
            log_step "Seerr: media server already connected"
        else
            local auth_message
            auth_message=$(echo "$auth_response" | jq -r '.message // .error // "unknown error"' 2>/dev/null || echo "unknown error")
            log_step_fail "Seerr: authentication failed — ${auth_message}"
            _cfg_log_info "  Complete setup manually at http://${API_HOST}:${seerr_port}"
            return 1
        fi
    else
        # Successful auth — verify admin user was created
        local auth_id
        auth_id=$(echo "$auth_response" | jq -r '.id // ""' 2>/dev/null || echo "")
        if [ -n "$auth_id" ]; then
            log_step "Seerr: authenticated against ${MEDIA_SERVICE:-jellyfin} (admin user created)"
        else
            log_step_fail "Seerr: authentication returned unexpected response"
            _cfg_log_info "  Complete setup manually at http://${API_HOST}:${seerr_port}"
            return 1
        fi
    fi

    # Step 5: Get a session cookie for subsequent API calls
    local seerr_cookie_jar="/tmp/seerr_cookie_jar_$$_${seerr_port}"

    # Get session cookie (with hostname for initial setup)
    if ! seerr_get_cookie "$seerr_cookie_jar" "true"; then
        # Retry with login-only if first attempt fails (hostname already configured)
        if ! seerr_get_cookie "$seerr_cookie_jar" "false"; then
            log_step_fail "Seerr: failed to get session cookie"
            rm -f "$seerr_cookie_jar"
            return 1
        fi
    fi

    # Note: Library sync is skipped here — Jellyfin hasn't indexed anything yet on first setup.
    # Seerr will auto-sync libraries periodically (every 24h) once content exists.

    # Step 6: Initialize Seerr (mark setup as complete)
    local init_code
    init_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 -X POST -b "$seerr_cookie_jar" \
        -H "Content-Type: application/json" \
        "http://${API_HOST}:${seerr_port}/api/v1/settings/initialize" 2>/dev/null || echo "000")

    if [ "$init_code" -ge 200 ] && [ "$init_code" -lt 300 ]; then
        log_step "Seerr: setup completed successfully"
    else
        log_step_fail "Seerr: failed to finalize setup (HTTP $init_code)"
        _cfg_log_info "  Complete setup manually at http://${API_HOST}:${seerr_port}"
        rm -f "$seerr_cookie_jar"
        return 1
    fi

    echo "Connecting Seerr services" >&2

    # Connect Radarr and Sonarr using shared helper
    local connect_errors=0
    if [ -n "$RADARR_API_KEY" ]; then
        if ! seerr_connect_service "radarr" 7878 "$RADARR_API_KEY" "lookup_radarr_profile" \
            "/data/media/movies" "${SEERR_IS_4K:-false}" "$seerr_cookie_jar"; then
            connect_errors=$((connect_errors + 1))
        fi
    fi

    if [ -n "$SONARR_API_KEY" ]; then
        if ! seerr_connect_service "sonarr" 8989 "$SONARR_API_KEY" "lookup_sonarr_profile" \
            "/data/media/tv" "false" "$seerr_cookie_jar"; then
            connect_errors=$((connect_errors + 1))
        fi
    fi

    echo >&2
    rm -f "$seerr_cookie_jar"

    if [ $connect_errors -gt 0 ]; then
        return 1
    fi
}
