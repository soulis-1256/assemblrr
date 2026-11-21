#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# assemblrr shared Radarr/Sonarr service wiring
# Requires: lib/core.sh, lib/api.sh, lib/qbit.sh

if [ -n "${_ASSEMBLRR_ARR_COMMON_SOURCED:-}" ]; then
    return 0
fi
readonly _ASSEMBLRR_ARR_COMMON_SOURCED=1

set_arr_auth() {
    local service_name="$1"
    local port="$2"
    local apikey="$3"
    local api_version="${4:-v3}"

    if [ -z "${AUTH_USERNAME:-}" ] || [ -z "${AUTH_PASSWORD:-}" ]; then
        log_step_fail "${service_name}: auth credentials missing — cannot enable forms auth"
        return 1
    fi

    local host_config
    host_config=$(api_get "$port" "/api/${api_version}/config/host" "$apikey") || {
        log_step_fail "${service_name}: failed to read host config for authentication"
        return 1
    }
    if [ -z "$host_config" ]; then
        log_step_fail "${service_name}: empty host config response"
        return 1
    fi

    local host_id
    host_id=$(jq_json_get "$host_config" "id")
    host_id=${host_id:-1}

    local updated_config
    updated_config=$(printf '%s' "$host_config" | jq \
        --arg hid "$host_id" --arg user "$AUTH_USERNAME" --arg pass "$AUTH_PASSWORD" \
        '.id = ($hid | tonumber) | .authenticationMethod = "forms" | .authenticationRequired = "enabled" | .username = $user | .password = $pass | .passwordConfirmation = $pass' 2>/dev/null || echo "")

    if [ -z "$updated_config" ]; then
        log_step_fail "${service_name}: failed to build auth config payload"
        return 1
    fi

    local auth_result
    auth_result=$(api_put "$port" "/api/${api_version}/config/host" "$apikey" "$updated_config") || {
        log_step_fail "${service_name}: failed to set authentication (HTTP ${HTTP_STATUS})"
        return 1
    }
    if jq_json_has_key "$auth_result" "id"; then
        log_step "${service_name}: set authentication (username: $AUTH_USERNAME)"
        return 0
    fi
    log_step_fail "${service_name}: failed to set authentication"
    return 1
}

# Point an existing *arr qBittorrent client at the current host (gluetun vs qbittorrent).
arr_update_qb_host() {
    local service_name="$1"
    local port="$2"
    local apikey="$3"
    local host="${QBITTORRENT_HOST:-qbittorrent}"
    local clients dc_id existing updated result

    [ -n "$apikey" ] || return 1
    clients=$(api_get "$port" "/api/v3/downloadclient" "$apikey") || return 1
    dc_id=$(printf '%s' "$clients" | jq -r \
        '[.[] | select(.implementationName == "qBittorrent" or .implementation == "QBittorrent")][0].id // empty' \
        2>/dev/null || true)
    [ -n "$dc_id" ] || return 1
    existing=$(printf '%s' "$clients" | jq --argjson id "$dc_id" '.[] | select(.id == $id)' 2>/dev/null || true)
    [ -n "$existing" ] || return 1
    updated=$(printf '%s' "$existing" | jq --arg host "$host" \
        '.fields = [.fields[] | if .name == "host" then .value = $host else . end]' \
        2>/dev/null || true)
    [ -n "$updated" ] || return 1
    result=$(api_put "$port" "/api/v3/downloadclient/${dc_id}" "$apikey" "$updated") || return 1
    if jq_json_has_key "$result" "id"; then
        log_step "${service_name}: qBittorrent host → ${host}"
        return 0
    fi
    return 1
}

_arr_build_qbit_payload() {
    local port="$1"
    local apikey="$2"
    local service_name="$3"
    local category_name="$4"
    local schemas="" base_schema=""
    schemas=$(api_get "$port" "/api/v3/downloadclient/schema" "$apikey" 2>/dev/null || true)
    if [ -n "$schemas" ]; then
        base_schema=$(printf '%s' "$schemas" | jq '[.[] | select(.implementation == "QBittorrent")][0] // empty' 2>/dev/null || true)
    fi

    if [ -n "$base_schema" ]; then
        printf '%s' "$base_schema" | jq \
            --arg host "$QBITTORRENT_HOST" --arg user "$AUTH_USERNAME" --arg pass "$AUTH_PASSWORD" \
            --arg cat_name "$category_name" --arg sn "$service_name" '
            (if $sn == "Radarr" then "movieCategory" else "tvCategory" end) as $cat_key |
            (if $sn == "Radarr" then "movieImportedCategory" else "tvImportedCategory" end) as $imp_key |
            (if $sn == "Radarr" then "recentMoviePriority" else "recentTvPriority" end) as $rec_key |
            (if $sn == "Radarr" then "olderMoviePriority" else "olderTvPriority" end) as $old_key |
            .enable = true |
            .removeCompletedDownloads = true |
            .removeFailedDownloads = true |
            .name = "qBittorrent" |
            .priority = 1 |
            .tags = [] |
            .fields = [.fields[] |
                if .name == "host" then .value = $host
                elif .name == "port" then .value = 8081
                elif .name == "useSsl" then .value = false
                elif .name == "urlBase" then .value = ""
                elif .name == "username" then .value = $user
                elif .name == "password" then .value = $pass
                elif .name == $cat_key then .value = $cat_name
                elif .name == $imp_key then .value = ""
                elif .name == $rec_key then .value = 0
                elif .name == $old_key then .value = 0
                elif .name == "initialState" then .value = 0
                elif .name == "sequentialOrder" then .value = false
                elif .name == "firstAndLast" then .value = false
                elif .name == "contentLayout" then .value = 0
                else . end
            ]
        ' 2>/dev/null || echo ""
        return 0
    fi

    jq -n --arg host "$QBITTORRENT_HOST" --arg user "$AUTH_USERNAME" --arg pass "$AUTH_PASSWORD" \
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
        }' 2>/dev/null || echo ""
}

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
    local root_folders existing_paths
    root_folders=$(api_get "$port" "/api/v3/rootfolder" "$apikey" || echo "[]")
    existing_paths=$(jq_json_list_values "$root_folders" "path")

    if ! printf '%s\n' "$existing_paths" | grep -Fxq "$root_path"; then
        local rf_result
        rf_result=$(api_post "$port" "/api/v3/rootfolder" "$apikey" "{\"path\":\"${root_path}\"}" || echo "")
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
    local all_root_folders extra_ids extra_id
    all_root_folders=$(api_get "$port" "/api/v3/rootfolder" "$apikey" || echo "[]")
    extra_ids=$(printf '%s' "$all_root_folders" | jq -r --arg rp "$root_path" '.[] | select(.path != $rp) | .id' 2>/dev/null || echo "")

    for extra_id in $extra_ids; do
        if [ -n "$extra_id" ]; then
            api_delete "$port" "/api/v3/rootfolder/${extra_id}" "$apikey" >/dev/null || true
            log_step "${service_name}: removed extra root folder (id: ${extra_id})"
        fi
    done

    # 2. Add or update qBittorrent download client
    local download_clients existing_impls qbit_payload
    download_clients=$(api_get "$port" "/api/v3/downloadclient" "$apikey" || echo "[]")
    existing_impls=$(jq_json_list_values "$download_clients" "implementationName")
    qbit_payload=$(_arr_build_qbit_payload "$port" "$apikey" "$service_name" "$category_name")

    if ! printf '%s\n' "$existing_impls" | grep -Fxq "qBittorrent"; then
        if [ -n "$qbit_payload" ]; then
            local dc_result
            dc_result=$(api_post "$port" "/api/v3/downloadclient" "$apikey" "$qbit_payload" || echo "")
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
        local existing_dc dc_id updated_dc dc_put
        existing_dc=$(printf '%s' "$download_clients" | jq '[.[] | select(.implementationName == "qBittorrent" or .implementation == "QBittorrent")][0]' 2>/dev/null || echo "")
        dc_id=$(printf '%s' "$existing_dc" | jq -r '.id // empty' 2>/dev/null || echo "")
        if [ -n "$dc_id" ] && [ -n "$qbit_payload" ]; then
            updated_dc=$(printf '%s' "$qbit_payload" | jq --argjson id "$dc_id" '.id = $id' 2>/dev/null || echo "")
            if [ -n "$updated_dc" ]; then
                dc_put=$(api_put "$port" "/api/v3/downloadclient/${dc_id}" "$apikey" "$updated_dc" || echo "")
                if jq_json_has_key "$dc_put" "id"; then
                    log_step "${service_name}: updated qBittorrent download client (host: ${QBITTORRENT_HOST})"
                else
                    log_step "${service_name}: qBittorrent download client already exists"
                fi
            else
                log_step "${service_name}: qBittorrent download client already exists"
            fi
        else
            log_step "${service_name}: qBittorrent download client already exists"
        fi
    fi

    # 2b. Create qBittorrent category with correct save path
    if ! qbit_create_category "$service_name" "$category_name" "$category_path"; then
        critical_errors=$((critical_errors + 1))
    fi

    # 2c. Enable hardlinks in Media Management (recycle bin disabled)
    local mediamgmt
    mediamgmt=$(api_get "$port" "/api/v3/config/mediamanagement" "$apikey" || echo "")
    if [ -n "$mediamgmt" ]; then
        local mgmt_payload
        mgmt_payload=$(printf '%s' "$mediamgmt" | jq --arg uf "$unmonitor_field" \
            '.copyUsingHardlinks = true | .enableMediaManagement = true | .[$uf] = true
             | .recycleBin = "" | .recycleBinCleanupDays = 0' 2>/dev/null || echo "")
        if [ -n "$mgmt_payload" ]; then
            local mgmt_result
            mgmt_result=$(api_put "$port" "/api/v3/config/mediamanagement" "$apikey" "$mgmt_payload" || echo "")
            if jq_json_has_key "$mgmt_result" "id"; then
                log_step "${service_name}: enabled hardlinks (recycle bin disabled)"
            else
                log_step_fail "${service_name}: failed to enable hardlinks"
            fi
        fi
    fi

    # 3. Set naming convention
    if [ -n "$naming_jq" ]; then
        local naming
        naming=$(api_get "$port" "/api/v3/config/naming" "$apikey" || echo "")
        if [ -n "$naming" ]; then
            local naming_payload
            naming_payload=$(printf '%s' "$naming" | jq "$naming_jq" 2>/dev/null || echo "")
            if [ -n "$naming_payload" ]; then
                local naming_result
                naming_result=$(api_put "$port" "/api/v3/config/naming" "$apikey" "$naming_payload" || echo "")
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

# On movie/series delete, run arr-purge-hook.sh (download client + files).
add_arr_purge_hook() {
    local app_name="$1"
    local port="$2"
    local apikey="$3"

    [ -z "$apikey" ] && return 0

    local notifications existing_id
    notifications=$(api_get "$port" "/api/v3/notification" "$apikey" || echo "[]")
    existing_id=$(printf '%s' "$notifications" | jq -r \
        '.[] | select(.implementation == "CustomScript" and .name == "assemblrr Media Purge") | .id // ""' \
        2>/dev/null | head -1 || echo "")

    if [ -f "${INSTALL_DIR:-}/scripts/arr-purge-hook.sh" ]; then
        chmod +x "${INSTALL_DIR}/scripts/arr-purge-hook.sh" 2>/dev/null || true
    fi
    if [ -f "${INSTALL_DIR:-}/scripts/media-purge.sh" ]; then
        chmod +x "${INSTALL_DIR}/scripts/media-purge.sh" 2>/dev/null || true
    fi

    local schema payload result
    schema=$(api_get "$port" "/api/v3/notification/schema" "$apikey" || echo "[]")

    if [ "$app_name" = "Radarr" ]; then
        payload=$(printf '%s' "$schema" | jq '
            [.[] | select(.implementation == "CustomScript")][0] |
            .fields = [.fields[] | if .name == "path" then .value = "/scripts/arr-purge-hook.sh" else . end] |
            .onGrab = false | .onDownload = false | .onUpgrade = false |
            .onRename = false | .onMovieAdded = false |
            .onMovieDelete = true | .onMovieFileDelete = false |
            .onMovieFileDeleteForUpgrade = false |
            .onHealthIssue = false | .onHealthRestored = false |
            .onApplicationUpdate = false | .onManualInteractionRequired = false |
            .includeHealthWarnings = false |
            .name = "assemblrr Media Purge" | .tags = []
        ' 2>/dev/null || echo "")
    else
        payload=$(printf '%s' "$schema" | jq '
            [.[] | select(.implementation == "CustomScript")][0] |
            .fields = [.fields[] | if .name == "path" then .value = "/scripts/arr-purge-hook.sh" else . end] |
            .onGrab = false | .onDownload = false | .onUpgrade = false |
            .onRename = false | .onSeriesAdd = false |
            .onSeriesDelete = true | .onEpisodeFileDelete = false |
            .onEpisodeFileDeleteForUpgrade = false |
            .onHealthIssue = false | .onHealthRestored = false |
            .onApplicationUpdate = false | .onManualInteractionRequired = false |
            .includeHealthWarnings = false |
            .name = "assemblrr Media Purge" | .tags = []
        ' 2>/dev/null || echo "")
    fi

    if [ -z "$payload" ]; then
        log_step_fail "${app_name}: CustomScript schema not found for media purge"
        return 1
    fi

    if [ -n "$existing_id" ]; then
        payload=$(printf '%s' "$payload" | jq --argjson id "$existing_id" '.id = $id' 2>/dev/null || echo "$payload")
        result=$(api_put "$port" "/api/v3/notification/${existing_id}" "$apikey" "$payload" || echo "")
        if jq_json_has_key "$result" "id"; then
            log_step "${app_name}: updated Media Purge hook"
            return 0
        fi
    fi

    result=$(api_post_force "$port" "/api/v3/notification" "$apikey" "$payload" || echo "")
    if jq_json_has_key "$result" "id"; then
        log_step "${app_name}: added Media Purge hook"
        return 0
    fi
    local err_msg
    err_msg=$(printf '%s' "$result" | jq -r 'if type == "array" then .[0].errorMessage // empty else .errorMessage // empty end' 2>/dev/null || echo "")
    if [ -n "$err_msg" ]; then
        log_step_fail "${app_name}: failed to add Media Purge hook (${err_msg})"
    else
        log_step_fail "${app_name}: failed to add Media Purge hook"
    fi
    return 1
}

configure_radarr() {
    local apikey="$1"
    configure_arr_service \
        "Radarr" "7878" "$apikey" \
        "/data/media/movies" "movies" "/data/torrents/movies" \
        "autoUnmonitorPreviouslyDownloadedMovies" \
        '.renameMovies = true | .standardMovieFormat = "{Movie CleanTitle} ({Release Year}) {Quality Full}" | .movieFolderFormat = "{Movie CleanTitle} ({Release Year})"'
}

configure_sonarr() {
    local apikey="$1"
    # Note: Sonarr v4 colonReplacementFormat=4 -> "Smart", multiEpisodeStyle=5 -> "Prefixed Range".
    configure_arr_service \
        "Sonarr" "8989" "$apikey" \
        "/data/media/tv" "tv" "/data/torrents/tv" \
        "autoUnmonitorPreviouslyDownloadedEpisodes" \
        '.renameEpisodes = true | .replaceIllegalCharacters = true | .standardEpisodeFormat = "{Series Title} - S{season:00}E{episode:00} - {Episode Title} {Quality Full}" | .dailyEpisodeFormat = "{Series Title} - {Air-Date} - {Episode Title} {Quality Full}" | .animeEpisodeFormat = "{Series Title} - S{season:00}E{episode:00} - {Episode Title} {Quality Full}" | .seriesFolderFormat = "{Series Title}" | .seasonFolderFormat = "Season {season}" | .multiEpisodeStyle = 5 | .colonReplacementFormat = 4'
}
