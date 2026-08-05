#!/bin/bash
# assemblrr Seerr & Recyclarr configuration — sourced by config.sh
# Provides: configure_seerr, configure_recyclarr
# Requires: lib/core.sh (logging), lib/api.sh (api_get/post helpers),
#           lib/arr.sh (lookup_radarr_profile, lookup_sonarr_profile),
#           config.sh (_cfg_log_info, log_step, log_step_fail, etc.)

set -euo pipefail

# --- Shared helper: connect or update a service (Radarr/Sonarr) in Seerr ---
# Usage: seerr_connect_service <service_type> <port> <api_key> <profile_func> <active_dir> <is_4k> <cookie_jar> [existing_id]
# With existing_id: PUT update; without: POST create.
# Example: seerr_connect_service "radarr" 7878 "$RADARR_API_KEY" "lookup_radarr_profile" "/data/media/movies" "true" "$cookie_jar"
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

    local profile
    profile=$($profile_func "$api_key")
    local profile_id="${profile%%:*}"
    local profile_name="${profile##*:}"

    # id is read-only on PUT — omit it from the body
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

    local http_code
    if [ -n "$existing_id" ]; then
        http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 -X PUT -b "$cookie_jar" \
            -H "Content-Type: application/json" \
            -d "$payload" \
            "http://${API_HOST}:5055/api/v1/settings/${service_type}/${existing_id}" 2>/dev/null || echo "000")
        if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
            log_step "Seerr: updated ${service_type^} profile → ${profile_name}"
            return 0
        else
            log_step_fail "Seerr: failed to update ${service_type} (HTTP $http_code)"
            return 1
        fi
    fi

    # POST new connection
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 -X POST -b "$cookie_jar" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "http://${API_HOST}:5055/api/v1/settings/${service_type}" 2>/dev/null || echo "000")

    if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
        log_step "Seerr: connected ${service_type^} (profile: ${profile_name})"
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

# --- Shared helper: first existing Seerr server id for a service (or empty) ---
# Usage: seerr_service_id <service_type> <cookie_jar>
seerr_service_id() {
    local service_type="$1"
    local cookie_jar="$2"

    local settings
    settings=$(curl -sf --connect-timeout 5 -b "$cookie_jar" \
        "http://${API_HOST}:5055/api/v1/settings/${service_type}" 2>/dev/null || echo "")

    if [ -z "$settings" ] || [ "$settings" = "[]" ]; then
        echo ""
        return 1
    fi

    echo "$settings" | jq -r '.[0].id // empty' 2>/dev/null || echo ""
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
    local template_root="$INSTALL_DIR/templates/recyclarr"
    mkdir -p "$recyclarr_config_dir/includes"

    if [ ! -w "$recyclarr_config_dir" ]; then
        log_step_fail "Recyclarr: config directory not writable (${recyclarr_config_dir})"
        return 1
    fi

    # Only substitute known vars so $schema in YAML comments is left alone
    export RADARR_API_KEY SONARR_API_KEY

    local default_label="assemblrr HD Bluray + WEB"
    if [ "${SEERR_IS_4K}" = "true" ]; then
        default_label="assemblrr UHD Bluray + WEB"
    fi

    if [ ! -f "$template_root/recyclarr.yml" ]; then
        log_step_fail "Recyclarr: template root not found (${template_root}/recyclarr.yml)"
        return 1
    fi

    if ! envsubst '${RADARR_API_KEY} ${SONARR_API_KEY}' \
        < "$template_root/recyclarr.yml" \
        > "$recyclarr_config_dir/recyclarr.yml"; then
        log_step_fail "Recyclarr: failed to write config (${recyclarr_config_dir}/recyclarr.yml)"
        return 1
    fi

    # Include packs (no secrets). Replace the directory contents with the template set.
    local include_src="$template_root/includes"
    if [ ! -d "$include_src" ]; then
        log_step_fail "Recyclarr: includes directory not found (${include_src})"
        return 1
    fi
    rm -f "$recyclarr_config_dir/includes"/*.yml 2>/dev/null || true
    if ! cp "$include_src"/*.yml "$recyclarr_config_dir/includes/"; then
        log_step_fail "Recyclarr: failed to copy include packs"
        return 1
    fi

    local pack_count
    pack_count=$(find "$recyclarr_config_dir/includes" -maxdepth 1 -name '*.yml' | wc -l | tr -d ' ')
    log_step "Recyclarr: generated config (${pack_count} include packs; Seerr default: ${default_label})"

    _cfg_log_info "Recyclarr: syncing TRaSH Guides to Radarr and Sonarr... this might take a moment"
    local sync_out
    if sync_out=$(docker exec recyclarr recyclarr sync 2>&1); then
        log_step "Recyclarr: synced Custom Formats and Quality Profiles successfully"
    else
        log_step_fail "Recyclarr: failed to sync to Radarr/Sonarr"
        echo "$sync_out" | grep -E '•|Error|error|Invalid|YAML' | head -5 | while IFS= read -r line; do
            _cfg_log_info "  $line"
        done
        return 1
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

            if [ -n "$RADARR_API_KEY" ]; then
                local radarr_id
                radarr_id=$(seerr_service_id "radarr" "$seerr_cookie_jar" || true)
                if ! seerr_connect_service "radarr" 7878 "$RADARR_API_KEY" "lookup_radarr_profile" \
                    "/data/media/movies" "${SEERR_IS_4K:-false}" "$seerr_cookie_jar" "$radarr_id"; then
                    log_step_fail "Seerr: failed to configure Radarr (re-run to retry)"
                fi
            fi

            if [ -n "$SONARR_API_KEY" ]; then
                local sonarr_id
                sonarr_id=$(seerr_service_id "sonarr" "$seerr_cookie_jar" || true)
                if ! seerr_connect_service "sonarr" 8989 "$SONARR_API_KEY" "lookup_sonarr_profile" \
                    "/data/media/tv" "false" "$seerr_cookie_jar" "$sonarr_id"; then
                    log_step_fail "Seerr: failed to configure Sonarr (re-run to retry)"
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

    # "already configured" is success when re-running against an initialized Seerr
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

    # Step 5: session cookie for subsequent API calls
    local seerr_cookie_jar="/tmp/seerr_cookie_jar_$$_${seerr_port}"

    if ! seerr_get_cookie "$seerr_cookie_jar" "true"; then
        if ! seerr_get_cookie "$seerr_cookie_jar" "false"; then
            log_step_fail "Seerr: failed to get session cookie"
            rm -f "$seerr_cookie_jar"
            return 1
        fi
    fi

    # Step 6: mark setup complete
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
