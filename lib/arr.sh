#!/bin/bash
# assemblrr *arr service configuration — sourced by configure.sh
# Provides: set_arr_auth, qbit helpers, configure_arr_service, profile lookups,
#           configure_radarr, configure_sonarr, configure_prowlarr
# Requires: lib/core.sh (logging), lib/api.sh (api_get/post/put/delete helpers),
#           configure.sh (_cfg_log_info, log_step, log_step_fail, AUTH_USERNAME, etc.)

set -euo pipefail

# --- Shared auth config for *arr services ---

set_arr_auth() {
    local service_name="$1"
    local port="$2"
    local apikey="$3"
    local api_version="${4:-v3}"

    if [ -z "$AUTH_USERNAME" ] || [ -z "$AUTH_PASSWORD" ]; then
        return
    fi

    local host_config
    host_config=$(api_get "$port" "/api/${api_version}/config/host" "$apikey")
    if [ -z "$host_config" ]; then
        return
    fi

    local host_id
    host_id=$(jq_json_get "$host_config" "id")
    host_id=${host_id:-1}

    local updated_config
    updated_config=$(echo "$host_config" | jq --arg hid "$host_id" --arg user "$AUTH_USERNAME" --arg pass "$AUTH_PASSWORD" \
        '.id = ($hid | tonumber) | .authenticationMethod = "forms" | .authenticationRequired = "enabled" | .username = $user | .password = $pass | .passwordConfirmation = $pass' 2>/dev/null || echo "")

    if [ -n "$updated_config" ]; then
        local auth_result
        auth_result=$(api_put "$port" "/api/${api_version}/config/host" "$apikey" "$updated_config")
        if jq_json_has_key "$auth_result" "id"; then
            log_step "${service_name}: set authentication (username: $AUTH_USERNAME)"
        else
            log_step_fail "${service_name}: failed to set authentication"
        fi
    else
        log_step_fail "${service_name}: failed to build auth config payload"
    fi
}

# --- qBittorrent helpers ---

# Set qBittorrent credentials and save path using the temp password from container logs
# Called once before configuring any *arr service.
# On re-runs, tries the final credentials first to avoid triggering brute-force bans.
qbit_set_credentials() {
    local qbit_port=8081
    local qbit_cookie_jar="/tmp/qb_cookie_jar_init_$$_${qbit_port}"

    # Try logging in with the final credentials first (already set from a previous run)
    if [ -n "$AUTH_USERNAME" ] && [ -n "$AUTH_PASSWORD" ]; then
        curl -s --connect-timeout 5 -c "$qbit_cookie_jar" \
            -H "Referer: http://${API_HOST}:${qbit_port}" \
            -d "username=${AUTH_USERNAME}&password=${AUTH_PASSWORD}" \
            "http://${API_HOST}:${qbit_port}/api/v2/auth/login" 2>/dev/null >/dev/null || true
        local qbit_sid
        qbit_sid=$(qbit_cookie_sid "$qbit_cookie_jar")
        if [ -n "$qbit_sid" ]; then
            # Credentials already set — ensure save path is configured
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

    # Credentials not set yet — use temp password from container logs
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

# Create a qBittorrent category with a save path
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
    if [ -n "$qbit_sid" ]; then
        curl -s --connect-timeout 10 \
            "http://${API_HOST}:${qbit_port}/api/v2/torrents/createCategory" \
            -b "$qbit_cookie_jar" \
            -H "Referer: http://${API_HOST}:${qbit_port}" \
            -d "category=${category}&savePath=${save_path}" \
            2>/dev/null >/dev/null || true
        log_step "${service_name}: created qBittorrent '${category}' category (${save_path})"
    else
        log_step_fail "${service_name}: could not login to qBittorrent to create categories"
    fi
    rm -f "$qbit_cookie_jar"
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
        fi
    else
        log_step "${service_name}: root folder ${root_path} already exists"
    fi

    # 1b. Remove stale auto-detected root folders
    local all_root_folders
    all_root_folders=$(api_get "$port" "/api/v3/rootfolder" "$apikey")
    local stale_ids
    stale_ids=$(echo "$all_root_folders" | jq -r --arg rp "$root_path" '.[] | select(.path != $rp) | .id' 2>/dev/null || echo "")

    for stale_id in $stale_ids; do
        if [ -n "$stale_id" ]; then
            api_delete "$port" "/api/v3/rootfolder/${stale_id}" "$apikey" >/dev/null || true
            log_step "${service_name}: removed stale root folder (id: ${stale_id})"
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
            fi
        else
            log_step_fail "${service_name}: failed to build qBittorrent payload"
        fi
    else
        log_step "${service_name}: qBittorrent download client already exists"
    fi

    # 2b. Create qBittorrent category with correct save path
    qbit_create_category "$service_name" "$category_name" "$category_path"

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

    # 3. Set naming convention (if jq expression provided)
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
    set_arr_auth "$service_name" "$port" "$apikey"
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

    # Recyclarr creates profiles with names like "Ultra-HD" or "HD Bluray + WEB"
    # Match by keyword since the exact name depends on TRaSH Guide version
    # Default Radarr profiles to skip: Any, SD, HD-720p, HD-1080p, HD - 720p/1080p
    local target_keyword
    if [ "${SEERR_IS_4K:-false}" = "true" ]; then
        target_keyword="Ultra"
    elif [ "${SEERR_DEFAULT_PROFILE:-1}" != "1" ]; then
        target_keyword="Bluray + WEB"
    else
        echo "1:Any"
        return
    fi

    local matched
    matched=$(echo "$profiles_json" | jq -r --arg kw "$target_keyword" '.[] | select(.name | contains($kw)) | select(.name as $n | ["Any","SD","HD-720p","HD-1080p","HD - 720p/1080p"] | index($n) | not) | "\(.id):\(.name)"' 2>/dev/null | head -1 || echo "")

    if [ -n "$matched" ]; then
        echo "$matched"
    else
        echo "1:Any"
    fi
}

lookup_sonarr_profile() {
    local apikey="$1"
    local profiles_json
    profiles_json=$(api_get "8989" "/api/v3/qualityprofile" "$apikey")

    if [ -z "$profiles_json" ]; then
        echo "1:Default"
        return
    fi

    # Recyclarr creates profiles with names like "Ultra-HD" or "WEB-1080p"
    # Match by keyword since the exact name depends on TRaSH Guide version
    # Default Sonarr profiles to skip: Any, SD, HD-720p, HD-1080p, HD - 720p/1080p
    local target_keyword
    if [ "${SEERR_IS_4K:-false}" = "true" ]; then
        target_keyword="Ultra"
    else
        target_keyword="WEB"
    fi

    local matched
    matched=$(echo "$profiles_json" | jq -r --arg kw "$target_keyword" '.[] | select(.name | contains($kw)) | select(.name as $n | ["Any","SD","HD-720p","HD-1080p","HD - 720p/1080p"] | index($n) | not) | "\(.id):\(.name)"' 2>/dev/null | head -1 || echo "")

    if [ -n "$matched" ]; then
        echo "$matched"
    else
        echo "1:Default"
    fi
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

configure_prowlarr() {
    local apikey="$1"
    local radarr_apikey="$2"

    # 1. Add Radarr as connected application
    local apps
    apps=$(api_get "9696" "/api/v1/applications" "$apikey")
    local existing_impls
    existing_impls=$(jq_json_list_values "$apps" "implementationName")

    if ! echo "$existing_impls" | grep -q "Radarr"; then
        # Get the Radarr application schema first to get correct field names
        local app_schema
        app_schema=$(api_get "9696" "/api/v1/applications/schema" "$apikey")
        local app_payload
        app_payload=$(echo "$app_schema" | jq --arg prowlarr_url "$PROWLARR_DOCKER_URL" --arg radarr_url "$RADARR_DOCKER_URL" --arg radarr_key "$radarr_apikey" '
            [.[] | select(.implementationName == "Radarr")][0] |
            .fields = [.fields[] | if .name == "prowlarrUrl" then .value = $prowlarr_url elif .name == "baseUrl" then .value = $radarr_url elif .name == "apiKey" then .value = $radarr_key elif .name == "syncCategories" then .value = [2000] elif .name == "syncRejectBlocklistedTorrentHashesWhileGrabbing" then .value = false else . end] |
            .enable = true | .syncLevel = "fullSync" | .name = "Radarr" | .priority = (.priority // 25) | .tags = []
        ' 2>/dev/null || echo "")
        if [ -z "$app_payload" ]; then
            log_step_fail "Prowlarr: Radarr application schema not found"
            return 0
        fi
        local app_result
        app_result=$(api_post_force "9696" "/api/v1/applications" "$apikey" "$app_payload")
        if jq_json_has_key "$app_result" "id"; then
            log_step "Prowlarr: added Radarr as connected application"
        else
            log_step_fail "Prowlarr: failed to add Radarr application"
        fi
    else
        log_step "Prowlarr: Radarr application already connected"
    fi

    # 1b. Add Sonarr as connected application
    local sonarr_apikey="$3"

    if [ -n "$sonarr_apikey" ]; then
        if ! echo "$existing_impls" | grep -q "Sonarr"; then
            local sonarr_app_payload
            sonarr_app_payload=$(echo "$app_schema" | jq --arg prowlarr_url "$PROWLARR_DOCKER_URL" --arg sonarr_url "$SONARR_DOCKER_URL" --arg sonarr_key "$sonarr_apikey" '
                [.[] | select(.implementationName == "Sonarr")][0] |
                .fields = [.fields[] | if .name == "prowlarrUrl" then .value = $prowlarr_url elif .name == "baseUrl" then .value = $sonarr_url elif .name == "apiKey" then .value = $sonarr_key elif .name == "syncCategories" then .value = [5000, 5010, 5020, 5030, 5040, 5045, 5050, 5090] elif .name == "animeSyncCategories" then .value = [5070] elif .name == "syncRejectBlocklistedTorrentHashesWhileGrabbing" then .value = false else . end] |
                .enable = true | .syncLevel = "fullSync" | .name = "Sonarr" | .priority = (.priority // 25) | .tags = []
            ' 2>/dev/null || echo "")
            if [ -z "$sonarr_app_payload" ]; then
                log_step_fail "Prowlarr: Sonarr application schema not found"
            else
                local sonarr_app_result
                sonarr_app_result=$(api_post_force "9696" "/api/v1/applications" "$apikey" "$sonarr_app_payload")
                if jq_json_has_key "$sonarr_app_result" "id"; then
                    log_step "Prowlarr: added Sonarr as connected application"
                else
                    log_step_fail "Prowlarr: failed to add Sonarr application"
                fi
            fi
        else
            log_step "Prowlarr: Sonarr application already connected"
        fi
    fi

    # 2. Add public indexers
    echo "Adding ${#PUBLIC_INDEXERS[@]} indexer(s) to Prowlarr" >&2
    local indexer_schemas
    indexer_schemas=$(api_get "9696" "/api/v1/indexer/schema" "$apikey")

    if [ -z "$indexer_schemas" ]; then
        log_step_fail "Prowlarr: failed to fetch indexer schemas"
        return 0
    fi

    # Get existing indexers to avoid duplicates
    local existing_indexers
    existing_indexers=$(api_get "9696" "/api/v1/indexer" "$apikey")
    local existing_names
    existing_names=$(jq_json_list_values "$existing_indexers" "name")

    for indexer_name in ${PUBLIC_INDEXERS[@]+"${PUBLIC_INDEXERS[@]}"}; do
        # Skip if already added
        if echo "$existing_names" | grep -q -F -x "$indexer_name"; then
            log_step "Prowlarr: ${indexer_name} indexer already exists"
            continue
        fi

        # Build the indexer payload using jq to safely extract from schema
        # Cardigann indexers use 'name' field to match, not implementationName
        # Skip empty field values — Prowlarr uses Cardigann definition defaults
        # Add as disabled for Cloudflare-protected indexers (need FlareSolverr)
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
    echo >&2
    log_success "Indexers added to Prowlarr!" >&2

    # 3. Set authentication
    set_arr_auth "Prowlarr" "9696" "$apikey" "v1"
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
