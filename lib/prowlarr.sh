#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# assemblrr Prowlarr wiring, indexer sync, Gluetun HTTP proxy, and Byparr solver
# Requires: lib/core.sh, lib/api.sh, lib/qbit.sh

if [ -n "${_ASSEMBLRR_PROWLARR_SOURCED:-}" ]; then
    return 0
fi
readonly _ASSEMBLRR_PROWLARR_SOURCED=1

readonly PROWLARR_GLUETUN_PROXY_NAME="assemblrr Gluetun"
readonly PROWLARR_GLUETUN_PROXY_HOST="gluetun"
readonly PROWLARR_GLUETUN_PROXY_PORT="8888"

readonly PROWLARR_BYPARR_PROXY_NAME="assemblrr Byparr"
readonly PROWLARR_BYPARR_HOST="http://byparr:8191/"
readonly PROWLARR_BYPARR_TAG="byparr"

_prowlarr_byparr_enabled() {
    case "${BYPARR_ENABLED:-n}" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

prowlarr_set_app_profile_min_seeders() {
    local prowlarr_key="$1"
    local profiles
    profiles=$(api_get "9696" "/api/v1/appprofile" "$prowlarr_key" || echo "")
    if [ -z "$profiles" ] || [ "$profiles" = "[]" ]; then
        return 1
    fi

    local updated=0 row profile_id profile_payload
    while IFS= read -r row; do
        [ -z "$row" ] && continue
        profile_id=$(printf '%s' "$row" | jq -r '.id // empty')
        [ -z "$profile_id" ] && continue
        profile_payload=$(printf '%s' "$row" | jq '.minimumSeeders = 0' 2>/dev/null || echo "")
        [ -z "$profile_payload" ] && continue
        if api_put "9696" "/api/v1/appprofile/${profile_id}" "$prowlarr_key" "$profile_payload" >/dev/null 2>&1; then
            updated=$((updated + 1))
        fi
    done < <(printf '%s' "$profiles" | jq -c '.[]' 2>/dev/null || true)

    if [ "$updated" -gt 0 ]; then
        log_step "Prowlarr: app profile minimumSeeders → 0"
        return 0
    fi
    return 1
}

arr_set_indexer_min_seeders() {
    local service_name="$1"
    local port="$2"
    local apikey="$3"

    [ -z "$apikey" ] && return 1

    local indexers
    indexers=$(api_get "$port" "/api/v3/indexer" "$apikey" || echo "")
    if [ -z "$indexers" ] || [ "$indexers" = "[]" ]; then
        return 1
    fi

    local ok=0 idx idx_id idx_payload result
    while IFS= read -r idx; do
        [ -z "$idx" ] && continue
        idx_id=$(printf '%s' "$idx" | jq -r '.id // empty')
        [ -z "$idx_id" ] && continue
        idx_payload=$(printf '%s' "$idx" | jq '
            .fields = [.fields[] |
                if .name == "minimumSeeders" then .value = 0
                else . end
            ]
        ' 2>/dev/null || echo "")
        [ -z "$idx_payload" ] && continue
        result=$(api_put "$port" "/api/v3/indexer/${idx_id}" "$apikey" "$idx_payload" || echo "")
        if printf '%s' "$result" | jq -e '.id' >/dev/null 2>&1; then
            ok=$((ok + 1))
        fi
    done < <(printf '%s' "$indexers" | jq -c '.[]' 2>/dev/null || true)

    if [ "$ok" -gt 0 ]; then
        log_step "${service_name}: indexer minSeeders=0 (${ok})"
        return 0
    fi
    return 1
}

_radarr_has_indexers() {
    local radarr_key="$1"
    local rc
    rc=$(api_get "7878" "/api/v3/indexer" "$radarr_key" 2>/dev/null | jq 'length' 2>/dev/null || echo 0)
    [ "${rc:-0}" -gt 0 ]
}

wait_for_arr_indexer_sync() {
    local radarr_key="${1:-}"
    [ -z "$radarr_key" ] && return 0
    wait_until "Waiting for Radarr indexers from Prowlarr" 30 2 _radarr_has_indexers "$radarr_key"
}

_prowlarr_gluetun_proxy_id() {
    local proxies="$1"
    local mode="${2:-any}"
    printf '%s' "$proxies" | jq -r \
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
    printf '%s' "$schema" | jq -c \
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

    proxies=$(api_get "9696" "/api/v1/indexerProxy" "$apikey" || echo "")
    if [ -z "$proxies" ]; then
        log_step_fail "Prowlarr: could not list search proxies"
        return 1
    fi

    if ! stack_vpn_enabled; then
        existing_id=$(_prowlarr_gluetun_proxy_id "$proxies" "name")
        [ -z "$existing_id" ] && return 0
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
    schema=$(api_get "9696" "/api/v1/indexerProxy/schema" "$apikey" || echo "")
    payload=$(_prowlarr_gluetun_proxy_payload "$schema")
    if [ -z "$payload" ]; then
        log_step_fail "Prowlarr: could not set up VPN search routing"
        return 1
    fi

    if [ -n "$existing_id" ]; then
        payload=$(printf '%s' "$payload" | jq -c --argjson id "$existing_id" '.id = $id' 2>/dev/null || echo "$payload")
        result=$(api_put_force "9696" "/api/v1/indexerProxy/${existing_id}" "$apikey" "$payload" || echo "")
    else
        result=$(api_post_force "9696" "/api/v1/indexerProxy" "$apikey" "$payload" || echo "")
    fi

    if jq_json_has_key "$result" "id"; then
        log_step "Prowlarr: searches go through the VPN"
        return 0
    fi
    log_step_fail "Prowlarr: could not send searches through the VPN"
    return 1
}

_prowlarr_ensure_tag() {
    local apikey="$1"
    local label="$2"
    local tags tid created
    tags=$(api_get "9696" "/api/v1/tag" "$apikey" || echo "[]")
    tid=$(printf '%s' "$tags" | jq -r --arg l "$label" \
        '[.[] | select((.label // "") | ascii_downcase == ($l | ascii_downcase))][0].id // empty' 2>/dev/null || true)
    if [ -n "$tid" ]; then
        echo "$tid"
        return 0
    fi
    created=$(api_post "9696" "/api/v1/tag" "$apikey" "$(jq -nc --arg l "$label" '{label:$l}')" || echo "")
    tid=$(printf '%s' "$created" | jq -r '.id // empty' 2>/dev/null || true)
    [ -n "$tid" ] && echo "$tid"
}

_byparr_is_ready() {
    command -v docker >/dev/null 2>&1 || return 0
    local st
    st=$(docker inspect --format='{{.State.Health.Status}}' byparr 2>/dev/null || echo "")
    [ "$st" = "healthy" ]
}

# Sync Byparr (FlareSolverr-compatible API solver) in Prowlarr.
prowlarr_sync_byparr_proxy() {
    local apikey="$1"
    [ -n "$apikey" ] || return 1

    local proxies existing_id
    proxies=$(api_get "9696" "/api/v1/indexerProxy" "$apikey" || echo "")
    [ -n "$proxies" ] || return 1

    existing_id=$(printf '%s' "$proxies" | jq -r --arg name "$PROWLARR_BYPARR_PROXY_NAME" '
        [.[] | select(.name == $name or .implementation == "FlareSolverr")][0].id // empty
    ' 2>/dev/null || true)

    if ! _prowlarr_byparr_enabled; then
        [ -z "$existing_id" ] && return 0
        # Only delete the proxy assemblrr manages
        local managed_id
        managed_id=$(printf '%s' "$proxies" | jq -r --arg name "$PROWLARR_BYPARR_PROXY_NAME" \
            '[.[] | select(.name == $name)][0].id // empty' 2>/dev/null || true)
        [ -z "$managed_id" ] && return 0
        local code
        code=$(api_delete "9696" "/api/v1/indexerProxy/${managed_id}" "$apikey")
        if [ "$code" = "200" ] || [ "$code" = "204" ]; then
            log_step "Prowlarr: removed Byparr solver proxy"
            return 0
        fi
        log_step_fail "Prowlarr: could not remove Byparr proxy (HTTP ${code:-?})"
        return 1
    fi

    # Wait for Byparr's initial GeoIP/browser warmup so Prowlarr's synchronous proxy test succeeds.
    if command -v docker >/dev/null 2>&1 && docker inspect byparr >/dev/null 2>&1; then
        wait_until "Waiting for Byparr solver" 60 2 _byparr_is_ready || true
    fi

    local tag_id schema payload result
    tag_id=$(_prowlarr_ensure_tag "$apikey" "$PROWLARR_BYPARR_TAG" || true)
    schema=$(api_get "9696" "/api/v1/indexerProxy/schema" "$apikey" || echo "")
    if [ -n "$tag_id" ]; then
        payload=$(printf '%s' "$schema" | jq -c \
            --arg name "$PROWLARR_BYPARR_PROXY_NAME" \
            --arg host "$PROWLARR_BYPARR_HOST" \
            --argjson tid "$tag_id" '
            [.[] | select(.implementation == "FlareSolverr")][0] |
            .fields = [.fields[] |
                if .name == "host" then .value = $host
                elif .name == "requestTimeout" then .value = 60
                else . end
            ] |
            .name = $name | .tags = [$tid]
        ' 2>/dev/null || echo "")
    else
        payload=$(printf '%s' "$schema" | jq -c \
            --arg name "$PROWLARR_BYPARR_PROXY_NAME" \
            --arg host "$PROWLARR_BYPARR_HOST" '
            [.[] | select(.implementation == "FlareSolverr")][0] |
            .fields = [.fields[] |
                if .name == "host" then .value = $host
                elif .name == "requestTimeout" then .value = 60
                else . end
            ] |
            .name = $name | .tags = []
        ' 2>/dev/null || echo "")
    fi

    if [ -z "$payload" ]; then
        log_step_fail "Prowlarr: FlareSolverr/Byparr proxy schema not found"
        return 1
    fi

    if [ -n "$existing_id" ]; then
        payload=$(printf '%s' "$payload" | jq -c --argjson id "$existing_id" '.id = $id' 2>/dev/null || echo "$payload")
        result=$(api_put_force "9696" "/api/v1/indexerProxy/${existing_id}" "$apikey" "$payload" || echo "")
    else
        result=$(api_post_force "9696" "/api/v1/indexerProxy" "$apikey" "$payload" || echo "")
    fi

    if jq_json_has_key "$result" "id"; then
        log_step "Prowlarr: Byparr Cloudflare solver wired (${PROWLARR_BYPARR_HOST}, tag: ${PROWLARR_BYPARR_TAG})"
        return 0
    fi
    log_step_fail "Prowlarr: failed to wire Byparr proxy"
    return 1
}

apply_selected_indexers() {
    local apikey="$1"
    local indexer_schemas
    indexer_schemas=$(api_get "9696" "/api/v1/indexer/schema" "$apikey" || echo "")

    if [ -z "$indexer_schemas" ]; then
        log_step_fail "Prowlarr: failed to fetch indexer schemas"
        return 1
    fi

    local selected_indexers=()
    if [ -n "${SELECTED_INDEXERS+x}" ] && [ "${#SELECTED_INDEXERS[@]}" -gt 0 ]; then
        selected_indexers=("${SELECTED_INDEXERS[@]}")
        echo "Applying ${#selected_indexers[@]} selected Prowlarr indexer(s)" >&2
    fi

    local existing_indexers existing_names indexer_name
    existing_indexers=$(api_get "9696" "/api/v1/indexer" "$apikey" || echo "[]")
    existing_names=$(jq_json_list_values "$existing_indexers" "name")

    for indexer_name in "${selected_indexers[@]+"${selected_indexers[@]}"}"; do
        if printf '%s\n' "$existing_names" | grep -q -F -x "$indexer_name"; then
            log_step "Prowlarr: ${indexer_name} indexer already exists"
            continue
        fi

        # Prefer exact case-insensitive match before falling back to prefix match.
        local indexer_payload
        indexer_payload=$(printf '%s' "$indexer_schemas" | jq --arg idx "$indexer_name" '
            (
              [.[] | select((.name | ascii_downcase) == ($idx | ascii_downcase))][0]
              // [.[] | select(.name | ascii_downcase | startswith($idx | ascii_downcase))][0]
            ) |
            .fields = [.fields[] | select(.value != "") | {name: .name, value: .value}] |
            .enable = true | .enableAutoSearch = true | .appProfileId = 1 | .priority = (.priority // 25)
        ' 2>/dev/null || echo "")

        if [ -z "$indexer_payload" ]; then
            log_step_fail "Prowlarr: ${indexer_name} schema not found"
            continue
        fi

        local idx_result
        idx_result=$(api_post_force "9696" "/api/v1/indexer" "$apikey" "$indexer_payload" || echo "")
        if jq_json_has_key "$idx_result" "id"; then
            log_step "Prowlarr: added ${indexer_name} indexer"
        else
            local err_msg disabled_payload
            err_msg=$(printf '%s' "$idx_result" | jq -r 'if type == "array" then .[0].errorMessage // empty else .errorMessage // empty end' 2>/dev/null || echo "")
            disabled_payload=$(printf '%s' "$indexer_payload" | jq -c '.enable = false' 2>/dev/null || echo "")
            idx_result=$(api_post_force "9696" "/api/v1/indexer" "$apikey" "$disabled_payload" || echo "")
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

sync_selected_indexers() {
    local apikey="$1"
    apply_selected_indexers "$apikey" || return 1

    local existing_indexers
    existing_indexers=$(api_get "9696" "/api/v1/indexer" "$apikey" || echo "[]")
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
    done < <(printf '%s' "$existing_indexers" | jq -r '.[] | "\(.id)\t\(.name)"' 2>/dev/null)
    return 0
}

configure_prowlarr() {
    local apikey="$1"
    local radarr_apikey="$2"
    local sonarr_apikey="${3:-}"
    local critical_errors=0

    # 1. App profile min seeders (best-effort)
    prowlarr_set_app_profile_min_seeders "$apikey" || true

    # 2. Add Radarr and Sonarr as connected applications
    local apps existing_impls app_schema=""
    apps=$(api_get "9696" "/api/v1/applications" "$apikey" || echo "[]")
    existing_impls=$(jq_json_list_values "$apps" "implementationName")

    if ! printf '%s\n' "$existing_impls" | grep -Fxq "Radarr"; then
        if [ -z "$radarr_apikey" ]; then
            log_step_fail "Prowlarr: Radarr API key missing — cannot connect application"
            critical_errors=$((critical_errors + 1))
        else
            app_schema=$(api_get "9696" "/api/v1/applications/schema" "$apikey" || echo "[]")
            local app_payload app_result
            app_payload=$(printf '%s' "$app_schema" | jq --arg prowlarr_url "$PROWLARR_DOCKER_URL" --arg radarr_url "$RADARR_DOCKER_URL" --arg radarr_key "$radarr_apikey" '
                [.[] | select(.implementationName == "Radarr")][0] |
                .fields = [.fields[] | if .name == "prowlarrUrl" then .value = $prowlarr_url elif .name == "baseUrl" then .value = $radarr_url elif .name == "apiKey" then .value = $radarr_key elif .name == "syncCategories" then .value = [2000] elif .name == "syncRejectBlocklistedTorrentHashesWhileGrabbing" then .value = false else . end] |
                .enable = true | .syncLevel = "fullSync" | .name = "Radarr" | .priority = (.priority // 25) | .tags = []
            ' 2>/dev/null || echo "")
            if [ -z "$app_payload" ]; then
                log_step_fail "Prowlarr: Radarr application schema not found"
                critical_errors=$((critical_errors + 1))
            else
                app_result=$(api_post_force "9696" "/api/v1/applications" "$apikey" "$app_payload" || echo "")
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

    if [ -n "$sonarr_apikey" ]; then
        if ! printf '%s\n' "$existing_impls" | grep -Fxq "Sonarr"; then
            [ -z "$app_schema" ] && app_schema=$(api_get "9696" "/api/v1/applications/schema" "$apikey" || echo "[]")
            local sonarr_app_payload sonarr_app_result
            sonarr_app_payload=$(printf '%s' "$app_schema" | jq --arg prowlarr_url "$PROWLARR_DOCKER_URL" --arg sonarr_url "$SONARR_DOCKER_URL" --arg sonarr_key "$sonarr_apikey" '
                [.[] | select(.implementationName == "Sonarr")][0] |
                .fields = [.fields[] | if .name == "prowlarrUrl" then .value = $prowlarr_url elif .name == "baseUrl" then .value = $sonarr_url elif .name == "apiKey" then .value = $sonarr_key elif .name == "syncCategories" then .value = [5000, 5010, 5020, 5030, 5040, 5045, 5050, 5090] elif .name == "animeSyncCategories" then .value = [5070] elif .name == "syncRejectBlocklistedTorrentHashesWhileGrabbing" then .value = false else . end] |
                .enable = true | .syncLevel = "fullSync" | .name = "Sonarr" | .priority = (.priority // 25) | .tags = []
            ' 2>/dev/null || echo "")
            if [ -z "$sonarr_app_payload" ]; then
                log_step_fail "Prowlarr: Sonarr application schema not found"
                critical_errors=$((critical_errors + 1))
            else
                sonarr_app_result=$(api_post_force "9696" "/api/v1/applications" "$apikey" "$sonarr_app_payload" || echo "")
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

    # 3. Search proxy via Gluetun when VPN is on
    if ! prowlarr_sync_gluetun_proxy "$apikey"; then
        critical_errors=$((critical_errors + 1))
    fi

    # 4. Byparr solver proxy (best-effort optional feature)
    prowlarr_sync_byparr_proxy "$apikey" || true

    # 5. Selected indexers + minSeeders sync
    apply_selected_indexers "$apikey"
    wait_for_arr_indexer_sync "$radarr_apikey" || true
    arr_set_indexer_min_seeders "Radarr" "7878" "$radarr_apikey" || true
    arr_set_indexer_min_seeders "Sonarr" "8989" "$sonarr_apikey" || true

    # 6. Forms authentication
    if ! set_arr_auth "Prowlarr" "9696" "$apikey" "v1"; then
        critical_errors=$((critical_errors + 1))
    fi

    [ "$critical_errors" -eq 0 ]
}
