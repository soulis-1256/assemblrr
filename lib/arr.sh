#!/bin/bash
# assemblrr *arr service configuration — sourced by config.sh
# Provides: set_arr_auth, qbit helpers, configure_arr_service, profile lookups,
#           configure_radarr, configure_sonarr, configure_prowlarr
# Requires: lib/core.sh (logging), lib/api.sh (api_get/post/put/delete helpers),
#           config.sh (_cfg_log_info, log_step, log_step_fail, AUTH_USERNAME, etc.)

set -euo pipefail

# --- Shared auth config for *arr services ---

set_arr_auth() {
    local service_name="$1"
    local port="$2"
    local apikey="$3"
    local api_version="${4:-v3}"

    if [ -z "$AUTH_USERNAME" ] || [ -z "$AUTH_PASSWORD" ]; then
        log_step_fail "${service_name}: auth credentials missing — cannot enable forms auth"
        return 1
    fi

    local host_config
    host_config=$(api_get "$port" "/api/${api_version}/config/host" "$apikey")
    if [ -z "$host_config" ]; then
        log_step_fail "${service_name}: failed to read host config for authentication"
        return 1
    fi

    local host_id
    host_id=$(jq_json_get "$host_config" "id")
    host_id=${host_id:-1}

    local updated_config
    updated_config=$(echo "$host_config" | jq --arg hid "$host_id" --arg user "$AUTH_USERNAME" --arg pass "$AUTH_PASSWORD" \
        '.id = ($hid | tonumber) | .authenticationMethod = "forms" | .authenticationRequired = "enabled" | .username = $user | .password = $pass | .passwordConfirmation = $pass' 2>/dev/null || echo "")

    if [ -z "$updated_config" ]; then
        log_step_fail "${service_name}: failed to build auth config payload"
        return 1
    fi

    local auth_result
    auth_result=$(api_put "$port" "/api/${api_version}/config/host" "$apikey" "$updated_config")
    if jq_json_has_key "$auth_result" "id"; then
        log_step "${service_name}: set authentication (username: $AUTH_USERNAME)"
        return 0
    fi
    log_step_fail "${service_name}: failed to set authentication"
    return 1
}

# --- qBittorrent helpers ---

# Set qBittorrent WebUI credentials and default save paths.
# Prefer final credentials when already configured (avoids brute-force lockouts).
qbit_set_credentials() {
    local qbit_port=8081
    local qbit_cookie_jar="/tmp/qb_cookie_jar_init_$$_${qbit_port}"

    # Idempotent: succeed if final credentials already work
    if [ -n "$AUTH_USERNAME" ] && [ -n "$AUTH_PASSWORD" ]; then
        curl -s --connect-timeout 5 -c "$qbit_cookie_jar" \
            -H "Referer: http://${API_HOST}:${qbit_port}" \
            -d "username=${AUTH_USERNAME}&password=${AUTH_PASSWORD}" \
            "http://${API_HOST}:${qbit_port}/api/v2/auth/login" 2>/dev/null >/dev/null || true
        local qbit_sid
        qbit_sid=$(qbit_cookie_sid "$qbit_cookie_jar")
        if [ -n "$qbit_sid" ]; then
            curl -s --connect-timeout 5 \
                "http://${API_HOST}:${qbit_port}/api/v2/app/setPreferences" \
                -b "$qbit_cookie_jar" \
                -H "Referer: http://${API_HOST}:${qbit_port}" \
                -d "json={\"save_path\":\"/data/torrents\",\"temp_path\":\"/data/torrents/incomplete\",\"temp_path_enabled\":true}" \
                2>/dev/null >/dev/null || true
            _cfg_log_info "qBittorrent credentials already set"
            rm -f "$qbit_cookie_jar"
            return 0
        fi
    fi

    # First-time setup: temporary password from container logs
    local wait_time=0
    local max_wait=60

    echo -n "Waiting for qBittorrent to initialize" >&2
    while [ $wait_time -lt $max_wait ]; do
        local qbit_temp_pass
        qbit_temp_pass=$(docker logs qbittorrent 2>&1 | awk -F': ' '/temporary password is provided for this session:/ { print $NF; exit }' || true)

        if [ -n "$qbit_temp_pass" ]; then
            curl -s --connect-timeout 5 -c "$qbit_cookie_jar" \
                -H "Referer: http://${API_HOST}:${qbit_port}" \
                -d "username=admin&password=${qbit_temp_pass}" \
                "http://${API_HOST}:${qbit_port}/api/v2/auth/login" 2>/dev/null >/dev/null || true
            local qbit_sid
            qbit_sid=$(qbit_cookie_sid "$qbit_cookie_jar")
            if [ -n "$qbit_sid" ]; then
                curl -s --connect-timeout 5 \
                    "http://${API_HOST}:${qbit_port}/api/v2/app/setPreferences" \
                    -b "$qbit_cookie_jar" \
                    -H "Referer: http://${API_HOST}:${qbit_port}" \
                    -d "json={\"web_ui_username\":\"${AUTH_USERNAME}\",\"web_ui_password\":\"${AUTH_PASSWORD}\",\"save_path\":\"/data/torrents\",\"temp_path\":\"/data/torrents/incomplete\",\"temp_path_enabled\":true}" \
                    2>/dev/null >/dev/null || true
                echo >&2
                _cfg_log_info "Set qBittorrent credentials and save path"
                rm -f "$qbit_cookie_jar"
                return 0
            fi
        fi
        sleep 3
        wait_time=$((wait_time + 3))
        dot_inline
    done
    echo >&2
    log_warning "Could not login to qBittorrent with temp password"
    rm -f "$qbit_cookie_jar"
    return 1
}

# Create or update a qBittorrent category with a save path
qbit_create_category() {
    local service_name="$1"
    local category="$2"
    local save_path="$3"

    local qbit_port=8081
    local qbit_cookie_jar="/tmp/qb_cookie_jar_${service_name}_$$_${qbit_port}"
    curl -s --connect-timeout 10 -c "$qbit_cookie_jar" \
        -H "Referer: http://${API_HOST}:${qbit_port}" \
        -d "username=${AUTH_USERNAME}&password=${AUTH_PASSWORD}" \
        "http://${API_HOST}:${qbit_port}/api/v2/auth/login" 2>/dev/null >/dev/null || true
    local qbit_sid
    qbit_sid=$(qbit_cookie_sid "$qbit_cookie_jar")
    if [ -z "$qbit_sid" ]; then
        log_step_fail "${service_name}: could not login to qBittorrent to create categories"
        rm -f "$qbit_cookie_jar"
        return 1
    fi

    # createCategory + editCategory so savePath is set whether the category is new or existing
    curl -s --connect-timeout 10 \
        "http://${API_HOST}:${qbit_port}/api/v2/torrents/createCategory" \
        -b "$qbit_cookie_jar" \
        -H "Referer: http://${API_HOST}:${qbit_port}" \
        -d "category=${category}&savePath=${save_path}" \
        2>/dev/null >/dev/null || true
    curl -s --connect-timeout 10 \
        "http://${API_HOST}:${qbit_port}/api/v2/torrents/editCategory" \
        -b "$qbit_cookie_jar" \
        -H "Referer: http://${API_HOST}:${qbit_port}" \
        -d "category=${category}&savePath=${save_path}" \
        2>/dev/null >/dev/null || true
    log_step "${service_name}: qBittorrent '${category}' category → ${save_path}"
    rm -f "$qbit_cookie_jar"
    return 0
}

# --- Shared *arr service configuration ---

# Configure a Radarr or Sonarr instance with common settings
# Parameters:
#   $1  service_name   (e.g. "Radarr" or "Sonarr")
#   $2  port           (e.g. "7878" or "8989")
#   $3  apikey
#   $4  root_path      (e.g. "/data/media/movies" or "/data/media/tv")
#   $5  category_name  (e.g. "movies" or "tv")
#   $6  category_path  (e.g. "/data/torrents/movies" or "/data/torrents/tv")
#   $7  unmonitor_field (e.g. "autoUnmonitorPreviouslyDownloadedMovies" or "autoUnmonitorPreviouslyDownloadedEpisodes")
#   $8  naming_jq      (jq expression for naming convention, or "" to skip)
configure_arr_service() {
    local service_name="$1"
    local port="$2"
    local apikey="$3"
    local root_path="$4"
    local category_name="$5"
    local category_path="$6"
    local unmonitor_field="$7"
    local naming_jq="$8"
    local critical_errors=0

    # 1. Add root folder
    local root_folders
    root_folders=$(api_get "$port" "/api/v3/rootfolder" "$apikey")
    local existing_paths
    existing_paths=$(jq_json_list_values "$root_folders" "path")

    if ! echo "$existing_paths" | grep -q "^${root_path}$"; then
        local rf_result
        rf_result=$(api_post "$port" "/api/v3/rootfolder" "$apikey" "{\"path\":\"${root_path}\"}")
        if jq_json_has_key "$rf_result" "id"; then
            log_step "${service_name}: added ${root_path} as root folder"
        else
            log_step_fail "${service_name}: failed to add root folder"
            critical_errors=$((critical_errors + 1))
        fi
    else
        log_step "${service_name}: root folder ${root_path} already exists"
    fi

    # Keep only the configured root folder
    local all_root_folders
    all_root_folders=$(api_get "$port" "/api/v3/rootfolder" "$apikey")
    local extra_ids
    extra_ids=$(echo "$all_root_folders" | jq -r --arg rp "$root_path" '.[] | select(.path != $rp) | .id' 2>/dev/null || echo "")

    for extra_id in $extra_ids; do
        if [ -n "$extra_id" ]; then
            api_delete "$port" "/api/v3/rootfolder/${extra_id}" "$apikey" >/dev/null || true
            log_step "${service_name}: removed extra root folder (id: ${extra_id})"
        fi
    done

    # 2. Add qBittorrent download client
    local download_clients
    download_clients=$(api_get "$port" "/api/v3/downloadclient" "$apikey")
    local existing_impls
    existing_impls=$(jq_json_list_values "$download_clients" "implementationName")

    if ! echo "$existing_impls" | grep -q "qBittorrent"; then
        # Build download client payload — category field names differ between Radarr and Sonarr
        local qbit_payload
        qbit_payload=$(jq -n --arg host "$QBITTORRENT_HOST" --arg user "$AUTH_USERNAME" --arg pass "$AUTH_PASSWORD" \
            --arg cat_name "$category_name" --arg sn "$service_name" '
            {
                "enable": true,
                "removeCompletedDownloads": true,
                "removeFailedDownloads": true,
                "name": "qBittorrent",
                "implementation": "QBittorrent",
                "implementationName": "qBittorrent",
                "configContract": "QBittorrentSettings",
                "priority": 1,
                "fields": [
                    {"name": "host", "value": $host},
                    {"name": "port", "value": 8081},
                    {"name": "useSsl", "value": false},
                    {"name": "urlBase", "value": ""},
                    {"name": "username", "value": $user},
                    {"name": "password", "value": $pass},
                    {"name": (if $sn == "Radarr" then "movieCategory" else "tvCategory" end), "value": $cat_name},
                    {"name": (if $sn == "Radarr" then "movieImportedCategory" else "tvImportedCategory" end), "value": ""},
                    {"name": (if $sn == "Radarr" then "recentMoviePriority" else "recentTvPriority" end), "value": 0},
                    {"name": (if $sn == "Radarr" then "olderMoviePriority" else "olderTvPriority" end), "value": 0},
                    {"name": "initialState", "value": 0},
                    {"name": "sequentialOrder", "value": false},
                    {"name": "firstAndLast", "value": false},
                    {"name": "contentLayout", "value": 0}
                ]
            }
        ' 2>/dev/null || echo "")

        if [ -n "$qbit_payload" ]; then
            local dc_result
            dc_result=$(api_post "$port" "/api/v3/downloadclient" "$apikey" "$qbit_payload")
            if jq_json_has_key "$dc_result" "id"; then
                log_step "${service_name}: added qBittorrent as download client (host: ${QBITTORRENT_HOST})"
            else
                log_step_fail "${service_name}: failed to add qBittorrent download client"
                critical_errors=$((critical_errors + 1))
            fi
        else
            log_step_fail "${service_name}: failed to build qBittorrent payload"
            critical_errors=$((critical_errors + 1))
        fi
    else
        log_step "${service_name}: qBittorrent download client already exists"
    fi

    # 2b. Create qBittorrent category with correct save path
    if ! qbit_create_category "$service_name" "$category_name" "$category_path"; then
        critical_errors=$((critical_errors + 1))
    fi

    # 2c. Enable hardlinks in Media Management
    local mediamgmt
    mediamgmt=$(api_get "$port" "/api/v3/config/mediamanagement" "$apikey")
    if [ -n "$mediamgmt" ]; then
        local mgmt_payload
        mgmt_payload=$(echo "$mediamgmt" | jq --arg uf "$unmonitor_field" '.copyUsingHardlinks = true | .enableMediaManagement = true | .[$uf] = true | .recycleBin = ""' 2>/dev/null || echo "")
        if [ -n "$mgmt_payload" ]; then
            local mgmt_result
            mgmt_result=$(api_put "$port" "/api/v3/config/mediamanagement" "$apikey" "$mgmt_payload")
            if jq_json_has_key "$mgmt_result" "id"; then
                log_step "${service_name}: enabled hardlinks in Media Management"
            else
                log_step_fail "${service_name}: failed to enable hardlinks"
            fi
        fi
    fi

    # 3. Set naming convention
    if [ -n "$naming_jq" ]; then
        local naming
        naming=$(api_get "$port" "/api/v3/config/naming" "$apikey")
        if [ -n "$naming" ]; then
            local naming_payload
            naming_payload=$(echo "$naming" | jq "$naming_jq" 2>/dev/null || echo "")
            if [ -n "$naming_payload" ]; then
                local naming_result
                naming_result=$(api_put "$port" "/api/v3/config/naming" "$apikey" "$naming_payload")
                if jq_json_has_key "$naming_result" "id"; then
                    log_step "${service_name}: set naming convention"
                else
                    log_step_fail "${service_name}: failed to set naming convention"
                fi
            else
                log_step_fail "${service_name}: failed to build naming config payload"
            fi
        fi
    fi

    # 4. Set authentication
    if ! set_arr_auth "$service_name" "$port" "$apikey"; then
        critical_errors=$((critical_errors + 1))
    fi

    [ "$critical_errors" -eq 0 ]
}

# --- Quality sizes & default profiles ---

# Set minSize=0 on every quality definition (no minimum file-size filter).
# Values live in the *arr DB; they only change when written via this API.
relax_quality_sizes() {
    local service_name="$1"
    local port="$2"
    local apikey="$3"

    local defs
    defs=$(api_get "$port" "/api/v3/qualitydefinition" "$apikey")
    if [ -z "$defs" ] || [ "$defs" = "[]" ]; then
        log_step_fail "${service_name}: no quality definitions to update"
        return 1
    fi

    # Only minSize is cleared; leave max/preferred alone (bulk update is picky about nulls).
    local payload
    payload=$(echo "$defs" | jq '[.[] | .minSize = 0]' 2>/dev/null || echo "")
    if [ -z "$payload" ]; then
        log_step_fail "${service_name}: failed to build quality definition payload"
        return 1
    fi

    local result
    result=$(api_put "$port" "/api/v3/qualitydefinition/update" "$apikey" "$payload")
    if echo "$result" | jq -e 'type == "array"' >/dev/null 2>&1; then
        log_step "${service_name}: quality minSize set to 0"
        return 0
    fi
    # Fallback: one PUT per definition
    local ok=0 total=0
    while IFS= read -r row; do
        [ -z "$row" ] && continue
        total=$((total + 1))
        local id
        id=$(echo "$row" | jq -r '.id // empty')
        [ -z "$id" ] && continue
        if api_put "$port" "/api/v3/qualitydefinition/${id}" "$apikey" "$row" >/dev/null 2>&1; then
            ok=$((ok + 1))
        fi
    done < <(echo "$payload" | jq -c '.[]' 2>/dev/null || true)

    if [ "$ok" -gt 0 ]; then
        log_step "${service_name}: quality minSize set to 0 (${ok}/${total})"
        return 0
    fi
    log_step_fail "${service_name}: failed to update quality definitions"
    return 1
}

# Record the preferred quality profile id/name for this install (setup choice).
set_default_quality_profile() {
    local service_name="$1"
    local port="$2"
    local apikey="$3"
    local profile_func="$4"

    local profile profile_id
    profile=$($profile_func "$apikey")
    profile_id="${profile%%:*}"
    local profile_name="${profile##*:}"

    if [ -z "$profile_id" ] || [ "$profile_id" = "1" ] && [ "$profile_name" = "Any" ]; then
        log_step "${service_name}: preferred quality profile → Any"
        return 0
    fi

    if [ -n "${INSTALL_DIR:-}" ]; then
        mkdir -p "$INSTALL_DIR/config"
        echo "${profile_id}:${profile_name}" > "$INSTALL_DIR/config/.${service_name,,}-default-quality-profile" 2>/dev/null || true
    fi
    log_step "${service_name}: preferred quality profile → ${profile_name} (id ${profile_id})"
}

# --- Quality profile lookup ---

lookup_radarr_profile() {
    local apikey="$1"
    local profiles_json
    profiles_json=$(api_get "7878" "/api/v3/qualityprofile" "$apikey")

    if [ -z "$profiles_json" ]; then
        echo "1:Any"
        return
    fi

    # Prefer assemblrr-named Recyclarr profiles; fall back to stock *arr names.
    local target_name=""
    local stock_fallback=""

    if [ "${SEERR_IS_4K:-false}" = "true" ]; then
        target_name="assemblrr UHD Bluray + WEB"
        stock_fallback="Ultra-HD"
    elif [ "${SEERR_DEFAULT_PROFILE:-1}" != "1" ]; then
        target_name="assemblrr HD Bluray + WEB"
        stock_fallback="HD-1080p"
    else
        echo "1:Any"
        return
    fi

    local matched
    matched=$(echo "$profiles_json" | jq -r --arg name "$target_name" '
        .[] | select(.name == $name) | "\(.id):\(.name)"
    ' 2>/dev/null | head -1 || echo "")

    if [ -n "$matched" ]; then
        echo "$matched"
        return
    fi

    if [ -n "$stock_fallback" ]; then
        matched=$(echo "$profiles_json" | jq -r --arg name "$stock_fallback" '
            .[] | select(.name == $name) | "\(.id):\(.name)"
        ' 2>/dev/null | head -1 || echo "")
        if [ -n "$matched" ]; then
            echo "$matched"
            return
        fi
    fi

    echo "1:Any"
}

lookup_sonarr_profile() {
    local apikey="$1"
    local profiles_json
    profiles_json=$(api_get "8989" "/api/v3/qualityprofile" "$apikey")

    if [ -z "$profiles_json" ]; then
        echo "1:Any"
        return
    fi

    # Default TV profile is assemblrr WEB-1080p (movies 4K choice does not change this).
    local target_name="assemblrr WEB-1080p"
    local stock_fallback="HD-1080p"

    local matched
    matched=$(echo "$profiles_json" | jq -r --arg name "$target_name" '
        .[] | select(.name == $name) | "\(.id):\(.name)"
    ' 2>/dev/null | head -1 || echo "")

    if [ -n "$matched" ]; then
        echo "$matched"
        return
    fi

    matched=$(echo "$profiles_json" | jq -r '
        .[] | select(.name | test("^assemblrr.*WEB.*1080"; "i")) | "\(.id):\(.name)"
    ' 2>/dev/null | head -1 || echo "")
    if [ -n "$matched" ]; then
        echo "$matched"
        return
    fi

    if [ -n "$stock_fallback" ]; then
        matched=$(echo "$profiles_json" | jq -r --arg name "$stock_fallback" '
            .[] | select(.name == $name) | "\(.id):\(.name)"
        ' 2>/dev/null | head -1 || echo "")
        if [ -n "$matched" ]; then
            echo "$matched"
            return
        fi
    fi

    echo "1:Any"
}

# --- Radarr configuration ---

configure_radarr() {
    local apikey="$1"
    configure_arr_service \
        "Radarr" "7878" "$apikey" \
        "/data/media/movies" "movies" "/data/torrents/movies" \
        "autoUnmonitorPreviouslyDownloadedMovies" \
        '.renameMovies = true | .standardMovieFormat = "{Movie CleanTitle} ({Release Year}) {Quality Full}" | .movieFolderFormat = "{Movie CleanTitle} ({Release Year})"'
}

# --- Prowlarr configuration ---

# Set minimumSeeders=0 on Prowlarr app profiles (call once before connecting apps).
prowlarr_set_app_profile_min_seeders() {
    local prowlarr_key="$1"
    local profiles
    profiles=$(api_get "9696" "/api/v1/appprofile" "$prowlarr_key")
    if [ -z "$profiles" ] || [ "$profiles" = "[]" ]; then
        return 1
    fi

    local updated=0
    local profile_id profile_payload
    while IFS= read -r row; do
        [ -z "$row" ] && continue
        profile_id=$(echo "$row" | jq -r '.id // empty')
        [ -z "$profile_id" ] && continue
        profile_payload=$(echo "$row" | jq '.minimumSeeders = 0' 2>/dev/null || echo "")
        [ -z "$profile_payload" ] && continue
        if api_put "9696" "/api/v1/appprofile/${profile_id}" "$prowlarr_key" "$profile_payload" >/dev/null 2>&1; then
            updated=$((updated + 1))
        fi
    done < <(echo "$profiles" | jq -c '.[]' 2>/dev/null || true)

    if [ "$updated" -gt 0 ]; then
        log_step "Prowlarr: app profile minimumSeeders → 0"
        return 0
    fi
    return 1
}

# Set minimumSeeders=0 on every indexer present in one *arr app.
# Call after Prowlarr fullSync has created the indexers (app profile alone is not enough).
arr_set_indexer_min_seeders() {
    local service_name="$1"
    local port="$2"
    local apikey="$3"

    [ -z "$apikey" ] && return 1

    local indexers
    indexers=$(api_get "$port" "/api/v3/indexer" "$apikey")
    if [ -z "$indexers" ] || [ "$indexers" = "[]" ]; then
        return 1
    fi

    local ok=0
    local idx_id idx_payload result
    while IFS= read -r idx; do
        [ -z "$idx" ] && continue
        idx_id=$(echo "$idx" | jq -r '.id // empty')
        [ -z "$idx_id" ] && continue
        idx_payload=$(echo "$idx" | jq '
            .fields = [.fields[] |
                if .name == "minimumSeeders" then .value = 0 else . end
            ]
        ' 2>/dev/null || echo "")
        [ -z "$idx_payload" ] && continue
        result=$(api_put "$port" "/api/v3/indexer/${idx_id}" "$apikey" "$idx_payload")
        if echo "$result" | jq -e '.id' >/dev/null 2>&1; then
            ok=$((ok + 1))
        fi
    done < <(echo "$indexers" | jq -c '.[]' 2>/dev/null || true)

    if [ "$ok" -gt 0 ]; then
        log_step "${service_name}: indexer minimumSeeders → 0 (${ok})"
        return 0
    fi
    return 1
}

# Wait until Radarr has at least one indexer from Prowlarr fullSync (max ~30s).
# Sonarr is not a gate — movie-only indexers never appear there.
wait_for_arr_indexer_sync() {
    local radarr_key="${1:-}"
    local waited=0

    [ -z "$radarr_key" ] && return 0

    while [ $waited -lt 30 ]; do
        local rc
        rc=$(api_get "7878" "/api/v3/indexer" "$radarr_key" | jq 'length' 2>/dev/null || echo 0)
        if [ "${rc:-0}" -gt 0 ]; then
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done
    return 1
}

configure_prowlarr() {
    local apikey="$1"
    local radarr_apikey="$2"
    local sonarr_apikey="${3:-}"
    local critical_errors=0

    # 1) App profile min seeders (best-effort)
    prowlarr_set_app_profile_min_seeders "$apikey" || true

    # 2. Add Radarr as connected application
    local apps
    apps=$(api_get "9696" "/api/v1/applications" "$apikey")
    local existing_impls
    existing_impls=$(jq_json_list_values "$apps" "implementationName")
    local app_schema=""

    if ! echo "$existing_impls" | grep -q "Radarr"; then
        if [ -z "$radarr_apikey" ]; then
            log_step_fail "Prowlarr: Radarr API key missing — cannot connect application"
            critical_errors=$((critical_errors + 1))
        else
            # Get application schema once for Radarr/Sonarr field names
            app_schema=$(api_get "9696" "/api/v1/applications/schema" "$apikey")
            local app_payload
            app_payload=$(echo "$app_schema" | jq --arg prowlarr_url "$PROWLARR_DOCKER_URL" --arg radarr_url "$RADARR_DOCKER_URL" --arg radarr_key "$radarr_apikey" '
                [.[] | select(.implementationName == "Radarr")][0] |
                .fields = [.fields[] | if .name == "prowlarrUrl" then .value = $prowlarr_url elif .name == "baseUrl" then .value = $radarr_url elif .name == "apiKey" then .value = $radarr_key elif .name == "syncCategories" then .value = [2000] elif .name == "syncRejectBlocklistedTorrentHashesWhileGrabbing" then .value = false else . end] |
                .enable = true | .syncLevel = "fullSync" | .name = "Radarr" | .priority = (.priority // 25) | .tags = []
            ' 2>/dev/null || echo "")
            if [ -z "$app_payload" ]; then
                log_step_fail "Prowlarr: Radarr application schema not found"
                critical_errors=$((critical_errors + 1))
            else
                local app_result
                app_result=$(api_post_force "9696" "/api/v1/applications" "$apikey" "$app_payload")
                if jq_json_has_key "$app_result" "id"; then
                    log_step "Prowlarr: added Radarr as connected application"
                else
                    log_step_fail "Prowlarr: failed to add Radarr application"
                    critical_errors=$((critical_errors + 1))
                fi
            fi
        fi
    else
        log_step "Prowlarr: Radarr application already connected"
    fi

    # 1b. Add Sonarr as connected application
    if [ -n "$sonarr_apikey" ]; then
        if ! echo "$existing_impls" | grep -q "Sonarr"; then
            if [ -z "$app_schema" ]; then
                app_schema=$(api_get "9696" "/api/v1/applications/schema" "$apikey")
            fi
            local sonarr_app_payload
            sonarr_app_payload=$(echo "$app_schema" | jq --arg prowlarr_url "$PROWLARR_DOCKER_URL" --arg sonarr_url "$SONARR_DOCKER_URL" --arg sonarr_key "$sonarr_apikey" '
                [.[] | select(.implementationName == "Sonarr")][0] |
                .fields = [.fields[] | if .name == "prowlarrUrl" then .value = $prowlarr_url elif .name == "baseUrl" then .value = $sonarr_url elif .name == "apiKey" then .value = $sonarr_key elif .name == "syncCategories" then .value = [5000, 5010, 5020, 5030, 5040, 5045, 5050, 5090] elif .name == "animeSyncCategories" then .value = [5070] elif .name == "syncRejectBlocklistedTorrentHashesWhileGrabbing" then .value = false else . end] |
                .enable = true | .syncLevel = "fullSync" | .name = "Sonarr" | .priority = (.priority // 25) | .tags = []
            ' 2>/dev/null || echo "")
            if [ -z "$sonarr_app_payload" ]; then
                log_step_fail "Prowlarr: Sonarr application schema not found"
                critical_errors=$((critical_errors + 1))
            else
                local sonarr_app_result
                sonarr_app_result=$(api_post_force "9696" "/api/v1/applications" "$apikey" "$sonarr_app_payload")
                if jq_json_has_key "$sonarr_app_result" "id"; then
                    log_step "Prowlarr: added Sonarr as connected application"
                else
                    log_step_fail "Prowlarr: failed to add Sonarr application"
                    critical_errors=$((critical_errors + 1))
                fi
            fi
        else
            log_step "Prowlarr: Sonarr application already connected"
        fi
    fi

    # 2. Selected indexers (optional; can add later in UI)
    local indexer_schemas
    indexer_schemas=$(api_get "9696" "/api/v1/indexer/schema" "$apikey")

    if [ -z "$indexer_schemas" ]; then
        log_step_fail "Prowlarr: failed to fetch indexer schemas"
    else
        local selected_indexers=()
        if [ -n "${SELECTED_INDEXERS+x}" ] && [ "${#SELECTED_INDEXERS[@]}" -gt 0 ]; then
            selected_indexers=("${SELECTED_INDEXERS[@]}")
            echo "Adding ${#selected_indexers[@]} indexer(s) to Prowlarr" >&2
        fi

        # Get existing indexers to avoid duplicates
        local existing_indexers
        existing_indexers=$(api_get "9696" "/api/v1/indexer" "$apikey")
        local existing_names
        existing_names=$(jq_json_list_values "$existing_indexers" "name")

        local indexer_name
        for indexer_name in "${selected_indexers[@]+"${selected_indexers[@]}"}"; do
            # Skip if already added
            if echo "$existing_names" | grep -q -F -x "$indexer_name"; then
                log_step "Prowlarr: ${indexer_name} indexer already exists"
                continue
            fi

            # Build the indexer payload using jq to safely extract from schema
            # Cardigann indexers use 'name' field to match, not implementationName
            # Skip empty field values — Prowlarr uses Cardigann definition defaults
            local indexer_payload
            indexer_payload=$(echo "$indexer_schemas" | jq --arg idx "$indexer_name" '
                [.[] | select(.name == $idx or (.name | ascii_downcase | startswith($idx | ascii_downcase)))][0] |
                .fields = [.fields[] | select(.value != "") | {name: .name, value: .value}] |
                .enable = true | .enableAutoSearch = true | .appProfileId = 1 | .priority = (.priority // 25)
            ' 2>/dev/null || echo "")

            if [ -z "$indexer_payload" ]; then
                log_step_fail "Prowlarr: ${indexer_name} schema not found"
                continue
            fi

            # Try adding with forceSave to bypass connectivity validation
            # If that fails (e.g. Cloudflare), retry with enable=false
            local idx_result
            idx_result=$(curl -s --connect-timeout 5 -X POST \
                -H "Content-Type: application/json" \
                -d "$indexer_payload" \
                "http://${API_HOST}:9696/api/v1/indexer?apikey=${apikey}&forceSave=true" 2>/dev/null)
            if jq_json_has_key "$idx_result" "id"; then
                log_step "Prowlarr: added ${indexer_name} indexer"
            else
                # Retry with enable=false
                local disabled_payload
                disabled_payload=$(echo "$indexer_payload" | jq -c '.enable = false' 2>/dev/null || echo "")
                idx_result=$(curl -s --connect-timeout 5 -X POST \
                    -H "Content-Type: application/json" \
                    -d "$disabled_payload" \
                    "http://${API_HOST}:9696/api/v1/indexer?apikey=${apikey}&forceSave=true" 2>/dev/null)
                if jq_json_has_key "$idx_result" "id"; then
                    log_step "Prowlarr: added ${indexer_name} indexer (disabled — needs FlareSolverr for Cloudflare)"
                else
                    log_step_fail "Prowlarr: failed to add ${indexer_name} indexer"
                fi
            fi
        done
        if [ "${#selected_indexers[@]}" -gt 0 ]; then
            echo >&2
            log_success "Indexer setup finished (check markers above for any failures)" >&2
        fi
    fi

    # 3) After fullSync, set min seeders on *arr indexers (best-effort)
    wait_for_arr_indexer_sync "$radarr_apikey" || true
    arr_set_indexer_min_seeders "Radarr" "7878" "$radarr_apikey" || true
    arr_set_indexer_min_seeders "Sonarr" "8989" "$sonarr_apikey" || true

    # 4. Set authentication
    if ! set_arr_auth "Prowlarr" "9696" "$apikey" "v1"; then
        critical_errors=$((critical_errors + 1))
    fi

    [ "$critical_errors" -eq 0 ]
}

# --- Sonarr configuration ---

configure_sonarr() {
    local apikey="$1"
    configure_arr_service \
        "Sonarr" "8989" "$apikey" \
        "/data/media/tv" "tv" "/data/torrents/tv" \
        "autoUnmonitorPreviouslyDownloadedEpisodes" \
        '.renameEpisodes = true | .replaceIllegalCharacters = true | .standardEpisodeFormat = "{Series Title} - S{season:00}E{episode:00} - {Episode Title} {Quality Full}" | .dailyEpisodeFormat = "{Series Title} - {Air-Date} - {Episode Title} {Quality Full}" | .animeEpisodeFormat = "{Series Title} - S{season:00}E{episode:00} - {Episode Title} {Quality Full}" | .seriesFolderFormat = "{Series Title}" | .seasonFolderFormat = "Season {season}" | .multiEpisodeStyle = 5 | .colonReplacementFormat = 4'
}
