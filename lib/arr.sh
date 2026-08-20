#!/bin/bash
# assemblrr *arr service configuration — sourced by config.sh
# Provides: set_arr_auth, qbit helpers, configure_arr_service, profile lookups,
#           configure_radarr, configure_sonarr, configure_prowlarr,
#           apply_selected_indexers, sync_selected_indexers,
#           prowlarr_sync_gluetun_proxy
# Requires: lib/core.sh (logging), lib/api.sh (api_get/post/put/delete helpers),
#           lib/quality.sh (tier + name lookup),
#           config.sh (_cfg_log_info, log_step, log_step_fail, AUTH_USERNAME, etc.)

set -euo pipefail

_arr_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[ -f "$_arr_dir/quality.sh" ] && source "$_arr_dir/quality.sh"

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

# True when this install routes qB through Gluetun.
qbit_vpn_enabled() {
    case "${VPN_ENABLED:-n}" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

# setPreferences JSON: save paths, Automatic Torrent Management, and tun0 when VPN is on.
# ATM makes category save paths real: Radarr → /data/torrents/movies, Sonarr → /data/torrents/tv.
# Per-torrent TMM is left alone, so already-downloaded torrents stay where they are.
# qB 5.x + WireGuard does not bind the POINTOPOINT tun by itself; "Any"
# listens on eth0 and Gluetun's kill switch then drops tracker/DHT packets
# ("Operation not permitted" → stalledDL).
# Optional $1/$2 = WebUI username/password (jq-escaped).
qbit_core_prefs_json() {
    local user="${1:-}"
    local pass="${2:-}"
    local iface=""
    if qbit_vpn_enabled; then
        iface="tun0"
    fi
    if [ -n "$user" ]; then
        jq -nc --arg iface "$iface" --arg user "$user" --arg pass "$pass" \
            '{save_path:"/data/torrents",temp_path:"/data/torrents/incomplete",temp_path_enabled:true,auto_tmm_enabled:true,current_network_interface:$iface,web_ui_username:$user,web_ui_password:$pass}'
    else
        jq -nc --arg iface "$iface" \
            '{save_path:"/data/torrents",temp_path:"/data/torrents/incomplete",temp_path_enabled:true,auto_tmm_enabled:true,current_network_interface:$iface}'
    fi
}

qbit_login_form() {
    local cookie_jar="$1"
    local user="$2"
    local pass="$3"
    local qbit_port="${4:-8081}"
    curl -s --connect-timeout 5 -c "$cookie_jar" \
        -H "Referer: http://${API_HOST}:${qbit_port}" \
        --data-urlencode "username=${user}" \
        --data-urlencode "password=${pass}" \
        "http://${API_HOST}:${qbit_port}/api/v2/auth/login" 2>/dev/null >/dev/null || true
}

qbit_apply_prefs() {
    local cookie_jar="$1"
    local user="${2:-}"
    local pass="${3:-}"
    local qbit_port=8081
    local json
    json=$(qbit_core_prefs_json "$user" "$pass")
    curl -s --connect-timeout 5 \
        "http://${API_HOST}:${qbit_port}/api/v2/app/setPreferences" \
        -b "$cookie_jar" \
        -H "Referer: http://${API_HOST}:${qbit_port}" \
        --data-urlencode "json=${json}" \
        2>/dev/null >/dev/null || true
}

# Set qBittorrent WebUI credentials, save paths, and VPN interface.
# Prefer final credentials when already configured (avoids brute-force lockouts).
qbit_set_credentials() {
    local qbit_port=8081
    local qbit_cookie_jar="/tmp/qb_cookie_jar_init_$$_${qbit_port}"

    # Idempotent: succeed if final credentials already work
    if [ -n "$AUTH_USERNAME" ] && [ -n "$AUTH_PASSWORD" ]; then
        qbit_login_form "$qbit_cookie_jar" "$AUTH_USERNAME" "$AUTH_PASSWORD" "$qbit_port"
        local qbit_sid
        qbit_sid=$(qbit_cookie_sid "$qbit_cookie_jar")
        if [ -n "$qbit_sid" ]; then
            qbit_apply_prefs "$qbit_cookie_jar"
            if qbit_vpn_enabled; then
                _cfg_log_info "qBittorrent credentials already set; BitTorrent bound to tun0"
            else
                _cfg_log_info "qBittorrent credentials already set"
            fi
            rm -f "$qbit_cookie_jar"
            return 0
        fi
    fi

    # First-time setup: temporary password from container logs
    local wait_time=0
    local max_wait=60

    while [ $wait_time -lt $max_wait ]; do
        local qbit_temp_pass
        qbit_temp_pass=$(docker logs qbittorrent 2>&1 | awk -F': ' '/temporary password is provided for this session:/ { print $NF; exit }' || true)

        if [ -n "$qbit_temp_pass" ]; then
            qbit_login_form "$qbit_cookie_jar" "admin" "$qbit_temp_pass" "$qbit_port"
            local qbit_sid
            qbit_sid=$(qbit_cookie_sid "$qbit_cookie_jar")
            if [ -n "$qbit_sid" ]; then
                qbit_apply_prefs "$qbit_cookie_jar" "$AUTH_USERNAME" "$AUTH_PASSWORD"
                echo >&2
                if qbit_vpn_enabled; then
                    _cfg_log_info "Set qBittorrent credentials, save path, and tun0 bind"
                else
                    _cfg_log_info "Set qBittorrent credentials and save path"
                fi
                rm -f "$qbit_cookie_jar"
                return 0
            fi
        fi
        wait_inline "Waiting for qBittorrent to initialize" "$wait_time"
        sleep 3
        wait_time=$((wait_time + 3))
    done
    echo >&2
    log_warning "Could not login to qBittorrent with temp password"
    rm -f "$qbit_cookie_jar"
    return 1
}

qbit_try_login() {
    local user="$1"
    local pass="$2"
    local cookie_jar="$3"
    local qbit_port=8081

    [ -n "$user" ] && [ -n "$pass" ] || return 1
    : >"$cookie_jar"
    qbit_login_form "$cookie_jar" "$user" "$pass" "$qbit_port"
    [ -n "$(qbit_cookie_sid "$cookie_jar")" ]
}

# Login with the old password, then set the new WebUI user/pass.
# Tries new (already changed) then the first-boot temp password if old fails.
qbit_change_credentials() {
    local old_user="$1"
    local old_pass="$2"
    local new_user="$3"
    local new_pass="$4"
    local qbit_port=8081
    local cookie_jar="/tmp/qb_cookie_jar_chpass_$$_${qbit_port}"
    local verify_jar="/tmp/qb_cookie_jar_chpass_v_$$_${qbit_port}"

    if [ -z "$new_user" ] || [ -z "$new_pass" ]; then
        log_step_fail "qBittorrent: new credentials missing"
        return 1
    fi

    if ! qbit_try_login "$old_user" "$old_pass" "$cookie_jar"; then
        if qbit_try_login "$new_user" "$new_pass" "$cookie_jar"; then
            qbit_apply_prefs "$cookie_jar"
            rm -f "$cookie_jar"
            log_step "qBittorrent: already using the new password"
            return 0
        fi
        local qbit_temp_pass
        qbit_temp_pass=$(docker logs qbittorrent 2>&1 | awk -F': ' '/temporary password is provided for this session:/ { print $NF; exit }' || true)
        if [ -z "$qbit_temp_pass" ] || ! qbit_try_login "admin" "$qbit_temp_pass" "$cookie_jar"; then
            rm -f "$cookie_jar"
            log_step_fail "qBittorrent: could not log in with the old password"
            return 1
        fi
    fi

    qbit_apply_prefs "$cookie_jar" "$new_user" "$new_pass"
    rm -f "$cookie_jar"

    if qbit_try_login "$new_user" "$new_pass" "$verify_jar"; then
        rm -f "$verify_jar"
        log_step "qBittorrent: set login (${new_user})"
        return 0
    fi
    rm -f "$verify_jar"
    log_step_fail "qBittorrent: password change did not stick"
    return 1
}

# Create or update a qBittorrent category with a save path
qbit_create_category() {
    local service_name="$1"
    local category="$2"
    local save_path="$3"

    local qbit_port=8081
    local qbit_cookie_jar="/tmp/qb_cookie_jar_${service_name}_$$_${qbit_port}"
    qbit_login_form "$qbit_cookie_jar" "$AUTH_USERNAME" "$AUTH_PASSWORD" "$qbit_port"
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

# Point an existing *arr qBittorrent client at the current host
# (gluetun when VPN is on, qbittorrent when off).
arr_update_qb_host() {
    local service_name="$1"
    local port="$2"
    local apikey="$3"
    local host="${QBITTORRENT_HOST:-qbittorrent}"
    local clients dc_id existing updated result

    [ -n "$apikey" ] || return 1
    clients=$(api_get "$port" "/api/v3/downloadclient" "$apikey")
    dc_id=$(echo "$clients" | jq -r \
        '[.[] | select(.implementationName == "qBittorrent" or .implementation == "QBittorrent")][0].id // empty' \
        2>/dev/null || true)
    [ -n "$dc_id" ] || return 1
    existing=$(echo "$clients" | jq --argjson id "$dc_id" '.[] | select(.id == $id)' 2>/dev/null || true)
    [ -n "$existing" ] || return 1
    updated=$(echo "$existing" | jq --arg host "$host" \
        '.fields = [.fields[] | if .name == "host" then .value = $host else . end]' \
        2>/dev/null || true)
    [ -n "$updated" ] || return 1
    result=$(api_put "$port" "/api/v3/downloadclient/${dc_id}" "$apikey" "$updated")
    if jq_json_has_key "$result" "id"; then
        log_step "${service_name}: qBittorrent host → ${host}"
        return 0
    fi
    return 1
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

    if ! echo "$existing_impls" | grep -q "qBittorrent"; then
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
        local existing_dc dc_id updated_dc dc_put
        existing_dc=$(echo "$download_clients" | jq '[.[] | select(.implementationName == "qBittorrent" or .implementation == "QBittorrent")][0]' 2>/dev/null || echo "")
        dc_id=$(echo "$existing_dc" | jq -r '.id // empty' 2>/dev/null || echo "")
        if [ -n "$dc_id" ] && [ -n "$qbit_payload" ]; then
            updated_dc=$(echo "$qbit_payload" | jq --argjson id "$dc_id" '.id = $id' 2>/dev/null || echo "")
            if [ -n "$updated_dc" ]; then
                dc_put=$(api_put "$port" "/api/v3/downloadclient/${dc_id}" "$apikey" "$updated_dc")
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

    # 2c. Enable hardlinks in Media Management
    local mediamgmt
    mediamgmt=$(api_get "$port" "/api/v3/config/mediamanagement" "$apikey")
    if [ -n "$mediamgmt" ]; then
        local mgmt_payload
        mgmt_payload=$(echo "$mediamgmt" | jq --arg uf "$unmonitor_field" \
            '.copyUsingHardlinks = true | .enableMediaManagement = true | .[$uf] = true
             | .recycleBin = "/data/media/.recycle" | .recycleBinCleanupDays = 7' 2>/dev/null || echo "")
        if [ -n "$mgmt_payload" ]; then
            local mgmt_result
            mgmt_result=$(api_put "$port" "/api/v3/config/mediamanagement" "$apikey" "$mgmt_payload")
            if jq_json_has_key "$mgmt_result" "id"; then
                log_step "${service_name}: enabled hardlinks + recycle bin (/data/media/.recycle)"
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

# Item ids whose qualityProfileId still needs updating.
# stdin: JSON array of {id, qualityProfileId}. $1 = target id. $2 = all | any-only | from:<id>
arr_quality_ids_needing_update() {
    local pid="$1"
    local mode="${2:-all}"
    case "$mode" in
        any-only)
            jq -c --argjson pid "$pid" '[.[] | select((.qualityProfileId // 0) == 1 and .id != null) | .id]'
            ;;
        from:*)
            local from="${mode#from:}"
            jq -c --argjson old "$from" '[.[] | select((.qualityProfileId // 0) == $old and .id != null) | .id]'
            ;;
        *)
            jq -c --argjson pid "$pid" '[.[] | select((.qualityProfileId // 0) != $pid and .id != null) | .id]'
            ;;
    esac
}

# stdin: source quality-profile object. $1 = dest id. $2 = dest name.
arr_quality_profile_clone_json() {
    local dest_id="$1"
    local dest_name="$2"
    jq --argjson id "$dest_id" --arg name "$dest_name" '.id = $id | .name = $name'
}

# stdin: one root-folder object. $1 = target quality profile id.
arr_rootfolder_with_default_profile() {
    local pid="$1"
    jq --argjson pid "$pid" 'del(.unmappedFolders) | .defaultQualityProfileId = $pid'
}

_arr_put_http() {
    local port="$1"
    local endpoint="$2"
    local apikey="$3"
    local data="$4"
    curl -s -o /tmp/arr-put-body -w "%{http_code}" --connect-timeout 8 -X PUT \
        -H "Content-Type: application/json" \
        -d "$data" \
        "http://${API_HOST}:${port}${endpoint}?apikey=${apikey}" 2>/dev/null || echo "000"
}

arr_set_root_folder_quality_profile() {
    local service_name="$1"
    local port="$2"
    local apikey="$3"
    local profile_id="$4"
    local folders folder payload code ok=0

    folders=$(api_get "$port" "/api/v3/rootfolder" "$apikey")
    if [ -z "$folders" ] || [ "$folders" = "[]" ]; then
        return 1
    fi

    while IFS= read -r folder; do
        [ -z "$folder" ] && continue
        local fid
        fid=$(echo "$folder" | jq -r '.id // empty')
        [ -n "$fid" ] || continue
        payload=$(echo "$folder" | arr_rootfolder_with_default_profile "$profile_id")
        [ -n "$payload" ] || continue
        code=$(_arr_put_http "$port" "/api/v3/rootfolder/${fid}" "$apikey" "$payload")
        if [ "$code" -ge 200 ] && [ "$code" -lt 300 ]; then
            ok=$((ok + 1))
        fi
    done < <(echo "$folders" | jq -c '.[]' 2>/dev/null || true)

    [ "$ok" -gt 0 ]
}

# $5 = movie | series. $6 = all | any-only (default all).
arr_set_items_quality_profile() {
    local service_name="$1"
    local port="$2"
    local apikey="$3"
    local profile_id="$4"
    local kind="$5"
    local mode="${6:-all}"
    local list_path editor_path id_key
    local items ids payload code

    if [ "$kind" = "series" ]; then
        list_path="/api/v3/series"
        editor_path="/api/v3/series/editor"
        id_key="seriesIds"
    else
        list_path="/api/v3/movie"
        editor_path="/api/v3/movie/editor"
        id_key="movieIds"
    fi

    items=$(api_get "$port" "$list_path" "$apikey")
    if [ -z "$items" ] || [ "$items" = "[]" ]; then
        return 0
    fi
    ids=$(echo "$items" | arr_quality_ids_needing_update "$profile_id" "$mode")
    if [ -z "$ids" ] || [ "$ids" = "[]" ]; then
        return 0
    fi

    payload=$(jq -nc --argjson ids "$ids" --argjson pid "$profile_id" --arg key "$id_key" \
        '{($key): $ids, qualityProfileId: $pid}')
    code=$(_arr_put_http "$port" "$editor_path" "$apikey" "$payload")
    if [ "$code" -ge 200 ] && [ "$code" -lt 300 ]; then
        local n
        n=$(echo "$ids" | jq 'length' 2>/dev/null || echo 0)
        log_step "${service_name}: moved ${n} title(s) → quality profile ${profile_id}"
        return 0
    fi
    return 1
}

arr_set_importlist_quality_profile() {
    local service_name="$1"
    local port="$2"
    local apikey="$3"
    local profile_id="$4"
    local lists list payload code ok=0 total=0

    lists=$(api_get "$port" "/api/v3/importlist" "$apikey")
    if [ -z "$lists" ] || [ "$lists" = "[]" ]; then
        return 0
    fi

    while IFS= read -r list; do
        [ -z "$list" ] && continue
        local lid cur
        lid=$(echo "$list" | jq -r '.id // empty')
        cur=$(echo "$list" | jq -r '.qualityProfileId // empty')
        [ -n "$lid" ] || continue
        total=$((total + 1))
        if [ "$cur" = "$profile_id" ]; then
            ok=$((ok + 1))
            continue
        fi
        payload=$(echo "$list" | jq --argjson pid "$profile_id" '.qualityProfileId = $pid')
        code=$(_arr_put_http "$port" "/api/v3/importlist/${lid}" "$apikey" "$payload")
        if [ "$code" -ge 200 ] && [ "$code" -lt 300 ]; then
            ok=$((ok + 1))
        fi
    done < <(echo "$lists" | jq -c '.[]' 2>/dev/null || true)

    [ "$total" -eq 0 ] || [ "$ok" -gt 0 ]
}

# *arr Add New defaults to quality profile id 1 (stock "Any"). There is no
# working "default profile" API on Sonarr (root-folder PUT is a no-op).
# Copy the assemblrr profile onto id 1 and drop the duplicate so the picker
# opens on the assemblrr profile.
arr_promote_quality_profile() {
    local service_name="$1"
    local port="$2"
    local apikey="$3"
    local src_id="$4"
    local src_name="$5"

    [ -n "$src_id" ] && [ -n "$src_name" ] || return 1
    if [ "$src_id" = "1" ]; then
        return 0
    fi

    # Recyclarr variants share a trash_id. Overwriting id 1 with a sibling
    # makes Recyclarr treat that as a rename and the other profile vanishes.
    local id1_name
    id1_name=$(api_get "$port" "/api/v3/qualityprofile/1" "$apikey" | jq -r '.name // empty')
    if [ -n "$id1_name" ] && [ "$id1_name" != "Any" ] && [ "$id1_name" != "$src_name" ]; then
        log_step "${service_name}: Add New slot stays ${id1_name}; default is ${src_name} (id ${src_id})"
        return 1
    fi

    local src dest tmp_name tmp_payload code
    src=$(api_get "$port" "/api/v3/qualityprofile/${src_id}" "$apikey")
    if [ -z "$src" ] || ! echo "$src" | jq -e '.id' >/dev/null 2>&1; then
        return 1
    fi

    tmp_name="${src_name}.__assemblrr_tmp"
    tmp_payload=$(echo "$src" | jq --arg n "$tmp_name" '.name = $n')
    code=$(_arr_put_http "$port" "/api/v3/qualityprofile/${src_id}" "$apikey" "$tmp_payload")
    if [ "$code" -lt 200 ] || [ "$code" -ge 300 ]; then
        return 1
    fi

    dest=$(echo "$src" | arr_quality_profile_clone_json 1 "$src_name")
    code=$(_arr_put_http "$port" "/api/v3/qualityprofile/1" "$apikey" "$dest")
    if [ "$code" -lt 200 ] || [ "$code" -ge 300 ]; then
        _arr_put_http "$port" "/api/v3/qualityprofile/${src_id}" "$apikey" "$src" >/dev/null || true
        return 1
    fi

    local kind="movie"
    [ "$service_name" = "Sonarr" ] && kind="series"
    arr_set_items_quality_profile "$service_name" "$port" "$apikey" "1" "$kind" "from:${src_id}" || true
    arr_set_importlist_quality_profile "$service_name" "$port" "$apikey" "1" || true

    local del
    del=$(api_delete "$port" "/api/v3/qualityprofile/${src_id}" "$apikey" || echo "000")
    if [ "$del" -ge 200 ] && [ "$del" -lt 300 ]; then
        log_step "${service_name}: Add New default is ${src_name}"
        return 0
    fi
    log_step "${service_name}: Add New default is ${src_name} (left extra profile id ${src_id})"
    return 0
}

# Apply the install's chosen quality profile as the *arr Add New default.
# Existing titles are left alone. Seerr uses the same lookup.
set_default_quality_profile() {
    local service_name="$1"
    local port="$2"
    local apikey="$3"
    local profile_func="$4"

    local profile profile_id profile_name
    profile=$($profile_func "$apikey")
    profile_id="${profile%%:*}"
    profile_name="${profile##*:}"

    if [ -z "$profile_id" ]; then
        log_step_fail "${service_name}: no quality profile to apply"
        return 1
    fi

    if quality_wants_named_profile && [ "$profile_id" = "1" ] && [ "$profile_name" = "Any" ]; then
        log_step_fail "${service_name}: assemblrr quality profile not found (Recyclarr sync missing?)"
        return 1
    fi

    if arr_promote_quality_profile "$service_name" "$port" "$apikey" "$profile_id" "$profile_name"; then
        profile_id="1"
    fi

    if [ -n "${INSTALL_DIR:-}" ]; then
        mkdir -p "$INSTALL_DIR/config"
        echo "${profile_id}:${profile_name}" > "$INSTALL_DIR/config/.${service_name,,}-default-quality-profile" 2>/dev/null || true
    fi

    # Best-effort: some Radarr builds honor this. Sonarr has no such field.
    arr_set_root_folder_quality_profile "$service_name" "$port" "$apikey" "$profile_id" || true
    arr_set_importlist_quality_profile "$service_name" "$port" "$apikey" "$profile_id" || true

    log_step "${service_name}: default quality profile → ${profile_name} (id ${profile_id})"
}

# --- Quality profile lookup ---

# $1 = api key, $2 = port, $3 = radarr | sonarr
lookup_arr_quality_profile() {
    local apikey="$1"
    local port="$2"
    local kind="$3"
    local profiles_json spec

    profiles_json=$(api_get "$port" "/api/v3/qualityprofile" "$apikey")
    if [ -z "$profiles_json" ]; then
        echo "1:Any"
        return
    fi

    spec=$(quality_profile_names "$kind")
    echo "$profiles_json" | arr_match_quality_profile "${spec%%|*}" "${spec##*|}"
}

lookup_radarr_profile() {
    lookup_arr_quality_profile "$1" 7878 radarr
}

lookup_sonarr_profile() {
    lookup_arr_quality_profile "$1" 8989 sonarr
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

# Indexer default: minSeeders=0 only. Seed ratio/time are left as the user set them.
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
                if .name == "minimumSeeders" then .value = 0
                else . end
            ]
        ' 2>/dev/null || echo "")
        [ -z "$idx_payload" ] && continue
        result=$(api_put "$port" "/api/v3/indexer/${idx_id}" "$apikey" "$idx_payload")
        if echo "$result" | jq -e '.id' >/dev/null 2>&1; then
            ok=$((ok + 1))
        fi
    done < <(echo "$indexers" | jq -c '.[]' 2>/dev/null || true)

    if [ "$ok" -gt 0 ]; then
        log_step "${service_name}: indexer minSeeders=0 (${ok})"
        return 0
    fi
    return 1
}

# On movie/series delete, run arr-purge-hook.sh (qB torrent + files).
add_arr_purge_hook() {
    local app_name="$1"
    local port="$2"
    local apikey="$3"

    [ -z "$apikey" ] && return 0

    local notifications existing_id
    notifications=$(api_get "$port" "/api/v3/notification" "$apikey")
    existing_id=$(echo "$notifications" | jq -r \
        '.[] | select(.implementation == "CustomScript" and .name == "assemblrr Media Purge") | .id // ""' \
        2>/dev/null | head -1 || echo "")

    if [ -f "${INSTALL_DIR:-}/scripts/arr-purge-hook.sh" ]; then
        chmod +x "${INSTALL_DIR}/scripts/arr-purge-hook.sh" 2>/dev/null || true
    fi
    if [ -f "${INSTALL_DIR:-}/scripts/media-purge.sh" ]; then
        chmod +x "${INSTALL_DIR}/scripts/media-purge.sh" 2>/dev/null || true
    fi

    local schema payload result
    schema=$(api_get "$port" "/api/v3/notification/schema" "$apikey")

    if [ "$app_name" = "Radarr" ]; then
        payload=$(echo "$schema" | jq '
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
        payload=$(echo "$schema" | jq '
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
        payload=$(echo "$payload" | jq --argjson id "$existing_id" '.id = $id' 2>/dev/null || echo "$payload")
        result=$(api_put "$port" "/api/v3/notification/${existing_id}" "$apikey" "$payload")
        if jq_json_has_key "$result" "id"; then
            log_step "${app_name}: updated Media Purge hook"
            return 0
        fi
    fi

    result=$(api_post_force "$port" "/api/v3/notification" "$apikey" "$payload")
    if jq_json_has_key "$result" "id"; then
        log_step "${app_name}: added Media Purge hook"
        return 0
    fi
    local err_msg
    err_msg=$(echo "$result" | jq -r 'if type == "array" then .[0].errorMessage // empty else .errorMessage // empty end' 2>/dev/null || echo "")
    if [ -n "$err_msg" ]; then
        log_step_fail "${app_name}: failed to add Media Purge hook (${err_msg})"
    else
        log_step_fail "${app_name}: failed to add Media Purge hook"
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
            [ "$waited" -gt 0 ] && echo >&2
            return 0
        fi
        wait_inline "Waiting for Radarr indexers from Prowlarr" "$waited"
        sleep 2
        waited=$((waited + 2))
    done
    echo >&2
    return 1
}

# Route Prowlarr indexer HTTP through Gluetun when VPN is on; remove it when off.
# Empty tags = every indexer. Does not wrap Radarr/Sonarr app sync (LAN hostnames).
# Manages only the proxy named below (or an existing Http proxy already on gluetun:8888).
PROWLARR_GLUETUN_PROXY_NAME="assemblrr Gluetun"
PROWLARR_GLUETUN_PROXY_HOST="gluetun"
PROWLARR_GLUETUN_PROXY_PORT="8888"

# $2 = "name" (managed only) or "any" (name or host:port — avoid duplicates)
_prowlarr_gluetun_proxy_id() {
    local proxies="$1"
    local mode="${2:-any}"
    echo "$proxies" | jq -r \
        --arg name "$PROWLARR_GLUETUN_PROXY_NAME" \
        --arg host "$PROWLARR_GLUETUN_PROXY_HOST" \
        --argjson port "$PROWLARR_GLUETUN_PROXY_PORT" \
        --arg mode "$mode" '
        .[] | select(
            .name == $name
            or (
                $mode == "any"
                and .implementation == "Http"
                and (([.fields[]? | select(.name == "host") | .value][0] // "") | tostring) == $host
                and (([.fields[]? | select(.name == "port") | .value][0] // 0) | tonumber) == $port
            )
        ) | .id
    ' 2>/dev/null | head -1
}

_prowlarr_gluetun_proxy_payload() {
    local schema="$1"
    echo "$schema" | jq -c \
        --arg name "$PROWLARR_GLUETUN_PROXY_NAME" \
        --arg host "$PROWLARR_GLUETUN_PROXY_HOST" \
        --argjson port "$PROWLARR_GLUETUN_PROXY_PORT" '
        [.[] | select(.implementation == "Http")][0] |
        .fields = [.fields[] | if .name == "host" then .value = $host
            elif .name == "port" then .value = $port
            elif .name == "username" then .value = ""
            elif .name == "password" then .value = ""
            else . end] |
        .name = $name | .tags = []
    ' 2>/dev/null || echo ""
}

prowlarr_sync_gluetun_proxy() {
    local apikey="$1"
    local proxies existing_id

    if [ -z "$apikey" ]; then
        log_step_fail "Prowlarr: no API key — cannot send searches through the VPN"
        return 1
    fi

    proxies=$(api_get "9696" "/api/v1/indexerProxy" "$apikey")
    if [ -z "$proxies" ]; then
        log_step_fail "Prowlarr: could not list search proxies"
        return 1
    fi
    if ! qbit_vpn_enabled; then
        existing_id=$(_prowlarr_gluetun_proxy_id "$proxies" "name")
        if [ -z "$existing_id" ]; then
            return 0
        fi
        local code
        code=$(api_delete "9696" "/api/v1/indexerProxy/${existing_id}" "$apikey")
        if [ "$code" = "200" ] || [ "$code" = "204" ]; then
            log_step "Prowlarr: searches no longer go through the VPN"
            return 0
        fi
        log_step_fail "Prowlarr: could not stop sending searches through the VPN (HTTP ${code:-?})"
        return 1
    fi

    existing_id=$(_prowlarr_gluetun_proxy_id "$proxies" "any")

    local schema payload result
    schema=$(api_get "9696" "/api/v1/indexerProxy/schema" "$apikey")
    payload=$(_prowlarr_gluetun_proxy_payload "$schema")
    if [ -z "$payload" ]; then
        log_step_fail "Prowlarr: could not set up VPN search routing"
        return 1
    fi

    if [ -n "$existing_id" ]; then
        payload=$(echo "$payload" | jq -c --argjson id "$existing_id" '.id = $id' 2>/dev/null || echo "$payload")
        result=$(curl -s --connect-timeout 5 -X PUT \
            -H "Content-Type: application/json" \
            -d "$payload" \
            "http://${API_HOST}:9696/api/v1/indexerProxy/${existing_id}?apikey=${apikey}&forceSave=true" 2>/dev/null)
        if jq_json_has_key "$result" "id"; then
            log_step "Prowlarr: searches go through the VPN"
            return 0
        fi
        log_step_fail "Prowlarr: could not send searches through the VPN"
        return 1
    fi

    result=$(curl -s --connect-timeout 5 -X POST \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "http://${API_HOST}:9696/api/v1/indexerProxy?apikey=${apikey}&forceSave=true" 2>/dev/null)
    if jq_json_has_key "$result" "id"; then
        log_step "Prowlarr: searches go through the VPN"
        return 0
    fi
    log_step_fail "Prowlarr: could not send searches through the VPN"
    return 1
}

# POST indexers named in SELECTED_INDEXERS into Prowlarr (skip existing).
# Used by first-run wiring and `assemblrr config edit`.
apply_selected_indexers() {
    local apikey="$1"
    local indexer_schemas
    indexer_schemas=$(api_get "9696" "/api/v1/indexer/schema" "$apikey")

    if [ -z "$indexer_schemas" ]; then
        log_step_fail "Prowlarr: failed to fetch indexer schemas"
        return 1
    fi

    local selected_indexers=()
    if [ -n "${SELECTED_INDEXERS+x}" ] && [ "${#SELECTED_INDEXERS[@]}" -gt 0 ]; then
        selected_indexers=("${SELECTED_INDEXERS[@]}")
        echo "Applying ${#selected_indexers[@]} selected Prowlarr indexer(s)" >&2
    fi

    local existing_indexers
    existing_indexers=$(api_get "9696" "/api/v1/indexer" "$apikey")
    local existing_names
    existing_names=$(jq_json_list_values "$existing_indexers" "name")

    local indexer_name
    for indexer_name in "${selected_indexers[@]+"${selected_indexers[@]}"}"; do
        if echo "$existing_names" | grep -q -F -x "$indexer_name"; then
            log_step "Prowlarr: ${indexer_name} indexer already exists"
            continue
        fi

        # Cardigann indexers match on 'name'. Empty field values use definition defaults.
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

        local idx_result
        idx_result=$(curl -s --connect-timeout 5 -X POST \
            -H "Content-Type: application/json" \
            -d "$indexer_payload" \
            "http://${API_HOST}:9696/api/v1/indexer?apikey=${apikey}&forceSave=true" 2>/dev/null)
        if jq_json_has_key "$idx_result" "id"; then
            log_step "Prowlarr: added ${indexer_name} indexer"
        else
            local err_msg disabled_payload
            err_msg=$(echo "$idx_result" | jq -r 'if type == "array" then .[0].errorMessage // empty else .errorMessage // empty end' 2>/dev/null || echo "")
            disabled_payload=$(echo "$indexer_payload" | jq -c '.enable = false' 2>/dev/null || echo "")
            idx_result=$(curl -s --connect-timeout 5 -X POST \
                -H "Content-Type: application/json" \
                -d "$disabled_payload" \
                "http://${API_HOST}:9696/api/v1/indexer?apikey=${apikey}&forceSave=true" 2>/dev/null)
            if jq_json_has_key "$idx_result" "id"; then
                log_step "Prowlarr: added ${indexer_name} indexer, but could not enable it"
                [ -n "$err_msg" ] && log_step "Prowlarr: ${err_msg}"
            else
                log_step_fail "Prowlarr: failed to add ${indexer_name} indexer"
            fi
        fi
    done
    if [ "${#selected_indexers[@]}" -gt 0 ]; then
        echo >&2
        log_success "Prowlarr indexer configuration finished (check markers above for any failures)" >&2
    fi
    return 0
}

# Make Prowlarr match SELECTED_INDEXERS: add missing, delete unselected.
# Esc/empty selection is a no-op (caller should skip). Confirm = desired set.
sync_selected_indexers() {
    local apikey="$1"
    apply_selected_indexers "$apikey" || return 1

    local existing_indexers
    existing_indexers=$(api_get "9696" "/api/v1/indexer" "$apikey")
    if [ -z "$existing_indexers" ] || [ "$existing_indexers" = "[]" ]; then
        return 0
    fi

    local id name
    while IFS=$'\t' read -r id name; do
        [ -n "$id" ] && [ -n "$name" ] || continue
        if printf '%s\n' "${SELECTED_INDEXERS[@]+"${SELECTED_INDEXERS[@]}"}" | grep -q -F -x "$name"; then
            continue
        fi
        local code
        code=$(api_delete "9696" "/api/v1/indexer/${id}" "$apikey")
        if [ "$code" = "200" ] || [ "$code" = "204" ]; then
            log_step "Prowlarr: removed ${name} indexer"
        else
            log_step_fail "Prowlarr: failed to remove ${name} indexer (HTTP ${code:-?})"
        fi
    done < <(echo "$existing_indexers" | jq -r '.[] | "\(.id)\t\(.name)"' 2>/dev/null)
    return 0
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

    # 2. Indexer HTTP via Gluetun when VPN is on (empty tags = all indexers)
    if ! prowlarr_sync_gluetun_proxy "$apikey"; then
        critical_errors=$((critical_errors + 1))
    fi

    # 3. Selected indexers (optional; can add later via `config edit`)
    apply_selected_indexers "$apikey"

    # 4) After fullSync, set min seeders on *arr indexers (best-effort)
    wait_for_arr_indexer_sync "$radarr_apikey" || true
    arr_set_indexer_min_seeders "Radarr" "7878" "$radarr_apikey" || true
    arr_set_indexer_min_seeders "Sonarr" "8989" "$sonarr_apikey" || true

    # 5. Set authentication
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

# --- Import existing media (unmapped folders) into *arr ---
# Netflix-like: files already on disk under root folders should appear in
# Radarr/Sonarr (and thus Bazarr) without a redownload.

_folder_year() {
    local name="$1"
    if [[ "$name" =~ \(([0-9]{4})\)$ ]]; then
        echo "${BASH_REMATCH[1]}"
    fi
}

_folder_title_guess() {
    local name="$1"
    # Strip trailing " (YYYY)"
    echo "$name" | sed -E 's/[[:space:]]*\([0-9]{4}\)[[:space:]]*$//'
}

# Import Radarr unmapped movie folders. Uses default quality profile; no search.
import_radarr_existing_media() {
    local apikey="$1"
    local port=7878
    local root_json unmapped profile_info profile_id
    local added=0 skipped=0 failed=0
    local folder_path folder_name year title_guess
    local lookup_json match payload result movie_id

    root_json=$(api_get "$port" "/api/v3/rootfolder" "$apikey")
    if [ -z "$root_json" ] || [ "$root_json" = "[]" ]; then
        log_step_fail "Radarr: no root folders — skip existing media import"
        return 1
    fi

    profile_info=$(lookup_radarr_profile "$apikey")
    profile_id=${profile_info%%:*}
    profile_id=${profile_id:-1}

    # Collect unmapped folder paths
    while IFS=$'\t' read -r folder_path folder_name; do
        [ -z "$folder_path" ] && continue
        year=$(_folder_year "$folder_name")
        title_guess=$(_folder_title_guess "$folder_name")

        # Already in library at this path?
        if api_get "$port" "/api/v3/movie" "$apikey" | jq -e --arg p "$folder_path" '
            any(.[]; .path == $p)
        ' >/dev/null 2>&1; then
            skipped=$((skipped + 1))
            continue
        fi

        # Lookup by title (+ year in query when known)
        local term="$title_guess"
        [ -n "$year" ] && term="${title_guess} ${year}"
        lookup_json=$(curl -sG --connect-timeout 15 \
            --data-urlencode "term=${term}" \
            "http://${API_HOST}:${port}/api/v3/movie/lookup?apikey=${apikey}" 2>/dev/null || echo "[]")

        if [ -z "$lookup_json" ] || [ "$lookup_json" = "[]" ]; then
            log_step_fail "Radarr: no match for '${folder_name}'"
            failed=$((failed + 1))
            continue
        fi

        # Prefer exact year match when folder has a year
        match=$(echo "$lookup_json" | jq -c --argjson y "${year:-0}" '
            if $y > 0 then
                ([.[] | select(.year == $y)] | .[0]) // .[0]
            else
                .[0]
            end
        ' 2>/dev/null || echo "")

        if [ -z "$match" ] || [ "$match" = "null" ]; then
            log_step_fail "Radarr: could not pick match for '${folder_name}'"
            failed=$((failed + 1))
            continue
        fi

        payload=$(echo "$match" | jq -c \
            --argjson qid "$profile_id" \
            --arg path "$folder_path" \
            --arg root "/data/media/movies" \
            '
            {
              title: .title,
              tmdbId: .tmdbId,
              year: .year,
              qualityProfileId: $qid,
              monitored: true,
              minimumAvailability: (.minimumAvailability // "announced"),
              rootFolderPath: $root,
              path: $path,
              addOptions: { searchForMovie: false }
            }
            ' 2>/dev/null || echo "")

        if [ -z "$payload" ]; then
            failed=$((failed + 1))
            continue
        fi

        result=$(api_post "$port" "/api/v3/movie" "$apikey" "$payload")
        movie_id=$(echo "$result" | jq -r '.id // empty' 2>/dev/null || echo "")
        if [ -z "$movie_id" ]; then
            # Already exists (tmdb) is not a hard failure
            if echo "$result" | jq -e '.message' 2>/dev/null | grep -qi 'exist\|already' 2>/dev/null; then
                skipped=$((skipped + 1))
            else
                log_step_fail "Radarr: import failed for '${folder_name}'"
                failed=$((failed + 1))
            fi
            continue
        fi

        # Link files already on disk
        api_post "$port" "/api/v3/command" "$apikey" \
            "{\"name\":\"RescanMovie\",\"movieId\":${movie_id}}" >/dev/null 2>&1 || true
        added=$((added + 1))
        log_step "Radarr: imported existing '${folder_name}' (id ${movie_id}, profile ${profile_id})"
    done < <(echo "$root_json" | jq -r '
        .[] | .unmappedFolders[]? | "\(.path)\t\(.name)"
    ' 2>/dev/null || true)

    if [ "$added" -eq 0 ] && [ "$failed" -eq 0 ]; then
        log_step "Radarr: no unmapped movie folders to import"
        return 0
    fi
    log_step "Radarr: existing media import done (added=${added}, skipped=${skipped}, failed=${failed})"
    [ "$failed" -eq 0 ]
}

# Import Sonarr unmapped series folders. No automatic search.
import_sonarr_existing_media() {
    local apikey="$1"
    local port=8989
    local root_json profile_info profile_id
    local added=0 skipped=0 failed=0
    local folder_path folder_name title_guess
    local lookup_json match payload result series_id language_profile_id

    root_json=$(api_get "$port" "/api/v3/rootfolder" "$apikey")
    if [ -z "$root_json" ] || [ "$root_json" = "[]" ]; then
        log_step_fail "Sonarr: no root folders — skip existing media import"
        return 1
    fi

    profile_info=$(lookup_sonarr_profile "$apikey")
    profile_id=${profile_info%%:*}
    profile_id=${profile_id:-1}

    # Language profile (required by modern Sonarr)
    language_profile_id=$(api_get "$port" "/api/v3/languageprofile" "$apikey" | jq -r '.[0].id // 1' 2>/dev/null || echo "1")

    while IFS=$'\t' read -r folder_path folder_name; do
        [ -z "$folder_path" ] && continue
        title_guess=$(_folder_title_guess "$folder_name")

        if api_get "$port" "/api/v3/series" "$apikey" | jq -e --arg p "$folder_path" '
            any(.[]; .path == $p)
        ' >/dev/null 2>&1; then
            skipped=$((skipped + 1))
            continue
        fi

        lookup_json=$(curl -sG --connect-timeout 15 \
            --data-urlencode "term=${title_guess}" \
            "http://${API_HOST}:${port}/api/v3/series/lookup?apikey=${apikey}" 2>/dev/null || echo "[]")

        if [ -z "$lookup_json" ] || [ "$lookup_json" = "[]" ]; then
            log_step_fail "Sonarr: no match for '${folder_name}'"
            failed=$((failed + 1))
            continue
        fi

        match=$(echo "$lookup_json" | jq -c '.[0]' 2>/dev/null || echo "")
        if [ -z "$match" ] || [ "$match" = "null" ]; then
            failed=$((failed + 1))
            continue
        fi

        payload=$(echo "$match" | jq -c \
            --argjson qid "$profile_id" \
            --argjson lid "$language_profile_id" \
            --arg path "$folder_path" \
            --arg root "/data/media/tv" \
            '
            . + {
              qualityProfileId: $qid,
              languageProfileId: $lid,
              rootFolderPath: $root,
              path: $path,
              monitored: true,
              seasonFolder: true,
              addOptions: {
                searchForMissingEpisodes: false,
                searchForCutoffUnmetEpisodes: false,
                monitor: "all"
              }
            } | del(.id, .statistics, .episodesChanged)
            ' 2>/dev/null || echo "")

        if [ -z "$payload" ]; then
            failed=$((failed + 1))
            continue
        fi

        result=$(api_post "$port" "/api/v3/series" "$apikey" "$payload")
        series_id=$(echo "$result" | jq -r '.id // empty' 2>/dev/null || echo "")
        if [ -z "$series_id" ]; then
            log_step_fail "Sonarr: import failed for '${folder_name}'"
            failed=$((failed + 1))
            continue
        fi

        api_post "$port" "/api/v3/command" "$apikey" \
            "{\"name\":\"RescanSeries\",\"seriesId\":${series_id}}" >/dev/null 2>&1 || true
        added=$((added + 1))
        log_step "Sonarr: imported existing '${folder_name}' (id ${series_id}, profile ${profile_id})"
    done < <(echo "$root_json" | jq -r '
        .[] | .unmappedFolders[]? | "\(.path)\t\(.name)"
    ' 2>/dev/null || true)

    if [ "$added" -eq 0 ] && [ "$failed" -eq 0 ]; then
        log_step "Sonarr: no unmapped series folders to import"
        return 0
    fi
    log_step "Sonarr: existing media import done (added=${added}, skipped=${skipped}, failed=${failed})"
    [ "$failed" -eq 0 ]
}

# Trigger Bazarr library sync after *arr imports (best-effort)
trigger_bazarr_library_sync() {
    local bazarr_key=""
    local cfg
    for cfg in \
        "$INSTALL_DIR/config/bazarr/config/config.yaml" \
        "$INSTALL_DIR/config/bazarr/config/config.ini"
    do
        [ -f "$cfg" ] || continue
        if [[ "$cfg" == *.yaml ]]; then
            bazarr_key=$(awk '
                /^auth:[[:space:]]*$/ { in_auth=1; next }
                in_auth && /^[^[:space:]]/ { in_auth=0 }
                in_auth && /^[[:space:]]+apikey:[[:space:]]*/ {
                    sub(/^[[:space:]]+apikey:[[:space:]]*/, "")
                    gsub(/["\047]/, "")
                    print; exit
                }
            ' "$cfg" 2>/dev/null | head -1)
        else
            bazarr_key=$(sed -n 's/^[[:space:]]*apikey[[:space:]]*=[[:space:]]*//p' "$cfg" 2>/dev/null | head -1)
        fi
        [ -n "$bazarr_key" ] && break
    done
    [ -z "$bazarr_key" ] && [ -f "$INSTALL_DIR/secrets/bazarr_api_key.txt" ] && \
        bazarr_key=$(cat "$INSTALL_DIR/secrets/bazarr_api_key.txt" 2>/dev/null || echo "")

    if [ -z "$bazarr_key" ]; then
        return 0
    fi

    curl -s -o /dev/null --connect-timeout 5 -X POST -F "taskid=update_movies" \
        "http://${API_HOST}:6767/api/system/tasks?apikey=${bazarr_key}" 2>/dev/null || true
    curl -s -o /dev/null --connect-timeout 5 -X POST -F "taskid=update_series" \
        "http://${API_HOST}:6767/api/system/tasks?apikey=${bazarr_key}" 2>/dev/null || true
    log_step "Bazarr: triggered library sync with Sonarr/Radarr"
    return 0
}

