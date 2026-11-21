#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# assemblrr Radarr/Sonarr quality sizes & default quality-profile promotion
# Requires: lib/core.sh, lib/api.sh, lib/quality.sh

if [ -n "${_ASSEMBLRR_ARR_QUALITY_SOURCED:-}" ]; then
    return 0
fi
readonly _ASSEMBLRR_ARR_QUALITY_SOURCED=1

_arr_quality_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/quality.sh
[ -f "$_arr_quality_dir/quality.sh" ] && source "$_arr_quality_dir/quality.sh"

# Set minSize=0 on every quality definition (avoids rejecting small legitimate releases).
relax_quality_sizes() {
    local service_name="$1"
    local port="$2"
    local apikey="$3"

    local defs
    defs=$(api_get "$port" "/api/v3/qualitydefinition" "$apikey" || echo "")
    if [ -z "$defs" ] || [ "$defs" = "[]" ]; then
        log_step_fail "${service_name}: no quality definitions to update"
        return 1
    fi

    local payload
    payload=$(printf '%s' "$defs" | jq '[.[] | .minSize = 0]' 2>/dev/null || echo "")
    if [ -z "$payload" ]; then
        log_step_fail "${service_name}: failed to build quality definition payload"
        return 1
    fi

    local result=""
    if result=$(api_put "$port" "/api/v3/qualitydefinition/update" "$apikey" "$payload") && \
       printf '%s' "$result" | jq -e 'type == "array"' >/dev/null 2>&1; then
        log_step "${service_name}: quality minSize set to 0"
        return 0
    fi

    # Fallback: one PUT per definition (check actual HTTP status via api_put return code)
    local ok=0 total=0 row id
    while IFS= read -r row; do
        [ -z "$row" ] && continue
        total=$((total + 1))
        id=$(printf '%s' "$row" | jq -r '.id // empty')
        [ -z "$id" ] && continue
        if api_put "$port" "/api/v3/qualitydefinition/${id}" "$apikey" "$row" >/dev/null 2>&1; then
            ok=$((ok + 1))
        fi
    done < <(printf '%s' "$payload" | jq -c '.[]' 2>/dev/null || true)

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

arr_quality_profile_clone_json() {
    local dest_id="$1"
    local dest_name="$2"
    jq --argjson id "$dest_id" --arg name "$dest_name" '.id = $id | .name = $name'
}

arr_rootfolder_with_default_profile() {
    local pid="$1"
    jq --argjson pid "$pid" 'del(.unmappedFolders) | .defaultQualityProfileId = $pid'
}

_arr_put_http() {
    local port="$1"
    local endpoint="$2"
    local apikey="$3"
    local data="$4"
    http_request PUT "http://${API_HOST}:${port}${endpoint}" \
        -H "X-Api-Key: ${apikey}" -H "Content-Type: application/json" -d "$data" || true
    printf '%s' "$HTTP_STATUS"
}

arr_set_root_folder_quality_profile() {
    local _service_name="$1"
    local port="$2"
    local apikey="$3"
    local profile_id="$4"
    local folders folder payload code ok=0

    folders=$(api_get "$port" "/api/v3/rootfolder" "$apikey" || echo "[]")
    if [ -z "$folders" ] || [ "$folders" = "[]" ]; then
        return 1
    fi

    while IFS= read -r folder; do
        [ -z "$folder" ] && continue
        local fid
        fid=$(printf '%s' "$folder" | jq -r '.id // empty')
        [ -n "$fid" ] || continue
        payload=$(printf '%s' "$folder" | arr_rootfolder_with_default_profile "$profile_id")
        [ -n "$payload" ] || continue
        code=$(_arr_put_http "$port" "/api/v3/rootfolder/${fid}" "$apikey" "$payload")
        if [ "$code" -ge 200 ] && [ "$code" -lt 300 ]; then
            ok=$((ok + 1))
        fi
    done < <(printf '%s' "$folders" | jq -c '.[]' 2>/dev/null || true)

    [ "$ok" -gt 0 ]
}

arr_set_items_quality_profile() {
    local service_name="$1"
    local port="$2"
    local apikey="$3"
    local profile_id="$4"
    local kind="$5"
    local mode="${6:-all}"
    local list_path editor_path id_key items ids payload code

    if [ "$kind" = "series" ]; then
        list_path="/api/v3/series"
        editor_path="/api/v3/series/editor"
        id_key="seriesIds"
    else
        list_path="/api/v3/movie"
        editor_path="/api/v3/movie/editor"
        id_key="movieIds"
    fi

    items=$(api_get "$port" "$list_path" "$apikey" || echo "[]")
    if [ -z "$items" ] || [ "$items" = "[]" ]; then
        return 0
    fi
    ids=$(printf '%s' "$items" | arr_quality_ids_needing_update "$profile_id" "$mode")
    if [ -z "$ids" ] || [ "$ids" = "[]" ]; then
        return 0
    fi

    payload=$(jq -nc --argjson ids "$ids" --argjson pid "$profile_id" --arg key "$id_key" \
        '{($key): $ids, qualityProfileId: $pid}')
    code=$(_arr_put_http "$port" "$editor_path" "$apikey" "$payload")
    if [ "$code" -ge 200 ] && [ "$code" -lt 300 ]; then
        local n
        n=$(printf '%s' "$ids" | jq 'length' 2>/dev/null || echo 0)
        log_step "${service_name}: moved ${n} title(s) → quality profile ${profile_id}"
        return 0
    fi
    return 1
}

arr_set_importlist_quality_profile() {
    local _service_name="$1"
    local port="$2"
    local apikey="$3"
    local profile_id="$4"
    local lists list payload code ok=0 total=0

    lists=$(api_get "$port" "/api/v3/importlist" "$apikey" || echo "[]")
    if [ -z "$lists" ] || [ "$lists" = "[]" ]; then
        return 0
    fi

    while IFS= read -r list; do
        [ -z "$list" ] && continue
        local lid cur
        lid=$(printf '%s' "$list" | jq -r '.id // empty')
        cur=$(printf '%s' "$list" | jq -r '.qualityProfileId // empty')
        [ -n "$lid" ] || continue
        total=$((total + 1))
        if [ "$cur" = "$profile_id" ]; then
            ok=$((ok + 1))
            continue
        fi
        payload=$(printf '%s' "$list" | jq --argjson pid "$profile_id" '.qualityProfileId = $pid')
        code=$(_arr_put_http "$port" "/api/v3/importlist/${lid}" "$apikey" "$payload")
        if [ "$code" -ge 200 ] && [ "$code" -lt 300 ]; then
            ok=$((ok + 1))
        fi
    done < <(printf '%s' "$lists" | jq -c '.[]' 2>/dev/null || true)

    [ "$total" -eq 0 ] || [ "$ok" -gt 0 ]
}

# *arr Add New defaults to quality profile id 1 (stock "Any").
# Promote the chosen assemblrr profile onto id 1 so Add Movie/Series opens on it.
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

    local id1_name
    id1_name=$(api_get "$port" "/api/v3/qualityprofile/1" "$apikey" 2>/dev/null | jq -r '.name // empty' || true)
    if [ "$id1_name" = "$src_name" ]; then
        return 0
    fi

    local src dest tmp_name tmp_payload code
    src=$(api_get "$port" "/api/v3/qualityprofile/${src_id}" "$apikey" || echo "")
    if [ -z "$src" ] || ! printf '%s' "$src" | jq -e '.id' >/dev/null 2>&1; then
        return 1
    fi

    tmp_name="${src_name}.__assemblrr_tmp"
    tmp_payload=$(printf '%s' "$src" | jq --arg n "$tmp_name" '.name = $n')
    code=$(_arr_put_http "$port" "/api/v3/qualityprofile/${src_id}" "$apikey" "$tmp_payload")
    if [ "$code" -lt 200 ] || [ "$code" -ge 300 ]; then
        return 1
    fi

    dest=$(printf '%s' "$src" | arr_quality_profile_clone_json 1 "$src_name")
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

clean_legacy_arr_quality_profiles() {
    local _service_name="$1"
    local port="$2"
    local apikey="$3"

    local profiles
    profiles=$(api_get "$port" "/api/v3/qualityprofile" "$apikey" || echo "")
    [ -n "$profiles" ] || return 0

    local legacy_names=(
        "assemblrr HD Bluray + WEB"
        "assemblrr UHD Bluray + WEB"
        "assemblrr WEB-1080p"
        "assemblrr WEB-2160p"
    )
    local lname lid
    for lname in "${legacy_names[@]}"; do
        lid=$(printf '%s' "$profiles" | jq -r --arg n "$lname" '.[] | select(.name == $n) | .id // empty' 2>/dev/null || true)
        if [ -n "$lid" ] && [ "$lid" != "1" ]; then
            api_delete "$port" "/api/v3/qualityprofile/${lid}" "$apikey" >/dev/null 2>&1 || true
        fi
    done
}

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

    clean_legacy_arr_quality_profiles "$service_name" "$port" "$apikey"

    arr_set_root_folder_quality_profile "$service_name" "$port" "$apikey" "$profile_id" || true
    arr_set_importlist_quality_profile "$service_name" "$port" "$apikey" "$profile_id" || true

    log_step "${service_name}: default quality profile → ${profile_name} (id ${profile_id})"
}

lookup_arr_quality_profile() {
    local apikey="$1"
    local port="$2"
    local kind="$3"
    local profiles_json spec

    profiles_json=$(api_get "$port" "/api/v3/qualityprofile" "$apikey" || echo "")
    if [ -z "$profiles_json" ]; then
        echo "1:Any"
        return
    fi

    spec=$(quality_profile_names "$kind")
    printf '%s' "$profiles_json" | arr_match_quality_profile "${spec%%|*}" "${spec##*|}"
}

lookup_radarr_profile() {
    lookup_arr_quality_profile "$1" 7878 radarr
}

lookup_sonarr_profile() {
    lookup_arr_quality_profile "$1" 8989 sonarr
}
